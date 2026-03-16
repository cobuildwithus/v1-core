// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface ITreasuryRuntimeViews {
    function resolved() external view returns (bool);
    function flow() external view returns (address);
    function treasuryBalance() external view returns (uint256);
}
