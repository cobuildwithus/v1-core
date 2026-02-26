// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library RewardEscrowMath {
    function computeSnapshotClaim(
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

    function updateRentIndex(
        uint256 tokenBalance,
        uint256 totalSnapshotClaimed,
        uint256 totalRentClaimed,
        uint256 indexedTotal,
        uint256 rentPerPointStored,
        uint256 snapshotPoints,
        uint256 indexScale
    ) internal pure returns (uint256 newIndexedTotal, uint256 newRentPerPointStored) {
        newIndexedTotal = indexedTotal;
        newRentPerPointStored = rentPerPointStored;

        uint256 cumulative = tokenBalance + totalSnapshotClaimed + totalRentClaimed;
        if (cumulative > indexedTotal) {
            if (snapshotPoints == 0) return (indexedTotal, rentPerPointStored);
            uint256 newRent = cumulative - indexedTotal;
            newIndexedTotal = cumulative;
            newRentPerPointStored = rentPerPointStored + Math.mulDiv(newRent, indexScale, snapshotPoints);
        }
    }

    function computeRentClaim(
        uint256 userPoints,
        uint256 paidPerPoint,
        uint256 latestPerPoint,
        uint256 indexScale
    ) internal pure returns (uint256 amount, uint256 newPaidPerPoint) {
        if (latestPerPoint <= paidPerPoint) {
            return (0, paidPerPoint);
        }

        newPaidPerPoint = latestPerPoint;
        amount = Math.mulDiv(userPoints, latestPerPoint - paidPerPoint, indexScale);
    }
}
