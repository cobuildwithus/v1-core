// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @notice Externalized source of allocation keys & weight.
interface IAllocationStrategy {
    /// Unique key used to index this allocation inside Flow storage.
    /// Strategies derive this from caller + aux data (for example tokenId or account key).
    function allocationKey(address caller, bytes calldata aux) external view returns (uint256);

    /// Live allocation weight for that key.
    function currentWeight(uint256 key) external view returns (uint256);

    /// optional safety hook – Flow may revert if false
    function canAllocate(uint256 key, address caller) external view returns (bool);

    /// optional hook for frontends

    /// @dev this is used to check if the account can allocate
    function canAccountAllocate(address account) external view returns (bool);

    /// @dev this is used to check the account's available allocation weight
    function accountAllocationWeight(address account) external view returns (uint256);

    /// @notice Returns the expected top-level JSON field name for this strategy.
    ///         Frontends can read this to construct the JSON payload for `buildAllocationData`.
    function strategyKey() external pure returns (string memory);

    /// Errors
    error ADDRESS_ZERO();
}
