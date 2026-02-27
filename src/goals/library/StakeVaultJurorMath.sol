// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library StakeVaultJurorMath {
    function computeOptInGoalWeightDelta(
        uint256 goalAmount,
        uint256 stakedGoal,
        uint256 lockedGoal,
        uint256 goalWeight,
        uint256 lockedGoalWeight
    ) internal pure returns (uint256 goalWeightDelta) {
        if (goalAmount == 0) return 0;

        uint256 freeGoal = stakedGoal - lockedGoal;
        uint256 freeGoalWeight = goalWeight - lockedGoalWeight;
        goalWeightDelta = goalAmount == freeGoal ? freeGoalWeight : Math.mulDiv(freeGoalWeight, goalAmount, freeGoal);
    }

    function computeFinalizeGoalWeightReduction(
        uint256 goalAmount,
        uint256 lockedGoal,
        uint256 lockedGoalWeight
    ) internal pure returns (uint256 goalWeightReduction) {
        if (goalAmount == 0) return 0;

        goalWeightReduction = goalAmount == lockedGoal
            ? lockedGoalWeight
            : Math.mulDiv(lockedGoalWeight, goalAmount, lockedGoal);
    }

    function clampToAvailable(uint256 requestedAmount, uint256 availableAmount) internal pure returns (uint256) {
        if (requestedAmount > availableAmount) return availableAmount;
        return requestedAmount;
    }
}
