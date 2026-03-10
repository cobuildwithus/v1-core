// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface ISpendPolicy {
    enum SyncMode {
        Capped,
        LinearSpendDownFallback
    }

    struct SpendContext {
        uint64 nowTs;
        uint64 activatedAt;
        uint64 deadline;
        uint256 treasuryBalance;
        uint256 timeRemaining;
        int96 incomingRate;
        int96 currentOutflowRate;
        uint128 totalRecipientUnits;
    }

    function targetFlowRate(SpendContext calldata ctx) external view returns (int96);
    function syncMode() external view returns (SyncMode);
}
