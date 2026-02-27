// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ITreasuryAuthority } from "./ITreasuryAuthority.sol";
import { ITreasuryDonations } from "./ITreasuryDonations.sol";
import { ISuccessAssertionTreasury } from "./ISuccessAssertionTreasury.sol";
import { ITreasuryFlowRateSyncEvents } from "./ITreasuryFlowRateSyncEvents.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

interface IBudgetTreasury is
    ITreasuryAuthority,
    ITreasuryDonations,
    ISuccessAssertionTreasury,
    ITreasuryFlowRateSyncEvents
{
    enum BudgetState {
        Funding,
        Active,
        Succeeded,
        Failed,
        Expired
    }

    struct BudgetConfig {
        address flow;
        uint64 fundingDeadline;
        uint64 executionDuration;
        uint256 activationThreshold;
        uint256 runwayCap;
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
    }

    struct BudgetLifecycleStatus {
        BudgetState currentState;
        bool isResolved;
        bool canAcceptFunding;
        bool isSuccessResolutionDisabled;
        bool isFundingWindowEnded;
        bool hasDeadline;
        bool isDeadlinePassed;
        bool hasPendingSuccessAssertion;
        uint256 treasuryBalance;
        uint256 activationThreshold;
        uint256 runwayCap;
        uint64 fundingDeadline;
        uint64 executionDuration;
        uint64 deadline;
        uint64 activatedAt;
        uint256 timeRemaining;
        int96 targetFlowRate;
    }

    error ADDRESS_ZERO();
    error INVALID_DEADLINES();
    error INVALID_EXECUTION_DURATION();
    error INVALID_THRESHOLDS(uint256 activationThreshold, uint256 runwayCap);
    error INVALID_STATE();
    error BUDGET_DEADLINE_PASSED();
    error ACTIVATION_THRESHOLD_NOT_REACHED(uint256 treasuryBalance, uint256 activationThreshold);
    error FUNDING_WINDOW_NOT_ENDED();
    error DEADLINE_NOT_REACHED();
    error FLOW_AUTHORITY_MISMATCH(address expected, address flowOperator, address sweeper);
    error PARENT_FLOW_NOT_CONFIGURED();
    error ONLY_SUCCESS_RESOLVER();
    error SUCCESS_ASSERTION_ALREADY_PENDING(bytes32 assertionId);
    error SUCCESS_ASSERTION_NOT_PENDING();
    error SUCCESS_ASSERTION_ID_MISMATCH(bytes32 expected, bytes32 actual);
    error INVALID_ASSERTION_ID();
    error INVALID_ASSERTION_CONFIG();
    error SUCCESS_ASSERTION_PENDING();
    error SUCCESS_RESOLUTION_DISABLED();
    error SUCCESS_ASSERTION_NOT_VERIFIED();
    error ONLY_CONTROLLER();

    event BudgetConfigured(
        address indexed controller,
        address flow,
        uint64 fundingDeadline,
        uint64 executionDuration,
        uint256 activationThreshold,
        uint256 runwayCap
    );
    event FlowRateSynced(int96 targetRate, int96 appliedRate, uint256 treasuryBalance, uint256 timeRemaining);
    event DonationRecorded(
        address indexed donor,
        address indexed sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount
    );
    event BudgetFinalized(BudgetState finalState);
    event TerminalSideEffectFailed(uint8 indexed operation, bytes reason);
    event ResidualSettled(address indexed destination, uint256 amount);
    event StateTransition(BudgetState previousState, BudgetState newState);
    event SuccessAssertionRegistered(bytes32 indexed assertionId, uint64 indexed assertedAt);
    event SuccessAssertionCleared(bytes32 indexed assertionId);
    event SuccessResolutionDisabled();
    event ReassertGraceActivated(bytes32 indexed clearedAssertionId, uint64 indexed graceDeadline);

    function fundingDeadline() external view returns (uint64);
    function executionDuration() external view returns (uint64);
    function deadline() external view returns (uint64);
    function activatedAt() external view returns (uint64);
    function controller() external view returns (address);
    function activationThreshold() external view returns (uint256);
    function runwayCap() external view returns (uint256);
    function resolvedAt() external view returns (uint64);
    function successResolutionDisabled() external view returns (bool);

    function canAcceptFunding() external view returns (bool);
    function sync() external;
    function retryTerminalSideEffects() external;
    function forceFlowRateToZero() external;
    function resolveFailure() external;

    function settleLateResidualToParent() external returns (uint256 amount);
    function disableSuccessResolution() external;

    function resolved() external view returns (bool);
    function state() external view returns (BudgetState);
    function flow() external view returns (address);
    function superToken() external view returns (ISuperToken);

    function treasuryBalance() external view returns (uint256);
    function timeRemaining() external view returns (uint256);
    function targetFlowRate() external view returns (int96);
    function lifecycleStatus() external view returns (BudgetLifecycleStatus memory status);
}
