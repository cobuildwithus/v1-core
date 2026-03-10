// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

/// @notice Optional lifecycle hooks for deployed allocation mechanisms.
/// @dev Allocation mechanism registries must treat these hooks as fail-open and optional.
interface IMechanismLifecycleHooks {
    /// @notice Called after escrowed mechanism funds are released to the payout recipient.
    /// @param released Amount released from escrow.
    function onFundingReleased(uint256 released) external;

    /// @notice Called when the parent mechanism registry finalizes mechanism removal.
    function onMechanismRemoved() external;
}
