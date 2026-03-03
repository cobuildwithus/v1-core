// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "../interfaces/IAllocationKeyAccountResolver.sol";
import { IAllocationPipeline } from "../interfaces/IAllocationPipeline.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "../interfaces/IFlow.sol";
import { IPremiumEscrow } from "../interfaces/IPremiumEscrow.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";
import { GoalFlowLedgerMode } from "../library/GoalFlowLedgerMode.sol";

/**
 * @notice Allocation pipeline that checkpoints to BudgetStakeLedger and optionally executes child syncs.
 * @dev Bind one pipeline instance to one ledger via constructor (ledger may be zero to disable all behavior).
 */
contract GoalFlowAllocationLedgerPipeline is IAllocationPipeline {
    enum ChildSyncDebtWriteMode {
        OpenAndClear,
        ClearOnly
    }

    struct ChildSyncDebtView {
        bool exists;
        address childFlow;
        address childStrategy;
        uint256 allocationKey;
        bytes32 reason;
    }

    struct ChildSyncDebt {
        address childFlow;
        address childStrategy;
        uint256 allocationKey;
        bytes32 reason;
        bool exists;
    }

    bytes32 private constant _CHILD_SYNC_SKIP_NO_COMMITMENT = "NO_COMMITMENT";
    bytes32 private constant _CHILD_SYNC_SKIP_TARGET_UNAVAILABLE = "TARGET_UNAVAILABLE";
    bytes32 private constant _CHILD_SYNC_DEBT_REASON_GAS_BUDGET = "GAS_BUDGET";
    bytes32 private constant _CHILD_SYNC_DEBT_REASON_SYNC_FAILED = "SYNC_FAILED";
    bytes32 private constant _CHILD_SYNC_DEBT_REASON_SYNCED = "SYNCED";
    bytes32 private constant _CHILD_SYNC_DEBT_REASON_REPAIRED = "REPAIRED";

    address public allocationLedger;
    bool private _initialized;

    mapping(address flow => GoalFlowLedgerMode.ValidationCache cache) private _validationCacheByFlow;
    mapping(address account => uint256 debtCount) private _childSyncDebtCount;
    mapping(address account => mapping(address budgetTreasury => ChildSyncDebt debt)) private _childSyncDebtByBudget;

    error ALREADY_INITIALIZED();
    error INVALID_ALLOCATION_PIPELINE_KEY_ACCOUNT(address strategy, uint256 allocationKey);
    error INVALID_BUDGET_PREMIUM_ESCROW(address budgetTreasury, address premiumEscrow);
    error ACCOUNT_HAS_CHILD_SYNC_DEBT(address account, uint256 debtCount);
    error CHILD_SYNC_DEBT_NOT_FOUND(address account, address budgetTreasury);
    error CHILD_SYNC_DEBT_REPAIR_FAILED(address account, address budgetTreasury, bytes reason);

    event ChildAllocationSyncAttempted(
        address indexed budgetTreasury,
        address indexed childFlow,
        address indexed strategy,
        uint256 allocationKey,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bool success
    );
    event ChildAllocationSyncFailed(
        address indexed budgetTreasury,
        address indexed childFlow,
        address indexed strategy,
        uint256 allocationKey,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bytes reason
    );
    event ChildAllocationSyncSkipped(
        address indexed budgetTreasury,
        address indexed childFlow,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bytes32 reason
    );
    event ChildSyncDebtOpened(
        address indexed account,
        address indexed budgetTreasury,
        address indexed childFlow,
        address childStrategy,
        uint256 allocationKey,
        bytes32 reason
    );
    event ChildSyncDebtCleared(
        address indexed account,
        address indexed budgetTreasury,
        address indexed childFlow,
        bytes32 reason
    );

    constructor(address allocationLedger_) {
        _initialize(allocationLedger_);
    }

    function initialize(address allocationLedger_) external {
        _initialize(allocationLedger_);
    }

    function _initialize(address allocationLedger_) internal {
        if (_initialized) revert ALREADY_INITIALIZED();
        _initialized = true;
        allocationLedger = allocationLedger_;
    }

    function validateForFlow(address flow) external view override {
        _validateFlowView(flow);
    }

    function childSyncDebtCount(address account) external view returns (uint256) {
        return _childSyncDebtCount[account];
    }

    function childSyncDebt(
        address account,
        address budgetTreasury
    ) external view returns (ChildSyncDebtView memory debt) {
        ChildSyncDebt storage storedDebt = _childSyncDebtByBudget[account][budgetTreasury];
        debt = ChildSyncDebtView({
            exists: storedDebt.exists,
            childFlow: storedDebt.childFlow,
            childStrategy: storedDebt.childStrategy,
            allocationKey: storedDebt.allocationKey,
            reason: storedDebt.reason
        });
    }

    function repairChildSyncDebt(address account, address budgetTreasury) external returns (bool cleared) {
        ChildSyncDebt storage debt = _childSyncDebtByBudget[account][budgetTreasury];
        if (!debt.exists) {
            revert CHILD_SYNC_DEBT_NOT_FOUND(account, budgetTreasury);
        }

        address[] memory singleBudget = new address[](1);
        singleBudget[0] = budgetTreasury;
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = GoalFlowLedgerMode.buildChildSyncActions(
            account,
            singleBudget
        );
        GoalFlowLedgerMode.ChildSyncAction memory action = actions[0];
        bytes32 skipReason = action.skipReason;

        if (skipReason != bytes32(0)) {
            if (_isChildSyncDebtClearSkipReason(skipReason)) {
                _clearChildSyncDebt(account, budgetTreasury, action.target.childFlow, skipReason);
                return true;
            }
            revert CHILD_SYNC_DEBT_REPAIR_FAILED(account, budgetTreasury, abi.encode(skipReason));
        }

        try
            ICustomFlow(action.target.childFlow).syncAllocation(
                action.target.childStrategy,
                action.target.allocationKey
            )
        {
            _clearChildSyncDebt(account, budgetTreasury, action.target.childFlow, _CHILD_SYNC_DEBT_REASON_REPAIRED);
            return true;
        } catch (bytes memory reason) {
            revert CHILD_SYNC_DEBT_REPAIR_FAILED(account, budgetTreasury, reason);
        }
    }

    function onAllocationCommitted(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsPpm,
        IAllocationPipeline.CommitKind commitKind
    ) external override {
        // Use the caller as canonical flow identity so a strategy cannot spoof another flow.
        // GoalFlowLedgerMode then validates ledger/stake-vault wiring against this flow address.
        address flow = msg.sender;
        address ledger = allocationLedger;
        if (ledger == address(0)) return;

        (address account, uint256 resolvedWeight, bool shouldCheckpoint) = _prepareCommittedCheckpoint(
            flow,
            ledger,
            strategy,
            allocationKey,
            newWeight
        );
        if (!shouldCheckpoint) return;
        bool compositionChanged = _allocationCompositionChanged(
            prevRecipientIds,
            prevAllocationsPpm,
            newRecipientIds,
            newAllocationsPpm
        );
        if (compositionChanged) {
            _revertIfAccountHasChildSyncDebt(account);
        }

        address[] memory changedBudgetTreasuries = _checkpointAndDetectBudgetDeltas(
            ledger,
            account,
            prevWeight,
            prevRecipientIds,
            prevAllocationsPpm,
            resolvedWeight,
            newRecipientIds,
            newAllocationsPpm
        );
        if (changedBudgetTreasuries.length == 0) return;

        _checkpointPremiumEscrows(account, changedBudgetTreasuries);
        _executeAndEmitChildSync(
            account,
            changedBudgetTreasuries,
            flow,
            strategy,
            allocationKey,
            _debtWriteModeForCommitKind(commitKind)
        );
    }

    function _prepareCommittedCheckpoint(
        address flow,
        address ledger,
        address strategy,
        uint256 allocationKey,
        uint256 committedWeight
    ) private returns (address account, uint256 resolvedWeight, bool shouldCheckpoint) {
        (
            GoalFlowLedgerMode.ValidationCache storage cache,
            IAllocationStrategy[] memory strategies
        ) = _cacheWithStrategies(flow, ledger);

        account = _accountForAllocationKey(strategy, allocationKey);
        (resolvedWeight, shouldCheckpoint) = GoalFlowLedgerMode.prepareCheckpointContextFromCommittedWeight(
            strategies,
            cache,
            ledger,
            committedWeight,
            flow
        );
    }

    function _checkpointAndDetectBudgetDeltas(
        address ledger,
        address account,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsPpm,
        uint256 resolvedWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsPpm
    ) private returns (address[] memory changedBudgetTreasuries) {
        IBudgetStakeLedger(ledger).checkpointAllocation(
            account,
            prevWeight,
            prevRecipientIds,
            prevAllocationsPpm,
            resolvedWeight,
            newRecipientIds,
            newAllocationsPpm
        );

        return
            GoalFlowLedgerMode.detectBudgetDeltasCalldata(
                FlowProtocolConstants.PPM_SCALE_UINT256,
                ledger,
                prevWeight,
                prevRecipientIds,
                prevAllocationsPpm,
                resolvedWeight,
                newRecipientIds,
                newAllocationsPpm
            );
    }

    function _executeAndEmitChildSync(
        address account,
        address[] memory changedBudgetTreasuries,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        ChildSyncDebtWriteMode debtWriteMode
    ) private {
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = GoalFlowLedgerMode.buildChildSyncActions(
            account,
            changedBudgetTreasuries
        );

        GoalFlowLedgerMode.ChildSyncExecution[] memory ledgerExecutions = GoalFlowLedgerMode.executeChildSyncBestEffort(
            actions
        );
        _applyChildSyncDebtPolicy(account, ledgerExecutions, debtWriteMode);
        _emitChildSyncExecutions(ledgerExecutions, parentFlow, parentStrategy, parentAllocationKey);
    }

    function _checkpointPremiumEscrows(address account, address[] memory changedBudgetTreasuries) private {
        uint256 budgetCount = changedBudgetTreasuries.length;
        for (uint256 i = 0; i < budgetCount; ) {
            address budgetTreasury = changedBudgetTreasuries[i];
            address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
            if (premiumEscrow == address(0) || premiumEscrow.code.length == 0) {
                revert INVALID_BUDGET_PREMIUM_ESCROW(budgetTreasury, premiumEscrow);
            }
            IPremiumEscrow(premiumEscrow).checkpoint(account);
            unchecked {
                ++i;
            }
        }
    }

    function previewChildSyncRequirements(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsPpm,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsPpm
    ) external view override returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        // Preview uses the same trust model as commit: caller is the flow identity under validation.
        address flow = msg.sender;
        address ledger = allocationLedger;
        if (ledger == address(0)) return new ICustomFlow.ChildSyncRequirement[](0);

        (
            GoalFlowLedgerMode.ValidationCache storage cache,
            IAllocationStrategy[] memory strategies
        ) = _cacheWithStrategies(flow, ledger);

        address account = _accountForAllocationKey(strategy, allocationKey);
        (uint256 resolvedWeight, bool shouldCheckpoint) = GoalFlowLedgerMode.prepareCheckpointContextView(
            strategies,
            cache,
            ledger,
            account,
            flow
        );
        if (!shouldCheckpoint) return new ICustomFlow.ChildSyncRequirement[](0);

        address[] memory changedBudgetTreasuries = GoalFlowLedgerMode.detectBudgetDeltasCalldata(
            FlowProtocolConstants.PPM_SCALE_UINT256,
            ledger,
            prevWeight,
            prevRecipientIds,
            prevAllocationsPpm,
            resolvedWeight,
            newRecipientIds,
            newAllocationsPpm
        );

        return GoalFlowLedgerMode.requiredChildSyncRequirements(account, changedBudgetTreasuries);
    }

    function _validateFlowView(address flow) private view {
        address ledger = allocationLedger;
        if (ledger == address(0)) return;

        (
            GoalFlowLedgerMode.ValidationCache storage cache,
            IAllocationStrategy[] memory strategies
        ) = _cacheWithStrategies(flow, ledger);
        GoalFlowLedgerMode.validateForInitializeOrRevertView(strategies, cache, ledger, flow);
    }

    function _cacheWithStrategies(
        address flow,
        address ledger
    ) private view returns (GoalFlowLedgerMode.ValidationCache storage cache, IAllocationStrategy[] memory strategies) {
        cache = _validationCacheByFlow[flow];
        strategies = new IAllocationStrategy[](0);
        if (cache.validatedLedger != ledger) {
            strategies = IFlow(flow).strategies();
        }
    }

    function _accountForAllocationKey(address strategy, uint256 allocationKey) private view returns (address account) {
        account = IAllocationKeyAccountResolver(strategy).accountForAllocationKey(allocationKey);
        if (account == address(0)) {
            revert INVALID_ALLOCATION_PIPELINE_KEY_ACCOUNT(strategy, allocationKey);
        }
    }

    function _emitChildSyncExecutions(
        GoalFlowLedgerMode.ChildSyncExecution[] memory ledgerExecutions,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey
    ) private {
        uint256 executionCount = ledgerExecutions.length;

        for (uint256 i = 0; i < executionCount; ) {
            GoalFlowLedgerMode.ChildSyncExecution memory execution = ledgerExecutions[i];
            if (execution.skipReason != bytes32(0)) {
                emit ChildAllocationSyncSkipped(
                    execution.budgetTreasury,
                    execution.childFlow,
                    parentFlow,
                    parentStrategy,
                    parentAllocationKey,
                    execution.skipReason
                );
            } else {
                emit ChildAllocationSyncAttempted(
                    execution.budgetTreasury,
                    execution.childFlow,
                    execution.childStrategy,
                    execution.allocationKey,
                    parentFlow,
                    parentStrategy,
                    parentAllocationKey,
                    execution.success
                );
                if (!execution.success) {
                    emit ChildAllocationSyncFailed(
                        execution.budgetTreasury,
                        execution.childFlow,
                        execution.childStrategy,
                        execution.allocationKey,
                        parentFlow,
                        parentStrategy,
                        parentAllocationKey,
                        execution.failureReason
                    );
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _applyChildSyncDebtPolicy(
        address account,
        GoalFlowLedgerMode.ChildSyncExecution[] memory ledgerExecutions,
        ChildSyncDebtWriteMode debtWriteMode
    ) private {
        uint256 executionCount = ledgerExecutions.length;
        for (uint256 i = 0; i < executionCount; ) {
            GoalFlowLedgerMode.ChildSyncExecution memory execution = ledgerExecutions[i];
            address budgetTreasury = execution.budgetTreasury;
            if (budgetTreasury != address(0)) {
                if (execution.attempted && execution.success) {
                    _clearChildSyncDebt(account, budgetTreasury, execution.childFlow, _CHILD_SYNC_DEBT_REASON_SYNCED);
                } else if (debtWriteMode != ChildSyncDebtWriteMode.ClearOnly) {
                    if (execution.skipReason == _CHILD_SYNC_DEBT_REASON_GAS_BUDGET) {
                        _openChildSyncDebt(
                            account,
                            budgetTreasury,
                            execution.childFlow,
                            execution.childStrategy,
                            execution.allocationKey,
                            execution.skipReason
                        );
                    } else if (execution.attempted) {
                        _openChildSyncDebt(
                            account,
                            budgetTreasury,
                            execution.childFlow,
                            execution.childStrategy,
                            execution.allocationKey,
                            _CHILD_SYNC_DEBT_REASON_SYNC_FAILED
                        );
                    }
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _debtWriteModeForCommitKind(
        IAllocationPipeline.CommitKind commitKind
    ) private pure returns (ChildSyncDebtWriteMode debtWriteMode) {
        return
            commitKind == IAllocationPipeline.CommitKind.MaintenanceSync
                ? ChildSyncDebtWriteMode.ClearOnly
                : ChildSyncDebtWriteMode.OpenAndClear;
    }

    function _isChildSyncDebtClearSkipReason(bytes32 skipReason) private pure returns (bool) {
        return skipReason == _CHILD_SYNC_SKIP_TARGET_UNAVAILABLE || skipReason == _CHILD_SYNC_SKIP_NO_COMMITMENT;
    }

    function _allocationCompositionChanged(
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsPpm,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsPpm
    ) private pure returns (bool changed) {
        uint256 prevLength = prevRecipientIds.length;
        if (prevLength != prevAllocationsPpm.length) return true;
        uint256 newLength = newRecipientIds.length;
        if (newLength != newAllocationsPpm.length) return true;
        if (prevLength != newLength) return true;

        for (uint256 i = 0; i < prevLength; ) {
            if (prevRecipientIds[i] != newRecipientIds[i]) return true;
            if (prevAllocationsPpm[i] != newAllocationsPpm[i]) return true;
            unchecked {
                ++i;
            }
        }

        return false;
    }

    function _revertIfAccountHasChildSyncDebt(address account) private view {
        uint256 debtCount = _childSyncDebtCount[account];
        if (debtCount != 0) revert ACCOUNT_HAS_CHILD_SYNC_DEBT(account, debtCount);
    }

    function _openChildSyncDebt(
        address account,
        address budgetTreasury,
        address childFlow,
        address childStrategy,
        uint256 allocationKey,
        bytes32 reason
    ) private {
        ChildSyncDebt storage debt = _childSyncDebtByBudget[account][budgetTreasury];
        bool existed = debt.exists;
        debt.childFlow = childFlow;
        debt.childStrategy = childStrategy;
        debt.allocationKey = allocationKey;
        debt.reason = reason;
        debt.exists = true;

        if (!existed) {
            unchecked {
                _childSyncDebtCount[account] += 1;
            }
        }

        emit ChildSyncDebtOpened(account, budgetTreasury, childFlow, childStrategy, allocationKey, reason);
    }

    function _clearChildSyncDebt(address account, address budgetTreasury, address childFlow, bytes32 reason) private {
        ChildSyncDebt storage debt = _childSyncDebtByBudget[account][budgetTreasury];
        if (!debt.exists) return;

        address eventChildFlow = childFlow != address(0) ? childFlow : debt.childFlow;
        delete _childSyncDebtByBudget[account][budgetTreasury];

        uint256 debtCount = _childSyncDebtCount[account];
        if (debtCount != 0) {
            unchecked {
                _childSyncDebtCount[account] = debtCount - 1;
            }
        }

        emit ChildSyncDebtCleared(account, budgetTreasury, eventChildFlow, reason);
    }
}
