// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IStakeVault } from "../interfaces/IStakeVault.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IGoalRevnetHookDirectoryReader } from "../interfaces/IGoalRevnetHookDirectoryReader.sol";
import { ISpendPolicy } from "../interfaces/ISpendPolicy.sol";
import { ISuccessAssertionTreasury } from "../interfaces/ISuccessAssertionTreasury.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBControlled } from "@bananapus/core-v5/interfaces/IJBControlled.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBApprovalStatus } from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TreasuryBase } from "./TreasuryBase.sol";
import { GoalSpendPatterns } from "./library/GoalSpendPatterns.sol";
import { TreasuryFlowRateSync } from "./library/TreasuryFlowRateSync.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";
import { TreasuryReassertGrace } from "./library/TreasuryReassertGrace.sol";
import { TreasuryPostDeadlineFinalize } from "./library/TreasuryPostDeadlineFinalize.sol";
import { TreasurySuccessAssertionLifecycle } from "./library/TreasurySuccessAssertionLifecycle.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";

contract GoalTreasury is IGoalTreasury, TreasuryBase {
    using SafeERC20 for IERC20;
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    GoalSpendPatterns.SpendPattern private constant GOAL_SPEND_PATTERN = GoalSpendPatterns.SpendPattern.Linear;
    uint64 private constant REASSERT_GRACE_DURATION = 1 days;
    string private constant SUCCESS_SETTLEMENT_BURN_MEMO = "GOAL_SUCCESS_SETTLEMENT_BURN";
    string private constant SUCCESS_RESIDUAL_BURN_MEMO = "GOAL_SUCCESS_RESIDUAL_BURN";
    string private constant TERMINAL_RESIDUAL_BURN_MEMO = "GOAL_TERMINAL_RESIDUAL_BURN";
    uint8 private constant DIRECTORY_FAILURE_NONE = 0;
    uint8 private constant DIRECTORY_FAILURE_INVALID = 1;
    uint8 private constant DIRECTORY_FAILURE_REVERT = 2;

    GoalState private _state;
    TreasurySuccessAssertions.State private _successAssertions;
    TreasuryReassertGrace.State private _reassertGrace;
    uint64 public override activatedAt;
    uint64 public override successAt;
    uint64 public override resolvedAt;

    IFlow private _flow;
    IStakeVault private _stakeVault;
    address private _budgetStakeLedger;
    address private _hook;

    IJBRulesets public override goalRulesets;
    uint256 public override goalRevnetId;
    uint256 public override cobuildRevnetId;

    ISuperToken public override superToken;

    uint64 public override minRaiseDeadline;
    uint64 public override deadline;
    uint256 public override minRaise;
    uint32 public override budgetPremiumPpm;
    uint32 public override budgetSlashPpm;
    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;
    address public override spendPolicy;

    uint256 public override totalRaised;
    uint256 public override deferredHookSuperTokenAmount;

    struct GoalDerivedState {
        GoalState state;
        bool isTerminal;
        bool minRaiseWindowElapsedWithoutGoal;
        bool deadlinePassed;
    }

    enum HookSplitPath {
        FundingIngress,
        SuccessSettlement,
        TerminalSettlement,
        DeferredIngress
    }

    event SuccessAssertionResolutionFailClosed(
        bytes32 indexed assertionId,
        TreasurySuccessAssertions.FailClosedReason indexed reason
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, GoalConfig calldata config) external initializer {
        __ReentrancyGuard_init();
        _initialize(initialOwner, config);
    }

    function _initialize(address initialOwner, GoalConfig memory config) internal {
        if (initialOwner == address(0)) revert ADDRESS_ZERO();
        if (config.flow == address(0)) revert ADDRESS_ZERO();
        if (config.stakeVault == address(0)) revert ADDRESS_ZERO();
        if (config.jurorSlasher == address(0)) revert ADDRESS_ZERO();
        if (config.underwriterSlasher == address(0)) revert ADDRESS_ZERO();
        if (config.jurorSlasher.code.length == 0) revert NOT_A_CONTRACT(config.jurorSlasher);
        if (config.underwriterSlasher.code.length == 0) revert NOT_A_CONTRACT(config.underwriterSlasher);
        if (config.budgetStakeLedger == address(0)) revert ADDRESS_ZERO();
        if (config.budgetStakeLedger.code.length == 0) revert NOT_A_CONTRACT(config.budgetStakeLedger);
        if (config.hook == address(0)) revert ADDRESS_ZERO();
        if (config.goalRulesets == address(0)) revert ADDRESS_ZERO();
        if (config.successResolver == address(0)) revert ADDRESS_ZERO();
        if (config.spendPolicy != address(0) && config.spendPolicy.code.length == 0) {
            revert NOT_A_CONTRACT(config.spendPolicy);
        }
        if (config.spendPolicy != address(0)) _requireValidSpendPolicy(config.spendPolicy);
        if (
            config.successAssertionLiveness == 0 ||
            config.successOracleSpecHash == bytes32(0) ||
            config.successAssertionPolicyHash == bytes32(0)
        ) {
            revert INVALID_ASSERTION_CONFIG();
        }
        if (config.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_BUDGET_PREMIUM_PPM(config.budgetPremiumPpm);
        }
        if (config.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_BUDGET_SLASH_PPM(config.budgetSlashPpm);
        }
        if (config.budgetSlashPpm != 0 && config.budgetPremiumPpm == 0) {
            revert INVALID_UNDERWRITING_SLASH_CONFIG(config.budgetPremiumPpm, config.budgetSlashPpm);
        }

        uint256 nowTs = block.timestamp;
        if (config.minRaiseDeadline == 0 || config.minRaiseDeadline < nowTs) revert INVALID_DEADLINES();

        _flow = IFlow(config.flow);
        _stakeVault = IStakeVault(config.stakeVault);
        _budgetStakeLedger = config.budgetStakeLedger;
        _hook = config.hook;
        goalRulesets = IJBRulesets(config.goalRulesets);
        goalRevnetId = config.goalRevnetId;
        IERC20 configuredGoalToken = _stakeVault.goalToken();
        IERC20 configuredCobuildToken = _stakeVault.cobuildToken();
        cobuildRevnetId = _deriveCobuildRevnetId(goalRevnetId, configuredCobuildToken, goalRulesets, _hook);

        address configuredGoalTreasury = _stakeVault.goalTreasury();
        if (configuredGoalTreasury != address(this)) {
            revert STAKE_VAULT_GOAL_MISMATCH(address(this), configuredGoalTreasury);
        }
        address ledgerGoalTreasury = IBudgetStakeLedger(_budgetStakeLedger).goalTreasury();
        if (ledgerGoalTreasury != address(this)) {
            revert BUDGET_STAKE_LEDGER_GOAL_MISMATCH(address(this), ledgerGoalTreasury);
        }
        _stakeVault.setJurorSlasher(config.jurorSlasher);
        _stakeVault.setUnderwriterSlasher(config.underwriterSlasher);

        superToken = _flow.superToken();
        if (address(superToken) == address(0)) revert ADDRESS_ZERO();
        _requireGoalTokenInvariants(superToken, _stakeVault, goalRulesets, _hook, goalRevnetId);
        uint64 derivedDeadline = _deriveDeadline();
        address configuredFlowOperator = _flow.flowOperator();
        address configuredSweeper = _flow.sweeper();
        if (configuredFlowOperator != address(this) || configuredSweeper != address(this)) {
            revert FLOW_AUTHORITY_MISMATCH(address(this), configuredFlowOperator, configuredSweeper);
        }
        if (config.minRaiseDeadline > derivedDeadline || derivedDeadline < nowTs) revert INVALID_DEADLINES();
        minRaiseDeadline = config.minRaiseDeadline;
        deadline = derivedDeadline;
        minRaise = config.minRaise;
        budgetPremiumPpm = config.budgetPremiumPpm;
        budgetSlashPpm = config.budgetSlashPpm;
        successResolver = config.successResolver;
        successAssertionLiveness = config.successAssertionLiveness;
        successAssertionBond = config.successAssertionBond;
        successOracleSpecHash = config.successOracleSpecHash;
        successAssertionPolicyHash = config.successAssertionPolicyHash;
        spendPolicy = config.spendPolicy;
        _state = GoalState.Funding;

        emit GoalConfigured(
            initialOwner,
            config.flow,
            config.stakeVault,
            config.budgetStakeLedger,
            config.hook,
            config.goalRulesets,
            config.goalRevnetId,
            config.minRaiseDeadline,
            derivedDeadline,
            config.minRaise,
            config.jurorSlasher,
            config.underwriterSlasher,
            config.successResolver,
            address(configuredGoalToken),
            address(configuredCobuildToken)
        );
    }

    function recordHookFunding(uint256 amount) external override nonReentrant returns (bool accepted) {
        if (msg.sender != _hook) revert ONLY_HOOK();
        if (amount == 0) return false;
        if (block.timestamp >= deadline) return false;
        if (!canAcceptHookFunding()) return false;

        totalRaised += amount;

        emit HookFundingRecorded(amount, totalRaised);

        return true;
    }

    function canAcceptHookFunding() public view override returns (bool) {
        return _canAcceptHookFunding(_deriveGoalDerivedState());
    }

    function isMintingOpen() public view override returns (bool) {
        (, bool mintingOpen) = _mintingStatus();
        return mintingOpen;
    }

    function processHookSplit(
        address sourceToken,
        uint256 sourceAmount
    ) external override nonReentrant returns (HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount) {
        if (msg.sender != _hook) revert ONLY_HOOK();
        if (!_isHookSourceToken(sourceToken)) revert INVALID_HOOK_SOURCE_TOKEN(sourceToken);
        if (sourceAmount == 0) return (HookSplitAction.Deferred, 0, 0);

        GoalDerivedState memory derivedState = _deriveGoalDerivedState();
        HookSplitPath path = _deriveHookSplitPath(derivedState);
        if (path == HookSplitPath.FundingIngress) {
            superTokenAmount = _processFundingIngress(sourceToken, sourceAmount);
            return (HookSplitAction.Funded, superTokenAmount, 0);
        }

        if (path == HookSplitPath.SuccessSettlement) {
            burnAmount = _processSuccessSettlement(sourceAmount);
            return (HookSplitAction.SuccessSettled, 0, burnAmount);
        }

        if (path == HookSplitPath.TerminalSettlement) {
            (superTokenAmount, burnAmount) = _processTerminalSettlement(derivedState.state, sourceToken, sourceAmount);
            return (HookSplitAction.TerminalSettled, superTokenAmount, burnAmount);
        }

        superTokenAmount = _processDeferredIngress(sourceToken, sourceAmount);
        return (HookSplitAction.Deferred, superTokenAmount, 0);
    }

    function sync() external override nonReentrant {
        GoalDerivedState memory derivedState = _deriveGoalDerivedState();
        if (derivedState.isTerminal) return;

        if (derivedState.state == GoalState.Funding) {
            if (derivedState.minRaiseWindowElapsedWithoutGoal || derivedState.deadlinePassed) {
                _finalize(GoalState.Expired);
            } else if (_raisedForLifecycle() >= minRaise) {
                _activateAndSync();
            }
            return;
        }

        if (derivedState.deadlinePassed) {
            if (_tryFinalizePostDeadline()) return;
        }

        _syncFlowRate();
    }

    function retryTerminalSideEffects() external override nonReentrant {
        GoalState finalState = _state;
        if (!_isTerminalState(finalState)) revert INVALID_STATE();
        _runTerminalSideEffects(finalState);
    }

    function resolveSuccess() external override nonReentrant {
        _requireSuccessResolver();
        if (_state != GoalState.Active) revert INVALID_STATE();
        _successAssertions.requirePending();
        _successAssertions.requireTruthful(successResolver, successAssertionLiveness, successAssertionBond);

        _finalize(GoalState.Succeeded);
    }

    function pendingSuccessAssertionId() external view override returns (bytes32) {
        return TreasurySuccessAssertions.pendingId(_successAssertions);
    }

    function treasuryKind() external pure override returns (ISuccessAssertionTreasury.TreasuryKind) {
        return ISuccessAssertionTreasury.TreasuryKind.Goal;
    }

    function pendingSuccessAssertionAt() external view override returns (uint64) {
        return TreasurySuccessAssertions.pendingAt(_successAssertions);
    }

    function reassertGraceDeadline() public view override returns (uint64) {
        return _reassertGrace.deadline;
    }

    function reassertGraceUsed() public view override returns (bool) {
        return _reassertGrace.used;
    }

    function isReassertGraceActive() public view override returns (bool) {
        return _reassertGrace.isActive();
    }

    function registerSuccessAssertion(bytes32 assertionId) external override {
        _requireSuccessResolver();
        if (_state != GoalState.Active) revert INVALID_STATE();
        if (block.timestamp >= deadline) {
            if (!_reassertGrace.consumeIfActive()) revert GOAL_DEADLINE_PASSED();
        }

        uint64 assertedAt = _successAssertions.registerPending(assertionId);
        emit SuccessAssertionRegistered(assertionId, assertedAt);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        _requireSuccessResolver();
        bytes32 clearedAssertionId = TreasurySuccessAssertionLifecycle.clearMatching(_successAssertions, assertionId);
        _emitSuccessAssertionCleared(clearedAssertionId);
        _tryActivateReassertGrace(clearedAssertionId);
    }

    function settleLateResidual() external override nonReentrant {
        GoalState finalState = _state;
        if (!_isTerminalState(finalState)) {
            revert INVALID_STATE();
        }

        _settleResidual(finalState);
        _settleDeferredHookFunding(finalState);
    }

    function resolved() external view override returns (bool) {
        return _isTerminalState(_state);
    }

    function state() external view override returns (GoalState) {
        return _state;
    }

    function flow() external view override returns (address) {
        return address(_flow);
    }

    function stakeVault() external view override returns (address) {
        return address(_stakeVault);
    }

    function budgetStakeLedger() external view override returns (address) {
        return _budgetStakeLedger;
    }

    function hook() external view override returns (address) {
        return _hook;
    }

    function treasuryBalance() public view override returns (uint256) {
        return _treasuryBalance();
    }

    function timeRemaining() public view override returns (uint256) {
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function targetFlowRate() public view override returns (int96) {
        if (_state != GoalState.Active) return 0;

        uint256 balance = treasuryBalance();
        uint256 remaining = timeRemaining();
        return _computeConfiguredTargetFlowRate(balance, remaining);
    }

    function lifecycleStatus() external view override returns (GoalLifecycleStatus memory status) {
        GoalState currentState = _state;
        uint256 treasuryBalance_ = treasuryBalance();
        status = GoalLifecycleStatus({
            currentState: currentState,
            isResolved: _isTerminalState(currentState),
            canAcceptHookFunding: canAcceptHookFunding(),
            isMintingOpen: isMintingOpen(),
            isMinRaiseReached: treasuryBalance_ >= minRaise,
            isMinRaiseWindowElapsed: currentState == GoalState.Funding && block.timestamp > minRaiseDeadline,
            isDeadlinePassed: block.timestamp >= deadline,
            hasPendingSuccessAssertion: TreasurySuccessAssertions.pendingId(_successAssertions) != bytes32(0),
            treasuryBalance: treasuryBalance_,
            minRaise: minRaise,
            minRaiseDeadline: minRaiseDeadline,
            deadline: deadline,
            timeRemaining: timeRemaining(),
            targetFlowRate: targetFlowRate()
        });
    }

    function _activateAndSync() internal {
        if (_state != GoalState.Funding) revert INVALID_STATE();
        if (block.timestamp >= deadline) revert GOAL_DEADLINE_PASSED();
        uint256 raised = _raisedForLifecycle();
        if (raised < minRaise) revert MIN_RAISE_NOT_REACHED(raised, minRaise);

        // Record the activation timestamp for downstream stake-weight schedules.
        // This is set once on Funding -> Active.
        activatedAt = uint64(block.timestamp);
        _setState(GoalState.Active);
        _syncFlowRate();
    }

    function _syncFlowRate() internal {
        uint256 balance = treasuryBalance();
        uint256 remaining = timeRemaining();
        int96 targetRate = _computeConfiguredTargetFlowRate(balance, remaining);
        int96 appliedRate;
        if (_syncMode() == ISpendPolicy.SyncMode.LinearSpendDownFallback) {
            appliedRate = TreasuryFlowRateSync.applyLinearSpendDownWithFallback(_flow, targetRate, balance, remaining);
        } else {
            appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(_flow, targetRate);
        }

        emit FlowRateSynced(targetRate, appliedRate, balance, remaining);
    }

    function _computeConfiguredTargetFlowRate(uint256 balance, uint256 remaining) internal view returns (int96) {
        if (remaining == 0) return 0;

        if (spendPolicy == address(0)) {
            return _computeLegacyClampedTargetFlowRate(balance, remaining);
        }

        uint128 totalUnits = _flow.distributionPool().getTotalUnits();
        if (totalUnits == 0) return 0;

        return ISpendPolicy(spendPolicy).targetFlowRate(_buildSpendContext(balance, remaining, totalUnits));
    }

    function _computeLegacyClampedTargetFlowRate(uint256 balance, uint256 remaining) internal view returns (int96) {
        int96 targetRate = GoalSpendPatterns.targetFlowRate(GOAL_SPEND_PATTERN, balance, remaining);

        // Underwriting is enforced via budget-level credit-line recipient gating.
        // Avoid streaming into an empty distribution pool (all recipients disabled or no recipients).
        if (_flow.distributionPool().getTotalUnits() == 0) return 0;

        return targetRate;
    }

    function _buildSpendContext(
        uint256 balance,
        uint256 remaining,
        uint128 totalUnits
    ) internal view returns (ISpendPolicy.SpendContext memory ctx) {
        ctx = ISpendPolicy.SpendContext({
            nowTs: uint64(block.timestamp),
            activatedAt: activatedAt,
            deadline: deadline,
            treasuryBalance: balance,
            timeRemaining: remaining,
            incomingRate: 0,
            currentOutflowRate: _flow.targetOutflowRate(),
            totalRecipientUnits: totalUnits
        });
    }

    function _syncMode() internal view returns (ISpendPolicy.SyncMode) {
        if (spendPolicy == address(0)) return ISpendPolicy.SyncMode.LinearSpendDownFallback;
        return ISpendPolicy(spendPolicy).syncMode();
    }

    function _requireValidSpendPolicy(address candidate) internal view {
        try ISpendPolicy(candidate).syncMode() returns (ISpendPolicy.SyncMode mode) {
            if (uint8(mode) > uint8(ISpendPolicy.SyncMode.LinearSpendDownFallback)) {
                revert INVALID_SPEND_POLICY(candidate);
            }
        } catch {
            revert INVALID_SPEND_POLICY(candidate);
        }

        try
            ISpendPolicy(candidate).targetFlowRate(
                ISpendPolicy.SpendContext({
                    nowTs: uint64(block.timestamp),
                    activatedAt: 0,
                    deadline: 0,
                    treasuryBalance: 0,
                    timeRemaining: 0,
                    incomingRate: 0,
                    currentOutflowRate: 0,
                    totalRecipientUnits: 0
                })
            )
        returns (int96) {} catch {
            revert INVALID_SPEND_POLICY(candidate);
        }
    }

    function _minRaiseWindowElapsedWithoutGoal(GoalState currentState) internal view returns (bool) {
        return
            currentState == GoalState.Funding && block.timestamp > minRaiseDeadline && _raisedForLifecycle() < minRaise;
    }

    function _deriveGoalDerivedState() internal view returns (GoalDerivedState memory derivedState) {
        GoalState currentState = _state;
        derivedState.state = currentState;
        derivedState.isTerminal = _isTerminalState(currentState);
        derivedState.minRaiseWindowElapsedWithoutGoal = _minRaiseWindowElapsedWithoutGoal(currentState);
        derivedState.deadlinePassed = block.timestamp >= deadline;
    }

    function _deriveHookSplitPath(GoalDerivedState memory derivedState) internal view returns (HookSplitPath) {
        if (_canAcceptHookFunding(derivedState)) return HookSplitPath.FundingIngress;
        if (derivedState.state == GoalState.Succeeded && isMintingOpen()) return HookSplitPath.SuccessSettlement;
        if (derivedState.isTerminal) return HookSplitPath.TerminalSettlement;
        return HookSplitPath.DeferredIngress;
    }

    function _canAcceptHookFunding(GoalDerivedState memory derivedState) internal pure returns (bool) {
        return
            !derivedState.isTerminal && !derivedState.minRaiseWindowElapsedWithoutGoal && !derivedState.deadlinePassed;
    }

    function _raisedForLifecycle() internal view returns (uint256) {
        return treasuryBalance();
    }

    function _flowContract() internal view override returns (IFlow) {
        return _flow;
    }

    function _superToken() internal view override returns (ISuperToken) {
        return superToken;
    }

    function _canAcceptDonation() internal view override returns (bool) {
        return canAcceptHookFunding();
    }

    function _afterDonation(
        address donor,
        address sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount
    ) internal override {
        totalRaised += superTokenAmount;
        emit DonationRecorded(donor, sourceToken, sourceAmount, superTokenAmount, totalRaised);
    }

    function _revertInvalidState() internal pure override {
        revert INVALID_STATE();
    }

    function _finalize(GoalState finalState) internal {
        if (!_isTerminalState(finalState)) revert INVALID_STATE();
        if (_isTerminalState(_state)) revert INVALID_STATE();

        _reassertGrace.clearDeadline();
        _emitSuccessAssertionCleared(TreasurySuccessAssertionLifecycle.clearPending(_successAssertions));

        uint64 finalizedAt = uint64(block.timestamp);
        _setState(finalState);
        resolvedAt = finalizedAt;
        if (finalState == GoalState.Succeeded) {
            successAt = finalizedAt;
        }

        _runTerminalSideEffects(finalState);

        emit GoalFinalized(finalState);
    }

    function _runTerminalSideEffects(GoalState finalState) internal {
        (bool flowStopped, bytes memory flowStopRevertData) = _tryForceFlowRateToZero();
        if (!flowStopped) {
            emit TerminalFlowStopFailed(flowStopRevertData);
        }

        _trySettleResidual(finalState);
        _trySettleDeferredHookFunding(finalState);
        _tryMarkStakeVaultResolved();
    }

    function _trySettleResidual(GoalState finalState) internal {
        try this.settleResidualForFinalize(finalState) {} catch (bytes memory revertData) {
            emit TerminalResidualSettlementFailed(revertData);
        }
    }

    function _trySettleDeferredHookFunding(GoalState finalState) internal {
        try this.settleDeferredHookFundingForFinalize(finalState) {} catch (bytes memory revertData) {
            emit TerminalDeferredHookFundingSettlementFailed(revertData);
        }
    }

    function _tryMarkStakeVaultResolved() internal {
        bool stakeVaultResolved;
        try _stakeVault.goalResolved() returns (bool resolved_) {
            stakeVaultResolved = resolved_;
        } catch (bytes memory revertData) {
            emit TerminalStakeVaultResolutionFailed(revertData);
            return;
        }
        if (stakeVaultResolved) return;

        try _stakeVault.markGoalResolved() {} catch (bytes memory revertData) {
            emit TerminalStakeVaultResolutionFailed(revertData);
        }
    }

    function settleResidualForFinalize(GoalState finalState) external onlySelf {
        _settleResidual(finalState);
    }

    function settleDeferredHookFundingForFinalize(GoalState finalState) external onlySelf {
        _settleDeferredHookFunding(finalState);
    }

    function _tryFinalizePostDeadline() internal returns (bool) {
        TreasurySuccessAssertionLifecycle.PostDeadlineResolution memory resolution = TreasurySuccessAssertionLifecycle
            .resolvePostDeadline(
                _successAssertions,
                _reassertGrace,
                successResolver,
                successAssertionLiveness,
                successAssertionBond
            );

        if (resolution.failClosedReason != TreasurySuccessAssertions.FailClosedReason.None) {
            emit SuccessAssertionResolutionFailClosed(resolution.pendingAssertionId, resolution.failClosedReason);
        }

        if (resolution.decision == TreasuryPostDeadlineFinalize.Decision.Wait) return false;
        if (resolution.decision == TreasuryPostDeadlineFinalize.Decision.FinalizeSucceeded) {
            _finalize(GoalState.Succeeded);
            return true;
        }
        if (resolution.decision == TreasuryPostDeadlineFinalize.Decision.ClearPendingAndActivateGrace) {
            _emitSuccessAssertionCleared(resolution.clearedAssertionId);
            if (resolution.finalizeFailureData.length != 0) {
                emit SuccessAssertionFinalizeFailed(resolution.clearedAssertionId, resolution.finalizeFailureData);
            }
            _tryActivateReassertGrace(resolution.clearedAssertionId);
            return false;
        }

        _finalize(GoalState.Expired);
        return true;
    }

    function _tryActivateReassertGrace(bytes32 clearedAssertionId) internal {
        if (_reassertGrace.used) return;
        if (_state != GoalState.Active) return;
        if (block.timestamp < deadline) return;

        (bool activated, uint64 graceDeadline) = _reassertGrace.activateOnce(REASSERT_GRACE_DURATION);
        if (!activated) return;

        emit ReassertGraceActivated(clearedAssertionId, graceDeadline);
    }

    function _setState(GoalState newState) internal {
        GoalState previous = _state;
        _state = newState;
        emit StateTransition(previous, newState);
    }

    function _requireSuccessResolver() internal view {
        if (msg.sender != successResolver) revert ONLY_SUCCESS_RESOLVER();
    }

    function _isTerminalState(GoalState stateValue) internal pure returns (bool) {
        return stateValue == GoalState.Succeeded || stateValue == GoalState.Expired;
    }

    function _emitSuccessAssertionCleared(bytes32 clearedAssertionId) internal {
        if (clearedAssertionId == bytes32(0)) return;
        emit SuccessAssertionCleared(clearedAssertionId);
    }

    function _settleResidual(GoalState finalState) internal {
        uint256 settled = _flow.sweepSuperToken(address(this), type(uint256).max);
        if (settled == 0) {
            emit ResidualSettled(finalState, 0, 0);
            return;
        }

        uint256 burnAmount = _settleSuperTokenAmount(finalState, settled);

        emit ResidualSettled(finalState, settled, burnAmount);
    }

    function _settleDeferredHookFunding(GoalState finalState) internal {
        uint256 deferred = deferredHookSuperTokenAmount;
        if (deferred == 0) return;

        deferredHookSuperTokenAmount = 0;
        uint256 burnAmount = _settleSuperTokenAmount(finalState, deferred);
        emit HookDeferredFundingSettled(finalState, deferred, burnAmount);
    }

    function _settleSuperTokenAmount(GoalState finalState, uint256 settled) internal returns (uint256 burnAmount) {
        if (settled == 0) return 0;

        IERC20 underlyingToken = IERC20(superToken.getUnderlyingToken());
        uint256 underlyingBefore = underlyingToken.balanceOf(address(this));
        superToken.downgrade(settled);
        burnAmount = underlyingToken.balanceOf(address(this)) - underlyingBefore;
        if (burnAmount != 0) {
            _burnViaController(
                goalRevnetId,
                burnAmount,
                finalState == GoalState.Succeeded ? SUCCESS_RESIDUAL_BURN_MEMO : TERMINAL_RESIDUAL_BURN_MEMO
            );
        }
    }

    function _settleSuccessHookSplit(uint256 sourceAmount) internal returns (uint256 burnAmount) {
        burnAmount = sourceAmount;

        if (burnAmount != 0) {
            _burnViaController(goalRevnetId, burnAmount, SUCCESS_SETTLEMENT_BURN_MEMO);
        }
    }

    function _processFundingIngress(
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 superTokenAmount) {
        superTokenAmount = _moveHeldSourceToFlowAsSuperToken(sourceToken, sourceAmount);
        _requireHookSuperTokenAmountMatches(sourceAmount, superTokenAmount);
        totalRaised += superTokenAmount;
        emit HookFundingRecorded(superTokenAmount, totalRaised);
    }

    function _processSuccessSettlement(uint256 sourceAmount) internal returns (uint256 burnAmount) {
        burnAmount = _settleSuccessHookSplit(sourceAmount);
    }

    function _processTerminalSettlement(
        GoalState terminalState,
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 superTokenAmount, uint256 burnAmount) {
        superTokenAmount = _convertHeldSourceToSuperToken(sourceToken, sourceAmount);
        burnAmount = _settleSuperTokenAmount(terminalState, superTokenAmount);
    }

    function _processDeferredIngress(
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 superTokenAmount) {
        superTokenAmount = _convertHeldSourceToSuperToken(sourceToken, sourceAmount);
        _requireHookSuperTokenAmountMatches(sourceAmount, superTokenAmount);

        deferredHookSuperTokenAmount += superTokenAmount;
        emit HookFundingDeferred(sourceToken, sourceAmount, superTokenAmount, deferredHookSuperTokenAmount);
    }

    function _requireHookSuperTokenAmountMatches(uint256 sourceAmount, uint256 superTokenAmount) internal pure {
        if (superTokenAmount != sourceAmount) {
            revert HOOK_SUPER_TOKEN_AMOUNT_MISMATCH(sourceAmount, superTokenAmount);
        }
    }

    function _moveHeldSourceToFlowAsSuperToken(address sourceToken, uint256 sourceAmount) internal returns (uint256) {
        uint256 flowBalanceBefore = IERC20(address(superToken)).balanceOf(address(_flow));
        uint256 superTokenAmount = _convertHeldSourceToSuperToken(sourceToken, sourceAmount);

        if (superTokenAmount != 0) {
            IERC20(address(superToken)).safeTransfer(address(_flow), superTokenAmount);
        }

        return IERC20(address(superToken)).balanceOf(address(_flow)) - flowBalanceBefore;
    }

    function _convertHeldSourceToSuperToken(address sourceToken, uint256 sourceAmount) internal returns (uint256) {
        IERC20 underlyingToken = IERC20(superToken.getUnderlyingToken());
        _requireTreasuryTokenBalance(underlyingToken, sourceAmount);

        uint256 superBalanceBefore = IERC20(address(superToken)).balanceOf(address(this));
        underlyingToken.forceApprove(address(superToken), 0);
        underlyingToken.forceApprove(address(superToken), sourceAmount);
        superToken.upgrade(sourceAmount);
        underlyingToken.forceApprove(address(superToken), 0);

        return IERC20(address(superToken)).balanceOf(address(this)) - superBalanceBefore;
    }

    function _isHookSourceToken(address token) internal view returns (bool) {
        return token == superToken.getUnderlyingToken();
    }

    function _requireTreasuryTokenBalance(IERC20 token, uint256 amount) internal view {
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert INSUFFICIENT_TREASURY_BALANCE(address(token), amount, balance);
    }

    function _deriveCobuildRevnetId(
        uint256 goalRevnetIdForLookup,
        IERC20 configuredCobuildToken,
        IJBRulesets configuredGoalRulesets,
        address configuredHook
    ) internal view returns (uint256) {
        if (address(configuredCobuildToken) == address(0)) return 0;

        (IJBDirectory directory, bytes memory directoryFailureReason) = _resolveRevnetDirectory(
            configuredGoalRulesets,
            configuredHook
        );
        if (address(directory) == address(0)) {
            revert COBUILD_REVNET_ID_NOT_DERIVABLE_WITH_REASON(address(configuredCobuildToken), directoryFailureReason);
        }

        address controller = address(directory.controllerOf(goalRevnetIdForLookup));
        if (controller == address(0)) revert INVALID_REVNET_CONTROLLER(controller);

        IJBTokens tokens;
        try IJBController(controller).TOKENS() returns (IJBTokens resolvedTokens) {
            tokens = resolvedTokens;
        } catch {
            revert COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
        }

        if (address(tokens) == address(0)) {
            revert COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
        }

        try tokens.projectIdOf(IJBToken(address(configuredCobuildToken))) returns (uint256 derivedRevnetId) {
            if (derivedRevnetId == 0) {
                revert COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
            }

            address cobuildController = address(directory.controllerOf(derivedRevnetId));
            if (cobuildController == address(0)) {
                revert COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
            }
            return derivedRevnetId;
        } catch {
            revert COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
        }
    }

    function _requireGoalTokenInvariants(
        ISuperToken configuredSuperToken,
        IStakeVault configuredStakeVault,
        IJBRulesets configuredGoalRulesets,
        address configuredHook,
        uint256 configuredGoalRevnetId
    ) internal view {
        IERC20 configuredGoalToken = configuredStakeVault.goalToken();
        address underlyingToken = configuredSuperToken.getUnderlyingToken();
        if (underlyingToken != address(configuredGoalToken)) {
            revert GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH(address(configuredGoalToken), underlyingToken);
        }

        (IJBDirectory directory, bytes memory directoryFailureReason) = _resolveRevnetDirectory(
            configuredGoalRulesets,
            configuredHook
        );
        if (address(directory) == address(0)) {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE_WITH_REASON(address(configuredGoalToken), directoryFailureReason);
        }

        _requireTokenMatchesRevnetId(directory, configuredGoalRevnetId, configuredGoalToken);
    }

    function _requireTokenMatchesRevnetId(
        IJBDirectory directory,
        uint256 expectedRevnetId,
        IERC20 token
    ) internal view {
        address controller = address(directory.controllerOf(expectedRevnetId));
        if (controller == address(0)) revert INVALID_REVNET_CONTROLLER(controller);

        IJBTokens tokens;
        try IJBController(controller).TOKENS() returns (IJBTokens resolvedTokens) {
            tokens = resolvedTokens;
        } catch {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(token));
        }

        if (address(tokens) == address(0)) {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(token));
        }

        uint256 derivedRevnetId;
        try tokens.projectIdOf(IJBToken(address(token))) returns (uint256 resolvedRevnetId) {
            derivedRevnetId = resolvedRevnetId;
        } catch {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(token));
        }

        if (derivedRevnetId != expectedRevnetId) {
            revert GOAL_TOKEN_REVNET_MISMATCH(address(token), expectedRevnetId, derivedRevnetId);
        }
    }

    function _resolveRevnetDirectory(
        IJBRulesets configuredGoalRulesets,
        address configuredHook
    ) private view returns (IJBDirectory directory, bytes memory failureReason) {
        uint8 rulesetsFailure = DIRECTORY_FAILURE_NONE;
        bytes memory rulesetsFailureReason;
        uint8 hookFailure = DIRECTORY_FAILURE_NONE;
        bytes memory hookFailureReason;

        // Prefer rulesets as the canonical source so treasury init does not depend on hook init ordering.
        try IJBControlled(address(configuredGoalRulesets)).DIRECTORY() returns (IJBDirectory rulesetsDirectory) {
            if (address(rulesetsDirectory) != address(0) && address(rulesetsDirectory).code.length != 0) {
                return (rulesetsDirectory, bytes(""));
            }
            rulesetsFailure = DIRECTORY_FAILURE_INVALID;
        } catch (bytes memory reason) {
            rulesetsFailure = DIRECTORY_FAILURE_REVERT;
            rulesetsFailureReason = reason;
        }

        try IGoalRevnetHookDirectoryReader(configuredHook).directory() returns (IJBDirectory hookDirectory) {
            if (address(hookDirectory) != address(0) && address(hookDirectory).code.length != 0) {
                return (hookDirectory, bytes(""));
            }
            hookFailure = DIRECTORY_FAILURE_INVALID;
        } catch (bytes memory reason) {
            hookFailure = DIRECTORY_FAILURE_REVERT;
            hookFailureReason = reason;
        }

        failureReason = abi.encode(
            address(configuredGoalRulesets),
            rulesetsFailure,
            rulesetsFailureReason,
            configuredHook,
            hookFailure,
            hookFailureReason
        );
        return (IJBDirectory(address(0)), failureReason);
    }

    function _burnViaController(uint256 revnetId, uint256 amount, string memory memo) internal {
        (IJBDirectory directory, ) = _resolveRevnetDirectory(goalRulesets, _hook);
        if (address(directory) == address(0)) revert INVALID_REVNET_CONTROLLER(address(0));

        address controller = address(directory.controllerOf(revnetId));
        if (controller == address(0)) revert INVALID_REVNET_CONTROLLER(controller);
        IJBController(controller).burnTokensOf(address(this), revnetId, amount, memo);
    }

    function _mintingStatus() internal view returns (bool known, bool open) {
        try goalRulesets.currentOf(goalRevnetId) returns (JBRuleset memory ruleset) {
            return (true, ruleset.weight > 0);
        } catch {
            return (false, false);
        }
    }

    function _deriveDeadline() internal view returns (uint64) {
        (JBRuleset memory terminal, JBApprovalStatus approvalStatus) = goalRulesets.latestQueuedOf(goalRevnetId);
        if (
            terminal.id == 0 ||
            terminal.start == 0 ||
            terminal.basedOnId == 0 ||
            terminal.weight != 0 ||
            (approvalStatus != JBApprovalStatus.Empty && approvalStatus != JBApprovalStatus.Approved)
        ) {
            revert DEADLINE_NOT_DERIVABLE();
        }

        JBRuleset memory initial = goalRulesets.getRulesetOf(goalRevnetId, terminal.basedOnId);
        if (initial.id == 0 || initial.weight == 0 || initial.basedOnId != 0 || initial.start >= terminal.start) {
            revert DEADLINE_NOT_DERIVABLE();
        }

        return uint64(terminal.start);
    }
}
