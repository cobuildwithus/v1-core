// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ITreasuryAuthority } from "./ITreasuryAuthority.sol";
import { ITreasuryDonations } from "./ITreasuryDonations.sol";
import { ISuccessAssertionTreasury } from "./ISuccessAssertionTreasury.sol";
import { ITreasuryFlowRateSyncEvents } from "./ITreasuryFlowRateSyncEvents.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

interface IGoalTreasury is
    ITreasuryAuthority,
    ITreasuryDonations,
    ISuccessAssertionTreasury,
    ITreasuryFlowRateSyncEvents
{
    enum GoalState {
        Funding,
        Active,
        Succeeded,
        Expired
    }

    enum HookSplitAction {
        Funded,
        SuccessSettled,
        Deferred,
        TerminalSettled
    }

    struct GoalConfig {
        address flow;
        address stakeVault;
        address budgetStakeLedger;
        address hook;
        address goalRulesets;
        uint256 goalRevnetId;
        uint64 minRaiseDeadline;
        uint256 minRaise;
        uint256 coverageLambda;
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
    }

    struct GoalLifecycleStatus {
        GoalState currentState;
        bool isResolved;
        bool canAcceptHookFunding;
        bool isMintingOpen;
        bool isMinRaiseReached;
        bool isMinRaiseWindowElapsed;
        bool isDeadlinePassed;
        bool hasPendingSuccessAssertion;
        uint256 treasuryBalance;
        uint256 minRaise;
        uint64 minRaiseDeadline;
        uint64 deadline;
        uint256 timeRemaining;
        int96 targetFlowRate;
    }

    error ADDRESS_ZERO();
    error INVALID_DEADLINES();
    error ONLY_HOOK();
    error INVALID_STATE();
    error GOAL_DEADLINE_PASSED();
    error MIN_RAISE_NOT_REACHED(uint256 raised, uint256 minRaise);
    error DEADLINE_NOT_DERIVABLE();
    error INVALID_BUDGET_PREMIUM_PPM(uint256 ppm);
    error INVALID_BUDGET_SLASH_PPM(uint256 ppm);
    error STAKE_VAULT_GOAL_MISMATCH(address expected, address actual);
    error BUDGET_STAKE_LEDGER_GOAL_MISMATCH(address expected, address actual);
    error FLOW_AUTHORITY_MISMATCH(address expected, address flowOperator, address sweeper);
    error GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH(address expected, address actual);
    error GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address goalToken);
    error GOAL_TOKEN_REVNET_MISMATCH(address goalToken, uint256 expectedRevnetId, uint256 actualRevnetId);
    error INVALID_REVNET_CONTROLLER(address controller);
    error COBUILD_REVNET_ID_NOT_DERIVABLE(address cobuildToken);
    error ONLY_SUCCESS_RESOLVER();
    error SUCCESS_ASSERTION_ALREADY_PENDING(bytes32 assertionId);
    error SUCCESS_ASSERTION_NOT_PENDING();
    error SUCCESS_ASSERTION_ID_MISMATCH(bytes32 expected, bytes32 actual);
    error INVALID_ASSERTION_ID();
    error INVALID_ASSERTION_CONFIG();
    error SUCCESS_ASSERTION_NOT_VERIFIED();
    error INVALID_HOOK_SOURCE_TOKEN(address token);
    error HOOK_SUPER_TOKEN_AMOUNT_MISMATCH(uint256 expected, uint256 actual);
    error ONLY_AUTHORITY();
    error INSUFFICIENT_TREASURY_BALANCE(address token, uint256 needed, uint256 have);

    event GoalConfigured(
        address indexed owner,
        address flow,
        address stakeVault,
        address budgetStakeLedger,
        address hook,
        address goalRulesets,
        uint256 goalRevnetId,
        uint64 minRaiseDeadline,
        uint64 deadline,
        uint256 minRaise
    );
    event HookFundingRecorded(uint256 amount, uint256 totalRaised);
    event FlowRateSynced(int96 targetRate, int96 appliedRate, uint256 treasuryBalance, uint256 timeRemaining);
    event DonationRecorded(
        address indexed donor,
        address indexed sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount,
        uint256 totalRaised
    );
    event ResidualSettled(
        GoalState indexed finalState,
        uint256 totalSettled,
        uint256 controllerBurnAmount
    );
    event GoalFinalized(GoalState finalState);
    event TerminalSideEffectFailed(uint8 indexed operation, bytes reason);
    event StateTransition(GoalState previousState, GoalState newState);
    event SuccessAssertionRegistered(bytes32 indexed assertionId, uint64 indexed assertedAt);
    event SuccessAssertionCleared(bytes32 indexed assertionId);
    event ReassertGraceActivated(bytes32 indexed clearedAssertionId, uint64 indexed graceDeadline);
    event HookFundingDeferred(
        address indexed sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount,
        uint256 totalDeferredSuperTokenAmount
    );
    event HookDeferredFundingSettled(
        GoalState indexed finalState,
        uint256 superTokenAmount,
        uint256 controllerBurnAmount
    );
    event JurorSlasherConfigured(address indexed authority, address indexed slasher);
    event UnderwriterSlasherConfigured(address indexed authority, address indexed slasher);

    function minRaiseDeadline() external view returns (uint64);
    function deadline() external view returns (uint64);
    function successAt() external view returns (uint64);
    function resolvedAt() external view returns (uint64);
    function minRaise() external view returns (uint256);
    function coverageLambda() external view returns (uint256);
    function budgetPremiumPpm() external view returns (uint32);
    function budgetSlashPpm() external view returns (uint32);
    function totalRaised() external view returns (uint256);
    function goalRulesets() external view returns (IJBRulesets);
    function goalRevnetId() external view returns (uint256);
    function cobuildRevnetId() external view returns (uint256);
    function budgetStakeLedger() external view returns (address);

    function recordHookFunding(uint256 amount) external returns (bool accepted);
    function canAcceptHookFunding() external view returns (bool);
    function isMintingOpen() external view returns (bool);
    function deferredHookSuperTokenAmount() external view returns (uint256);
    function processHookSplit(
        address sourceToken,
        uint256 sourceAmount
    )
        external
        returns (HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount);
    function sync() external;
    function retryTerminalSideEffects() external;

    function settleLateResidual() external;
    function configureJurorSlasher(address slasher) external;
    function configureUnderwriterSlasher(address slasher) external;

    function resolved() external view returns (bool);
    function state() external view returns (GoalState);
    function flow() external view returns (address);
    function stakeVault() external view returns (address);
    function hook() external view returns (address);
    function superToken() external view returns (ISuperToken);

    function treasuryBalance() external view returns (uint256);
    function timeRemaining() external view returns (uint256);
    function targetFlowRate() external view returns (int96);
    function lifecycleStatus() external view returns (GoalLifecycleStatus memory status);
}
