// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";

interface ICobuildSplitHook is IJBSplitHook {
    struct PendingRouteView {
        address payer;
        address beneficiary;
        uint64 createdAt;
        uint256 backlogTokenCount;
        uint256[] goalIds;
        uint32[] weights;
    }

    struct HistoricalBacklogProgressView {
        bool active;
        uint256 epoch;
        uint256 remainingAmount;
        uint256 processedGoalCount;
    }

    function communityRevnetId() external view returns (uint256);

    function communityToken() external view returns (address);

    function routeSetter() external view returns (address);

    function goalRegistry() external view returns (address);

    function observedVolumeOf(uint256 goalId) external view returns (uint256);

    function cumulativeObservedVolume() external view returns (uint256);

    function currentHistoricalTotalVolume() external view returns (uint256);

    function historicalBacklogAmount() external view returns (uint256);

    function historicalBacklogProgress() external view returns (HistoricalBacklogProgressView memory progress);

    function selectableGoalIds() external view returns (uint256[] memory goalIds);

    function historicalRoute() external view returns (uint256[] memory goalIds, uint256[] memory volumes);

    function pendingRoute() external view returns (PendingRouteView memory);

    function hasPendingRoute() external view returns (bool);

    function beginPendingRoute(
        address payer,
        address beneficiary,
        uint256 backlogTokenCount,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) external;

    function cancelPendingRoute() external;

    /// @notice Best-effort permissionless backlog flush. Routes at most `maxGoalCount` historical goals in this call.
    /// @dev Returns 0 and leaves backlog parked when no historical route exists.
    function flushHistoricalBacklog(uint256 maxGoalCount) external returns (uint256 routedAmount);
}
