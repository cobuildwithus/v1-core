// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationPipeline } from "../interfaces/IAllocationPipeline.sol";
import { ICustomFlow } from "../interfaces/IFlow.sol";
import { FlowAllocations } from "./FlowAllocations.sol";
import { CustomFlowPreviousState } from "./CustomFlowPreviousState.sol";
import { FlowTypes } from "../storage/FlowStorage.sol";

/// @notice Read-only helper library for CustomFlow child-sync requirement previews.
library CustomFlowPreview {
    function previewChildSyncRequirements(
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        FlowTypes.PipelineState storage pipelineState,
        address flow,
        address strategy,
        uint256 allocationKey,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external view returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        FlowAllocations.validateAllocations(recipients, newRecipientIds, newAllocationPpm);

        address pipeline = pipelineState.allocationPipeline;
        if (pipeline == address(0)) return new ICustomFlow.ChildSyncRequirement[](0);

        (bytes32[] memory prevIds, uint32[] memory prevAllocationPpm, uint256 prevWeight) = CustomFlowPreviousState
            .loadAndResolvePreviousState(recipients, alloc, strategy, allocationKey);

        return
            IAllocationPipeline(pipeline).previewChildSyncRequirements(
                flow,
                strategy,
                allocationKey,
                prevWeight,
                prevIds,
                prevAllocationPpm,
                newRecipientIds,
                newAllocationPpm
            );
    }
}
