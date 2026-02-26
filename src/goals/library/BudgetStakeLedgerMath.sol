// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library BudgetStakeLedgerMath {
    uint256 private constant _WAD = 1e18;

    function accruePoints(
        uint256 allocatedStake,
        uint256 unmaturedStake,
        uint256 accruedPoints,
        uint64 lastCheckpoint,
        uint64 checkpointTime,
        uint64 maturationSeconds
    ) internal pure returns (uint256 newUnmaturedStake, uint256 newAccruedPoints, uint64 newLastCheckpoint) {
        newUnmaturedStake = unmaturedStake;
        newAccruedPoints = accruedPoints;
        newLastCheckpoint = lastCheckpoint;

        if (lastCheckpoint == 0) {
            newLastCheckpoint = checkpointTime;
            return (newUnmaturedStake, newAccruedPoints, newLastCheckpoint);
        }
        if (checkpointTime <= lastCheckpoint) {
            return (newUnmaturedStake, newAccruedPoints, newLastCheckpoint);
        }

        uint256 dt = uint256(checkpointTime - lastCheckpoint);
        if (allocatedStake == 0) {
            newUnmaturedStake = 0;
            newLastCheckpoint = checkpointTime;
            return (newUnmaturedStake, newAccruedPoints, newLastCheckpoint);
        }

        uint256 area;
        if (newUnmaturedStake != 0) {
            (newUnmaturedStake, area) = decayUnmatured(newUnmaturedStake, dt, uint256(maturationSeconds));
        }

        uint256 full = allocatedStake * dt;
        if (area > full) area = full;

        newAccruedPoints += full - area;
        newLastCheckpoint = checkpointTime;
    }

    function previewPoints(
        uint256 allocatedStake,
        uint256 unmaturedStake,
        uint256 accruedPoints,
        uint64 lastCheckpoint,
        uint64 cutoff,
        uint64 maturationSeconds
    ) internal pure returns (uint256 points) {
        if (lastCheckpoint == 0) return 0;

        points = accruedPoints;
        if (cutoff <= lastCheckpoint) return points;
        if (allocatedStake == 0) return points;

        uint256 dt = uint256(cutoff - lastCheckpoint);
        uint256 area;

        if (unmaturedStake != 0) {
            (, area) = decayUnmatured(unmaturedStake, dt, uint256(maturationSeconds));
        }

        uint256 full = allocatedStake * dt;
        if (area > full) area = full;
        points += full - area;
    }

    function applyStakeChangeToUnmatured(
        uint256 unmatured,
        uint256 oldAllocated,
        uint256 newAllocated
    ) internal pure returns (uint256) {
        if (newAllocated == 0) return 0;
        if (oldAllocated == 0) return newAllocated;
        if (newAllocated > oldAllocated) return unmatured + (newAllocated - oldAllocated);
        return Math.mulDiv(unmatured, newAllocated, oldAllocated);
    }

    function decayUnmatured(
        uint256 unmatured,
        uint256 dt,
        uint256 maturationSeconds
    ) internal pure returns (uint256 unmaturedEnd, uint256 area) {
        if (unmatured == 0 || dt == 0) return (unmatured, 0);
        if (maturationSeconds == 0) maturationSeconds = 1;

        uint256 rWad = maturationSeconds <= 1 ? 0 : Math.mulDiv(maturationSeconds - 1, _WAD, maturationSeconds);
        uint256 rPow = powWad(rWad, dt);
        unmaturedEnd = Math.mulDiv(unmatured, rPow, _WAD);
        area = Math.mulDiv(unmatured, (_WAD - rPow) * maturationSeconds, _WAD);
    }

    function powWad(uint256 xWad, uint256 n) internal pure returns (uint256 result) {
        result = _WAD;
        while (n != 0) {
            if (n & 1 != 0) {
                result = Math.mulDiv(result, xWad, _WAD);
            }
            n >>= 1;
            if (n != 0) {
                xWad = Math.mulDiv(xWad, xWad, _WAD);
            }
        }
    }
}
