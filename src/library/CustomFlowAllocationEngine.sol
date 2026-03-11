// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { CustomFlowPreviousState } from "./CustomFlowPreviousState.sol";
import { FlowAllocations } from "./FlowAllocations.sol";
import { FlowTypes } from "../storage/FlowStorage.sol";
import { IAllocationPipeline } from "../interfaces/IAllocationPipeline.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IFlow } from "../interfaces/IFlow.sol";

/// @notice Allocation action/apply orchestration extracted from CustomFlow.
library CustomFlowAllocationEngine {
    function processAllocationForCaller(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        FlowTypes.PipelineState storage pipelineState,
        address flow,
        IAllocationStrategy strategy,
        address caller,
        FlowAllocations.AllocationVector memory newAllocation
    ) external {
        uint256 allocationKey = strategy.allocationKey(caller, bytes(""));
        if (!strategy.canAllocate(flow, allocationKey, caller)) revert IFlow.NOT_ABLE_TO_ALLOCATE();

        address strategyAddress = address(strategy);
        (bytes32[] memory prevIds, uint32[] memory prevAllocationPpm, uint256 prevWeight) = CustomFlowPreviousState
            .loadAndResolvePreviousState(recipients, alloc, strategyAddress, allocationKey);
        applyAllocationEditWithPipeline(
            cfg,
            recipients,
            alloc,
            pipelineState,
            FlowAllocations.AllocationEditRequest({
                strategy: strategyAddress,
                allocationKey: allocationKey,
                previousAllocation: _previousAllocation(prevIds, prevAllocationPpm, prevWeight),
                newAllocation: newAllocation,
                newWeight: strategy.currentWeight(flow, allocationKey)
            })
        );
    }

    function applyAllocationEditWithPipeline(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        FlowTypes.PipelineState storage pipelineState,
        FlowAllocations.AllocationEditRequest memory request
    ) public {
        FlowAllocations.applyAllocationEdit(cfg, recipients, alloc, request);
        _runPipeline(
            pipelineState,
            request.strategy,
            request.allocationKey,
            request.previousAllocation.weight,
            request.previousAllocation.allocation.recipientIds,
            request.previousAllocation.allocation.allocationsPpm,
            request.newWeight,
            request.newAllocation.recipientIds,
            request.newAllocation.allocationsPpm,
            IAllocationPipeline.CommitKind.AllocationEdit
        );
    }

    function applyMaintenanceWithPipeline(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        FlowTypes.PipelineState storage pipelineState,
        FlowAllocations.MaintenanceApplyRequest memory request
    ) public {
        FlowAllocations.applyStoredAllocationMaintenance(cfg, recipients, alloc, request);
        _runPipeline(
            pipelineState,
            request.strategy,
            request.allocationKey,
            request.storedAllocation.weight,
            request.storedAllocation.allocation.recipientIds,
            request.storedAllocation.allocation.allocationsPpm,
            request.newWeight,
            request.storedAllocation.allocation.recipientIds,
            request.storedAllocation.allocation.allocationsPpm,
            IAllocationPipeline.CommitKind.MaintenanceSync
        );
    }

    function _runPipeline(
        FlowTypes.PipelineState storage pipelineState,
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] memory prevIds,
        uint32[] memory prevAllocationPpm,
        uint256 newWeight,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        IAllocationPipeline.CommitKind commitKind
    ) private {
        address pipeline = pipelineState.allocationPipeline;
        if (pipeline == address(0)) return;

        IAllocationPipeline(pipeline).onAllocationCommitted(
            strategy,
            allocationKey,
            prevWeight,
            prevIds,
            prevAllocationPpm,
            newWeight,
            recipientIds,
            allocationsPpm,
            commitKind
        );
    }

    function _previousAllocation(
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        uint256 weight
    ) private pure returns (FlowAllocations.PreviousAllocationData memory previousAllocation) {
        previousAllocation = FlowAllocations.PreviousAllocationData({
            allocation: FlowAllocations.AllocationVector({
                recipientIds: recipientIds,
                allocationsPpm: allocationsPpm
            }),
            weight: weight
        });
    }
}
