// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StakeVaultRentMath } from "src/goals/library/StakeVaultRentMath.sol";
import { StakeVaultJurorMath } from "src/goals/library/StakeVaultJurorMath.sol";
import { StakeVaultSlashMath } from "src/goals/library/StakeVaultSlashMath.sol";

contract StakeVaultMathTest is Test {
    function testFuzz_accrualCutoff_differentialMatchesLegacy(uint64 nowTs, uint64 goalResolvedAt) public view {
        uint64 newCutoff = StakeVaultRentMath.accrualCutoff(nowTs, goalResolvedAt);
        uint64 refCutoff = _legacyAccrualCutoff(nowTs, goalResolvedAt);
        assertEq(newCutoff, refCutoff);
    }

    function testFuzz_previewAdditionalRent_differentialMatchesLegacy(
        uint64 lastCheckpoint,
        uint64 cutoffSeed,
        uint256 stakedSeed,
        uint256 rentRateSeed
    ) public view {
        uint64 cutoff = cutoffSeed;
        uint256 staked = bound(stakedSeed, 0, 1e36);
        uint256 rentWadPerSecond = bound(rentRateSeed, 0, 1e18);

        uint256 newValue = StakeVaultRentMath.previewAdditionalRent(lastCheckpoint, cutoff, staked, rentWadPerSecond);
        uint256 refValue = _legacyPreviewAdditionalRent(lastCheckpoint, cutoff, staked, rentWadPerSecond);

        assertEq(newValue, refValue);
    }

    function testFuzz_accrueRent_differentialMatchesLegacy(
        uint64 lastCheckpoint,
        uint64 cutoffSeed,
        uint256 goalStakeSeed,
        uint256 cobuildStakeSeed,
        uint256 pendingGoalSeed,
        uint256 pendingCobuildSeed,
        uint256 rentRateSeed
    ) public view {
        uint64 cutoff = cutoffSeed;
        uint256 goalStake = bound(goalStakeSeed, 0, 1e30);
        uint256 cobuildStake = bound(cobuildStakeSeed, 0, 1e30);
        uint256 pendingGoalRent = bound(pendingGoalSeed, 0, 1e30);
        uint256 pendingCobuildRent = bound(pendingCobuildSeed, 0, 1e30);
        uint256 rentWadPerSecond = bound(rentRateSeed, 0, 1e18);

        (uint64 newLast, uint256 newPendingGoal, uint256 newPendingCobuild) = StakeVaultRentMath.accrueRent(
            lastCheckpoint,
            cutoff,
            goalStake,
            cobuildStake,
            pendingGoalRent,
            pendingCobuildRent,
            rentWadPerSecond
        );
        (uint64 refLast, uint256 refPendingGoal, uint256 refPendingCobuild) = _legacyAccrueRent(
            lastCheckpoint,
            cutoff,
            goalStake,
            cobuildStake,
            pendingGoalRent,
            pendingCobuildRent,
            rentWadPerSecond
        );

        assertEq(newLast, refLast);
        assertEq(newPendingGoal, refPendingGoal);
        assertEq(newPendingCobuild, refPendingCobuild);
        assertGe(newPendingGoal, pendingGoalRent);
        assertGe(newPendingCobuild, pendingCobuildRent);
    }

    function testFuzz_computeOptInGoalWeightDelta_differentialMatchesLegacy(
        uint256 stakedGoalSeed,
        uint256 lockedGoalSeed,
        uint256 goalWeightSeed,
        uint256 lockedGoalWeightSeed,
        uint256 goalAmountSeed
    ) public view {
        uint256 stakedGoal = bound(stakedGoalSeed, 0, 1e30);
        uint256 lockedGoal = bound(lockedGoalSeed, 0, stakedGoal);
        uint256 goalWeight = bound(goalWeightSeed, 0, 1e30);
        uint256 lockedGoalWeight = bound(lockedGoalWeightSeed, 0, goalWeight);
        uint256 freeGoal = stakedGoal - lockedGoal;
        uint256 goalAmount = freeGoal == 0 ? 0 : bound(goalAmountSeed, 0, freeGoal);

        uint256 newDelta = StakeVaultJurorMath.computeOptInGoalWeightDelta(
            goalAmount,
            stakedGoal,
            lockedGoal,
            goalWeight,
            lockedGoalWeight
        );
        uint256 refDelta = _legacyComputeOptInGoalWeightDelta(
            goalAmount,
            stakedGoal,
            lockedGoal,
            goalWeight,
            lockedGoalWeight
        );

        assertEq(newDelta, refDelta);
    }

    function testFuzz_computeFinalizeGoalWeightReduction_differentialMatchesLegacy(
        uint256 lockedGoalSeed,
        uint256 lockedGoalWeightSeed,
        uint256 goalAmountSeed
    ) public view {
        uint256 lockedGoal = bound(lockedGoalSeed, 0, 1e30);
        uint256 lockedGoalWeight = bound(lockedGoalWeightSeed, 0, 1e30);
        uint256 goalAmount = lockedGoal == 0 ? 0 : bound(goalAmountSeed, 0, lockedGoal);

        uint256 newReduction =
            StakeVaultJurorMath.computeFinalizeGoalWeightReduction(goalAmount, lockedGoal, lockedGoalWeight);
        uint256 refReduction = _legacyComputeFinalizeGoalWeightReduction(goalAmount, lockedGoal, lockedGoalWeight);

        assertEq(newReduction, refReduction);
    }

    function testFuzz_slashBreakdown_differentialMatchesLegacy_andBounded(
        uint256 stakedGoalSeed,
        uint256 goalWeightSeed,
        uint256 stakedCobuildSeed,
        uint256 requestedWeightSeed,
        uint256 lockedGoalSeed,
        uint256 lockedGoalWeightSeed,
        uint256 lockedCobuildSeed
    ) public view {
        uint256 stakedGoal = bound(stakedGoalSeed, 0, 1e30);
        uint256 goalWeight = bound(goalWeightSeed, 0, 1e30);
        uint256 stakedCobuild = bound(stakedCobuildSeed, 0, 1e30);
        uint256 currentStakeWeight = goalWeight + stakedCobuild;
        uint256 requestedWeight = currentStakeWeight == 0 ? 0 : bound(requestedWeightSeed, 0, currentStakeWeight);

        uint256 lockedGoal = bound(lockedGoalSeed, 0, stakedGoal);
        uint256 lockedGoalWeight = bound(lockedGoalWeightSeed, 0, goalWeight);
        uint256 lockedCobuild = bound(lockedCobuildSeed, 0, stakedCobuild);

        (uint256 newGoalSlash, uint256 newGoalWeightSlash, uint256 newCobuildSlash) = _computeNewStakeSlashBreakdown(
            stakedGoal,
            goalWeight,
            stakedCobuild,
            requestedWeight,
            currentStakeWeight
        );
        (uint256 refGoalSlash, uint256 refGoalWeightSlash, uint256 refCobuildSlash) = _legacyComputeStakeSlashAmounts(
            requestedWeight,
            currentStakeWeight,
            stakedGoal,
            goalWeight,
            stakedCobuild
        );

        assertEq(newGoalSlash, refGoalSlash);
        assertEq(newGoalWeightSlash, refGoalWeightSlash);
        assertEq(newCobuildSlash, refCobuildSlash);

        (uint256 newLockedGoalSlash, uint256 newLockedGoalWeightSlash, uint256 newLockedCobuildSlash) = _computeNewLockedSlashBreakdown(
            stakedGoal,
            goalWeight,
            stakedCobuild,
            lockedGoal,
            lockedGoalWeight,
            lockedCobuild,
            newGoalSlash,
            newCobuildSlash
        );
        (uint256 refLockedGoalSlash, uint256 refLockedGoalWeightSlash, uint256 refLockedCobuildSlash) =
            _legacyComputeLockedSlashAmounts(
                newGoalSlash,
                newCobuildSlash,
                stakedGoal,
                stakedCobuild,
                lockedGoal,
                lockedGoalWeight,
                lockedCobuild
            );

        assertEq(newLockedGoalSlash, refLockedGoalSlash);
        assertEq(newLockedGoalWeightSlash, refLockedGoalWeightSlash);
        assertEq(newLockedCobuildSlash, refLockedCobuildSlash);

        assertLe(newGoalSlash, stakedGoal);
        assertLe(newCobuildSlash, stakedCobuild);
        assertLe(newGoalWeightSlash + newCobuildSlash, requestedWeight);
        assertLe(newLockedGoalSlash, lockedGoal);
        assertLe(newLockedCobuildSlash, lockedCobuild);
    }

    function _computeNewStakeSlashBreakdown(
        uint256 stakedGoal,
        uint256 goalWeight,
        uint256 stakedCobuild,
        uint256 requestedWeight,
        uint256 currentStakeWeight
    ) internal pure returns (uint256 goalSlash, uint256 goalWeightSlash, uint256 cobuildSlash) {
        StakeVaultSlashMath.StakeSlashSnapshot memory snapshot = StakeVaultSlashMath.StakeSlashSnapshot({
            stakedGoal: stakedGoal,
            goalWeight: goalWeight,
            stakedCobuild: stakedCobuild,
            lockedGoal: 0,
            lockedGoalWeight: 0,
            lockedCobuild: 0
        });
        StakeVaultSlashMath.SlashAmounts memory slash =
            StakeVaultSlashMath.computeStakeSlashBreakdown(snapshot, requestedWeight, currentStakeWeight);
        return (slash.goalAmount, slash.goalWeight, slash.cobuildAmount);
    }

    function _computeNewLockedSlashBreakdown(
        uint256 stakedGoal,
        uint256 goalWeight,
        uint256 stakedCobuild,
        uint256 lockedGoal,
        uint256 lockedGoalWeight,
        uint256 lockedCobuild,
        uint256 slashGoalAmount,
        uint256 slashCobuildAmount
    ) internal pure returns (uint256 goalSlash, uint256 goalWeightSlash, uint256 cobuildSlash) {
        StakeVaultSlashMath.StakeSlashSnapshot memory snapshot = StakeVaultSlashMath.StakeSlashSnapshot({
            stakedGoal: stakedGoal,
            goalWeight: goalWeight,
            stakedCobuild: stakedCobuild,
            lockedGoal: lockedGoal,
            lockedGoalWeight: lockedGoalWeight,
            lockedCobuild: lockedCobuild
        });
        StakeVaultSlashMath.SlashAmounts memory slash =
            StakeVaultSlashMath.SlashAmounts({goalAmount: slashGoalAmount, goalWeight: 0, cobuildAmount: slashCobuildAmount});
        StakeVaultSlashMath.SlashAmounts memory lockedSlash =
            StakeVaultSlashMath.computeLockedSlashBreakdown(snapshot, slash);
        return (lockedSlash.goalAmount, lockedSlash.goalWeight, lockedSlash.cobuildAmount);
    }

    function _legacyAccrualCutoff(uint64 nowTs, uint64 goalResolvedAt) internal pure returns (uint64 cutoff) {
        cutoff = nowTs;
        if (goalResolvedAt != 0 && goalResolvedAt < cutoff) {
            cutoff = goalResolvedAt;
        }
    }

    function _legacyPreviewAdditionalRent(
        uint64 lastCheckpoint,
        uint64 cutoff,
        uint256 staked,
        uint256 rentWadPerSecond
    ) internal pure returns (uint256) {
        if (lastCheckpoint == 0 || cutoff <= lastCheckpoint || staked == 0 || rentWadPerSecond == 0) return 0;
        uint256 scaledRate = rentWadPerSecond * uint256(cutoff - lastCheckpoint);
        return Math.mulDiv(staked, scaledRate, 1e18);
    }

    function _legacyAccrueRent(
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
            newPendingGoalRent += Math.mulDiv(goalStake, scaledRate, 1e18);
        }

        if (cobuildStake != 0) {
            newPendingCobuildRent += Math.mulDiv(cobuildStake, scaledRate, 1e18);
        }

        newLastCheckpoint = cutoff;
    }

    function _legacyComputeOptInGoalWeightDelta(
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

    function _legacyComputeFinalizeGoalWeightReduction(
        uint256 goalAmount,
        uint256 lockedGoal,
        uint256 lockedGoalWeight
    ) internal pure returns (uint256 goalWeightReduction) {
        if (goalAmount == 0) return 0;
        goalWeightReduction = goalAmount == lockedGoal
            ? lockedGoalWeight
            : Math.mulDiv(lockedGoalWeight, goalAmount, lockedGoal);
    }

    function _legacyComputeStakeSlashAmounts(
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

    function _legacyComputeLockedSlashAmounts(
        uint256 goalAmountSlash,
        uint256 cobuildAmountSlash,
        uint256 stakedGoal,
        uint256 stakedCobuild,
        uint256 lockedGoal,
        uint256 lockedGoalWeight,
        uint256 lockedCobuild
    ) internal pure returns (uint256 lockedGoalSlash, uint256 lockedGoalWeightSlash, uint256 lockedCobuildSlash) {
        if (goalAmountSlash != 0 && lockedGoal != 0) {
            lockedGoalSlash = goalAmountSlash == stakedGoal ? lockedGoal : Math.mulDiv(lockedGoal, goalAmountSlash, stakedGoal);
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
