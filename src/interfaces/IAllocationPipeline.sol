// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ICustomFlow } from "./IFlow.sol";

/**
 * @notice Optional post-allocation pipeline invoked by Flow after each successful allocation commitment.
 * @dev Implementations may checkpoint ledger state, detect changed budgets, and execute child-sync mutations.
 */
interface IAllocationPipeline {
    /**
     * @notice Optional fail-fast validation hook for flow-level pipeline configuration.
     * @dev Called during flow initialization when pipeline is non-zero.
     */
    function validateForFlow(address flow) external view;

    /**
     * @notice Handles post-commit allocation pipeline execution.
     * @dev Called by Flow after the parent commitment is updated.
     */
    function onAllocationCommitted(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsScaled,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsScaled
    ) external;

    /**
     * @notice Read-only preview of child-sync requirements for an allocation delta.
     */
    function previewChildSyncRequirements(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsScaled,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsScaled
    ) external view returns (ICustomFlow.ChildSyncRequirement[] memory reqs);
}
