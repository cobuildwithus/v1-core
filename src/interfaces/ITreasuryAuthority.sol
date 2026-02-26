// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @notice Canonical treasury authority surface for privileged integrations.
interface ITreasuryAuthority {
    function authority() external view returns (address);
}
