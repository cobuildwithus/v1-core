// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { GoalRevnetFixtureBase } from "test/goals/helpers/GoalRevnetFixtureBase.t.sol";

import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IRewardEscrow } from "src/interfaces/IRewardEscrow.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { RevnetTestHarness } from "test/goals/helpers/RevnetTestHarness.sol";

import { SuperTokenV1Library } from
    "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract RewardEscrowIntegrationTest is GoalRevnetFixtureBase {
    using SuperTokenV1Library for ISuperToken;

    uint8 internal constant GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint8 internal constant GOAL_EXPIRED = uint8(IGoalTreasury.GoalState.Expired);

    uint32 internal constant FULL_SCALED = 1_000_000;
    bytes32 internal constant SUCCESS_BUDGET_RECIPIENT = keccak256("reward-escrow-success-budget");
    bytes32 internal constant WITHDRAW_BUDGET_RECIPIENT = keccak256("reward-escrow-withdraw-budget");
    uint256 internal constant POINT_ROUNDING_TOLERANCE = 10_000;

    int96 internal constant INCOMING_FLOW_RATE = 1_000_000; // wei per second

    address internal alice = address(0xB0B);
    address internal bob = address(0xCA11);
    address internal collector = address(0xF00D);

    function setUp() public override {
        super.setUp();

        _setUpGoalIntegration(_goalConfigPresetWithEscrow());
        _mintAndApproveStakeTokens(alice, 1_000e18, 1_000e18);
        _mintAndApproveStakeTokens(bob, 1_000e18, 1_000e18);

        _configureFlowRewardEscrowRouting();
    }

    function test_success_claimsFollowCheckpointPoints_withMixedStakeTypes_andStreamFunding() public {
        _stakeGoal(alice, 80e18); // 40e18 weight with goal ruleset weight = 2e18.
        _stakeCobuild(alice, 10e18);
        _stakeCobuild(bob, 50e18);

        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);
        assertEq(treasury.totalRaised(), 100e18);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);

        int96 managerRate = ISuperToken(address(superToken)).getFlowRate(address(flow), address(rewardEscrow));
        assertGt(managerRate, 0);

        uint256 aliceWeight = vault.weightOf(alice);
        uint256 bobWeight = vault.weightOf(bob);
        assertEq(vault.totalWeight(), aliceWeight + bobWeight);
        assertGt(aliceWeight, 0);
        assertGt(bobWeight, 0);

        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, aliceWeight);
        vm.warp(block.timestamp + 1 days);
        _allocateToBudget(bob, SUCCESS_BUDGET_RECIPIENT, bobWeight);
        vm.warp(block.timestamp + 1 days);

        uint256 liveEscrowSuperTokenBalance = superToken.balanceOf(address(rewardEscrow));
        assertGt(liveEscrowSuperTokenBalance, 0);

        uint64 resolvedAt = uint64(block.timestamp);
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);
        budget.setResolvedAt(resolvedAt);

        _resolveGoalSuccessViaAssertion();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(rewardEscrow.finalized());
        assertEq(rewardEscrow.finalState(), GOAL_SUCCEEDED);
        assertGe(rewardEscrow.rewardPoolSnapshot(), liveEscrowSuperTokenBalance);
        assertEq(rewardEscrow.goalFinalizedAt(), resolvedAt);
        assertTrue(rewardEscrow.budgetSucceededAtFinalize(address(budget)));
        assertEq(rewardEscrow.budgetResolvedAtFinalize(address(budget)), resolvedAt);
        assertEq(superToken.balanceOf(address(rewardEscrow)), 0);

        uint256 totalPoints = rewardEscrow.totalPointsSnapshot();
        assertGt(totalPoints, 0);
        assertEq(rewardEscrow.budgetPoints(address(budget)), totalPoints);

        uint256 alicePoints = rewardEscrow.userPointsOnBudget(alice, address(budget));
        uint256 bobPoints = rewardEscrow.userPointsOnBudget(bob, address(budget));
        assertGt(alicePoints, bobPoints);
        assertApproxEqAbs(totalPoints, alicePoints + bobPoints, POINT_ROUNDING_TOLERANCE);

        uint256 aliceGoalBefore = goalToken.balanceOf(alice);
        uint256 bobGoalBefore = goalToken.balanceOf(bob);

        vm.prank(alice);
        (uint256 aliceClaim, ) = rewardEscrow.claim(alice);
        vm.prank(bob);
        (uint256 bobClaim, ) = rewardEscrow.claim(bob);

        uint256 snapshot = rewardEscrow.rewardPoolSnapshot();
        uint256 expectedAlice = (snapshot * alicePoints) / totalPoints;
        uint256 expectedBob = (snapshot * bobPoints) / totalPoints;
        uint256 remainingAfterAlice = snapshot - expectedAlice;
        if (expectedBob > remainingAfterAlice) expectedBob = remainingAfterAlice;

        assertApproxEqAbs(aliceClaim, expectedAlice, POINT_ROUNDING_TOLERANCE);
        assertApproxEqAbs(bobClaim, expectedBob, POINT_ROUNDING_TOLERANCE);
        assertApproxEqAbs(goalToken.balanceOf(alice) - aliceGoalBefore, expectedAlice, POINT_ROUNDING_TOLERANCE);
        assertApproxEqAbs(goalToken.balanceOf(bob) - bobGoalBefore, expectedBob, POINT_ROUNDING_TOLERANCE);
        assertEq(rewardEscrow.totalClaimed(), aliceClaim + bobClaim);
    }

    function test_managerRewardStream_routesToEscrow_afterActivation() public {
        _stakeCobuild(alice, 1e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        assertEq(flow.managerRewardPool(), address(rewardEscrow));

        int96 rewardFlowRate = ISuperToken(address(superToken)).getFlowRate(address(flow), address(rewardEscrow));
        assertGt(rewardFlowRate, 0);
        assertEq(rewardFlowRate, flow.getManagerRewardPoolFlowRate());

        // The original FlowTestBase manager reward pool should no longer receive a stream.
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 0);
    }

    function test_permissionlessUnwrapGoalSuperToken_convertsEscrowBalance() public {
        _stakeCobuild(alice, 1e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        vm.warp(block.timestamp + 1 days);

        uint256 superTokenBalanceBefore = superToken.balanceOf(address(rewardEscrow));
        assertGt(superTokenBalanceBefore, 0);
        uint256 goalTokenBalanceBefore = goalToken.balanceOf(address(rewardEscrow));

        vm.prank(alice);
        uint256 unwrapped = rewardEscrow.unwrapAllGoalSuperTokens();

        assertEq(unwrapped, superTokenBalanceBefore);
        assertEq(superToken.balanceOf(address(rewardEscrow)), 0);
        assertEq(goalToken.balanceOf(address(rewardEscrow)) - goalTokenBalanceBefore, unwrapped);
    }

    function test_failedPath_claimsZero_andSweepRequiresTreasuryCaller() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        vm.warp(block.timestamp + 1 days);

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertEq(rewardEscrow.finalState(), GOAL_EXPIRED);
        assertGt(rewardEscrow.rewardPoolSnapshot(), 0);

        vm.prank(alice);
        (uint256 claimAmount, ) = rewardEscrow.claim(alice);
        assertEq(claimAmount, 0);

        vm.prank(owner);
        vm.expectRevert(IRewardEscrow.ONLY_GOAL_TREASURY.selector);
        rewardEscrow.releaseFailedAssetsToTreasury();

        // In production this must be invoked by GoalTreasury itself.
        uint256 treasuryGoalBefore = goalToken.balanceOf(address(treasury));
        vm.prank(address(treasury));
        uint256 swept = rewardEscrow.releaseFailedAssetsToTreasury();
        assertEq(swept, rewardEscrow.rewardPoolSnapshot());
        assertEq(goalToken.balanceOf(address(treasury)) - treasuryGoalBefore, swept);
        assertEq(goalToken.balanceOf(address(rewardEscrow)), 0);
    }

    function test_failedPath_sweepFailedAndBurn_doesNotBurnCobuildWhenVaultWithdrawalsDoNotAccrueRent() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);
        vm.warp(block.timestamp + 2 days);

        vm.warp(treasury.deadline());
        treasury.sync();
        assertEq(rewardEscrow.finalState(), GOAL_EXPIRED);

        uint256 escrowCobuildBefore = cobuildToken.balanceOf(address(rewardEscrow));
        uint256 aliceCobuildBefore = cobuildToken.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawCobuild(100e18, alice);
        uint256 escrowCobuildDelta = cobuildToken.balanceOf(address(rewardEscrow)) - escrowCobuildBefore;
        assertEq(escrowCobuildDelta, 0);
        assertEq(cobuildToken.balanceOf(alice) - aliceCobuildBefore, 100e18);

        uint256 derivedCobuildRevnetId = treasury.cobuildRevnetId();
        assertTrue(derivedCobuildRevnetId != 0);
        assertTrue(derivedCobuildRevnetId != goalRevnetId);

        RevnetTestHarness harness = RevnetTestHarness(address(revnets));
        uint256 goalBurnBefore = harness.burnedTokenCountOf(goalRevnetId);
        uint256 cobuildBurnBefore = harness.burnedTokenCountOf(derivedCobuildRevnetId);

        vm.prank(owner);
        uint256 sweptGoalAmount = treasury.sweepFailedAndBurn();

        assertEq(harness.burnedTokenCountOf(goalRevnetId) - goalBurnBefore, sweptGoalAmount);
        assertEq(harness.burnedTokenCountOf(derivedCobuildRevnetId) - cobuildBurnBefore, 0);
    }

    function test_success_withNoSuccessfulBudgets_allowsGoalTreasurySweep() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, vault.weightOf(alice));
        vm.warp(block.timestamp + 1 days);

        budget.setState(IBudgetTreasury.BudgetState.Failed);
        budget.setResolvedAt(uint64(block.timestamp));

        _resolveGoalSuccessViaAssertion();

        assertEq(rewardEscrow.finalState(), GOAL_SUCCEEDED);
        assertEq(rewardEscrow.totalPointsSnapshot(), 0);

        uint256 treasuryGoalBefore = goalToken.balanceOf(address(treasury));
        vm.prank(owner);
        uint256 swept = treasury.sweepFailedAndBurn();
        assertGt(swept, 0);
        assertEq(goalToken.balanceOf(address(treasury)) - treasuryGoalBefore, swept);
    }

    function test_success_immediateEscrowFinalize_stillAllowsWithdrawals() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, vault.weightOf(alice));
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);
        budget.setResolvedAt(uint64(block.timestamp));

        _resolveGoalSuccessViaAssertion();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(vault.goalResolved());
        assertTrue(rewardEscrow.finalized());
        assertEq(address(budget), rewardEscrow.trackedBudgetAt(0));

        vm.prank(alice);
        vault.withdrawCobuild(100e18, alice);
        assertEq(vault.weightOf(alice), 0);
    }

    function test_failedPath_sweepFailedAndBurn_autoUnwrapsLateGoalSuperToken() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);
        vm.warp(block.timestamp + 1 days);

        vm.warp(treasury.deadline());
        treasury.sync();
        assertEq(rewardEscrow.finalState(), GOAL_EXPIRED);

        _mintAndUpgrade(other, 7e18);
        vm.prank(other);
        superToken.transfer(address(rewardEscrow), 7e18);
        assertEq(superToken.balanceOf(address(rewardEscrow)), 7e18);

        uint256 treasuryGoalBefore = goalToken.balanceOf(address(treasury));
        vm.prank(owner);
        uint256 swept = treasury.sweepFailedAndBurn();
        assertEq(superToken.balanceOf(address(rewardEscrow)), 0);
        assertEq(goalToken.balanceOf(address(treasury)) - treasuryGoalBefore, swept);
    }

    function test_expiredPath_syncFinalizesEscrow_withZeroClaims() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        vm.warp(treasury.deadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertEq(rewardEscrow.finalState(), GOAL_EXPIRED);

        vm.prank(alice);
        (uint256 claimAmount, ) = rewardEscrow.claim(alice);
        assertEq(claimAmount, 0);

        uint256 snapshot = rewardEscrow.rewardPoolSnapshot();
        uint256 treasuryGoalBefore = goalToken.balanceOf(address(treasury));
        vm.prank(address(treasury));
        uint256 swept = rewardEscrow.releaseFailedAssetsToTreasury();
        assertEq(swept, snapshot);
        assertEq(goalToken.balanceOf(address(treasury)) - treasuryGoalBefore, swept);
        assertEq(goalToken.balanceOf(address(rewardEscrow)), 0);
    }

    function test_success_withdrawBeforeClaim_doesNotChangeCheckpointedPayout() public {
        _stakeCobuild(alice, 50e18);
        _stakeCobuild(bob, 50e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(WITHDRAW_BUDGET_RECIPIENT);

        uint256 aliceWeight = vault.weightOf(alice);
        uint256 bobWeight = vault.weightOf(bob);
        _allocateToBudget(alice, WITHDRAW_BUDGET_RECIPIENT, aliceWeight);
        _allocateToBudget(bob, WITHDRAW_BUDGET_RECIPIENT, bobWeight);
        vm.warp(block.timestamp + 1 days);

        uint64 resolvedAt = uint64(block.timestamp);
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);
        budget.setResolvedAt(resolvedAt);

        _resolveGoalSuccessViaAssertion();

        uint256 snapshot = rewardEscrow.rewardPoolSnapshot();
        uint256 totalPoints = rewardEscrow.totalPointsSnapshot();
        uint256 alicePoints = rewardEscrow.userPointsOnBudget(alice, address(budget));
        uint256 bobPoints = rewardEscrow.userPointsOnBudget(bob, address(budget));
        assertGt(totalPoints, 0);
        assertApproxEqAbs(totalPoints, alicePoints + bobPoints, POINT_ROUNDING_TOLERANCE);

        vm.prank(alice);
        vault.withdrawCobuild(50e18, alice);
        assertEq(vault.weightOf(alice), 0);

        vm.prank(alice);
        (uint256 aliceClaim, ) = rewardEscrow.claim(alice);
        uint256 expectedAlice = (snapshot * alicePoints) / totalPoints;
        assertEq(aliceClaim, expectedAlice);

        vm.prank(bob);
        (uint256 bobClaim, ) = rewardEscrow.claim(bob);
        uint256 expectedBob = (snapshot * bobPoints) / totalPoints;
        uint256 remainingAfterAlice = snapshot - expectedAlice;
        if (expectedBob > remainingAfterAlice) expectedBob = remainingAfterAlice;
        assertEq(bobClaim, expectedBob);
        assertEq(rewardEscrow.totalClaimed(), expectedAlice + expectedBob);
    }

    function test_slash_autoSyncCheckpointsBudgetStake() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        uint256 weightBeforeSlash = vault.weightOf(alice);
        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, weightBeforeSlash);

        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), weightBeforeSlash);

        _setJurorSlasher(address(this));
        uint256 key = uint256(uint160(alice));
        uint256 expectedWeightAfterSlash = weightBeforeSlash - 40e18;
        strategy.setWeight(key, expectedWeightAfterSlash);

        vault.slashJurorStake(alice, 40e18, collector);

        uint256 weightAfterSlash = vault.weightOf(alice);
        assertEq(weightAfterSlash, expectedWeightAfterSlash);

        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), weightAfterSlash);
    }

    function test_slash_autoSyncCheckpointsBudgetStakeToZero() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        uint256 weightBeforeSlash = vault.weightOf(alice);
        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, weightBeforeSlash);

        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), weightBeforeSlash);

        _setJurorSlasher(address(this));
        uint256 key = uint256(uint160(alice));
        strategy.setWeight(key, 0);

        vault.slashJurorStake(alice, 100e18, collector);

        uint256 weightAfterSlash = vault.weightOf(alice);
        assertEq(weightAfterSlash, 0);

        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), 0);
    }

    function test_sync_afterGoalResolved_doesNotAdvanceBudgetLedgerPoints() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        uint256 key = uint256(uint160(alice));
        uint256 weight = vault.weightOf(alice);
        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, weight);
        uint256 allocatedBefore = budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget));
        assertEq(allocatedBefore, weight);
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);
        budget.setResolvedAt(uint64(block.timestamp));

        _resolveGoalSuccessViaAssertion();
        assertTrue(rewardEscrow.finalized());

        uint256 pointsBefore = budgetStakeLedger.budgetPoints(address(budget));

        vm.warp(block.timestamp + 1 days);

        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        assertEq(budgetStakeLedger.budgetPoints(address(budget)), pointsBefore);
        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), allocatedBefore);
    }

    function test_clearStale_afterGoalResolved_doesNotAdvanceBudgetLedgerPoints() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        uint256 key = uint256(uint160(alice));
        uint256 weight = vault.weightOf(alice);
        _allocateToBudget(alice, SUCCESS_BUDGET_RECIPIENT, weight);
        uint256 allocatedBefore = budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget));
        assertEq(allocatedBefore, weight);
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);
        budget.setResolvedAt(uint64(block.timestamp));

        _resolveGoalSuccessViaAssertion();
        assertTrue(rewardEscrow.finalized());

        uint256 pointsBefore = budgetStakeLedger.budgetPoints(address(budget));
        vm.warp(block.timestamp + 1 days);

        strategy.setWeight(key, 0);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), key);

        assertEq(budgetStakeLedger.budgetPoints(address(budget)), pointsBefore);
        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), allocatedBefore);
    }

    function test_allocate_checkpointsCommittedStrategyWeightFloorWhenWeightDiffers() public {
        _stakeCobuild(alice, 100e18);
        _activateWithIncomingFlowAndHookFunding(100e18, other, INCOMING_FLOW_RATE);

        MockRewardEscrowBudget budget = _addBudgetRecipient(SUCCESS_BUDGET_RECIPIENT);
        uint256 actualWeight = vault.weightOf(alice);
        assertGt(actualWeight, 0);

        uint256 key = uint256(uint160(alice));
        uint256 strategyWeight = actualWeight - 1;
        strategy.setWeight(key, strategyWeight);
        strategy.setCanAllocate(key, alice, true);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = SUCCESS_BUDGET_RECIPIENT;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;

        _allocateWithPrevStateForStrategy(alice, allocationData, address(strategy), address(flow), recipientIds, scaled);

        // BudgetStakeLedger tracks effective unit-scale stake (1e15 floor), sourced from committed strategy weight.
        uint256 expectedEffectiveWeight = (strategyWeight / 1e15) * 1e15;
        assertEq(budgetStakeLedger.userAllocatedStakeOnBudget(alice, address(budget)), expectedEffectiveWeight);
    }

    function _addBudgetRecipient(
        bytes32 recipientId
    ) internal returns (MockRewardEscrowBudget budget) {
        MockRewardEscrowBudgetFlow budgetFlow = new MockRewardEscrowBudgetFlow(address(flow));
        budget = new MockRewardEscrowBudget(address(budgetFlow));

        vm.startPrank(address(treasury));
        flow.addRecipient(recipientId, address(budget), recipientMetadata);
        budgetStakeLedger.registerBudget(recipientId, address(budget));
        vm.stopPrank();
    }

    function _configureFlowRewardEscrowRouting() internal {
        assertEq(flow.managerRewardPool(), address(rewardEscrow));
    }

    function _setJurorSlasher(address slasher) internal {
        vm.prank(address(treasury));
        vault.setJurorSlasher(slasher);
    }

    function _allocateToBudget(address account, bytes32 recipientId, uint256 weight) internal {
        uint256 key = uint256(uint160(account));
        strategy.setWeight(key, weight);
        strategy.setCanAllocate(key, account, true);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;

        _allocateWithPrevStateForStrategy(account, allocationData, address(strategy), address(flow), recipientIds, scaled);
    }
}

contract MockRewardEscrowBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory) {
        return IFlow(parent).strategies();
    }

    function getAllocationCommitment(address, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract MockRewardEscrowBudget {
    address public flow;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Funding;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;

    constructor(address flow_) {
        flow = flow_;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }

    function setExecutionDuration(uint64 executionDuration_) external {
        executionDuration = executionDuration_;
    }

    function setFundingDeadline(uint64 fundingDeadline_) external {
        fundingDeadline = fundingDeadline_;
    }
}
