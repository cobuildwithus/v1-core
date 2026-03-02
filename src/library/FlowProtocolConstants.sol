// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

library FlowProtocolConstants {
    /// @dev Percentage scale where 1_000_000 == 100%.
    uint32 internal constant PPM_SCALE = 1_000_000;
    /// @dev Canonical uint256 form of PPM scale for uint256-denominator math paths.
    uint256 internal constant PPM_SCALE_UINT256 = uint256(PPM_SCALE);
    /// @dev Basis-point scale where 10_000 == 100%.
    uint16 internal constant BPS_SCALE = 10_000;
    /// @dev Canonical uint256 form of BPS scale for uint256-denominator math paths.
    uint256 internal constant BPS_SCALE_UINT256 = uint256(BPS_SCALE);
    /// @dev Minimum quantization unit for allocation-weight accounting (1 unit == 1e15 weight).
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;
    /// @dev Gas stipend for best-effort goal-ledger child flow sync attempts.
    uint256 internal constant GOAL_LEDGER_CHILD_SYNC_GAS_STIPEND = 1_000_000;
}
