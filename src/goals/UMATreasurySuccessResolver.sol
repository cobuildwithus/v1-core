// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISuccessAssertionTreasury } from "src/interfaces/ISuccessAssertionTreasury.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import { OptimisticOracleV3CallbackRecipientInterface } from "src/interfaces/uma/OptimisticOracleV3CallbackRecipientInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

contract UMATreasurySuccessResolver is OptimisticOracleV3CallbackRecipientInterface, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AssertionMeta {
        address treasury;
        address asserter;
        uint64 assertedAt;
        ISuccessAssertionTreasury.TreasuryKind kind;
        bool disputed;
        bool resolved;
        bool truthful;
        bool finalized;
    }

    error ADDRESS_ZERO();
    error EVIDENCE_TOO_LONG(uint256 maxLength, uint256 actualLength);
    error INVALID_ASSERTION_CONFIG();
    error INVALID_TREASURY();
    error ONLY_ORACLE();
    error ASSERTION_ALREADY_ACTIVE(bytes32 assertionId);
    error ASSERTION_NOT_FOUND();
    error ASSERTION_NOT_RESOLVED();
    error ASSERTION_ALREADY_FINALIZED();
    error ASSERTION_NOT_ACTIVE(bytes32 expected, bytes32 actual);
    error TREASURY_NOT_CONFIGURED_FOR_RESOLVER(address expectedResolver, address actualResolver);
    error TREASURY_PENDING_ASSERTION_MISMATCH(bytes32 expected, bytes32 actual);
    error TREASURY_RESOLVE_SUCCESS_FAILED(address treasury, bytes32 assertionId);
    error TREASURY_CLEAR_ASSERTION_FAILED(address treasury, bytes32 assertionId);

    event SuccessAssertionRequested(
        bytes32 indexed assertionId,
        address indexed treasury,
        address indexed asserter,
        ISuccessAssertionTreasury.TreasuryKind kind,
        uint64 liveness,
        uint256 bond,
        string evidence
    );

    event SuccessAssertionDisputed(bytes32 indexed assertionId, address indexed treasury);
    event SuccessAssertionResolved(bytes32 indexed assertionId, address indexed treasury, bool truthful);
    event SuccessAssertionFinalized(bytes32 indexed assertionId, address indexed treasury, bool truthful, bool applied);

    uint256 public constant EVIDENCE_MAX_LENGTH = 2048;
    bytes32 public constant UMA_ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");

    OptimisticOracleV3Interface public immutable optimisticOracle;
    IERC20 public immutable assertionCurrency;
    address public immutable escalationManager;
    bytes32 public immutable domainId;

    mapping(address => bytes32) public activeAssertionOfTreasury;
    mapping(bytes32 => AssertionMeta) public assertionMeta;

    constructor(
        OptimisticOracleV3Interface optimisticOracle_,
        IERC20 assertionCurrency_,
        address escalationManager_,
        bytes32 domainId_
    ) {
        if (address(optimisticOracle_) == address(0) || address(assertionCurrency_) == address(0))
            revert ADDRESS_ZERO();

        optimisticOracle = optimisticOracle_;
        assertionCurrency = assertionCurrency_;
        escalationManager = escalationManager_;
        domainId = domainId_;
    }

    function assertSuccess(
        address treasury,
        string calldata evidence
    ) external nonReentrant returns (bytes32 assertionId) {
        if (bytes(evidence).length > EVIDENCE_MAX_LENGTH) {
            revert EVIDENCE_TOO_LONG(EVIDENCE_MAX_LENGTH, bytes(evidence).length);
        }

        bytes32 activeAssertionId = activeAssertionOfTreasury[treasury];
        if (activeAssertionId != bytes32(0)) revert ASSERTION_ALREADY_ACTIVE(activeAssertionId);

        ISuccessAssertionTreasury.TreasuryKind kind = _detectTreasuryKind(treasury);
        ISuccessAssertionTreasury successTreasury = ISuccessAssertionTreasury(treasury);

        address configuredResolver = successTreasury.successResolver();
        if (configuredResolver != address(this)) {
            revert TREASURY_NOT_CONFIGURED_FOR_RESOLVER(address(this), configuredResolver);
        }

        uint64 liveness = successTreasury.successAssertionLiveness();
        uint256 configuredBond = successTreasury.successAssertionBond();
        bytes32 specHash = successTreasury.successOracleSpecHash();
        bytes32 policyHash = successTreasury.successAssertionPolicyHash();
        if (liveness == 0 || specHash == bytes32(0) || policyHash == bytes32(0)) revert INVALID_ASSERTION_CONFIG();

        optimisticOracle.syncUmaParams(UMA_ASSERT_TRUTH_IDENTIFIER, address(assertionCurrency));

        uint256 minimumBond = optimisticOracle.getMinimumBond(address(assertionCurrency));
        uint256 bond = configuredBond > minimumBond ? configuredBond : minimumBond;

        assertionCurrency.safeTransferFrom(msg.sender, address(this), bond);
        assertionCurrency.forceApprove(address(optimisticOracle), bond);

        uint64 assertedAt = uint64(block.timestamp);
        bytes memory claim = _buildClaim(treasury, kind, assertedAt, specHash, policyHash, evidence);
        assertionId = optimisticOracle.assertTruth(
            claim,
            msg.sender,
            address(this),
            escalationManager,
            liveness,
            assertionCurrency,
            bond,
            UMA_ASSERT_TRUTH_IDENTIFIER,
            domainId
        );
        assertionCurrency.forceApprove(address(optimisticOracle), 0);

        successTreasury.registerSuccessAssertion(assertionId);

        activeAssertionOfTreasury[treasury] = assertionId;
        assertionMeta[assertionId] = AssertionMeta({
            treasury: treasury,
            asserter: msg.sender,
            assertedAt: assertedAt,
            kind: kind,
            disputed: false,
            resolved: false,
            truthful: false,
            finalized: false
        });

        emit SuccessAssertionRequested(assertionId, treasury, msg.sender, kind, liveness, bond, evidence);
    }

    function settle(bytes32 assertionId) external nonReentrant {
        optimisticOracle.settleAssertion(assertionId);
    }

    function finalize(bytes32 assertionId) external nonReentrant returns (bool applied) {
        AssertionMeta storage meta = assertionMeta[assertionId];
        if (meta.treasury == address(0)) revert ASSERTION_NOT_FOUND();

        return _finalizeAssertion(assertionId, meta);
    }

    function settleAndFinalize(bytes32 assertionId) external nonReentrant returns (bool applied) {
        AssertionMeta storage meta = assertionMeta[assertionId];
        if (meta.treasury == address(0)) revert ASSERTION_NOT_FOUND();

        if (!meta.resolved) {
            optimisticOracle.settleAssertion(assertionId);
        }

        return _finalizeAssertion(assertionId, meta);
    }

    function _finalizeAssertion(bytes32 assertionId, AssertionMeta storage meta) internal returns (bool applied) {
        if (!meta.resolved) revert ASSERTION_NOT_RESOLVED();
        if (meta.finalized) revert ASSERTION_ALREADY_FINALIZED();

        address treasury = meta.treasury;
        bytes32 activeAssertionId = activeAssertionOfTreasury[treasury];
        if (activeAssertionId != assertionId) {
            revert ASSERTION_NOT_ACTIVE(assertionId, activeAssertionId);
        }

        bool assertionResult = meta.truthful;
        meta.finalized = true;
        delete activeAssertionOfTreasury[treasury];

        applied = _applyTreasuryResolution(treasury, assertionResult, assertionId);

        emit SuccessAssertionFinalized(assertionId, treasury, assertionResult, applied);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        if (msg.sender != address(optimisticOracle)) revert ONLY_ORACLE();

        AssertionMeta storage meta = assertionMeta[assertionId];
        if (meta.treasury == address(0)) return;

        meta.resolved = true;
        meta.truthful = assertedTruthfully;

        emit SuccessAssertionResolved(assertionId, meta.treasury, assertedTruthfully);
    }

    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(optimisticOracle)) revert ONLY_ORACLE();

        AssertionMeta storage meta = assertionMeta[assertionId];
        if (meta.treasury == address(0)) return;

        meta.disputed = true;

        emit SuccessAssertionDisputed(assertionId, meta.treasury);
    }

    function _applyTreasuryResolution(
        address treasury,
        bool assertionResult,
        bytes32 assertionId
    ) internal returns (bool) {
        ISuccessAssertionTreasury successTreasury = ISuccessAssertionTreasury(treasury);
        bytes32 treasuryPendingAssertionId = successTreasury.pendingSuccessAssertionId();

        if (treasuryPendingAssertionId == bytes32(0)) return false;
        if (treasuryPendingAssertionId != assertionId) {
            revert TREASURY_PENDING_ASSERTION_MISMATCH(assertionId, treasuryPendingAssertionId);
        }

        if (assertionResult) {
            try successTreasury.resolveSuccess() {
                return true;
            } catch {
                revert TREASURY_RESOLVE_SUCCESS_FAILED(treasury, assertionId);
            }
        }

        try successTreasury.clearSuccessAssertion(assertionId) {
            return false;
        } catch {
            revert TREASURY_CLEAR_ASSERTION_FAILED(treasury, assertionId);
        }
    }

    function _buildClaim(
        address treasury,
        ISuccessAssertionTreasury.TreasuryKind kind,
        uint64 assertedAt,
        bytes32 specHash,
        bytes32 policyHash,
        string calldata evidence
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                "As of assertion timestamp ",
                Strings.toString(assertedAt),
                ", treasury ",
                Strings.toHexString(uint160(treasury), 20),
                " (type: ",
                _kindLabel(kind),
                ") has satisfied the Success Specification specHash=",
                Strings.toHexString(uint256(specHash), 32),
                " and complied with Policy policyHash=",
                Strings.toHexString(uint256(policyHash), 32),
                ". Evidence: ",
                evidence
            );
    }

    function _detectTreasuryKind(address treasury) internal view returns (ISuccessAssertionTreasury.TreasuryKind) {
        if (treasury == address(0) || treasury.code.length == 0) revert INVALID_TREASURY();

        (bool ok, bytes memory returnData) = treasury.staticcall(
            abi.encodeCall(ISuccessAssertionTreasury.treasuryKind, ())
        );
        if (!ok || returnData.length != 32) revert INVALID_TREASURY();

        uint8 kindId = abi.decode(returnData, (uint8));
        if (
            kindId == uint8(ISuccessAssertionTreasury.TreasuryKind.Unknown) ||
            kindId > uint8(ISuccessAssertionTreasury.TreasuryKind.Budget)
        ) revert INVALID_TREASURY();

        return ISuccessAssertionTreasury.TreasuryKind(kindId);
    }

    function _kindLabel(ISuccessAssertionTreasury.TreasuryKind kind) internal pure returns (string memory) {
        if (kind == ISuccessAssertionTreasury.TreasuryKind.Goal) return "GOAL";
        if (kind == ISuccessAssertionTreasury.TreasuryKind.Budget) return "BUDGET";
        return "UNKNOWN";
    }
}
