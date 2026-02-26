// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library GoalStakeVaultRentMath {
    uint256 private constant _WAD = 1e18;

    function accrualCutoff(uint64 nowTs, uint64 goalResolvedAt) internal pure returns (uint64 cutoff) {
        cutoff = nowTs;
        if (goalResolvedAt != 0 && goalResolvedAt < cutoff) {
            cutoff = goalResolvedAt;
        }
    }

    function previewAdditionalRent(
        uint64 lastCheckpoint,
        uint64 cutoff,
        uint256 staked,
        uint256 rentWadPerSecond
    ) internal pure returns (uint256) {
        if (lastCheckpoint == 0 || cutoff <= lastCheckpoint || staked == 0 || rentWadPerSecond == 0) return 0;

        uint256 scaledRate = rentWadPerSecond * uint256(cutoff - lastCheckpoint);
        return Math.mulDiv(staked, scaledRate, _WAD);
    }

    function accrueRent(
        uint64 lastCheckpoint,
        uint64 cutoff,
        uint256 goalStake,
        uint256 cobuildStake,
        uint256 pendingGoalRent,
        uint256 pendingCobuildRent,
        uint256 rentWadPerSecond
    ) internal pure returns (uint64 newLastCheckpoint, uint256 newPendingGoalRent, uint256 newPendingCobuildRent) {
        newLastCheckpoint = lastCheckpoint;
        newPendingGoalRent = pendingGoalRent;
        newPendingCobuildRent = pendingCobuildRent;

        if (lastCheckpoint == 0) {
            newLastCheckpoint = cutoff;
            return (newLastCheckpoint, newPendingGoalRent, newPendingCobuildRent);
        }
        if (cutoff <= lastCheckpoint || rentWadPerSecond == 0) {
            return (newLastCheckpoint, newPendingGoalRent, newPendingCobuildRent);
        }

        uint256 scaledRate = rentWadPerSecond * uint256(cutoff - lastCheckpoint);

        if (goalStake != 0) {
            newPendingGoalRent += Math.mulDiv(goalStake, scaledRate, _WAD);
        }

        if (cobuildStake != 0) {
            newPendingCobuildRent += Math.mulDiv(cobuildStake, scaledRate, _WAD);
        }

        newLastCheckpoint = cutoff;
    }
}
