// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "../interfaces/IPremiumEscrow.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { ISpendPolicy } from "../interfaces/ISpendPolicy.sol";
import { ISuccessAssertionTreasury } from "../interfaces/ISuccessAssertionTreasury.sol";
import { IBudgetTCR } from "../tcr/interfaces/IBudgetTCR.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TreasuryBase } from "./TreasuryBase.sol";
import { TreasuryFlowRateSync } from "./library/TreasuryFlowRateSync.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";
import { TreasuryReassertGrace } from "./library/TreasuryReassertGrace.sol";
import { TreasuryPostDeadlineFinalize } from "./library/TreasuryPostDeadlineFinalize.sol";
import { TreasurySuccessAssertionLifecycle } from "./library/TreasurySuccessAssertionLifecycle.sol";

contract BudgetTreasury is IBudgetTreasury, TreasuryBase {
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    uint64 private constant REASSERT_GRACE_DURATION = 1 days;

    BudgetState private _state;
    TreasurySuccessAssertions.State private _successAssertions;
    TreasuryReassertGrace.State private _reassertGrace;

    IFlow private _flow;
    ISuperToken public override superToken;
    address public override premiumEscrow;

    uint64 public override fundingDeadline;
    uint64 public override executionDuration;
    address public override controller;
    uint256 public override activationThreshold;
    uint256 public override runwayCap;
    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;
    address public override spendPolicy;

    uint64 public override deadline;
    uint64 public override activatedAt;
    uint64 public override resolvedAt;
    bool public override successResolutionDisabled;

    struct BudgetDerivedState {
        BudgetState state;
        bool isTerminal;
        bool fundingWindowEnded;
        bool deadlinePassed;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialController, BudgetConfig calldata config) external initializer {
        __ReentrancyGuard_init();
        controller = _requireNonZeroController(initialController);
        if (config.flow == address(0)) revert ADDRESS_ZERO();
        address premiumEscrow_ = config.premiumEscrow;
        if (premiumEscrow_ == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrow_.code.length == 0) revert NOT_A_CONTRACT(premiumEscrow_);
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
        if (config.executionDuration == 0) revert INVALID_EXECUTION_DURATION();
        if (config.runwayCap != 0 && config.runwayCap < config.activationThreshold) {
            revert INVALID_THRESHOLDS(config.activationThreshold, config.runwayCap);
        }

        uint256 nowTs = block.timestamp;
        if (config.fundingDeadline == 0 || config.fundingDeadline < nowTs) revert INVALID_DEADLINES();
        if (uint256(config.fundingDeadline) + uint256(config.executionDuration) > type(uint64).max) {
            revert INVALID_DEADLINES();
        }

        _flow = IFlow(config.flow);

        superToken = _flow.superToken();
        if (address(superToken) == address(0)) revert ADDRESS_ZERO();
        address configuredFlowOperator = _flow.flowOperator();
        address configuredSweeper = _flow.sweeper();
        if (configuredFlowOperator != address(this) || configuredSweeper != address(this)) {
            revert FLOW_AUTHORITY_MISMATCH(address(this), configuredFlowOperator, configuredSweeper);
        }
        address parentFlow = _flow.parent();
        if (parentFlow == address(0) || parentFlow.code.length == 0) revert PARENT_FLOW_NOT_CONFIGURED();
        try IFlow(parentFlow).getMemberFlowRate(address(_flow)) returns (int96) {} catch {
            revert PARENT_FLOW_NOT_CONFIGURED();
        }

        fundingDeadline = config.fundingDeadline;
        executionDuration = config.executionDuration;
        activationThreshold = config.activationThreshold;
        runwayCap = config.runwayCap;
        premiumEscrow = premiumEscrow_;
        successResolver = config.successResolver;
        successAssertionLiveness = config.successAssertionLiveness;
        successAssertionBond = config.successAssertionBond;
        successOracleSpecHash = config.successOracleSpecHash;
        successAssertionPolicyHash = config.successAssertionPolicyHash;
        spendPolicy = config.spendPolicy;

        _state = BudgetState.Funding;

        emit BudgetConfigured(
            initialController,
            config.flow,
            config.fundingDeadline,
            config.executionDuration,
            config.activationThreshold,
            config.runwayCap
        );
    }

    function canAcceptFunding() public view override returns (bool) {
        return _canAcceptFunding(_deriveBudgetDerivedState());
    }

    function sync() external override nonReentrant {
        BudgetDerivedState memory derivedState = _deriveBudgetDerivedState();
        if (derivedState.isTerminal) return;

        if (derivedState.state == BudgetState.Funding) {
            if (successResolutionDisabled) {
                _finalize(BudgetState.Failed);
                return;
            }
            if (treasuryBalance() >= activationThreshold) {
                _activateAndSync();
                if (block.timestamp >= deadline) {
                    if (_tryFinalizePostDeadline()) return;
                }
            } else if (derivedState.fundingWindowEnded) {
                _finalize(BudgetState.Expired);
            }
            return;
        }

        if (derivedState.deadlinePassed) {
            if (_tryFinalizePostDeadline()) return;
        }

        _syncFlowRate();
    }

    function retryTerminalSideEffects() external override nonReentrant {
        BudgetState terminalState = _state;
        if (!_isTerminalState(terminalState)) revert INVALID_STATE();
        _runTerminalSideEffects(terminalState);
    }

    function forceFlowRateToZero() external override onlyController nonReentrant {
        _forceFlowRateToZero();
    }

    function resolveSuccess() external override nonReentrant {
        if (msg.sender != successResolver) revert ONLY_SUCCESS_RESOLVER();
        if (_state != BudgetState.Active) revert INVALID_STATE();
        if (successResolutionDisabled) revert SUCCESS_RESOLUTION_DISABLED();
        _successAssertions.requirePending();
        _successAssertions.requireTruthful(successResolver, successAssertionLiveness, successAssertionBond);

        _finalize(BudgetState.Succeeded);
    }

    function resolveFailure() external override onlyController nonReentrant {
        BudgetState currentState = _state;
        if (currentState != BudgetState.Active && currentState != BudgetState.Funding) revert INVALID_STATE();

        if (successResolutionDisabled) {
            _finalize(BudgetState.Failed);
            return;
        }

        if (currentState == BudgetState.Funding) {
            if (!_isFundingWindowEnded()) revert FUNDING_WINDOW_NOT_ENDED();
        } else {
            if (TreasurySuccessAssertions.pendingId(_successAssertions) != bytes32(0)) {
                revert SUCCESS_ASSERTION_PENDING();
            }
            if (block.timestamp < deadline) revert DEADLINE_NOT_REACHED();
        }

        _finalize(BudgetState.Failed);
    }

    function pendingSuccessAssertionId() external view override returns (bytes32) {
        return TreasurySuccessAssertions.pendingId(_successAssertions);
    }

    function treasuryKind() external pure override returns (ISuccessAssertionTreasury.TreasuryKind) {
        return ISuccessAssertionTreasury.TreasuryKind.Budget;
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
        if (msg.sender != successResolver) revert ONLY_SUCCESS_RESOLVER();
        if (_state != BudgetState.Active) revert INVALID_STATE();
        if (successResolutionDisabled) revert SUCCESS_RESOLUTION_DISABLED();
        if (!_isFundingWindowEnded()) revert FUNDING_WINDOW_NOT_ENDED();
        if (block.timestamp >= deadline) {
            if (!_reassertGrace.consumeIfActive()) revert BUDGET_DEADLINE_PASSED();
        }

        uint64 assertedAt = _successAssertions.registerPending(assertionId);
        emit SuccessAssertionRegistered(assertionId, assertedAt);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_SUCCESS_RESOLVER();
        bytes32 clearedAssertionId = TreasurySuccessAssertionLifecycle.clearMatching(_successAssertions, assertionId);
        _emitSuccessAssertionCleared(clearedAssertionId);
        _tryActivateReassertGrace(clearedAssertionId);
    }

    function disableSuccessResolution() external override onlyController {
        if (successResolutionDisabled) return;

        successResolutionDisabled = true;
        _reassertGrace.clearDeadline();
        _emitSuccessAssertionCleared(TreasurySuccessAssertionLifecycle.clearPending(_successAssertions));
        emit SuccessResolutionDisabled();
    }

    function settleLateResidualToParent() external override nonReentrant returns (uint256 amount) {
        if (!_isTerminalState(_state)) revert INVALID_STATE();
        amount = _settleResidualToParent();
    }

    function resolved() external view override returns (bool) {
        return _isTerminalState(_state);
    }

    function state() external view override returns (BudgetState) {
        return _state;
    }

    function flow() external view override returns (address) {
        return address(_flow);
    }

    function authority() external view override returns (address) {
        return controller;
    }

    function treasuryBalance() public view override returns (uint256) {
        return _treasuryBalance();
    }

    function timeRemaining() public view override returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (deadline == 0 || block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function targetFlowRate() public view override returns (int96) {
        if (_state != BudgetState.Active) return 0;

        uint256 balance = treasuryBalance();
        uint256 remaining = timeRemaining();
        // slither-disable-next-line incorrect-equality
        if (remaining == 0) return 0;

        return ISpendPolicy(spendPolicy).targetFlowRate(_buildSpendContext(balance, remaining));
    }

    function lifecycleStatus() external view override returns (BudgetLifecycleStatus memory status) {
        uint256 treasuryBalance_ = treasuryBalance();
        bool deadlineSet = deadline != 0;
        status = BudgetLifecycleStatus({
            currentState: _state,
            isResolved: _isTerminalState(_state),
            canAcceptFunding: canAcceptFunding(),
            isSuccessResolutionDisabled: successResolutionDisabled,
            isFundingWindowEnded: _isFundingWindowEnded(),
            hasDeadline: deadlineSet,
            isDeadlinePassed: deadlineSet && block.timestamp >= deadline,
            hasPendingSuccessAssertion: TreasurySuccessAssertions.pendingId(_successAssertions) != bytes32(0),
            treasuryBalance: treasuryBalance_,
            activationThreshold: activationThreshold,
            runwayCap: runwayCap,
            fundingDeadline: fundingDeadline,
            executionDuration: executionDuration,
            deadline: deadline,
            activatedAt: activatedAt,
            timeRemaining: timeRemaining(),
            targetFlowRate: targetFlowRate()
        });
    }

    function _incomingFlowRate() internal view returns (int96) {
        int96 parentMemberFlowRate = IFlow(_flow.parent()).getMemberFlowRate(address(_flow));
        if (parentMemberFlowRate <= 0) return 0;
        return parentMemberFlowRate;
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
            incomingRate: _incomingFlowRate(),
            currentOutflowRate: _flow.targetOutflowRate()
        });
    }

    function _syncMode() internal view returns (ISpendPolicy.SyncMode) {
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
                    activatedAt: uint64(block.timestamp),
                    deadline: uint64(block.timestamp) + 1,
                    treasuryBalance: 1,
                    timeRemaining: 1,
                    incomingRate: 0,
                    currentOutflowRate: 0
                })
            )
        returns (int96) {} catch {
            revert INVALID_SPEND_POLICY(candidate);
        }
    }

    function _activateAndSync() internal {
        if (_state != BudgetState.Funding) revert INVALID_STATE();
        uint256 balance = treasuryBalance();
        if (balance < activationThreshold) {
            revert ACTIVATION_THRESHOLD_NOT_REACHED(balance, activationThreshold);
        }

        uint256 computedDeadline = uint256(fundingDeadline) + uint256(executionDuration);
        if (computedDeadline > type(uint64).max) revert INVALID_DEADLINES();
        deadline = SafeCast.toUint64(computedDeadline);
        activatedAt = uint64(block.timestamp);

        _setState(BudgetState.Active);
        _syncFlowRate();
    }

    function _syncFlowRate() internal {
        uint256 balance = treasuryBalance();
        uint256 remaining = timeRemaining();
        int96 targetRate = targetFlowRate();
        int96 appliedRate;
        if (_syncMode() == ISpendPolicy.SyncMode.LinearSpendDownFallback) {
            appliedRate = TreasuryFlowRateSync.applyLinearSpendDownWithFallback(_flow, targetRate, balance, remaining);
        } else {
            appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(_flow, targetRate);
        }

        emit FlowRateSynced(targetRate, appliedRate, balance, remaining);
    }

    function _finalize(BudgetState finalState) internal {
        if (!_isTerminalState(finalState)) revert INVALID_STATE();
        if (_isTerminalState(_state)) revert INVALID_STATE();

        _reassertGrace.clearDeadline();
        _emitSuccessAssertionCleared(TreasurySuccessAssertionLifecycle.clearPending(_successAssertions));

        _setState(finalState);
        resolvedAt = uint64(block.timestamp);

        _runTerminalSideEffects(finalState);

        emit BudgetFinalized(finalState);
    }

    function _runTerminalSideEffects(BudgetState finalState) internal {
        _tryClosePremiumEscrow(finalState);

        (bool flowStopped, bytes memory flowStopRevertData) = _tryForceFlowRateToZero();
        if (!flowStopped) {
            emit TerminalFlowStopFailed(flowStopRevertData);
        }

        _tryPruneTerminalRecipientFromParent();
        _trySettleResidualToParent();
    }

    function _tryClosePremiumEscrow(BudgetState finalState) internal {
        address escrow = premiumEscrow;
        if (escrow == address(0)) return;

        try IPremiumEscrow(escrow).close(finalState, activatedAt, resolvedAt) {} catch (bytes memory revertData) {
            emit TerminalPremiumEscrowCloseFailed(revertData);
        }
    }

    function _trySettleResidualToParent() internal {
        try this.settleResidualToParentForFinalize() {} catch (bytes memory revertData) {
            emit TerminalResidualSettlementToParentFailed(revertData);
        }
    }

    function _tryPruneTerminalRecipientFromParent() internal {
        address controller_ = controller;
        if (controller_.code.length == 0) return;

        try IBudgetTCR(controller_).pruneTerminalBudget(address(this)) returns (
            bool removedFromParent,
            bool goalSynced
        ) {
            if (!goalSynced) {
                emit TerminalParentGoalSyncNotApplied(removedFromParent);
            }
        } catch (bytes memory revertData) {
            emit TerminalParentPruneFailed(revertData);
        }
    }

    function settleResidualToParentForFinalize() external onlySelf {
        _settleResidualToParent();
    }

    function _setState(BudgetState newState) internal {
        BudgetState previous = _state;
        _state = newState;
        emit StateTransition(previous, newState);
    }

    function _isTerminalState(BudgetState stateValue) internal pure returns (bool) {
        return
            stateValue == BudgetState.Succeeded ||
            stateValue == BudgetState.Failed ||
            stateValue == BudgetState.Expired;
    }

    function _isFundingWindowEnded() internal view returns (bool) {
        return block.timestamp > fundingDeadline;
    }

    function _deriveBudgetDerivedState() internal view returns (BudgetDerivedState memory derivedState) {
        BudgetState currentState = _state;
        derivedState.state = currentState;
        derivedState.isTerminal = _isTerminalState(currentState);
        derivedState.fundingWindowEnded = _isFundingWindowEnded();
        derivedState.deadlinePassed = deadline != 0 && block.timestamp >= deadline;
    }

    function _canAcceptFunding(BudgetDerivedState memory derivedState) internal view returns (bool) {
        if (derivedState.isTerminal) return false;

        if (derivedState.state == BudgetState.Funding) return !derivedState.fundingWindowEnded;
        return !derivedState.deadlinePassed;
    }

    function _emitSuccessAssertionCleared(bytes32 clearedAssertionId) internal {
        if (clearedAssertionId == bytes32(0)) return;
        emit SuccessAssertionCleared(clearedAssertionId);
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
            _finalize(BudgetState.Succeeded);
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

        _finalize(BudgetState.Expired);
        return true;
    }

    function _tryActivateReassertGrace(bytes32 clearedAssertionId) internal {
        if (_reassertGrace.used) return;
        if (_state != BudgetState.Active || successResolutionDisabled) return;
        if (deadline == 0 || block.timestamp < deadline) return;

        (bool activated, uint64 graceDeadline) = _reassertGrace.activateOnce(REASSERT_GRACE_DURATION);
        if (!activated) return;

        emit ReassertGraceActivated(clearedAssertionId, graceDeadline);
    }

    function _flowContract() internal view override returns (IFlow) {
        return _flow;
    }

    function _superToken() internal view override returns (ISuperToken) {
        return superToken;
    }

    function _canAcceptDonation() internal view override returns (bool) {
        return canAcceptFunding();
    }

    function _afterDonation(
        address donor,
        address sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount
    ) internal override {
        emit DonationRecorded(donor, sourceToken, sourceAmount, superTokenAmount);
    }

    function _revertInvalidState() internal pure override {
        revert INVALID_STATE();
    }

    function _settleResidualToParent() internal returns (uint256 settled) {
        address parentFlow = _flow.parent();
        if (parentFlow == address(0)) revert PARENT_FLOW_NOT_CONFIGURED();

        settled = _flow.sweepSuperToken(parentFlow, type(uint256).max);
        emit ResidualSettled(parentFlow, settled);
    }

    function _requireNonZeroController(address account) private pure returns (address) {
        if (account == address(0)) revert ADDRESS_ZERO();
        return account;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert ONLY_CONTROLLER();
        _;
    }
}
