// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { AllocationCommitment } from "./AllocationCommitment.sol";
import { AllocationSnapshot } from "./AllocationSnapshot.sol";
import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow } from "../interfaces/IFlow.sol";

/// @notice Shared previous-allocation snapshot decoding + cached weight resolution for CustomFlow allocation paths.
library CustomFlowPreviousState {
    function loadAndResolvePreviousState(
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        address strategy,
        uint256 allocationKey
    ) external view returns (bytes32[] memory prevIds, uint32[] memory prevAllocationScaled, uint256 prevWeight) {
        (prevIds, prevAllocationScaled) = AllocationSnapshot.decodeStorage(
            recipients,
            alloc.allocSnapshotPacked[strategy][allocationKey]
        );

        bytes32 oldCommit = alloc.allocCommit[strategy][allocationKey];
        if (oldCommit == bytes32(0)) {
            if (prevIds.length != 0 || prevAllocationScaled.length != 0) revert IFlow.INVALID_PREV_ALLOCATION();
            return (prevIds, prevAllocationScaled, 0);
        }

        uint256 cachedWeightPlusOne = alloc.allocWeightPlusOne[strategy][allocationKey];
        if (cachedWeightPlusOne == 0) revert IFlow.INVALID_PREV_ALLOCATION();
        unchecked {
            prevWeight = cachedWeightPlusOne - 1;
        }

        if (AllocationCommitment.hashMemory(prevIds, prevAllocationScaled) != oldCommit) {
            revert IFlow.INVALID_PREV_ALLOCATION();
        }
    }
}
