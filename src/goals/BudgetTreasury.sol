// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "../interfaces/IPremiumEscrow.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { ISuccessAssertionTreasury } from "../interfaces/ISuccessAssertionTreasury.sol";
import { IUMATreasurySuccessResolver } from "../interfaces/IUMATreasurySuccessResolver.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { TreasuryBase } from "./TreasuryBase.sol";
import { TreasuryFlowRateSync } from "./library/TreasuryFlowRateSync.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";
import { TreasuryReassertGrace } from "./library/TreasuryReassertGrace.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract BudgetTreasury is IBudgetTreasury, TreasuryBase, Initializable {
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    uint64 private constant REASSERT_GRACE_DURATION = 1 days;
    uint8 private constant TERMINAL_OP_FLOW_STOP = 1;
    uint8 private constant TERMINAL_OP_RESIDUAL_SETTLE = 2;
    uint8 private constant TERMINAL_OP_PREMIUM_ESCROW_CLOSE = 3;

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

    error ONLY_SELF();

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialController, BudgetConfig calldata config) external initializer {
        controller = _requireNonZeroController(initialController);
        if (config.flow == address(0)) revert ADDRESS_ZERO();
        address premiumEscrow_ = config.premiumEscrow;
        if (premiumEscrow_ == address(0) || premiumEscrow_.code.length == 0) revert ADDRESS_ZERO();
        if (config.successResolver == address(0)) revert ADDRESS_ZERO();
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
        return _canAcceptFunding(_deriveBudgetDerivedState(), treasuryBalance());
    }

    function sync() external override nonReentrant {
        BudgetDerivedState memory derivedState = _deriveBudgetDerivedState();
        if (derivedState.isTerminal) return;

        if (derivedState.state == BudgetState.Funding) {
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
        if (!_isTerminalState(_state)) revert INVALID_STATE();
        _runTerminalSideEffects();
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
            if (block.timestamp <= fundingDeadline) revert FUNDING_WINDOW_NOT_ENDED();
        } else {
            if (TreasurySuccessAssertions.pendingId(_successAssertions) != bytes32(0))
                revert SUCCESS_ASSERTION_PENDING();
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
        if (block.timestamp < fundingDeadline) revert FUNDING_WINDOW_NOT_ENDED();
        if (block.timestamp >= deadline) {
            if (!_reassertGrace.consumeIfActive()) revert BUDGET_DEADLINE_PASSED();
        }

        uint64 assertedAt = _successAssertions.registerPending(assertionId);
        emit SuccessAssertionRegistered(assertionId, assertedAt);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_SUCCESS_RESOLVER();
        bytes32 clearedAssertionId = _successAssertions.clearMatching(assertionId);
        emit SuccessAssertionCleared(clearedAssertionId);
        _tryActivateReassertGrace(clearedAssertionId);
    }

    function disableSuccessResolution() external override onlyController {
        if (successResolutionDisabled) return;

        successResolutionDisabled = true;
        _reassertGrace.clearDeadline();
        _clearPendingSuccessAssertion();
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

        uint256 remaining = timeRemaining();
        // slither-disable-next-line incorrect-equality
        if (remaining == 0) return 0;

        return _incomingFlowRate();
    }

    function lifecycleStatus() external view override returns (BudgetLifecycleStatus memory status) {
        uint256 treasuryBalance_ = treasuryBalance();
        bool deadlineSet = deadline != 0;
        status = BudgetLifecycleStatus({
            currentState: _state,
            isResolved: _isTerminalState(_state),
            canAcceptFunding: canAcceptFunding(),
            isSuccessResolutionDisabled: successResolutionDisabled,
            isFundingWindowEnded: block.timestamp > fundingDeadline,
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

    function _activateAndSync() internal {
        if (_state != BudgetState.Funding) revert INVALID_STATE();
        uint256 balance = treasuryBalance();
        if (balance < activationThreshold) {
            revert ACTIVATION_THRESHOLD_NOT_REACHED(balance, activationThreshold);
        }

        uint256 computedDeadline = uint256(fundingDeadline) + uint256(executionDuration);
        if (computedDeadline > type(uint64).max) revert INVALID_DEADLINES();
        deadline = uint64(computedDeadline);
        activatedAt = uint64(block.timestamp);

        _setState(BudgetState.Active);
        _syncFlowRate();
    }

    function _syncFlowRate() internal {
        int96 targetRate = targetFlowRate();
        int96 appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(_flow, targetRate);

        emit FlowRateSynced(targetRate, appliedRate, treasuryBalance(), timeRemaining());
    }

    function _finalize(BudgetState finalState) internal {
        if (!_isTerminalState(finalState)) revert INVALID_STATE();
        if (_isTerminalState(_state)) revert INVALID_STATE();

        _reassertGrace.clearDeadline();
        _clearPendingSuccessAssertion();

        _setState(finalState);
        resolvedAt = uint64(block.timestamp);

        _runTerminalSideEffects();

        emit BudgetFinalized(finalState);
    }

    function _runTerminalSideEffects() internal {
        BudgetState terminalState = _state;
        if (_isTerminalState(terminalState)) {
            _tryClosePremiumEscrow(terminalState);
        }

        (bool flowStopped, bytes memory flowStopReason) = _tryForceFlowRateToZero();
        if (!flowStopped) {
            emit TerminalSideEffectFailed(TERMINAL_OP_FLOW_STOP, flowStopReason);
        }

        _trySettleResidualToParent();
    }

    function _tryClosePremiumEscrow(BudgetState finalState) internal {
        address escrow = premiumEscrow;
        if (escrow == address(0)) return;

        try IPremiumEscrow(escrow).close(finalState, activatedAt, resolvedAt) {} catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_PREMIUM_ESCROW_CLOSE, reason);
        }
    }

    function _trySettleResidualToParent() internal {
        try this.settleResidualToParentForFinalize() {} catch (bytes memory reason) {
            emit TerminalSideEffectFailed(TERMINAL_OP_RESIDUAL_SETTLE, reason);
        }
    }

    function settleResidualToParentForFinalize() external {
        if (msg.sender != address(this)) revert ONLY_SELF();
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

    function _deriveBudgetDerivedState() internal view returns (BudgetDerivedState memory derivedState) {
        BudgetState currentState = _state;
        derivedState.state = currentState;
        derivedState.isTerminal = _isTerminalState(currentState);
        derivedState.fundingWindowEnded = block.timestamp > fundingDeadline;
        derivedState.deadlinePassed = deadline != 0 && block.timestamp >= deadline;
    }

    function _canAcceptFunding(
        BudgetDerivedState memory derivedState,
        uint256 currentTreasuryBalance
    ) internal view returns (bool) {
        if (derivedState.isTerminal) return false;

        if (derivedState.state == BudgetState.Funding) {
            if (derivedState.fundingWindowEnded) return false;
        } else if (derivedState.deadlinePassed) {
            return false;
        }

        if (runwayCap != 0 && currentTreasuryBalance >= runwayCap) return false;

        return true;
    }

    function _clearPendingSuccessAssertion() internal returns (bytes32 clearedAssertionId) {
        clearedAssertionId = _successAssertions.clear();
        if (clearedAssertionId == bytes32(0)) return clearedAssertionId;
        emit SuccessAssertionCleared(clearedAssertionId);
    }

    function _tryFinalizePostDeadline() internal returns (bool) {
        bytes32 pendingAssertionId = TreasurySuccessAssertions.pendingId(_successAssertions);
        if (pendingAssertionId == bytes32(0)) {
            if (_reassertGrace.isActive()) return false;
            _finalize(BudgetState.Expired);
            return true;
        }

        (bool assertionResolved, bool assertionTruthful) = _successAssertions.pendingSuccessAssertionResolution(
            pendingAssertionId,
            successResolver,
            successAssertionLiveness,
            successAssertionBond
        );
        if (!assertionResolved) return false;

        if (assertionTruthful) {
            _finalize(BudgetState.Succeeded);
            return true;
        }

        if (!_reassertGrace.used) {
            bytes32 clearedAssertionId = _clearPendingSuccessAssertion();
            if (clearedAssertionId != bytes32(0)) {
                try IUMATreasurySuccessResolver(successResolver).finalize(clearedAssertionId) {} catch {}
            }
            _tryActivateReassertGrace(clearedAssertionId);
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
