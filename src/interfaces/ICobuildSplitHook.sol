// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";

interface ICobuildSplitHook is IJBSplitHook {
    struct PendingRouteView {
        address payer;
        address beneficiary;
        uint64 createdAt;
        bool usesHistoricalDefault;
        uint256[] goalIds;
        uint32[] weights;
    }

    function communityRevnetId() external view returns (uint256);

    function communityToken() external view returns (address);

    function routeSetter() external view returns (address);

    function goalManager() external view returns (address);

    function goalTreasuryOf(uint256 goalId) external view returns (address);

    function observedVolumeOf(uint256 goalId) external view returns (uint256);

    function observedTotalVolume() external view returns (uint256);

    function approvedGoals() external view returns (uint256[] memory);

    function historicalRoute() external view returns (uint256[] memory goalIds, uint256[] memory volumes);

    function pendingRoute() external view returns (PendingRouteView memory);

    function hasPendingRoute() external view returns (bool);

    function beginPendingRoute(
        address payer,
        address beneficiary,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) external;

    function beginPendingHistoricalRoute(address payer, address beneficiary) external;

    function cancelPendingRoute() external;

    function addApprovedGoal(uint256 goalId, address goalTreasury) external;

    function removeApprovedGoal(uint256 goalId) external;
}
