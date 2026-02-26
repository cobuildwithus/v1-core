// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUMATreasurySuccessResolverConfig} from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";
import {ISuccessAssertionTreasury} from "src/interfaces/ISuccessAssertionTreasury.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";

/// @notice Test-only resolver that acts as both resolver config and OOv3 endpoint.
/// @dev Intended for non-production deployments where resolver actions are manually controlled by owner.
contract FakeUMATreasurySuccessResolver is Ownable, IUMATreasurySuccessResolverConfig, OptimisticOracleV3Interface {
    bytes32 internal constant UMA_ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address target);
    error ASSERTION_NOT_FOUND(bytes32 assertionId);
    error ASSERTION_NOT_SETTLED(bytes32 assertionId);
    error UNSUPPORTED();

    event AssertionPrepared(address indexed treasury, bytes32 indexed assertionId, bool settlementResolution);
    event TreasurySuccessResolved(address indexed treasury);

    OptimisticOracleV3Interface public immutable override optimisticOracle;
    IERC20 public immutable override assertionCurrency;
    address public immutable override escalationManager;
    bytes32 public immutable override domainId;

    mapping(bytes32 assertionId => Assertion assertionData) internal _assertions;
    mapping(bytes32 assertionId => bool exists) internal _assertionExists;

    constructor(IERC20 assertionCurrency_, address escalationManager_, bytes32 domainId_, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(assertionCurrency_) == address(0)) revert ADDRESS_ZERO();
        optimisticOracle = OptimisticOracleV3Interface(address(this));
        assertionCurrency = assertionCurrency_;
        escalationManager = escalationManager_;
        domainId = domainId_;
    }

    /// @notice Register a pending success assertion on a treasury and mark it settled in this fake oracle.
    /// @dev Must be called by owner. `truthful` controls whether treasury can be resolved as success.
    function prepareAssertionForTreasury(address treasury, bool truthful)
        external
        onlyOwner
        returns (bytes32 assertionId)
    {
        assertionId = _prepareAssertionForTreasury(treasury, truthful);
    }

    /// @notice Convenience helper for success path in tests.
    function prepareTruthfulAssertionForTreasury(address treasury) external onlyOwner returns (bytes32 assertionId) {
        assertionId = _prepareAssertionForTreasury(treasury, true);
    }

    /// @notice Owner-triggered wrapper to call `resolveSuccess()` on a treasury.
    function resolveTreasurySuccess(address treasury) external onlyOwner {
        if (treasury.code.length == 0) revert NOT_A_CONTRACT(treasury);
        ISuccessAssertionTreasury(treasury).resolveSuccess();
        emit TreasurySuccessResolved(treasury);
    }

    function setSettlementResolution(bytes32 assertionId, bool truthful) external onlyOwner {
        _requireAssertionExists(assertionId);
        _assertions[assertionId].settlementResolution = truthful;
    }

    function setAssertionTail(bytes32 assertionId, uint64 assertedAt, uint64 liveness, uint256 bond)
        external
        onlyOwner
    {
        _requireAssertionExists(assertionId);
        Assertion storage a = _assertions[assertionId];
        a.assertionTime = assertedAt;
        a.expirationTime = assertedAt + liveness;
        a.bond = bond;
    }

    // ---- OptimisticOracleV3Interface ----

    function getAssertion(bytes32 assertionId) external view override returns (Assertion memory) {
        _requireAssertionExists(assertionId);
        return _assertions[assertionId];
    }

    function defaultIdentifier() external pure override returns (bytes32) {
        return UMA_ASSERT_TRUTH_IDENTIFIER;
    }

    function settleAssertion(bytes32 assertionId) external view override {
        _requireSettled(assertionId);
    }

    function settleAndGetAssertionResult(bytes32 assertionId) external view override returns (bool) {
        _requireSettled(assertionId);
        return _assertions[assertionId].settlementResolution;
    }

    function getAssertionResult(bytes32 assertionId) external view override returns (bool) {
        _requireSettled(assertionId);
        return _assertions[assertionId].settlementResolution;
    }

    function getMinimumBond(address) external pure override returns (uint256) {
        return 0;
    }

    function assertTruthWithDefaults(bytes memory, address) external pure override returns (bytes32) {
        revert UNSUPPORTED();
    }

    function assertTruth(bytes memory, address, address, address, uint64, IERC20, uint256, bytes32, bytes32)
        external
        pure
        override
        returns (bytes32)
    {
        revert UNSUPPORTED();
    }

    function disputeAssertion(bytes32, address) external pure override {
        revert UNSUPPORTED();
    }

    function syncUmaParams(bytes32, address) external pure override {
        revert UNSUPPORTED();
    }

    function _prepareAssertionForTreasury(address treasury, bool truthful) internal returns (bytes32 assertionId) {
        if (treasury == address(0)) revert ADDRESS_ZERO();

        ISuccessAssertionTreasury successTreasury = ISuccessAssertionTreasury(treasury);
        assertionId = keccak256(abi.encodePacked(address(this), treasury, block.chainid, block.number, block.timestamp));
        successTreasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = successTreasury.pendingSuccessAssertionAt();
        uint64 liveness = successTreasury.successAssertionLiveness();
        uint256 bond = successTreasury.successAssertionBond();

        Assertion storage a = _assertions[assertionId];
        _assertionExists[assertionId] = true;
        a.assertionTime = assertedAt;
        a.expirationTime = assertedAt + liveness;
        a.identifier = UMA_ASSERT_TRUTH_IDENTIFIER;
        a.currency = assertionCurrency;
        a.domainId = domainId;
        a.escalationManagerSettings.assertingCaller = address(this);
        a.escalationManagerSettings.escalationManager = escalationManager;
        a.callbackRecipient = address(this);
        a.asserter = address(this);
        a.bond = bond;
        a.settled = true;
        a.settlementResolution = truthful;
        a.disputer = address(0);

        emit AssertionPrepared(treasury, assertionId, truthful);
    }

    function _requireAssertionExists(bytes32 assertionId) internal view {
        if (!_assertionExists[assertionId]) revert ASSERTION_NOT_FOUND(assertionId);
    }

    function _requireSettled(bytes32 assertionId) internal view {
        _requireAssertionExists(assertionId);
        if (!_assertions[assertionId].settled) revert ASSERTION_NOT_SETTLED(assertionId);
    }
}
