// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library GoalStakeVaultSlashMath {
    struct StakeSlashSnapshot {
        uint256 stakedGoal;
        uint256 goalWeight;
        uint256 stakedCobuild;
        uint256 lockedGoal;
        uint256 lockedGoalWeight;
        uint256 lockedCobuild;
    }

    struct SlashAmounts {
        uint256 goalAmount;
        uint256 goalWeight;
        uint256 cobuildAmount;
    }

    function computeStakeSlashBreakdown(
        StakeSlashSnapshot memory snapshot,
        uint256 requestedWeight,
        uint256 currentStakeWeight
    ) internal pure returns (SlashAmounts memory slash) {
        (slash.goalAmount, slash.goalWeight, slash.cobuildAmount) = computeStakeSlashAmounts(
            requestedWeight,
            currentStakeWeight,
            snapshot.stakedGoal,
            snapshot.goalWeight,
            snapshot.stakedCobuild
        );
    }

    function computeLockedSlashBreakdown(
        StakeSlashSnapshot memory snapshot,
        SlashAmounts memory slash
    ) internal pure returns (SlashAmounts memory lockedSlash) {
        (lockedSlash.goalAmount, lockedSlash.goalWeight, lockedSlash.cobuildAmount) = computeLockedSlashAmounts(
            slash.goalAmount,
            slash.cobuildAmount,
            snapshot.stakedGoal,
            snapshot.stakedCobuild,
            snapshot.lockedGoal,
            snapshot.lockedGoalWeight,
            snapshot.lockedCobuild
        );
    }

    function computeStakeSlashAmounts(
        uint256 requestedWeight,
        uint256 currentStakeWeight,
        uint256 stakedGoal,
        uint256 goalWeightForUser,
        uint256 stakedCobuild
    ) internal pure returns (uint256 goalAmountSlash, uint256 goalWeightReduction, uint256 cobuildAmountSlash) {
        uint256 targetGoalWeightSlash = 0;
        if (goalWeightForUser != 0) {
            targetGoalWeightSlash = requestedWeight == currentStakeWeight
                ? goalWeightForUser
                : Math.mulDiv(goalWeightForUser, requestedWeight, currentStakeWeight);
        }

        if (targetGoalWeightSlash != 0 && goalWeightForUser != 0 && stakedGoal != 0) {
            goalAmountSlash = targetGoalWeightSlash == goalWeightForUser
                ? stakedGoal
                : Math.mulDiv(stakedGoal, targetGoalWeightSlash, goalWeightForUser);
            if (goalAmountSlash > stakedGoal) goalAmountSlash = stakedGoal;
            if (goalAmountSlash != 0) {
                goalWeightReduction = goalAmountSlash == stakedGoal
                    ? goalWeightForUser
                    : Math.mulDiv(goalWeightForUser, goalAmountSlash, stakedGoal);
            }
        }

        cobuildAmountSlash = requestedWeight - targetGoalWeightSlash;
        if (cobuildAmountSlash > stakedCobuild) cobuildAmountSlash = stakedCobuild;

        uint256 appliedWeight = goalWeightReduction + cobuildAmountSlash;
        if (appliedWeight < requestedWeight && stakedCobuild > cobuildAmountSlash) {
            uint256 topUp = requestedWeight - appliedWeight;
            uint256 remainingCobuild = stakedCobuild - cobuildAmountSlash;
            if (topUp > remainingCobuild) topUp = remainingCobuild;
            cobuildAmountSlash += topUp;
        }
    }

    function computeLockedSlashAmounts(
        uint256 goalAmountSlash,
        uint256 cobuildAmountSlash,
        uint256 stakedGoal,
        uint256 stakedCobuild,
        uint256 lockedGoal,
        uint256 lockedGoalWeight,
        uint256 lockedCobuild
    ) internal pure returns (uint256 lockedGoalSlash, uint256 lockedGoalWeightSlash, uint256 lockedCobuildSlash) {
        if (goalAmountSlash != 0 && lockedGoal != 0) {
            lockedGoalSlash = goalAmountSlash == stakedGoal
                ? lockedGoal
                : Math.mulDiv(lockedGoal, goalAmountSlash, stakedGoal);
            if (lockedGoalSlash > lockedGoal) lockedGoalSlash = lockedGoal;
            if (lockedGoalSlash != 0 && lockedGoalWeight != 0) {
                lockedGoalWeightSlash = lockedGoalSlash == lockedGoal
                    ? lockedGoalWeight
                    : Math.mulDiv(lockedGoalWeight, lockedGoalSlash, lockedGoal);
            }
        }

        if (cobuildAmountSlash != 0 && lockedCobuild != 0) {
            lockedCobuildSlash = cobuildAmountSlash == stakedCobuild
                ? lockedCobuild
                : Math.mulDiv(lockedCobuild, cobuildAmountSlash, stakedCobuild);
            if (lockedCobuildSlash > lockedCobuild) lockedCobuildSlash = lockedCobuild;
        }
    }
}
