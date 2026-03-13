// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IStakeVault } from "../interfaces/IStakeVault.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { ISpendPolicy } from "../interfaces/ISpendPolicy.sol";
import { ISuccessAssertionTreasury } from "../interfaces/ISuccessAssertionTreasury.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TreasuryFlowRateSync } from "./library/TreasuryFlowRateSync.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";
import { TreasuryReassertGrace } from "./library/TreasuryReassertGrace.sol";
import { TreasurySuccessAssertionLifecycle } from "./library/TreasurySuccessAssertionLifecycle.sol";
import { GoalTreasuryTerminalRollover } from "./library/GoalTreasuryTerminalRollover.sol";
import { GoalTreasuryRevnetLib } from "./library/GoalTreasuryRevnetLib.sol";
import { TreasurySuccessAssertionMixin } from "./TreasurySuccessAssertionMixin.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";

contract GoalTreasury is IGoalTreasury, TreasurySuccessAssertionMixin {
    using SafeERC20 for IERC20;
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    uint64 private constant REASSERT_GRACE_DURATION = 1 days;
    string private constant SUCCESS_SETTLEMENT_BURN_MEMO = "GOAL_SUCCESS_SETTLEMENT_BURN";
    string private constant SUCCESS_RESIDUAL_BURN_MEMO = "GOAL_SUCCESS_RESIDUAL_BURN";
    string private constant TERMINAL_RESIDUAL_BURN_MEMO = "GOAL_TERMINAL_RESIDUAL_BURN";
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
    uint64 public override terminalRolloverCooldown;
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

    function initialize(GoalConfig calldata config) external initializer {
        __ReentrancyGuard_init();
        _initialize(config);
    }

    function _initialize(GoalConfig memory config) private {
        if (config.flow == address(0)) revert ADDRESS_ZERO();
        if (config.stakeVault == address(0)) revert ADDRESS_ZERO();
        if (config.jurorSlasher != address(0) && config.jurorSlasher.code.length == 0) {
            revert NOT_A_CONTRACT(config.jurorSlasher);
        }
        if (config.budgetStakeLedger == address(0)) revert ADDRESS_ZERO();
        if (config.budgetStakeLedger.code.length == 0) revert NOT_A_CONTRACT(config.budgetStakeLedger);
        if (config.hook == address(0)) revert ADDRESS_ZERO();
        if (config.goalRulesets == address(0)) revert ADDRESS_ZERO();
        if (config.successResolver == address(0)) revert ADDRESS_ZERO();
        if (config.spendPolicy == address(0)) revert ADDRESS_ZERO();
        if (config.spendPolicy.code.length == 0) revert NOT_A_CONTRACT(config.spendPolicy);
        _requireValidSpendPolicy(config.spendPolicy);
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
        if (config.budgetSlashPpm == 0) {
            if (config.underwriterSlasher != address(0)) revert ADDRESS_ZERO();
        } else if (config.underwriterSlasher == address(0)) {
            revert ADDRESS_ZERO();
        } else if (config.underwriterSlasher.code.length == 0) {
            revert NOT_A_CONTRACT(config.underwriterSlasher);
        }

        uint256 nowTs = block.timestamp;
        if (config.minRaiseDeadline == 0 || config.minRaiseDeadline < nowTs) revert INVALID_DEADLINES();

        _flow = IFlow(config.flow);
        _stakeVault = IStakeVault(config.stakeVault);
        _budgetStakeLedger = config.budgetStakeLedger;
        _hook = config.hook;
        goalRulesets = IJBRulesets(config.goalRulesets);
        goalRevnetId = config.goalRevnetId;
        address configuredGoalTreasury = _stakeVault.goalTreasury();
        if (configuredGoalTreasury != address(this)) {
            revert STAKE_VAULT_GOAL_MISMATCH(address(this), configuredGoalTreasury);
        }
        address ledgerGoalTreasury = IBudgetStakeLedger(_budgetStakeLedger).goalTreasury();
        if (ledgerGoalTreasury != address(this)) {
            revert BUDGET_STAKE_LEDGER_GOAL_MISMATCH(address(this), ledgerGoalTreasury);
        }
        if (config.jurorSlasher != address(0)) {
            _stakeVault.setJurorSlasher(config.jurorSlasher);
        }
        if (config.budgetSlashPpm != 0) {
            _stakeVault.setUnderwriterSlasher(config.underwriterSlasher);
        }

        ISuperToken configuredSuperToken = _flow.superToken();
        if (address(configuredSuperToken) == address(0)) revert ADDRESS_ZERO();
        (
            address configuredGoalTokenAddress,
            address configuredCobuildTokenAddress,
            uint256 derivedCobuildRevnetId,
            uint64 derivedDeadline
        ) = GoalTreasuryRevnetLib.deriveInitState(_stakeVault, configuredSuperToken, goalRulesets, _hook, goalRevnetId);
        IERC20 configuredGoalToken = IERC20(configuredGoalTokenAddress);
        IERC20 configuredCobuildToken = IERC20(configuredCobuildTokenAddress);
        cobuildRevnetId = derivedCobuildRevnetId;
        superToken = configuredSuperToken;
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
        terminalRolloverCooldown = config.terminalRolloverCooldown;
        successResolver = config.successResolver;
        successAssertionLiveness = config.successAssertionLiveness;
        successAssertionBond = config.successAssertionBond;
        successOracleSpecHash = config.successOracleSpecHash;
        successAssertionPolicyHash = config.successAssertionPolicyHash;
        spendPolicy = config.spendPolicy;
        _state = GoalState.Funding;

        emit GoalConfigured(
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

    function pendingSuccessAssertionId()
        public
        view
        override(ISuccessAssertionTreasury, TreasurySuccessAssertionMixin)
        returns (bytes32)
    {
        return super.pendingSuccessAssertionId();
    }

    function pendingSuccessAssertionAt()
        public
        view
        override(ISuccessAssertionTreasury, TreasurySuccessAssertionMixin)
        returns (uint64)
    {
        return super.pendingSuccessAssertionAt();
    }

    function reassertGraceDeadline()
        public
        view
        override(ISuccessAssertionTreasury, TreasurySuccessAssertionMixin)
        returns (uint64)
    {
        return super.reassertGraceDeadline();
    }

    function reassertGraceUsed()
        public
        view
        override(ISuccessAssertionTreasury, TreasurySuccessAssertionMixin)
        returns (bool)
    {
        return super.reassertGraceUsed();
    }

    function isReassertGraceActive()
        public
        view
        override(ISuccessAssertionTreasury, TreasurySuccessAssertionMixin)
        returns (bool)
    {
        return super.isReassertGraceActive();
    }

    function resolved() public view override(IGoalTreasury, TreasurySuccessAssertionMixin) returns (bool) {
        return super.resolved();
    }

    function flow() public view override(IGoalTreasury, TreasurySuccessAssertionMixin) returns (address) {
        return super.flow();
    }

    function treasuryBalance() public view override(IGoalTreasury, TreasurySuccessAssertionMixin) returns (uint256) {
        return super.treasuryBalance();
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
        if (sourceToken != superToken.getUnderlyingToken()) revert INVALID_HOOK_SOURCE_TOKEN(sourceToken);
        if (sourceAmount == 0) return (HookSplitAction.Deferred, 0, 0);

        GoalDerivedState memory derivedState = _deriveGoalDerivedState();
        HookSplitPath path = _deriveHookSplitPath(derivedState);
        if (path == HookSplitPath.FundingIngress) {
            superTokenAmount = _processFundingIngress(sourceAmount);
            return (HookSplitAction.Funded, superTokenAmount, 0);
        }

        if (path == HookSplitPath.SuccessSettlement) {
            burnAmount = _settleSuccessHookSplit(sourceAmount);
            return (HookSplitAction.SuccessSettled, 0, burnAmount);
        }

        if (path == HookSplitPath.TerminalSettlement) {
            (superTokenAmount, burnAmount) = _processTerminalSettlement(derivedState.state, sourceAmount);
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
            } else if (treasuryBalance() >= minRaise) {
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

    function treasuryKind() external pure override returns (ISuccessAssertionTreasury.TreasuryKind) {
        return ISuccessAssertionTreasury.TreasuryKind.Goal;
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
        TreasurySuccessAssertionLifecycle.ClearResult memory clearResult = TreasurySuccessAssertionLifecycle
            .clearMatchingAndTryActivateGrace(
                _successAssertions,
                _reassertGrace,
                assertionId,
                _canActivateReassertGrace(),
                REASSERT_GRACE_DURATION
            );
        _emitSuccessAssertionCleared(clearResult.clearedAssertionId);
        if (clearResult.graceActivated) {
            _emitReassertGraceActivated(clearResult.clearedAssertionId, clearResult.graceDeadline);
        }
    }

    function settleLateResidual() external override nonReentrant {
        GoalState finalState = _state;
        if (!_isTerminalState(finalState)) {
            revert INVALID_STATE();
        }

        _settleResidual(finalState);
        _settleDeferredHookFunding(finalState);
    }

    function state() external view override returns (GoalState) {
        return _state;
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
        uint256 raised = treasuryBalance();
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

        uint128 totalUnits = _flow.distributionPool().getTotalUnits();
        if (totalUnits == 0) return 0;

        return ISpendPolicy(spendPolicy).targetFlowRate(_buildSpendContext(balance, remaining));
    }

    function _buildSpendContext(
        uint256 balance,
        uint256 remaining
    ) internal view returns (ISpendPolicy.SpendContext memory ctx) {
        ctx = ISpendPolicy.SpendContext({
            nowTs: uint64(block.timestamp),
            activatedAt: activatedAt,
            deadline: deadline,
            treasuryBalance: balance,
            timeRemaining: remaining,
            incomingRate: 0,
            currentOutflowRate: _flow.targetOutflowRate()
        });
    }

    function _revertInvalidSpendPolicy(address candidate) internal pure override {
        revert INVALID_SPEND_POLICY(candidate);
    }

    function _minRaiseWindowElapsedWithoutGoal(GoalState currentState) internal view returns (bool) {
        return currentState == GoalState.Funding && block.timestamp > minRaiseDeadline && treasuryBalance() < minRaise;
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

        _clearPendingSuccessAssertionAndResetGrace();

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
        PostDeadlineAction action = _resolvePostDeadlineAction(REASSERT_GRACE_DURATION);
        if (action == PostDeadlineAction.None) return false;
        if (action == PostDeadlineAction.FinalizeSucceeded) {
            _finalize(GoalState.Succeeded);
            return true;
        }
        _finalize(GoalState.Expired);
        return true;
    }

    function _canActivateReassertGrace() internal view override returns (bool) {
        return _state == GoalState.Active && block.timestamp >= deadline;
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

    function _settleResidual(GoalState finalState) internal {
        uint256 settled = _flow.sweepSuperToken(address(this), type(uint256).max);
        uint256 burnAmount = _settleSuperTokenAmount(finalState, settled);
        if (settled == 0 && finalState == GoalState.Succeeded && terminalRolloverCooldown != 0) {
            GoalTreasuryTerminalRollover.queueHeldBalanceIfAny(
                GoalTreasuryRevnetLib.requireResolvedDirectory(goalRulesets, _hook),
                cobuildRevnetId,
                _stakeVault.cobuildToken(),
                GoalTreasuryTerminalRollover.terminalRolloverReleaseAt(resolvedAt, terminalRolloverCooldown)
            );
        }

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
        uint256 goalTokenAmount = underlyingToken.balanceOf(address(this)) - underlyingBefore;
        if (goalTokenAmount == 0) return 0;

        if (finalState == GoalState.Succeeded && terminalRolloverCooldown != 0) {
            _queueSucceededTerminalRollover(goalTokenAmount);
            return 0;
        }

        burnAmount = goalTokenAmount;
        if (burnAmount != 0) {
            GoalTreasuryRevnetLib.burnViaController(
                goalRulesets,
                _hook,
                goalRevnetId,
                burnAmount,
                finalState == GoalState.Succeeded ? SUCCESS_RESIDUAL_BURN_MEMO : TERMINAL_RESIDUAL_BURN_MEMO
            );
        }
    }

    function _queueSucceededTerminalRollover(uint256 goalTokenAmount) internal {
        IJBDirectory directory = GoalTreasuryRevnetLib.requireResolvedDirectory(goalRulesets, _hook);
        IERC20 paymentToken = _stakeVault.cobuildToken();
        uint64 releaseAt = GoalTreasuryTerminalRollover.terminalRolloverReleaseAt(resolvedAt, terminalRolloverCooldown);
        GoalTreasuryTerminalRollover.queueHeldBalanceIfAny(directory, cobuildRevnetId, paymentToken, releaseAt);
        uint256 rolloverAmount = GoalTreasuryTerminalRollover.cashOutAndQueue(
            directory,
            goalRevnetId,
            cobuildRevnetId,
            paymentToken,
            superToken.getUnderlyingToken(),
            goalTokenAmount,
            releaseAt
        );

        emit TerminalRolloverQueued(goalRevnetId, goalTokenAmount, rolloverAmount, releaseAt);
    }

    function _settleSuccessHookSplit(uint256 sourceAmount) internal returns (uint256 burnAmount) {
        burnAmount = sourceAmount;

        if (burnAmount != 0) {
            GoalTreasuryRevnetLib.burnViaController(
                goalRulesets,
                _hook,
                goalRevnetId,
                burnAmount,
                SUCCESS_SETTLEMENT_BURN_MEMO
            );
        }
    }

    function _processFundingIngress(uint256 sourceAmount) internal returns (uint256 superTokenAmount) {
        superTokenAmount = _moveHeldSourceToFlowAsSuperToken(sourceAmount);
        _requireHookSuperTokenAmountMatches(sourceAmount, superTokenAmount);
        totalRaised += superTokenAmount;
        emit HookFundingRecorded(superTokenAmount, totalRaised);
    }

    function _processTerminalSettlement(
        GoalState terminalState,
        uint256 sourceAmount
    ) internal returns (uint256 superTokenAmount, uint256 burnAmount) {
        superTokenAmount = _convertHeldSourceToSuperToken(sourceAmount);
        burnAmount = _settleSuperTokenAmount(terminalState, superTokenAmount);
    }

    function _processDeferredIngress(
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 superTokenAmount) {
        superTokenAmount = _convertHeldSourceToSuperToken(sourceAmount);
        _requireHookSuperTokenAmountMatches(sourceAmount, superTokenAmount);

        deferredHookSuperTokenAmount += superTokenAmount;
        emit HookFundingDeferred(sourceToken, sourceAmount, superTokenAmount, deferredHookSuperTokenAmount);
    }

    function _requireHookSuperTokenAmountMatches(uint256 sourceAmount, uint256 superTokenAmount) internal pure {
        if (superTokenAmount != sourceAmount) {
            revert HOOK_SUPER_TOKEN_AMOUNT_MISMATCH(sourceAmount, superTokenAmount);
        }
    }

    function _moveHeldSourceToFlowAsSuperToken(uint256 sourceAmount) internal returns (uint256) {
        uint256 flowBalanceBefore = IERC20(address(superToken)).balanceOf(address(_flow));
        uint256 superTokenAmount = _convertHeldSourceToSuperToken(sourceAmount);

        if (superTokenAmount != 0) {
            IERC20(address(superToken)).safeTransfer(address(_flow), superTokenAmount);
        }

        return IERC20(address(superToken)).balanceOf(address(_flow)) - flowBalanceBefore;
    }

    function _convertHeldSourceToSuperToken(uint256 sourceAmount) internal returns (uint256) {
        IERC20 underlyingToken = IERC20(superToken.getUnderlyingToken());
        _requireTreasuryTokenBalance(underlyingToken, sourceAmount);

        uint256 superBalanceBefore = IERC20(address(superToken)).balanceOf(address(this));
        underlyingToken.forceApprove(address(superToken), 0);
        underlyingToken.forceApprove(address(superToken), sourceAmount);
        superToken.upgrade(sourceAmount);
        underlyingToken.forceApprove(address(superToken), 0);

        return IERC20(address(superToken)).balanceOf(address(this)) - superBalanceBefore;
    }

    function _requireTreasuryTokenBalance(IERC20 token, uint256 amount) internal view {
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert INSUFFICIENT_TREASURY_BALANCE(address(token), amount, balance);
    }

    function _successAssertionsState()
        internal
        view
        override
        returns (TreasurySuccessAssertions.State storage assertionsState)
    {
        assertionsState = _successAssertions;
    }

    function _reassertGraceState() internal view override returns (TreasuryReassertGrace.State storage graceState) {
        graceState = _reassertGrace;
    }

    function _spendPolicy() internal view override returns (address) {
        return spendPolicy;
    }

    function _successResolver() internal view override returns (address) {
        return successResolver;
    }

    function _successAssertionLiveness() internal view override returns (uint64) {
        return successAssertionLiveness;
    }

    function _successAssertionBond() internal view override returns (uint256) {
        return successAssertionBond;
    }

    function _isResolvedState() internal view override returns (bool) {
        return _isTerminalState(_state);
    }

    function _emitSuccessAssertionCleared(bytes32 assertionId) internal override {
        if (assertionId == bytes32(0)) return;
        emit SuccessAssertionCleared(assertionId);
    }

    function _emitSuccessAssertionResolutionFailClosed(
        bytes32 assertionId,
        TreasurySuccessAssertions.FailClosedReason reason
    ) internal override {
        emit SuccessAssertionResolutionFailClosed(assertionId, reason);
    }

    function _emitSuccessAssertionFinalizeFailed(bytes32 assertionId, bytes memory revertData) internal override {
        emit SuccessAssertionFinalizeFailed(assertionId, revertData);
    }

    function _emitReassertGraceActivated(bytes32 clearedAssertionId, uint64 graceDeadline) internal override {
        emit ReassertGraceActivated(clearedAssertionId, graceDeadline);
    }

    function _mintingStatus() internal view returns (bool known, bool open) {
        try goalRulesets.currentOf(goalRevnetId) returns (JBRuleset memory ruleset) {
            return (true, ruleset.weight > 0);
        } catch {
            return (false, false);
        }
    }
}
