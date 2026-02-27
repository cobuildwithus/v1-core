// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

contract BudgetStakeLedgerEconomicsTest is Test {
    bytes32 internal constant BUDGET_RECIPIENT_ID = bytes32(uint256(1));
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);

    uint32 internal constant FULL_SCALED = 1_000_000;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;
    uint64 internal constant MIN_SCORING_WINDOW_SECONDS = 1;
    uint64 internal constant MIN_MATURATION_SECONDS = 1;
    uint64 internal constant MAX_MATURATION_SECONDS = 30 days;
    uint64 internal constant MATURATION_WINDOW_DIVISOR = 10;

    BudgetStakeLedgerEconomicsMockGoalFlow internal goalFlow;
    BudgetStakeLedgerEconomicsMockGoalTreasury internal goalTreasury;
    BudgetStakeLedgerEconomicsMockBudgetFlow internal budgetFlow;
    BudgetStakeLedgerEconomicsMockBudgetTreasury internal budget;

    BudgetStakeLedger internal ledger;

    function setUp() public {
        goalFlow = new BudgetStakeLedgerEconomicsMockGoalFlow(MANAGER);
        goalTreasury = new BudgetStakeLedgerEconomicsMockGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        budgetFlow = new BudgetStakeLedgerEconomicsMockBudgetFlow(address(goalFlow));
        budget = new BudgetStakeLedgerEconomicsMockBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        ledger.registerBudget(BUDGET_RECIPIENT_ID, address(budget));
    }

    function test_userPointsOnBudget_preFinalizePreviewsToNow() public {
        uint256 weight = 1e21;
        uint64 startTs = uint64(block.timestamp);
        _checkpoint(ACCOUNT, 0, weight);

        vm.warp(startTs + 7 days);
        uint256 pointsAfterOneWeek = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        assertGt(pointsAfterOneWeek, 0);

        vm.warp(startTs + 14 days);
        uint256 pointsAfterTwoWeeks = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        assertGt(pointsAfterTwoWeeks, pointsAfterOneWeek);
    }

    function test_userPointsOnBudget_preFinalizeCapsAtFundingDeadline() public {
        uint256 weight = 1e21;
        _checkpoint(ACCOUNT, 0, weight);

        uint64 fundingDeadline = budget.fundingDeadline();
        vm.warp(fundingDeadline - 1 days);
        uint256 pointsBeforeDeadline = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        assertGt(pointsBeforeDeadline, 0);

        vm.warp(fundingDeadline + 1 days);
        uint256 pointsAfterDeadline = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        assertGt(pointsAfterDeadline, pointsBeforeDeadline);

        vm.warp(fundingDeadline + 31 days);
        uint256 pointsLongAfterDeadline = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        assertEq(pointsLongAfterDeadline, pointsAfterDeadline);
    }

    function test_checkpointAllocation_emitsClampedEffectiveCheckpointTime() public {
        uint256 weight = 1e21;
        _checkpoint(ACCOUNT, 0, weight);

        uint64 fundingDeadline = budget.fundingDeadline();
        vm.warp(fundingDeadline + 7 days);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit IBudgetStakeLedger.AllocationCheckpointed(ACCOUNT, address(budget), weight, fundingDeadline);

        _checkpoint(ACCOUNT, weight, weight);
    }

    function test_checkpointAllocation_postDeadlineCheckpointDoesNotIncreasePoints() public {
        uint256 weight = 1e21;
        _checkpoint(ACCOUNT, 0, weight);

        uint64 fundingDeadline = budget.fundingDeadline();

        vm.warp(fundingDeadline);
        _checkpoint(ACCOUNT, weight, weight);

        uint256 userPointsAtDeadline = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        uint256 budgetPointsAtDeadline = ledger.budgetPoints(address(budget));

        vm.warp(fundingDeadline + 7 days);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit IBudgetStakeLedger.AllocationCheckpointed(ACCOUNT, address(budget), weight, fundingDeadline);

        _checkpoint(ACCOUNT, weight, weight);

        assertEq(ledger.userPointsOnBudget(ACCOUNT, address(budget)), userPointsAtDeadline);
        assertEq(ledger.budgetPoints(address(budget)), budgetPointsAtDeadline);
    }

    function test_userPointsOnBudget_preFinalizeCapsAtBudgetRemoval() public {
        uint256 weight = 1e21;
        uint64 startTs = uint64(block.timestamp);
        _checkpoint(ACCOUNT, 0, weight);

        vm.warp(startTs + 7 days);
        uint256 pointsBeforeRemoval = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        assertGt(pointsBeforeRemoval, 0);

        vm.prank(MANAGER);
        ledger.removeBudget(BUDGET_RECIPIENT_ID);

        uint256 pointsAtRemoval = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        vm.warp(startTs + 14 days);
        uint256 pointsAfterRemoval = ledger.userPointsOnBudget(ACCOUNT, address(budget));

        assertEq(pointsAfterRemoval, pointsAtRemoval);
    }

    function test_budgetInfoAndCheckpointViews_exposeTrackedMetadataAndCutoffs() public {
        uint256 weight = 2e21;
        _checkpoint(ACCOUNT, 0, weight);
        vm.warp(block.timestamp + 1 days);

        IBudgetStakeLedger.BudgetInfoView memory info = ledger.budgetInfo(address(budget));
        assertTrue(info.isTracked);
        assertGt(info.scoringStartsAt, 0);
        assertLe(info.scoringStartsAt, info.scoringEndsAt);
        assertEq(info.scoringEndsAt, budget.fundingDeadline());
        assertEq(info.removedAt, 0);
        assertEq(info.maturationPeriodSeconds, _expectedMaturationPeriodSeconds(info.scoringStartsAt, info.scoringEndsAt));

        IBudgetStakeLedger.UserBudgetCheckpointView memory userCheckpoint =
            ledger.userBudgetCheckpoint(ACCOUNT, address(budget));
        assertEq(userCheckpoint.allocatedStake, weight);
        assertEq(userCheckpoint.effectiveCutoff, uint64(block.timestamp));
        assertGt(userCheckpoint.lastCheckpoint, 0);

        IBudgetStakeLedger.BudgetCheckpointView memory budgetCheckpoint = ledger.budgetCheckpoint(address(budget));
        assertEq(budgetCheckpoint.totalAllocatedStake, weight);
        assertEq(budgetCheckpoint.effectiveCutoff, uint64(block.timestamp));
        assertGt(budgetCheckpoint.lastCheckpoint, 0);
    }

    function test_trackedBudgetSlice_returnsSummariesWithFinalizeFlags() public {
        IBudgetStakeLedger.TrackedBudgetSummary[] memory initialSlice = ledger.trackedBudgetSlice(0, 10);
        assertEq(initialSlice.length, 1);
        assertEq(initialSlice[0].budget, address(budget));
        assertFalse(initialSlice[0].wasSuccessfulAtFinalization);
        assertEq(initialSlice[0].resolvedAtFinalization, 0);

        uint256 weight = 1e21;
        _checkpoint(ACCOUNT, 0, weight);
        vm.warp(block.timestamp + 2 days);
        _checkpoint(ACCOUNT, weight, weight);

        budget.setResolvedAt(uint64(block.timestamp));
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);

        vm.prank(address(goalTreasury));
        ledger.finalize(2, uint64(block.timestamp));

        IBudgetStakeLedger.TrackedBudgetSummary[] memory finalizedSlice = ledger.trackedBudgetSlice(0, 1);
        assertEq(finalizedSlice.length, 1);
        assertEq(finalizedSlice[0].budget, address(budget));
        assertTrue(finalizedSlice[0].wasSuccessfulAtFinalization);
        assertEq(finalizedSlice[0].resolvedAtFinalization, uint64(block.timestamp));
        assertGt(finalizedSlice[0].points, 0);

        IBudgetStakeLedger.TrackedBudgetSummary[] memory emptySlice = ledger.trackedBudgetSlice(5, 3);
        assertEq(emptySlice.length, 0);
    }

    function testFuzz_pointsMonotonicInTimeForFixedAllocation(
        uint96 weightSeed,
        uint32 firstStepSeed,
        uint32 secondStepSeed
    ) public {
        uint256 weight = bound(uint256(weightSeed), 1e18, 1e30);
        uint64 firstStep = uint64(bound(uint256(firstStepSeed), 1, 30 days));
        uint64 secondStep = uint64(bound(uint256(secondStepSeed), 1, 30 days));

        _checkpoint(ACCOUNT, 0, weight);

        uint256 points0 = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        uint256 budgetPoints0 = ledger.budgetPoints(address(budget));

        vm.warp(block.timestamp + firstStep);
        _checkpoint(ACCOUNT, weight, weight);

        uint256 points1 = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        uint256 budgetPoints1 = ledger.budgetPoints(address(budget));

        vm.warp(block.timestamp + secondStep);
        _checkpoint(ACCOUNT, weight, weight);

        uint256 points2 = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        uint256 budgetPoints2 = ledger.budgetPoints(address(budget));

        assertGe(points1, points0);
        assertGe(points2, points1);
        assertGe(budgetPoints1, budgetPoints0);
        assertGe(budgetPoints2, budgetPoints1);
    }

    function test_pointsRequireEffectiveUnitScaleStake() public {
        uint256 dustWeight = UNIT_WEIGHT_SCALE - 1;
        uint256 effectiveWeight = UNIT_WEIGHT_SCALE;

        vm.warp(100);
        _checkpoint(ACCOUNT, 0, dustWeight);

        vm.warp(200);
        _checkpoint(ACCOUNT, dustWeight, dustWeight);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);
        assertEq(ledger.userPointsOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.budgetPoints(address(budget)), 0);

        vm.warp(300);
        _checkpoint(ACCOUNT, dustWeight, effectiveWeight);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), effectiveWeight);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), effectiveWeight);

        vm.warp(400);
        _checkpoint(ACCOUNT, effectiveWeight, effectiveWeight);
        assertGt(ledger.userPointsOnBudget(ACCOUNT, address(budget)), 0);
        assertGt(ledger.budgetPoints(address(budget)), 0);
    }

    function testFuzz_pointsRemainBoundedAcrossIncreaseDecreaseZeroAndReaddTransitions(
        uint96 startWeightSeed,
        uint96 increaseDeltaSeed,
        uint96 decreaseWeightSeed,
        uint96 readdWeightSeed,
        uint32 firstStepSeed,
        uint32 secondStepSeed,
        uint32 thirdStepSeed,
        uint32 fourthStepSeed
    ) public {
        uint256 startWeight = bound(uint256(startWeightSeed), 1e18, 1e30);
        uint256 increaseDelta = bound(uint256(increaseDeltaSeed), 1, 1e30);
        uint256 increasedWeight = startWeight + increaseDelta;
        uint256 decreasedWeight = bound(uint256(decreaseWeightSeed), 1, increasedWeight - 1);
        uint256 readdWeight = bound(uint256(readdWeightSeed), 1e18, 1e30);

        uint64 firstStep = uint64(bound(uint256(firstStepSeed), 1, 30 days));
        uint64 secondStep = uint64(bound(uint256(secondStepSeed), 1, 30 days));
        uint64 thirdStep = uint64(bound(uint256(thirdStepSeed), 1, 30 days));
        uint64 fourthStep = uint64(bound(uint256(fourthStepSeed), 1, 30 days));
        uint256 maxEffectiveStake = _max4(
            _effectiveWeight(startWeight),
            _effectiveWeight(increasedWeight),
            _effectiveWeight(decreasedWeight),
            _effectiveWeight(readdWeight)
        );

        _checkpoint(ACCOUNT, 0, startWeight);
        _assertSingleAccountPointConsistency(maxEffectiveStake);

        vm.warp(block.timestamp + firstStep);
        _checkpoint(ACCOUNT, startWeight, increasedWeight);
        _assertSingleAccountPointConsistency(maxEffectiveStake);

        vm.warp(block.timestamp + secondStep);
        _checkpoint(ACCOUNT, increasedWeight, decreasedWeight);
        _assertSingleAccountPointConsistency(maxEffectiveStake);

        vm.warp(block.timestamp + thirdStep);
        _checkpoint(ACCOUNT, decreasedWeight, 0);
        _assertSingleAccountPointConsistency(maxEffectiveStake);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);

        vm.warp(block.timestamp + fourthStep);
        _checkpoint(ACCOUNT, 0, readdWeight);
        _assertSingleAccountPointConsistency(maxEffectiveStake);
        uint256 expectedReaddAllocated = (readdWeight / UNIT_WEIGHT_SCALE) * UNIT_WEIGHT_SCALE;
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), expectedReaddAllocated);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), expectedReaddAllocated);
    }

    function testFuzz_reallocationDoesNotCreatePointsOutOfThinAir(
        uint96 weightASeed,
        uint96 weightBSeed,
        uint32 firstStepSeed,
        uint32 secondStepSeed
    ) public {
        uint256 weightA = bound(uint256(weightASeed), 1e18, 1e30);
        uint256 weightB = bound(uint256(weightBSeed), 0, 1e30);
        uint256 firstStep = bound(uint256(firstStepSeed), 1, 14 days);
        uint256 secondStep = bound(uint256(secondStepSeed), 1, 14 days);

        _checkpoint(ACCOUNT, 0, weightA);

        vm.warp(block.timestamp + firstStep);
        _checkpoint(ACCOUNT, weightA, weightB);

        vm.warp(block.timestamp + secondStep);
        _checkpoint(ACCOUNT, weightB, weightB);

        uint256 userPoints = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        uint256 budgetPoints = ledger.budgetPoints(address(budget));

        uint256 maxPointsFromRawStakeTime = weightA * firstStep + weightB * secondStep;

        assertLe(userPoints, maxPointsFromRawStakeTime);
        assertLe(budgetPoints, maxPointsFromRawStakeTime);
    }

    function testFuzz_finalizeSealsStateAndPostFinalizeCheckpointsAreNoOps(
        uint96 weightSeed,
        uint96 nextWeightSeed,
        uint32 timeStepSeed
    ) public {
        uint256 weight = bound(uint256(weightSeed), 1e18, 1e30);
        uint256 nextWeight = bound(uint256(nextWeightSeed), 0, 1e30);
        vm.assume(nextWeight != weight);

        uint64 timeStep = uint64(bound(uint256(timeStepSeed), 1, 30 days));

        _checkpoint(ACCOUNT, 0, weight);

        vm.warp(block.timestamp + timeStep);
        _checkpoint(ACCOUNT, weight, weight);

        budget.setResolvedAt(uint64(block.timestamp));
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);

        vm.prank(address(goalTreasury));
        ledger.finalize(2, uint64(block.timestamp));

        uint256 totalPointsSnapshot = ledger.totalPointsSnapshot();
        uint256 allocatedBefore = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget));
        uint256 totalAllocatedBefore = ledger.budgetTotalAllocatedStake(address(budget));
        uint256 userPointsBefore = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        uint256 budgetPointsBefore = ledger.budgetPoints(address(budget));

        vm.warp(block.timestamp + 1 days);
        _checkpoint(ACCOUNT, weight, nextWeight);

        assertEq(ledger.totalPointsSnapshot(), totalPointsSnapshot);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), allocatedBefore);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), totalAllocatedBefore);
        assertEq(ledger.userPointsOnBudget(ACCOUNT, address(budget)), userPointsBefore);
        assertEq(ledger.budgetPoints(address(budget)), budgetPointsBefore);

        vm.expectRevert(IBudgetStakeLedger.ALREADY_FINALIZED.selector);
        vm.prank(address(goalTreasury));
        ledger.finalize(2, uint64(block.timestamp));
    }

    function test_checkpointAllocation_revertsOnAllocationDrift() public {
        uint256 storedWeight = 2e21;
        uint256 stalePrevWeight = 1e21;
        uint256 newWeight = 3e21;

        _checkpoint(ACCOUNT, 0, storedWeight);

        (bytes32[] memory ids, uint32[] memory scaled) = _singleBudgetAllocation();
        uint256 storedEffective = (storedWeight / UNIT_WEIGHT_SCALE) * UNIT_WEIGHT_SCALE;
        uint256 staleEffective = (stalePrevWeight / UNIT_WEIGHT_SCALE) * UNIT_WEIGHT_SCALE;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.ALLOCATION_DRIFT.selector,
                ACCOUNT,
                address(budget),
                storedEffective,
                staleEffective
            )
        );
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(ACCOUNT, stalePrevWeight, ids, scaled, newWeight, ids, scaled);
    }

    function _checkpoint(address account, uint256 prevWeight, uint256 newWeight) internal {
        (bytes32[] memory ids, uint32[] memory scaled) = _singleBudgetAllocation();

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(account, prevWeight, ids, scaled, newWeight, ids, scaled);
    }

    function _currentPoints() internal view returns (uint256 userPoints, uint256 budgetPoints) {
        userPoints = ledger.userPointsOnBudget(ACCOUNT, address(budget));
        budgetPoints = ledger.budgetPoints(address(budget));
    }

    function _assertSingleAccountPointConsistency(uint256 maxEffectiveStake) internal view {
        (uint256 userPoints, uint256 budgetPoints) = _currentPoints();
        assertEq(userPoints, budgetPoints);
        assertLe(userPoints, maxEffectiveStake);
    }

    function _effectiveWeight(uint256 weight) internal pure returns (uint256) {
        return (weight / UNIT_WEIGHT_SCALE) * UNIT_WEIGHT_SCALE;
    }

    function _max4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256) {
        uint256 maxValue = a;
        if (b > maxValue) maxValue = b;
        if (c > maxValue) maxValue = c;
        if (d > maxValue) maxValue = d;
        return maxValue;
    }

    function _expectedMaturationPeriodSeconds(uint64 scoringStartsAt, uint64 scoringEndsAt) internal pure returns (uint64) {
        uint64 scoringWindow = scoringEndsAt > scoringStartsAt
            ? scoringEndsAt - scoringStartsAt
            : MIN_SCORING_WINDOW_SECONDS;
        uint64 maturity = scoringWindow / MATURATION_WINDOW_DIVISOR;
        if (maturity < MIN_MATURATION_SECONDS) maturity = MIN_MATURATION_SECONDS;
        if (maturity > MAX_MATURATION_SECONDS) maturity = MAX_MATURATION_SECONDS;
        return maturity;
    }

    function _singleBudgetAllocation() internal pure returns (bytes32[] memory ids, uint32[] memory scaled) {
        ids = new bytes32[](1);
        ids[0] = BUDGET_RECIPIENT_ID;

        scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;
    }
}

contract BudgetStakeLedgerEconomicsMockGoalFlow {
    address public manager;

    constructor(address manager_) {
        manager = manager_;
    }

    function recipientAdmin() external view returns (address) {
        return manager;
    }
}

contract BudgetStakeLedgerEconomicsMockGoalTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract BudgetStakeLedgerEconomicsMockBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract BudgetStakeLedgerEconomicsMockBudgetTreasury {
    address public flow;
    uint64 public resolvedAt;
    uint64 public executionDuration = 10 days;
    uint64 public fundingDeadline;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        fundingDeadline = uint64(block.timestamp + 365 days);
        state = IBudgetTreasury.BudgetState.Funding;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }
}
