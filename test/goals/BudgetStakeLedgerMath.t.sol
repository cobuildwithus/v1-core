// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { BudgetStakeLedgerMath } from "src/goals/library/BudgetStakeLedgerMath.sol";

contract BudgetStakeLedgerMathTest is Test {
    uint256 private constant _WAD = 1e18;
    uint256 private constant _WEEK = 7 days;

    function testFuzz_decayUnmatured_differentialMatchesLegacy(
        uint256 unmaturedSeed,
        uint32 dtSeed,
        uint32 maturationSeed
    ) public view {
        uint256 unmatured = bound(unmaturedSeed, 0, 1e36);
        uint256 dt = bound(uint256(dtSeed), 0, 365 days);
        uint256 maturationSeconds = bound(uint256(maturationSeed), 0, 365 days);

        (uint256 endNew, uint256 areaNew) = BudgetStakeLedgerMath.decayUnmatured(unmatured, dt, maturationSeconds);
        (uint256 endRef, uint256 areaRef) = _legacyDecayUnmatured(unmatured, dt, maturationSeconds);

        assertEq(endNew, endRef);
        assertEq(areaNew, areaRef);
    }

    function testFuzz_accruePoints_differentialMatchesLegacy(
        uint256 allocatedSeed,
        uint256 unmaturedSeed,
        uint256 accruedSeed,
        uint64 lastSeed,
        uint64 deltaSeed,
        uint32 maturationSeed
    ) public view {
        uint256 allocatedStake = bound(allocatedSeed, 0, 1e30);
        uint256 unmaturedStake = bound(unmaturedSeed, 0, allocatedStake);
        uint256 accruedPoints = bound(accruedSeed, 0, 1e36);
        uint64 lastCheckpoint = uint64(bound(uint256(lastSeed), 0, type(uint32).max));
        uint64 dt = uint64(bound(uint256(deltaSeed), 0, 30 days));
        uint64 checkpointTime = lastCheckpoint + dt;
        uint64 maturationSeconds = uint64(bound(uint256(maturationSeed), 0, 365 days));

        (uint256 unmaturedNew, uint256 accruedNew, uint64 lastNew) = BudgetStakeLedgerMath.accruePoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            checkpointTime,
            maturationSeconds
        );
        (uint256 unmaturedRef, uint256 accruedRef, uint64 lastRef) = _legacyAccruePoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            checkpointTime,
            maturationSeconds
        );

        assertEq(unmaturedNew, unmaturedRef);
        assertEq(accruedNew, accruedRef);
        assertEq(lastNew, lastRef);
    }

    function testFuzz_previewPoints_monotonicAndBounded(
        uint256 allocatedSeed,
        uint256 unmaturedSeed,
        uint256 accruedSeed,
        uint64 lastSeed,
        uint32 stepOneSeed,
        uint32 stepTwoSeed,
        uint32 maturationSeed
    ) public view {
        uint256 allocatedStake = bound(allocatedSeed, 0, 1e30);
        uint256 unmaturedStake = bound(unmaturedSeed, 0, allocatedStake);
        uint256 accruedPoints = bound(accruedSeed, 0, 1e36);
        uint64 lastCheckpoint = uint64(bound(uint256(lastSeed), 1, type(uint32).max));
        uint64 stepOne = uint64(bound(uint256(stepOneSeed), 0, 14 days));
        uint64 stepTwo = uint64(bound(uint256(stepTwoSeed), 0, 14 days));
        uint64 cutoffOne = lastCheckpoint + stepOne;
        uint64 cutoffTwo = cutoffOne + stepTwo;
        uint64 maturationSeconds = uint64(bound(uint256(maturationSeed), 0, 365 days));

        uint256 pointsOne = BudgetStakeLedgerMath.previewPoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            cutoffOne,
            maturationSeconds
        );
        uint256 pointsTwo = BudgetStakeLedgerMath.previewPoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            cutoffTwo,
            maturationSeconds
        );

        assertGe(pointsOne, accruedPoints);
        assertGe(pointsTwo, pointsOne);

        uint256 fullStakeTimeOne = allocatedStake * uint256(stepOne);
        uint256 fullStakeTimeTwo = allocatedStake * uint256(stepOne + stepTwo);
        assertLe(pointsOne - accruedPoints, fullStakeTimeOne);
        assertLe(pointsTwo - accruedPoints, fullStakeTimeTwo);
    }

    function test_previewPoints_monotonicWhenAllocatedStakePositive() public pure {
        uint256 allocatedStake = 1e24;
        uint256 unmaturedStake = allocatedStake;
        uint256 accruedPoints = 0;
        uint64 lastCheckpoint = 100;
        uint64 cutoffOne = 100 + 3 days;
        uint64 cutoffTwo = cutoffOne + 9 days;
        uint64 maturationSeconds = 30 days;

        uint256 pointsOne = BudgetStakeLedgerMath.previewPoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            cutoffOne,
            maturationSeconds
        );
        uint256 pointsTwo = BudgetStakeLedgerMath.previewPoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            cutoffTwo,
            maturationSeconds
        );

        assertGe(pointsOne, accruedPoints);
        assertGe(pointsTwo, pointsOne);
    }

    function test_accruePoints_clampsAreaToFullStakeTimeBound() public pure {
        uint256 allocatedStake = 100;
        uint256 unmaturedStake = 1_000;
        uint256 accruedPoints = 77;
        uint64 lastCheckpoint = 10;
        uint64 checkpointTime = 12;
        uint64 maturationSeconds = 1;

        (uint256 unmaturedAfter, uint256 accruedAfter, uint64 lastAfter) = BudgetStakeLedgerMath.accruePoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            checkpointTime,
            maturationSeconds
        );

        assertEq(unmaturedAfter, 0);
        assertEq(accruedAfter, accruedPoints);
        assertEq(lastAfter, checkpointTime);
    }

    function test_decayUnmatured_maturationOne_zeroesUnmaturedAfterOneSecond() public pure {
        uint256 unmatured = 5e21;
        (uint256 unmaturedEnd, uint256 area) = BudgetStakeLedgerMath.decayUnmatured(unmatured, 1, 1);
        assertEq(unmaturedEnd, 0);
        assertEq(area, unmatured);
    }

    function test_accruePoints_maturationOne_firstSecondAddsZeroMatured() public pure {
        uint256 allocatedStake = 5e21;
        uint256 unmaturedStake = allocatedStake;
        uint256 accruedPoints = 3e18;
        uint64 lastCheckpoint = 100;
        uint64 checkpointTime = 101;

        (uint256 unmaturedAfter, uint256 accruedAfter, uint64 lastAfter) = BudgetStakeLedgerMath.accruePoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            checkpointTime,
            1
        );

        assertEq(unmaturedAfter, 0);
        assertEq(accruedAfter, accruedPoints);
        assertEq(lastAfter, checkpointTime);
    }

    function test_previewPoints_largeWeeksLargeMaturation_noOverflowAndBounded() public pure {
        uint256 allocatedStake = 1e30;
        uint256 unmaturedStake = allocatedStake;
        uint256 accruedPoints = 4e35;
        uint64 lastCheckpoint = 1;
        uint64 cutoff = lastCheckpoint + uint64(8 * _WEEK);
        uint64 maturationSeconds = uint64(365 days);

        uint256 points = BudgetStakeLedgerMath.previewPoints(
            allocatedStake,
            unmaturedStake,
            accruedPoints,
            lastCheckpoint,
            cutoff,
            maturationSeconds
        );
        uint256 fullStakeTime = allocatedStake * uint256(cutoff - lastCheckpoint);

        assertGe(points, accruedPoints);
        assertLe(points - accruedPoints, fullStakeTime);
    }

    function testFuzz_applyStakeChangeToUnmatured_differentialAndBounds(
        uint256 unmaturedSeed,
        uint256 oldAllocatedSeed,
        uint256 newAllocatedSeed
    ) public {
        uint256 oldAllocated = bound(oldAllocatedSeed, 0, 1e30);
        uint256 unmatured = oldAllocated == 0 ? 0 : bound(unmaturedSeed, 0, oldAllocated);
        uint256 newAllocated = bound(newAllocatedSeed, 0, 1e30);

        uint256 value = BudgetStakeLedgerMath.applyStakeChangeToUnmatured(unmatured, oldAllocated, newAllocated);
        uint256 expected = _legacyApplyStakeChangeToUnmatured(unmatured, oldAllocated, newAllocated);

        assertEq(value, expected);
        if (newAllocated == 0) {
            assertEq(value, 0);
        }
    }

    function _legacyAccruePoints(
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

        uint64 last = lastCheckpoint;
        if (last == 0) {
            newLastCheckpoint = checkpointTime;
            return (newUnmaturedStake, newAccruedPoints, newLastCheckpoint);
        }
        if (checkpointTime <= last) {
            return (newUnmaturedStake, newAccruedPoints, newLastCheckpoint);
        }

        uint256 dt = uint256(checkpointTime - last);
        if (allocatedStake == 0) {
            newUnmaturedStake = 0;
            newLastCheckpoint = checkpointTime;
            return (newUnmaturedStake, newAccruedPoints, newLastCheckpoint);
        }

        uint256 area;
        if (newUnmaturedStake != 0) {
            (newUnmaturedStake, area) = _legacyDecayUnmatured(newUnmaturedStake, dt, uint256(maturationSeconds));
        }

        uint256 full = allocatedStake * dt;
        if (area > full) area = full;
        newAccruedPoints += full - area;
        newLastCheckpoint = checkpointTime;
    }

    function _legacyApplyStakeChangeToUnmatured(
        uint256 unmatured,
        uint256 oldAllocated,
        uint256 newAllocated
    ) internal pure returns (uint256) {
        if (newAllocated == 0) return 0;
        if (oldAllocated == 0) return newAllocated;
        if (newAllocated > oldAllocated) return unmatured + (newAllocated - oldAllocated);
        return Math.mulDiv(unmatured, newAllocated, oldAllocated);
    }

    function _legacyDecayUnmatured(
        uint256 unmatured,
        uint256 dt,
        uint256 maturationSeconds
    ) internal pure returns (uint256 unmaturedEnd, uint256 area) {
        if (unmatured == 0 || dt == 0) return (unmatured, 0);
        if (maturationSeconds == 0) maturationSeconds = 1;

        uint256 rWad = maturationSeconds <= 1 ? 0 : Math.mulDiv(maturationSeconds - 1, _WAD, maturationSeconds);
        uint256 rPow = _legacyPowWad(rWad, dt);
        unmaturedEnd = Math.mulDiv(unmatured, rPow, _WAD);
        area = Math.mulDiv(unmatured, (_WAD - rPow) * maturationSeconds, _WAD);
    }

    function _legacyPowWad(uint256 xWad, uint256 n) internal pure returns (uint256 result) {
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
