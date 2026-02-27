// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RoundPrizeVault
 * @notice Holds the round prize pool and pays out the underlying goal token.
 *
 *         Funds can come from:
 *         - Accepted submission deposits routed via a SubmissionDepositStrategy (underlying goal token).
 *         - Budget flow streams (goal super token) sent to this vault as a Flow recipient.
 *
 *         Payouts are always made in the underlying goal token. If the vault only has super tokens
 *         available, it can downgrade on-demand.
 */
contract RoundPrizeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ADDRESS_ZERO();
    error ONLY_OPERATOR();
    error ONLY_SUBMITTER();
    error SUBMISSION_NOT_REGISTERED();
    error NOTHING_TO_CLAIM();
    error ENTITLEMENT_LT_CLAIMED(uint256 entitlement, uint256 claimed);
    error INSUFFICIENT_UNDERLYING(uint256 required, uint256 available);
    error SUPER_TOKEN_NOT_CONFIGURED();
    error LENGTH_MISMATCH();

    event OperatorSet(address indexed previousOperator, address indexed newOperator);
    event EntitlementRecipientSnapshotted(bytes32 indexed submissionId, address indexed recipient);
    event EntitlementSet(bytes32 indexed submissionId, uint256 entitlement);
    event Claimed(bytes32 indexed submissionId, address indexed recipient, uint256 amount);
    event Downgraded(uint256 amount);

    IERC20 public immutable underlyingToken;
    ISuperToken public immutable superToken;
    RoundSubmissionTCR public immutable submissionsTCR;

    address public operator;

    /// @notice Total payout entitlement per submission.
    mapping(bytes32 => uint256) public entitlementOf;
    /// @notice Amount already claimed per submission.
    mapping(bytes32 => uint256) public claimedOf;
    /// @notice Snapshotted payout recipient for a submission.
    mapping(bytes32 => address) public payoutRecipientOf;

    constructor(
        IERC20 underlyingToken_,
        ISuperToken superToken_,
        RoundSubmissionTCR submissionsTCR_,
        address operator_
    ) {
        if (address(underlyingToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(submissionsTCR_) == address(0)) revert ADDRESS_ZERO();
        if (operator_ == address(0)) revert ADDRESS_ZERO();

        underlyingToken = underlyingToken_;
        superToken = superToken_;
        submissionsTCR = submissionsTCR_;
        operator = operator_;
        emit OperatorSet(address(0), operator_);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert ONLY_OPERATOR();
        _;
    }

    function setOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ADDRESS_ZERO();
        address prev = operator;
        operator = newOperator;
        emit OperatorSet(prev, newOperator);
    }

    /// @notice Sets the total entitlement for a submission. May be called multiple times.
    /// @dev Enforces entitlement >= already-claimed.
    function setEntitlement(bytes32 submissionId, uint256 entitlement) external onlyOperator {
        uint256 alreadyClaimed = claimedOf[submissionId];
        if (entitlement < alreadyClaimed) revert ENTITLEMENT_LT_CLAIMED(entitlement, alreadyClaimed);
        _snapshotRecipientIfUnset(submissionId, entitlement);
        entitlementOf[submissionId] = entitlement;
        emit EntitlementSet(submissionId, entitlement);
    }

    function setEntitlements(bytes32[] calldata submissionIds, uint256[] calldata entitlements) external onlyOperator {
        uint256 length = submissionIds.length;
        if (length != entitlements.length) revert LENGTH_MISMATCH();
        for (uint256 i = 0; i < length;) {
            bytes32 submissionId = submissionIds[i];
            uint256 entitlement = entitlements[i];
            uint256 alreadyClaimed = claimedOf[submissionId];
            if (entitlement < alreadyClaimed) revert ENTITLEMENT_LT_CLAIMED(entitlement, alreadyClaimed);
            _snapshotRecipientIfUnset(submissionId, entitlement);
            entitlementOf[submissionId] = entitlement;
            emit EntitlementSet(submissionId, entitlement);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claim any unclaimed entitlement for the caller's submission.
    function claim(bytes32 submissionId) external nonReentrant returns (uint256 amount) {
        address recipient = payoutRecipientOf[submissionId];
        if (recipient != msg.sender) revert ONLY_SUBMITTER();

        uint256 total = entitlementOf[submissionId];
        uint256 already = claimedOf[submissionId];
        if (total <= already) revert NOTHING_TO_CLAIM();

        amount = total - already;
        claimedOf[submissionId] = total;

        _ensureUnderlying(amount);
        underlyingToken.safeTransfer(msg.sender, amount);

        emit Claimed(submissionId, msg.sender, amount);
    }

    function _snapshotRecipientIfUnset(bytes32 submissionId, uint256 entitlement) internal {
        if (entitlement == 0 || payoutRecipientOf[submissionId] != address(0)) return;
        (address manager, IGeneralizedTCR.Status status) = submissionsTCR.itemManagerAndStatus(submissionId);
        if (manager == address(0) || status != IGeneralizedTCR.Status.Registered) revert SUBMISSION_NOT_REGISTERED();
        payoutRecipientOf[submissionId] = manager;
        emit EntitlementRecipientSnapshotted(submissionId, manager);
    }

    /// @notice Permissionless helper to downgrade super tokens into underlying tokens.
    function downgrade(uint256 amount) external nonReentrant {
        if (address(superToken) == address(0)) revert SUPER_TOKEN_NOT_CONFIGURED();
        if (amount == 0) return;
        superToken.downgrade(amount);
        emit Downgraded(amount);
    }

    function _ensureUnderlying(uint256 required) internal {
        uint256 bal = underlyingToken.balanceOf(address(this));
        if (bal >= required) return;

        if (address(superToken) == address(0)) revert INSUFFICIENT_UNDERLYING(required, bal);

        uint256 missing = required - bal;
        uint256 superBal = superToken.balanceOf(address(this));
        if (superBal == 0) revert INSUFFICIENT_UNDERLYING(required, bal);

        uint256 toDowngrade = missing > superBal ? superBal : missing;
        superToken.downgrade(toDowngrade);
        emit Downgraded(toDowngrade);

        uint256 afterBal = underlyingToken.balanceOf(address(this));
        if (afterBal < required) revert INSUFFICIENT_UNDERLYING(required, afterBal);
    }
}
