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
}
