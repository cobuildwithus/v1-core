// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IStakeVault } from "../interfaces/IStakeVault.sol";
import { IStakeVaultUnderwriterConfig } from "../interfaces/IStakeVaultUnderwriterConfig.sol";
import { IRewardEscrow } from "../interfaces/IRewardEscrow.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IGoalRevnetHookDirectoryReader } from "../interfaces/IGoalRevnetHookDirectoryReader.sol";
import { ISuccessAssertionTreasury } from "../interfaces/ISuccessAssertionTreasury.sol";
import { IUMATreasurySuccessResolver } from "../interfaces/IUMATreasurySuccessResolver.sol";
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
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { TreasuryBase } from "./TreasuryBase.sol";
import { GoalSpendPatterns } from "./library/GoalSpendPatterns.sol";
import { TreasuryFlowRateSync } from "./library/TreasuryFlowRateSync.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";
import { TreasuryReassertGrace } from "./library/TreasuryReassertGrace.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";

contract GoalTreasury is IGoalTreasury, TreasuryBase, Initializable {
    using SafeERC20 for IERC20;
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    GoalSpendPatterns.SpendPattern private constant GOAL_SPEND_PATTERN = GoalSpendPatterns.SpendPattern.Linear;
    uint64 private constant REASSERT_GRACE_DURATION = 1 days;
    string private constant SUCCESS_SETTLEMENT_BURN_MEMO = "GOAL_SUCCESS_SETTLEMENT_BURN";
    string private constant SUCCESS_RESIDUAL_BURN_MEMO = "GOAL_SUCCESS_RESIDUAL_BURN";
    string private constant TERMINAL_RESIDUAL_BURN_MEMO = "GOAL_TERMINAL_RESIDUAL_BURN";
    string private constant FAILED_ESCROW_SWEEP_BURN_MEMO = "GOAL_FAILED_ESCROW_SWEEP_BURN";
    string private constant FAILED_ESCROW_SWEEP_COBUILD_BURN_MEMO = "GOAL_FAILED_ESCROW_SWEEP_COBUILD_BURN";
    uint8 private constant TERMINAL_OP_FLOW_STOP = 1;
    uint8 private constant TERMINAL_OP_RESIDUAL_SETTLE = 2;
    uint8 private constant TERMINAL_OP_DEFERRED_SETTLE = 3;
    uint8 private constant TERMINAL_OP_REWARD_ESCROW_FINALIZE = 4;
    uint8 private constant TERMINAL_OP_STAKE_VAULT_RESOLVE = 5;

    GoalState private _state;
    TreasurySuccessAssertions.State private _successAssertions;
    TreasuryReassertGrace.State private _reassertGrace;
    uint64 public override successAt;
    uint64 public override resolvedAt;

    IFlow private _flow;
    IStakeVault private _stakeVault;
    IRewardEscrow private _rewardEscrow;
    address private _hook;
    address private _authority;

    IJBRulesets public override goalRulesets;
    uint256 public override goalRevnetId;
    uint256 public override cobuildRevnetId;
    uint32 public override successSettlementRewardEscrowPpm;

    ISuperToken public override superToken;

    uint64 public override minRaiseDeadline;
    uint64 public override deadline;
    uint256 public override minRaise;
    uint256 public override coverageLambda;
    uint32 public override budgetPremiumPpm;
    uint32 public override budgetSlashPpm;
    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;

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

    error ONLY_SELF();

    event SuccessAssertionResolutionFailClosed(
        bytes32 indexed assertionId,
        TreasurySuccessAssertions.FailClosedReason indexed reason
    );

    constructor(address initialOwner, GoalConfig memory config) {
        if (initialOwner == address(0)) {
            if (!_isImplementationConfig(config)) revert ADDRESS_ZERO();
            _disableInitializers();
            return;
        }

        _initialize(initialOwner, config);
        _disableInitializers();
    }

    function initialize(address initialOwner, GoalConfig calldata config) external initializer {
        _initialize(initialOwner, config);
    }

    function _initialize(address initialOwner, GoalConfig memory config) internal {
        if (initialOwner == address(0)) revert ADDRESS_ZERO();
        if (config.flow == address(0)) revert ADDRESS_ZERO();
        if (config.stakeVault == address(0)) revert ADDRESS_ZERO();
        if (config.hook == address(0)) revert ADDRESS_ZERO();
        if (config.goalRulesets == address(0)) revert ADDRESS_ZERO();
        if (config.successResolver == address(0)) revert ADDRESS_ZERO();
        if (
            config.successAssertionLiveness == 0 ||
            config.successOracleSpecHash == bytes32(0) ||
            config.successAssertionPolicyHash == bytes32(0)
        ) {
            revert INVALID_ASSERTION_CONFIG();
        }
        if (config.successSettlementRewardEscrowPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_SETTLEMENT_SCALED(config.successSettlementRewardEscrowPpm);
        }
        if (config.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_BUDGET_PREMIUM_PPM(config.budgetPremiumPpm);
        }
        if (config.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_BUDGET_SLASH_PPM(config.budgetSlashPpm);
        }
        if (config.successSettlementRewardEscrowPpm != 0 && config.rewardEscrow == address(0)) {
            revert REWARD_ESCROW_NOT_CONFIGURED();
        }

        uint256 nowTs = block.timestamp;
        if (config.minRaiseDeadline == 0 || config.minRaiseDeadline < nowTs) revert INVALID_DEADLINES();

        _flow = IFlow(config.flow);
        _stakeVault = IStakeVault(config.stakeVault);
        _rewardEscrow = IRewardEscrow(config.rewardEscrow);
        _hook = config.hook;
        _authority = initialOwner;
        goalRulesets = IJBRulesets(config.goalRulesets);
        goalRevnetId = config.goalRevnetId;
        cobuildRevnetId = _deriveCobuildRevnetId(goalRevnetId, _stakeVault.cobuildToken(), goalRulesets, _hook);
        successSettlementRewardEscrowPpm = config.successSettlementRewardEscrowPpm;

        address configuredGoalTreasury = _stakeVault.goalTreasury();
        if (configuredGoalTreasury != address(this)) {
            revert STAKE_VAULT_GOAL_MISMATCH(address(this), configuredGoalTreasury);
        }

        superToken = _flow.superToken();
        if (address(superToken) == address(0)) revert ADDRESS_ZERO();
        _requireGoalTokenInvariants(superToken, _stakeVault, goalRulesets, _hook, goalRevnetId);
        if (config.rewardEscrow != address(0)) {
            address rewardEscrowSuperToken = address(_rewardEscrow.rewardSuperToken());
            if (rewardEscrowSuperToken != address(superToken)) {
                revert REWARD_ESCROW_SUPER_TOKEN_MISMATCH(address(superToken), rewardEscrowSuperToken);
            }
        }
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
        coverageLambda = config.coverageLambda;
        budgetPremiumPpm = config.budgetPremiumPpm;
        budgetSlashPpm = config.budgetSlashPpm;
        successResolver = config.successResolver;
        successAssertionLiveness = config.successAssertionLiveness;
        successAssertionBond = config.successAssertionBond;
        successOracleSpecHash = config.successOracleSpecHash;
        successAssertionPolicyHash = config.successAssertionPolicyHash;
        _state = GoalState.Funding;

        emit GoalConfigured(
            initialOwner,
            config.flow,
            config.stakeVault,
            config.rewardEscrow,
            config.hook,
            config.goalRulesets,
            config.goalRevnetId,
            config.minRaiseDeadline,
            derivedDeadline,
            config.minRaise
        );
    }

    function _isImplementationConfig(GoalConfig memory config) private pure returns (bool) {
        return
            config.flow == address(0) &&
            config.stakeVault == address(0) &&
            config.rewardEscrow == address(0) &&
            config.hook == address(0) &&
            config.goalRulesets == address(0) &&
            config.goalRevnetId == 0 &&
            config.minRaiseDeadline == 0 &&
            config.minRaise == 0 &&
            config.coverageLambda == 0 &&
            config.budgetPremiumPpm == 0 &&
            config.budgetSlashPpm == 0 &&
            config.successSettlementRewardEscrowPpm == 0 &&
            config.successResolver == address(0) &&
            config.successAssertionLiveness == 0 &&
            config.successAssertionBond == 0 &&
            config.successOracleSpecHash == bytes32(0) &&
            config.successAssertionPolicyHash == bytes32(0);
    }

    function recordHookFunding(uint256 amount) external override nonReentrant returns (bool accepted) {
        if (msg.sender != _hook) revert ONLY_HOOK();
        if (amount == 0) return false;
        if (block.timestamp >= deadline) revert GOAL_DEADLINE_PASSED();
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
    )
        external
        override
        nonReentrant
        returns (HookSplitAction action, uint256 superTokenAmount, uint256 rewardEscrowAmount, uint256 burnAmount)
    {
        if (msg.sender != _hook) revert ONLY_HOOK();
        if (!_isHookSourceToken(sourceToken)) revert INVALID_HOOK_SOURCE_TOKEN(sourceToken);
        if (sourceAmount == 0) return (HookSplitAction.Deferred, 0, 0, 0);

        GoalDerivedState memory derivedState = _deriveGoalDerivedState();
        HookSplitPath path = _deriveHookSplitPath(derivedState);
        if (path == HookSplitPath.FundingIngress) {
            superTokenAmount = _processFundingIngress(sourceToken, sourceAmount);
            return (HookSplitAction.Funded, superTokenAmount, 0, 0);
        }

        if (path == HookSplitPath.SuccessSettlement) {
            (rewardEscrowAmount, burnAmount) = _processSuccessSettlement(sourceToken, sourceAmount);
            return (HookSplitAction.SuccessSettled, 0, rewardEscrowAmount, burnAmount);
        }

        if (path == HookSplitPath.TerminalSettlement) {
            (superTokenAmount, rewardEscrowAmount, burnAmount) = _processTerminalSettlement(
                derivedState.state,
                sourceToken,
                sourceAmount
            );
            return (HookSplitAction.TerminalSettled, superTokenAmount, rewardEscrowAmount, burnAmount);
        }

        superTokenAmount = _processDeferredIngress(sourceToken, sourceAmount);
        return (HookSplitAction.Deferred, superTokenAmount, 0, 0);
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
        bytes32 clearedAssertionId = _successAssertions.clearMatching(assertionId);
        emit SuccessAssertionCleared(clearedAssertionId);
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

    function sweepFailedAndBurn() external override nonReentrant returns (uint256 amount) {
        if (!_isTerminalState(_state)) revert INVALID_STATE();
        IRewardEscrow escrow = _rewardEscrow;
        if (address(escrow) == address(0)) revert INVALID_STATE();
        IERC20 goalToken = _stakeVault.goalToken();
        IERC20 cobuildToken = _stakeVault.cobuildToken();
        uint256 goalBalanceBefore = goalToken.balanceOf(address(this));
        uint256 cobuildBalanceBefore;
        if (address(cobuildToken) != address(0)) {
            cobuildBalanceBefore = cobuildToken.balanceOf(address(this));
        }

        amount = escrow.releaseFailedAssetsToTreasury();

        uint256 goalBalanceAfter = goalToken.balanceOf(address(this));
        uint256 burnAmount = goalBalanceAfter - goalBalanceBefore;
        if (burnAmount != 0) {
            _burnViaController(goalRevnetId, burnAmount, FAILED_ESCROW_SWEEP_BURN_MEMO);
        }
        if (address(cobuildToken) != address(0)) {
            uint256 cobuildBalanceAfter = cobuildToken.balanceOf(address(this));
            uint256 cobuildSweepAmount = cobuildBalanceAfter - cobuildBalanceBefore;
            if (cobuildSweepAmount != 0) {
                _burnViaController(cobuildRevnetId, cobuildSweepAmount, FAILED_ESCROW_SWEEP_COBUILD_BURN_MEMO);
            }
        }
    }

    function configureJurorSlasher(address slasher) external override {
        if (msg.sender != _authority) revert ONLY_AUTHORITY();
        _stakeVault.setJurorSlasher(slasher);
        emit JurorSlasherConfigured(msg.sender, slasher);
    }

    function configureUnderwriterSlasher(address slasher) external override {
        if (msg.sender != _authority) revert ONLY_AUTHORITY();
        IStakeVaultUnderwriterConfig(address(_stakeVault)).setUnderwriterSlasher(slasher);
        emit UnderwriterSlasherConfigured(msg.sender, slasher);
    }

    function authority() external view override returns (address) {
        return _authority;
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

    function rewardEscrow() external view override returns (address) {
        return address(_rewardEscrow);
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

        return _computeClampedTargetFlowRate(treasuryBalance(), timeRemaining());
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

        _setState(GoalState.Active);
        _syncFlowRate();
    }

    function _syncFlowRate() internal {
        uint256 balance = treasuryBalance();
        uint256 remaining = timeRemaining();
        int96 targetRate = _computeClampedTargetFlowRate(balance, remaining);
        int96 appliedRate = TreasuryFlowRateSync.applyLinearSpendDownWithFallback(
            _flow,
            targetRate,
            balance,
            remaining
        );

        emit FlowRateSynced(targetRate, appliedRate, balance, remaining);
    }

    function _computeClampedTargetFlowRate(uint256 balance, uint256 remaining) internal view returns (int96) {
        int96 targetRate = GoalSpendPatterns.targetFlowRate(GOAL_SPEND_PATTERN, balance, remaining);
        return _clampTargetFlowRateToCoverageCap(targetRate);
    }

    function _coverageCapFlowRate() internal view returns (int96) {
        uint256 lambda = coverageLambda;
        if (lambda == 0) return type(int96).max;

        uint256 cappedRate = uint256(_flow.distributionPool().getTotalUnits()) / lambda;
        uint256 int96Max = uint256(uint96(type(int96).max));
        if (cappedRate > int96Max) {
            cappedRate = int96Max;
        }

        return int96(int256(cappedRate));
    }

    function _clampTargetFlowRateToCoverageCap(int96 targetRate) internal view returns (int96) {
        int96 capRate = _coverageCapFlowRate();
        if (targetRate > capRate) return capRate;
        return targetRate;
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
        _clearPendingSuccessAssertion();

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
        (bool flowStopped, bytes memory flowStopReason) = _tryForceFlowRateToZero();
        if (!flowStopped) {
            emit TerminalSideEffectFailed(TERMINAL_OP_FLOW_STOP, flowStopReason);
        }

        _trySettleResidual(finalState);
        _trySettleDeferredHookFunding(finalState);
        _tryFinalizeRewardEscrow(finalState);
        _tryMarkStakeVaultResolved();
    }

    function _trySettleResidual(GoalState finalState) internal {
        try this.settleResidualForFinalize(finalState) {} catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_RESIDUAL_SETTLE, reason);
        }
    }

    function _trySettleDeferredHookFunding(GoalState finalState) internal {
        try this.settleDeferredHookFundingForFinalize(finalState) {} catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_DEFERRED_SETTLE, reason);
        }
    }

    function _tryFinalizeRewardEscrow(GoalState finalState) internal {
        IRewardEscrow escrow = _rewardEscrow;
        if (address(escrow) == address(0)) return;

        bool escrowFinalized;
        try escrow.finalized() returns (bool finalized_) {
            escrowFinalized = finalized_;
        } catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_REWARD_ESCROW_FINALIZE, reason);
            return;
        }
        if (escrowFinalized) return;

        uint64 rewardEscrowFinalizedAt = resolvedAt;
        if (finalState == GoalState.Succeeded && successAt != 0) {
            rewardEscrowFinalizedAt = successAt;
        }

        try escrow.finalize(uint8(finalState), rewardEscrowFinalizedAt) {
            if (finalState != GoalState.Succeeded) return;

            bool escrowNowFinalized;
            try escrow.finalized() returns (bool finalized_) {
                escrowNowFinalized = finalized_;
            } catch (bytes memory reason) {
                emit TerminalSideEffectFailed(TERMINAL_OP_REWARD_ESCROW_FINALIZE, reason);
                return;
            }

            if (escrowNowFinalized) {
                emit SuccessRewardsFinalized(rewardEscrowFinalizedAt, uint64(block.timestamp));
            }
        } catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_REWARD_ESCROW_FINALIZE, reason);
        }
    }

    function _tryMarkStakeVaultResolved() internal {
        bool stakeVaultResolved;
        try _stakeVault.goalResolved() returns (bool resolved_) {
            stakeVaultResolved = resolved_;
        } catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_STAKE_VAULT_RESOLVE, reason);
            return;
        }
        if (stakeVaultResolved) return;

        try _stakeVault.markGoalResolved() {} catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_STAKE_VAULT_RESOLVE, reason);
        }
    }

    function settleResidualForFinalize(GoalState finalState) external {
        if (msg.sender != address(this)) revert ONLY_SELF();
        _settleResidual(finalState);
    }

    function settleDeferredHookFundingForFinalize(GoalState finalState) external {
        if (msg.sender != address(this)) revert ONLY_SELF();
        _settleDeferredHookFunding(finalState);
    }

    function _tryFinalizePostDeadline() internal returns (bool) {
        bytes32 pendingAssertionId = TreasurySuccessAssertions.pendingId(_successAssertions);
        if (pendingAssertionId == bytes32(0)) {
            if (_reassertGrace.isActive()) return false;
            _finalize(GoalState.Expired);
            return true;
        }

        (
            bool assertionResolved,
            bool assertionTruthful,
            TreasurySuccessAssertions.FailClosedReason failClosedReason
        ) = _successAssertions.pendingSuccessAssertionResolutionWithReason(
                pendingAssertionId,
                successResolver,
                successAssertionLiveness,
                successAssertionBond
            );
        if (failClosedReason != TreasurySuccessAssertions.FailClosedReason.None) {
            emit SuccessAssertionResolutionFailClosed(pendingAssertionId, failClosedReason);
        }
        if (!assertionResolved) return false;

        if (assertionTruthful) {
            _finalize(GoalState.Succeeded);
            return true;
        }

        if (!_reassertGrace.used) {
            bytes32 clearedAssertionId = _clearPendingSuccessAssertion();
            if (clearedAssertionId != bytes32(0)) {
                try IUMATreasurySuccessResolver(successResolver).finalize(clearedAssertionId) { } catch { }
            }
            _tryActivateReassertGrace(clearedAssertionId);
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

    function _clearPendingSuccessAssertion() internal returns (bytes32 clearedAssertionId) {
        clearedAssertionId = _successAssertions.clear();
        if (clearedAssertionId == bytes32(0)) return bytes32(0);
        emit SuccessAssertionCleared(clearedAssertionId);
    }

    function _settleResidual(GoalState finalState) internal {
        uint256 settled = _flow.sweepSuperToken(address(this), type(uint256).max);
        if (settled == 0) {
            emit ResidualSettled(finalState, 0, 0, 0);
            return;
        }

        (uint256 rewardAmount, uint256 burnAmount) = _settleSuperTokenAmount(finalState, settled);

        emit ResidualSettled(finalState, settled, rewardAmount, burnAmount);
    }

    function _settleDeferredHookFunding(GoalState finalState) internal {
        uint256 deferred = deferredHookSuperTokenAmount;
        if (deferred == 0) return;

        deferredHookSuperTokenAmount = 0;
        (uint256 rewardAmount, uint256 burnAmount) = _settleSuperTokenAmount(finalState, deferred);
        emit HookDeferredFundingSettled(finalState, deferred, rewardAmount, burnAmount);
    }

    function _settleSuperTokenAmount(
        GoalState finalState,
        uint256 settled
    ) internal returns (uint256 rewardAmount, uint256 burnAmount) {
        uint256 burnSuperTokenAmount;

        if (finalState == GoalState.Succeeded) {
            rewardAmount = Math.mulDiv(
                settled,
                successSettlementRewardEscrowPpm,
                FlowProtocolConstants.PPM_SCALE_UINT256
            );
            burnSuperTokenAmount = settled - rewardAmount;

            if (rewardAmount != 0) {
                if (address(_rewardEscrow) == address(0)) revert REWARD_ESCROW_NOT_CONFIGURED();
                IERC20(address(superToken)).safeTransfer(address(_rewardEscrow), rewardAmount);
            }
        } else {
            burnSuperTokenAmount = settled;
        }

        if (burnSuperTokenAmount == 0) return (rewardAmount, 0);

        IERC20 underlyingToken = IERC20(superToken.getUnderlyingToken());
        uint256 underlyingBefore = underlyingToken.balanceOf(address(this));
        superToken.downgrade(burnSuperTokenAmount);
        burnAmount = underlyingToken.balanceOf(address(this)) - underlyingBefore;
        if (burnAmount != 0) {
            _burnViaController(
                goalRevnetId,
                burnAmount,
                finalState == GoalState.Succeeded ? SUCCESS_RESIDUAL_BURN_MEMO : TERMINAL_RESIDUAL_BURN_MEMO
            );
        }
    }

    function _settleSuccessHookSplit(
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 rewardAmount, uint256 burnAmount) {
        rewardAmount = Math.mulDiv(
            sourceAmount,
            successSettlementRewardEscrowPpm,
            FlowProtocolConstants.PPM_SCALE_UINT256
        );
        burnAmount = sourceAmount - rewardAmount;

        if (rewardAmount != 0) {
            if (address(_rewardEscrow) == address(0)) revert REWARD_ESCROW_NOT_CONFIGURED();
            IERC20(sourceToken).safeTransfer(address(_rewardEscrow), rewardAmount);
        }

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

    function _processSuccessSettlement(
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 rewardEscrowAmount, uint256 burnAmount) {
        (rewardEscrowAmount, burnAmount) = _settleSuccessHookSplit(sourceToken, sourceAmount);
    }

    function _processTerminalSettlement(
        GoalState terminalState,
        address sourceToken,
        uint256 sourceAmount
    ) internal returns (uint256 superTokenAmount, uint256 rewardEscrowAmount, uint256 burnAmount) {
        superTokenAmount = _convertHeldSourceToSuperToken(sourceToken, sourceAmount);
        (rewardEscrowAmount, burnAmount) = _settleSuperTokenAmount(terminalState, superTokenAmount);
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

        IJBDirectory directory = _resolveRevnetDirectory(configuredGoalRulesets, configuredHook);
        if (address(directory) == address(0)) {
            revert COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
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

        IJBDirectory directory = _resolveRevnetDirectory(configuredGoalRulesets, configuredHook);
        if (address(directory) == address(0)) {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(configuredGoalToken));
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
    ) private view returns (IJBDirectory directory) {
        // Prefer rulesets as the canonical source so treasury init does not depend on hook init ordering.
        try IJBControlled(address(configuredGoalRulesets)).DIRECTORY() returns (IJBDirectory rulesetsDirectory) {
            if (address(rulesetsDirectory) != address(0) && address(rulesetsDirectory).code.length != 0) {
                return rulesetsDirectory;
            }
        } catch {
            // Fall back to the hook directory when rulesets does not expose DIRECTORY.
        }

        try IGoalRevnetHookDirectoryReader(configuredHook).directory() returns (IJBDirectory hookDirectory) {
            if (address(hookDirectory) != address(0) && address(hookDirectory).code.length != 0) {
                return hookDirectory;
            }
        } catch {}

        return IJBDirectory(address(0));
    }

    function _burnViaController(uint256 revnetId, uint256 amount, string memory memo) internal {
        IJBDirectory directory = _resolveRevnetDirectory(goalRulesets, _hook);
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
