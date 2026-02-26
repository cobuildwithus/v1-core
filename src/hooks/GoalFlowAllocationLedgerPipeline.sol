// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "../interfaces/IAllocationKeyAccountResolver.sol";
import { IAllocationPipeline } from "../interfaces/IAllocationPipeline.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "../interfaces/IFlow.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";
import { GoalFlowLedgerMode } from "../library/GoalFlowLedgerMode.sol";

/**
 * @notice Allocation pipeline that checkpoints to BudgetStakeLedger and optionally executes child syncs.
 * @dev Bind one pipeline instance to one ledger via constructor (ledger may be zero to disable all behavior).
 */
contract GoalFlowAllocationLedgerPipeline is IAllocationPipeline {
    uint256 private constant _BUDGET_TREASURY_SYNC_REVERT_DATA_MAX_BYTES = 160;

    address public immutable allocationLedger;

    mapping(address flow => GoalFlowLedgerMode.ValidationCache cache) private _validationCacheByFlow;

    error INVALID_ALLOCATION_PIPELINE_KEY_ACCOUNT(address strategy, uint256 allocationKey);

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
    event ChildAllocationSyncSkipped(
        address indexed budgetTreasury,
        address indexed childFlow,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bytes32 reason
    );
    event BudgetTreasurySyncAttempted(
        address indexed budgetTreasury,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bool success
    );
    event BudgetTreasurySyncFailed(
        address indexed budgetTreasury,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bytes4 revertSelector,
        bytes32 revertDataHash,
        uint256 revertDataLength,
        bytes revertDataTruncated
    );

    constructor(address allocationLedger_) {
        allocationLedger = allocationLedger_;
    }

    function validateForFlow(address flow) external view override {
        _validateFlowView(flow);
    }

    function onAllocationCommitted(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsScaled,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsScaled
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

        address[] memory changedBudgetTreasuries = _checkpointAndDetectBudgetDeltas(
            ledger,
            account,
            prevWeight,
            prevRecipientIds,
            prevAllocationsScaled,
            resolvedWeight,
            newRecipientIds,
            newAllocationsScaled
        );
        if (changedBudgetTreasuries.length == 0) return;

        _syncBudgetTreasuriesBestEffort(changedBudgetTreasuries, flow, strategy, allocationKey);
        _executeAndEmitChildSync(account, changedBudgetTreasuries, flow, strategy, allocationKey);
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
        uint32[] calldata prevAllocationsScaled,
        uint256 resolvedWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsScaled
    ) private returns (address[] memory changedBudgetTreasuries) {
        IBudgetStakeLedger(ledger).checkpointAllocation(
            account,
            prevWeight,
            prevRecipientIds,
            prevAllocationsScaled,
            resolvedWeight,
            newRecipientIds,
            newAllocationsScaled
        );

        return
            GoalFlowLedgerMode.detectBudgetDeltasCalldata(
                FlowProtocolConstants.PPM_SCALE_UINT256,
                ledger,
                prevWeight,
                prevRecipientIds,
                prevAllocationsScaled,
                resolvedWeight,
                newRecipientIds,
                newAllocationsScaled
            );
    }

    function _executeAndEmitChildSync(
        address account,
        address[] memory changedBudgetTreasuries,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey
    ) private {
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = GoalFlowLedgerMode.buildChildSyncActions(
            account,
            changedBudgetTreasuries
        );

        GoalFlowLedgerMode.ChildSyncExecution[] memory ledgerExecutions = GoalFlowLedgerMode.executeChildSyncBestEffort(
            actions
        );
        _emitChildSyncExecutions(ledgerExecutions, parentFlow, parentStrategy, parentAllocationKey);
    }

    function previewChildSyncRequirements(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsScaled,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsScaled
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
            prevAllocationsScaled,
            resolvedWeight,
            newRecipientIds,
            newAllocationsScaled
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
            }
            unchecked {
                ++i;
            }
        }
    }

    function _syncBudgetTreasuriesBestEffort(
        address[] memory budgetTreasuries,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey
    ) private {
        uint256 count = budgetTreasuries.length;
        uint256 gasAtStart = gasleft();
        uint256 budgetSyncGasStipend = GoalFlowLedgerMode.budgetTreasurySyncGasStipend();
        uint256 minGasReserve = GoalFlowLedgerMode.syncMinGasReserve(gasAtStart);
        uint256 minGasForBudgetSyncAttempt = minGasReserve + budgetSyncGasStipend;
        for (uint256 i = 0; i < count; ) {
            address budgetTreasury = budgetTreasuries[i];
            bool success;
            if (budgetTreasury.code.length != 0 && gasleft() > minGasForBudgetSyncAttempt) {
                try IBudgetTreasury(budgetTreasury).sync{ gas: budgetSyncGasStipend }() {
                    success = true;
                } catch {
                    (
                        bytes4 revertSelector,
                        bytes32 revertDataHash,
                        uint256 revertDataLength,
                        bytes memory revertDataTruncated
                    ) = _captureRevertDiagnostics(_BUDGET_TREASURY_SYNC_REVERT_DATA_MAX_BYTES);
                    emit BudgetTreasurySyncFailed(
                        budgetTreasury,
                        parentFlow,
                        parentStrategy,
                        parentAllocationKey,
                        revertSelector,
                        revertDataHash,
                        revertDataLength,
                        revertDataTruncated
                    );
                }
            }
            emit BudgetTreasurySyncAttempted(budgetTreasury, parentFlow, parentStrategy, parentAllocationKey, success);
            unchecked {
                ++i;
            }
        }
    }

    function _revertSelector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
        }
    }

    function _captureRevertDiagnostics(
        uint256 maxLength
    ) private pure returns (bytes4 selector, bytes32 dataHash, uint256 dataLength, bytes memory dataTruncated) {
        uint256 copyLength;
        assembly ("memory-safe") {
            dataLength := returndatasize()
            copyLength := dataLength
            if gt(copyLength, maxLength) {
                copyLength := maxLength
            }

            dataTruncated := mload(0x40)
            mstore(dataTruncated, copyLength)
            returndatacopy(add(dataTruncated, 0x20), 0, copyLength)

            let roundedCopyLength := and(add(copyLength, 0x1f), not(0x1f))
            mstore(0x40, add(add(dataTruncated, 0x20), roundedCopyLength))
        }

        selector = _revertSelector(dataTruncated);
        dataHash = keccak256(dataTruncated);
    }
}
