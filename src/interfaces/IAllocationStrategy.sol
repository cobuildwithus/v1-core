// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @notice Externalized source of allocation keys & weight.
interface IAllocationStrategy {
    /// Unique key used to index this allocation inside Flow storage.
    /// Strategies derive this from caller + aux data (for example tokenId or account key).
    function allocationKey(address caller, bytes calldata aux) external view returns (uint256);

    /// Live allocation weight for that key in explicit `flow` context.
    function currentWeight(address flow, uint256 key) external view returns (uint256);

    /// Optional safety hook; Flow may revert if false.
    function canAllocate(address flow, uint256 key, address caller) external view returns (bool);

    /// @notice Returns the expected top-level JSON field name for this strategy.
    ///         Frontends can read this to construct the JSON payload for `buildAllocationData`.
    function strategyKey() external pure returns (string memory);

    /// Errors
    error ADDRESS_ZERO();
}
