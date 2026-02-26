// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { RewardEscrowMath } from "src/goals/library/RewardEscrowMath.sol";

contract RewardEscrowMathTest is Test {
    uint256 private constant _INDEX_SCALE = 1e18;

    function testFuzz_computeSnapshotClaim_differentialMatchesLegacy(
        uint256 poolSeed,
        uint256 claimedSeed,
        uint256 userPointsSeed,
        uint256 snapshotPointsSeed
    ) public view {
        uint256 poolSnapshot = bound(poolSeed, 0, 1e36);
        uint256 alreadyClaimed = bound(claimedSeed, 0, poolSnapshot);
        uint256 userPoints = bound(userPointsSeed, 0, 1e30);
        uint256 snapshotPoints = bound(snapshotPointsSeed, 0, 1e30);

        uint256 newAmount = RewardEscrowMath.computeSnapshotClaim(poolSnapshot, alreadyClaimed, userPoints, snapshotPoints);
        uint256 refAmount = _legacySnapshotClaim(poolSnapshot, alreadyClaimed, userPoints, snapshotPoints);

        assertEq(newAmount, refAmount);
        assertLe(newAmount, poolSnapshot - alreadyClaimed);
    }

    function testFuzz_updateRentIndex_differentialMatchesLegacy_andMonotonic(
        uint256 indexedSeed,
        uint256 balanceSeed,
        uint256 snapshotClaimedSeed,
        uint256 rentClaimedSeed,
        uint256 rentPerPointSeed,
        uint256 snapshotPointsSeed
    ) public view {
        uint256 indexedTotal = bound(indexedSeed, 0, 1e36);
        uint256 tokenBalance = bound(balanceSeed, 0, 1e36);
        uint256 totalSnapshotClaimed = bound(snapshotClaimedSeed, 0, 1e36);
        uint256 totalRentClaimed = bound(rentClaimedSeed, 0, 1e36);
        uint256 rentPerPointStored = bound(rentPerPointSeed, 0, 1e36);
        uint256 snapshotPoints = bound(snapshotPointsSeed, 1, 1e30);

        uint256 cumulative = tokenBalance + totalSnapshotClaimed + totalRentClaimed;
        if (cumulative < indexedTotal) {
            indexedTotal = cumulative;
        }

        (uint256 newIndexedTotal, uint256 newRentPerPointStored) = RewardEscrowMath.updateRentIndex(
            tokenBalance,
            totalSnapshotClaimed,
            totalRentClaimed,
            indexedTotal,
            rentPerPointStored,
            snapshotPoints,
            _INDEX_SCALE
        );
        (uint256 refIndexedTotal, uint256 refRentPerPointStored) = _legacyUpdateRentIndex(
            tokenBalance,
            totalSnapshotClaimed,
            totalRentClaimed,
            indexedTotal,
            rentPerPointStored,
            snapshotPoints
        );

        assertEq(newIndexedTotal, refIndexedTotal);
        assertEq(newRentPerPointStored, refRentPerPointStored);
        assertGe(newIndexedTotal, indexedTotal);
        assertGe(newRentPerPointStored, rentPerPointStored);
    }

    function test_updateRentIndex_snapshotPointsZeroWithNewRent_keepsRentPending() public pure {
        uint256 tokenBalance = 150e18;
        uint256 totalSnapshotClaimed = 20e18;
        uint256 totalRentClaimed = 5e18;
        uint256 indexedTotal = 160e18;
        uint256 rentPerPointStored = 2e18;

        (uint256 pendingIndexedTotal, uint256 pendingRentPerPointStored) = RewardEscrowMath.updateRentIndex(
            tokenBalance,
            totalSnapshotClaimed,
            totalRentClaimed,
            indexedTotal,
            rentPerPointStored,
            0,
            _INDEX_SCALE
        );

        assertEq(pendingIndexedTotal, indexedTotal);
        assertEq(pendingRentPerPointStored, rentPerPointStored);

        uint256 snapshotPoints = 10;
        (uint256 updatedIndexedTotal, uint256 updatedRentPerPointStored) = RewardEscrowMath.updateRentIndex(
            tokenBalance,
            totalSnapshotClaimed,
            totalRentClaimed,
            pendingIndexedTotal,
            pendingRentPerPointStored,
            snapshotPoints,
            _INDEX_SCALE
        );

        uint256 cumulative = tokenBalance + totalSnapshotClaimed + totalRentClaimed;
        uint256 pendingRent = cumulative - indexedTotal;
        assertEq(updatedIndexedTotal, cumulative);
        assertEq(updatedRentPerPointStored, rentPerPointStored + Math.mulDiv(pendingRent, _INDEX_SCALE, snapshotPoints));
    }

    function test_updateRentIndex_snapshotPointsZeroWithoutNewRent_noStateChange() public pure {
        uint256 tokenBalance = 100e18;
        uint256 totalSnapshotClaimed = 50e18;
        uint256 totalRentClaimed = 25e18;
        uint256 indexedTotal = tokenBalance + totalSnapshotClaimed + totalRentClaimed;
        uint256 rentPerPointStored = 3e18;

        (uint256 newIndexedTotal, uint256 newRentPerPointStored) = RewardEscrowMath.updateRentIndex(
            tokenBalance,
            totalSnapshotClaimed,
            totalRentClaimed,
            indexedTotal,
            rentPerPointStored,
            0,
            _INDEX_SCALE
        );

        assertEq(newIndexedTotal, indexedTotal);
        assertEq(newRentPerPointStored, rentPerPointStored);
    }

    function testFuzz_computeRentClaim_differentialMatchesLegacy(
        uint256 userPointsSeed,
        uint256 paidPerPointSeed,
        uint256 latestPerPointSeed
    ) public view {
        uint256 userPoints = bound(userPointsSeed, 0, 1e30);
        uint256 paidPerPoint = bound(paidPerPointSeed, 0, 1e36);
        uint256 latestPerPoint = bound(latestPerPointSeed, 0, 1e36);

        (uint256 newAmount, uint256 newPaidPerPoint) = RewardEscrowMath.computeRentClaim(
            userPoints,
            paidPerPoint,
            latestPerPoint,
            _INDEX_SCALE
        );
        (uint256 refAmount, uint256 refPaidPerPoint) = _legacyComputeRentClaim(userPoints, paidPerPoint, latestPerPoint);

        assertEq(newAmount, refAmount);
        assertEq(newPaidPerPoint, refPaidPerPoint);
        if (latestPerPoint <= paidPerPoint) {
            assertEq(newAmount, 0);
            assertEq(newPaidPerPoint, paidPerPoint);
        } else {
            assertEq(newPaidPerPoint, latestPerPoint);
        }
    }

    function _legacySnapshotClaim(
        uint256 poolSnapshot,
        uint256 alreadyClaimed,
        uint256 userPoints,
        uint256 snapshotPoints
    ) internal pure returns (uint256 amount) {
        if (poolSnapshot == 0 || userPoints == 0 || snapshotPoints == 0) return 0;

        amount = Math.mulDiv(poolSnapshot, userPoints, snapshotPoints);
        uint256 remaining = poolSnapshot - alreadyClaimed;
        if (amount > remaining) amount = remaining;
    }

    function _legacyUpdateRentIndex(
        uint256 tokenBalance,
        uint256 totalSnapshotClaimed,
        uint256 totalRentClaimed,
        uint256 indexedTotal,
        uint256 rentPerPointStored,
        uint256 snapshotPoints
    ) internal pure returns (uint256 newIndexedTotal, uint256 newRentPerPointStored) {
        newIndexedTotal = indexedTotal;
        newRentPerPointStored = rentPerPointStored;

        uint256 cumulative = tokenBalance + totalSnapshotClaimed + totalRentClaimed;
        if (cumulative > indexedTotal) {
            uint256 newRent = cumulative - indexedTotal;
            newIndexedTotal = cumulative;
            newRentPerPointStored = rentPerPointStored + Math.mulDiv(newRent, _INDEX_SCALE, snapshotPoints);
        }
    }

    function _legacyComputeRentClaim(
        uint256 userPoints,
        uint256 paidPerPoint,
        uint256 latestPerPoint
    ) internal pure returns (uint256 amount, uint256 newPaidPerPoint) {
        if (latestPerPoint <= paidPerPoint) {
            return (0, paidPerPoint);
        }

        newPaidPerPoint = latestPerPoint;
        amount = Math.mulDiv(userPoints, latestPerPoint - paidPerPoint, _INDEX_SCALE);
    }
}
