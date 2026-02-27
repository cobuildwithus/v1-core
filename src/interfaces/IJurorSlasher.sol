// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @notice Minimal surface for a contract that can slash juror stake weight.
/// @dev Used by arbitrators when the stake vault's juror slasher is a router.
interface IJurorSlasher {
    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external;
}
