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
        IAllocationStrategy strategy,
        address caller,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) external {
        uint256 allocationKey = strategy.allocationKey(caller, bytes(""));
        if (!strategy.canAllocate(allocationKey, caller)) revert IFlow.NOT_ABLE_TO_ALLOCATE();

        address strategyAddress = address(strategy);
        (bytes32[] memory prevIds, uint32[] memory prevScaled, uint256 prevWeight) = CustomFlowPreviousState
            .loadAndResolvePreviousState(recipients, alloc, strategyAddress, allocationKey);

        applyAllocationWithPipeline(
            cfg,
            recipients,
            alloc,
            pipelineState,
            strategyAddress,
            allocationKey,
            prevWeight,
            prevIds,
            prevScaled,
            recipientIds,
            allocationsPpm
        );
    }

    function applyAllocationWithPipeline(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        FlowTypes.PipelineState storage pipelineState,
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] memory prevIds,
        uint32[] memory prevAllocationScaled,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) public {
        FlowAllocations.applyAllocationWithPreviousStateMemoryUnchecked(
            cfg,
            recipients,
            alloc,
            strategy,
            allocationKey,
            prevIds,
            prevAllocationScaled,
            prevWeight,
            recipientIds,
            allocationsPpm
        );

        address pipeline = pipelineState.allocationPipeline;
        if (pipeline == address(0)) return;

        IAllocationPipeline(pipeline).onAllocationCommitted(
            strategy,
            allocationKey,
            prevWeight,
            prevIds,
            prevAllocationScaled,
            _committedWeight(alloc, strategy, allocationKey),
            recipientIds,
            allocationsPpm
        );
    }

    function _committedWeight(
        FlowTypes.AllocationState storage alloc,
        address strategy,
        uint256 allocationKey
    ) private view returns (uint256 weight) {
        uint256 weightPlusOne = alloc.allocWeightPlusOne[strategy][allocationKey];
        if (weightPlusOne == 0) return 0;
        unchecked {
            weight = weightPlusOne - 1;
        }
    }
}
