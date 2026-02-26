// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IRewardEscrow } from "src/interfaces/IRewardEscrow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IGoalStakeVault } from "src/interfaces/IGoalStakeVault.sol";
import { SharedMockFlow, SharedMockStakeVault } from "test/goals/helpers/TreasurySharedMocks.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract RewardEscrowTest is Test {
    uint8 internal constant GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint8 internal constant GOAL_EXPIRED = uint8(IGoalTreasury.GoalState.Expired);
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    bytes32 internal constant RECIPIENT_A = bytes32(uint256(1));
    bytes32 internal constant RECIPIENT_B = bytes32(uint256(2));
    bytes32 internal constant RECIPIENT_C = bytes32(uint256(3));
    bytes32 internal constant RECIPIENT_D = bytes32(uint256(4));
    bytes32 internal constant RECIPIENT_UNKNOWN = bytes32(uint256(99));
    bytes32 internal constant RECIPIENT_WARMUP = bytes32(uint256(100));
    bytes32 internal constant CLAIMED_EVENT_TOPIC =
        keccak256("Claimed(address,address,uint256,uint256,uint256,uint256)");

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xCA11);

    RewardEscrowMockToken internal rewardToken;
    RewardEscrowMockToken internal cobuildToken;
    SharedMockStakeVault internal stakeVault;

    RewardEscrowMockGoalTreasury internal goalTreasury;
    SharedMockFlow internal goalFlow;

    SharedMockFlow internal budgetFlowA;
    SharedMockFlow internal budgetFlowB;
    SharedMockFlow internal budgetFlowC;
    SharedMockFlow internal budgetFlowInvalid;

    RewardEscrowMockBudgetTreasury internal budgetA;
    RewardEscrowMockBudgetTreasury internal budgetB;
    RewardEscrowMockBudgetTreasury internal budgetC;
    RewardEscrowMockBudgetTreasury internal budgetInvalid;

    BudgetStakeLedger internal ledger;
    RewardEscrow internal escrow;

    function setUp() public {
        rewardToken = new RewardEscrowMockToken();
        cobuildToken = new RewardEscrowMockToken();
        stakeVault = new SharedMockStakeVault();
        stakeVault.setGoalToken(IERC20(address(rewardToken)));
        stakeVault.setCobuildToken(IERC20(address(cobuildToken)));

        goalTreasury = new RewardEscrowMockGoalTreasury();
        goalFlow = new SharedMockFlow(ISuperToken(address(rewardToken)));
        goalTreasury.setFlow(address(goalFlow));

        budgetFlowA = new SharedMockFlow(ISuperToken(address(rewardToken)));
        budgetFlowB = new SharedMockFlow(ISuperToken(address(rewardToken)));
        budgetFlowC = new SharedMockFlow(ISuperToken(address(rewardToken)));
        budgetFlowInvalid = new SharedMockFlow(ISuperToken(address(rewardToken)));

        budgetFlowA.setParent(address(goalFlow));
        budgetFlowB.setParent(address(goalFlow));
        budgetFlowC.setParent(address(goalFlow));
        budgetFlowInvalid.setParent(address(0xDEAD));

        budgetA = new RewardEscrowMockBudgetTreasury(address(budgetFlowA));
        budgetB = new RewardEscrowMockBudgetTreasury(address(budgetFlowB));
        budgetC = new RewardEscrowMockBudgetTreasury(address(budgetFlowC));
        budgetInvalid = new RewardEscrowMockBudgetTreasury(address(budgetFlowInvalid));

        goalFlow.setRecipient(RECIPIENT_A, address(budgetA));
        goalFlow.setRecipient(RECIPIENT_B, address(budgetB));
        goalFlow.setRecipient(RECIPIENT_C, address(budgetC));
        goalFlow.setRecipient(RECIPIENT_D, address(budgetInvalid));

        ledger = new BudgetStakeLedger(address(goalTreasury));
        escrow = new RewardEscrow(
            address(goalTreasury),
            IERC20(address(rewardToken)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );
        goalTreasury.setRewardEscrow(address(escrow));

        vm.mockCall(address(goalFlow), abi.encodeWithSignature("recipientAdmin()"), abi.encode(address(this)));
        vm.mockCall(address(goalFlow), abi.encodeWithSignature("allocationPipeline()"), abi.encode(address(0)));
        ledger.registerBudget(RECIPIENT_A, address(budgetA));
        ledger.registerBudget(RECIPIENT_B, address(budgetB));
        ledger.registerBudget(RECIPIENT_C, address(budgetC));
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IRewardEscrow.ADDRESS_ZERO.selector);
        new RewardEscrow(
            address(0),
            IERC20(address(rewardToken)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );

        vm.expectRevert(IRewardEscrow.ADDRESS_ZERO.selector);
        new RewardEscrow(
            address(goalTreasury),
            IERC20(address(0)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );

        vm.expectRevert(IRewardEscrow.ADDRESS_ZERO.selector);
        new RewardEscrow(
            address(goalTreasury),
            IERC20(address(rewardToken)),
            IGoalStakeVault(address(0)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );

        vm.expectRevert(IRewardEscrow.ADDRESS_ZERO.selector);
        new RewardEscrow(
            address(goalTreasury),
            IERC20(address(rewardToken)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(0))
        );
    }

    function test_constructor_revertsWhenStakeVaultGoalTokenReadFails() public {
        RewardEscrowMockStakeVaultGoalTokenReverts badStakeVault = new RewardEscrowMockStakeVaultGoalTokenReverts();

        vm.expectRevert(RewardEscrowMockStakeVaultGoalTokenReverts.GOAL_TOKEN_REVERT.selector);
        new RewardEscrow(
            address(goalTreasury),
            IERC20(address(rewardToken)),
            IGoalStakeVault(address(badStakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );
    }

    function test_finalize_onlyGoalTreasury() public {
        vm.expectRevert(IRewardEscrow.ONLY_GOAL_TREASURY.selector);
        vm.prank(alice);
        escrow.finalize(GOAL_SUCCEEDED, uint64(block.timestamp));
    }

    function test_finalize_revertsOnInvalidStateAndSecondCall() public {
        vm.expectRevert(IRewardEscrow.INVALID_FINAL_STATE.selector);
        vm.prank(address(goalTreasury));
        escrow.finalize(1, uint64(block.timestamp));

        _resolveFundingBudgetsAsFailed(uint64(block.timestamp));

        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, uint64(block.timestamp));

        vm.expectRevert(IRewardEscrow.ALREADY_FINALIZED.selector);
        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, uint64(block.timestamp));
    }

    function test_claim_revertsBeforeFinalize() public {
        vm.expectRevert(IRewardEscrow.NOT_FINALIZED.selector);
        vm.prank(alice);
        escrow.claim(alice);
    }

    function test_previewClaim_preFinalizeReturnsZeroes() public view {
        IRewardEscrow.ClaimPreview memory preview = escrow.previewClaim(alice);
        assertEq(preview.snapshotGoalAmount, 0);
        assertEq(preview.snapshotCobuildAmount, 0);
        assertEq(preview.goalRentAmount, 0);
        assertEq(preview.cobuildRentAmount, 0);
        assertEq(preview.totalGoalAmount, 0);
        assertEq(preview.totalCobuildAmount, 0);
        assertEq(preview.userPoints, 0);
        assertFalse(preview.snapshotClaimed);
    }

    function test_previewClaim_andClaimCursor_reflectProjectedAndRealizedClaims() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 60, ids, scaled);
        _checkpointInitial(bob, 40, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(200);

        rewardToken.mint(address(escrow), 1_000e18);
        vm.warp(200);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        rewardToken.mint(address(escrow), 100e18);
        cobuildToken.mint(address(escrow), 50e18);

        IRewardEscrow.ClaimCursor memory beforeCursor = escrow.claimCursor(alice);
        assertFalse(beforeCursor.snapshotClaimed);
        assertFalse(beforeCursor.successfulPointsCached);
        assertEq(beforeCursor.cachedSuccessfulPoints, 0);

        IRewardEscrow.ClaimPreview memory beforePreview = escrow.previewClaim(alice);
        assertFalse(beforePreview.snapshotClaimed);
        assertGt(beforePreview.snapshotGoalAmount, 0);
        assertGt(beforePreview.goalRentAmount, 0);
        assertGt(beforePreview.cobuildRentAmount, 0);
        assertEq(beforePreview.totalGoalAmount, beforePreview.snapshotGoalAmount + beforePreview.goalRentAmount);
        assertEq(
            beforePreview.totalCobuildAmount,
            beforePreview.snapshotCobuildAmount + beforePreview.cobuildRentAmount
        );

        vm.prank(alice);
        (uint256 goalClaimed, uint256 cobuildClaimed) = escrow.claim(alice);

        assertApproxEqAbs(goalClaimed, beforePreview.totalGoalAmount, 1);
        assertApproxEqAbs(cobuildClaimed, beforePreview.totalCobuildAmount, 1);

        IRewardEscrow.ClaimCursor memory afterCursor = escrow.claimCursor(alice);
        assertTrue(afterCursor.snapshotClaimed);
        assertTrue(afterCursor.successfulPointsCached);
        assertGt(afterCursor.cachedSuccessfulPoints, 0);
        assertEq(afterCursor.goalRentPerPointPaid, escrow.goalRentPerPointStored());
        assertEq(afterCursor.cobuildRentPerPointPaid, escrow.cobuildRentPerPointStored());

        IRewardEscrow.ClaimPreview memory afterPreview = escrow.previewClaim(alice);
        assertTrue(afterPreview.snapshotClaimed);
        assertEq(afterPreview.snapshotGoalAmount, 0);
        assertEq(afterPreview.snapshotCobuildAmount, 0);
        assertEq(afterPreview.goalRentAmount, 0);
        assertEq(afterPreview.cobuildRentAmount, 0);
        assertEq(afterPreview.totalGoalAmount, 0);
        assertEq(afterPreview.totalCobuildAmount, 0);
    }

    function test_checkpointAllocation_onlyGoalFlow() public {
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        vm.expectRevert(IBudgetStakeLedger.ONLY_GOAL_FLOW.selector);
        ledger.checkpointAllocation(alice, 0, emptyIds, emptyScaled, 1, emptyIds, emptyScaled);
    }

    function test_checkpointAllocation_revertsOnZeroAccountAndInvalidData() public {
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        bytes32[] memory oneId = _ids1(RECIPIENT_A);
        uint32[] memory oneScaled = _scaled1(1_000_000);

        vm.expectRevert(IBudgetStakeLedger.ADDRESS_ZERO.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(address(0), 0, emptyIds, emptyScaled, 1, oneId, oneScaled);

        vm.expectRevert(IBudgetStakeLedger.INVALID_CHECKPOINT_DATA.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(alice, 1, oneId, emptyScaled, 1, oneId, oneScaled);

        vm.expectRevert(IBudgetStakeLedger.INVALID_CHECKPOINT_DATA.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(alice, 1, oneId, oneScaled, 1, oneId, emptyScaled);
    }

    function test_checkpointAllocation_revertsOnUnsortedRecipientIds() public {
        bytes32[] memory sortedIds = _ids2(RECIPIENT_A, RECIPIENT_B);
        uint32[] memory sortedScaled = _scaled2(600_000, 400_000);
        bytes32[] memory unsortedIds = _ids2(RECIPIENT_B, RECIPIENT_A);

        vm.expectRevert(IBudgetStakeLedger.INVALID_CHECKPOINT_DATA.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(alice, 100, unsortedIds, sortedScaled, 100, sortedIds, sortedScaled);

        vm.expectRevert(IBudgetStakeLedger.INVALID_CHECKPOINT_DATA.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(alice, 100, sortedIds, sortedScaled, 100, unsortedIds, sortedScaled);
    }

    function test_checkpointAllocation_revertsOnDuplicateRecipientIds() public {
        bytes32[] memory sortedIds = _ids2(RECIPIENT_A, RECIPIENT_B);
        uint32[] memory sortedScaled = _scaled2(600_000, 400_000);

        bytes32[] memory duplicatePrevIds = _ids2(RECIPIENT_A, RECIPIENT_A);
        uint32[] memory duplicatePrevScaled = _scaled2(300_000, 700_000);

        vm.expectRevert(IBudgetStakeLedger.INVALID_CHECKPOINT_DATA.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(alice, 100, duplicatePrevIds, duplicatePrevScaled, 100, sortedIds, sortedScaled);

        bytes32[] memory duplicateNewIds = _ids2(RECIPIENT_B, RECIPIENT_B);
        uint32[] memory duplicateNewScaled = _scaled2(450_000, 550_000);

        vm.expectRevert(IBudgetStakeLedger.INVALID_CHECKPOINT_DATA.selector);
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(alice, 100, sortedIds, sortedScaled, 100, duplicateNewIds, duplicateNewScaled);
    }

    function test_checkpointAllocation_tracksOnlyValidGoalChildBudgets() public {
        bytes32[] memory ids = _ids3(RECIPIENT_A, RECIPIENT_D, RECIPIENT_UNKNOWN);
        uint32[] memory scaled = _scaled3(500_000, 300_000, 200_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        assertEq(escrow.trackedBudgetCount(), 3);
        assertEq(escrow.trackedBudgetAt(0), address(budgetA));
        assertEq(escrow.trackedBudgetAt(1), address(budgetB));
        assertEq(escrow.trackedBudgetAt(2), address(budgetC));

        vm.warp(110);
        _checkpoint(alice, 100, ids, scaled, 100, ids, scaled);

        assertEq(escrow.budgetPoints(address(budgetA)), 450 * UNIT_WEIGHT_SCALE);
        assertEq(escrow.userPointsOnBudget(alice, address(budgetA)), 450 * UNIT_WEIGHT_SCALE);
        assertEq(escrow.budgetPoints(address(budgetInvalid)), 0);
        assertEq(escrow.trackedBudgetCount(), 3);
    }

    function test_finalize_success_claimsProRataBySuccessfulBudgetPoints() public {
        bytes32[] memory ids = _ids4(RECIPIENT_A, RECIPIENT_B, RECIPIENT_C, RECIPIENT_D);

        uint32[] memory aliceScaledStart = _scaled4(600_000, 200_000, 100_000, 100_000);
        uint32[] memory aliceScaledMid = _scaled4(300_000, 400_000, 200_000, 100_000);

        uint32[] memory bobPpmStart = _scaled4(400_000, 300_000, 200_000, 100_000);
        uint32[] memory bobPpmMid = _scaled4(500_000, 250_000, 150_000, 100_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, aliceScaledStart);
        _checkpointInitial(bob, 50, ids, bobPpmStart);

        vm.warp(160);
        _checkpoint(alice, 100, ids, aliceScaledStart, 100, ids, aliceScaledMid);

        vm.warp(200);
        _checkpoint(bob, 50, ids, bobPpmStart, 80, ids, bobPpmMid);

        assertEq(escrow.trackedBudgetCount(), 3);
        assertEq(escrow.trackedBudgetAt(0), address(budgetA));
        assertEq(escrow.trackedBudgetAt(1), address(budgetB));
        assertEq(escrow.trackedBudgetAt(2), address(budgetC));

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(220);

        budgetB.setState(IBudgetTreasury.BudgetState.Failed);
        budgetB.setResolvedAt(220);

        budgetC.setState(IBudgetTreasury.BudgetState.Failed);
        budgetC.setResolvedAt(220);

        rewardToken.mint(address(escrow), 820e18);
        cobuildToken.mint(address(escrow), 410e18);

        vm.warp(300);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        assertTrue(escrow.finalized());
        assertEq(escrow.finalState(), GOAL_SUCCEEDED);
        assertEq(escrow.goalFinalizedAt(), 300);
        assertEq(escrow.rewardPoolSnapshot(), 820e18);

        uint256 totalPoints = escrow.totalPointsSnapshot();
        assertGt(totalPoints, 0);

        assertEq(escrow.budgetPoints(address(budgetA)), totalPoints);
        assertGt(escrow.budgetPoints(address(budgetB)), 0);
        assertGt(escrow.budgetPoints(address(budgetC)), 0);
        assertEq(escrow.budgetPoints(address(budgetInvalid)), 0);

        assertTrue(escrow.budgetSucceededAtFinalize(address(budgetA)));
        assertFalse(escrow.budgetSucceededAtFinalize(address(budgetB)));
        assertFalse(escrow.budgetSucceededAtFinalize(address(budgetC)));

        assertEq(escrow.budgetResolvedAtFinalize(address(budgetA)), 220);
        assertEq(escrow.budgetResolvedAtFinalize(address(budgetB)), 220);
        assertEq(escrow.budgetResolvedAtFinalize(address(budgetC)), 220);

        uint256 alicePoints = escrow.userPointsOnBudget(alice, address(budgetA));
        uint256 bobPoints = escrow.userPointsOnBudget(bob, address(budgetA));
        assertEq(totalPoints, alicePoints + bobPoints);

        vm.prank(alice);
        (uint256 aliceClaim, uint256 aliceCobuildClaim) = escrow.claim(alice);

        vm.prank(bob);
        (uint256 bobClaim, uint256 bobCobuildClaim) = escrow.claim(bob);

        uint256 expectedAlice = (820e18 * alicePoints) / totalPoints;
        uint256 expectedBob = (820e18 * bobPoints) / totalPoints;
        uint256 remainingReward = 820e18 - expectedAlice;
        if (expectedBob > remainingReward) expectedBob = remainingReward;

        uint256 expectedAliceCobuild = (410e18 * alicePoints) / totalPoints;
        uint256 expectedBobCobuild = (410e18 * bobPoints) / totalPoints;
        uint256 remainingCobuild = 410e18 - expectedAliceCobuild;
        if (expectedBobCobuild > remainingCobuild) expectedBobCobuild = remainingCobuild;

        assertEq(aliceClaim, expectedAlice);
        assertEq(bobClaim, expectedBob);
        assertEq(aliceCobuildClaim, expectedAliceCobuild);
        assertEq(bobCobuildClaim, expectedBobCobuild);
        assertEq(rewardToken.balanceOf(alice), expectedAlice);
        assertEq(rewardToken.balanceOf(bob), expectedBob);
        assertEq(cobuildToken.balanceOf(alice), expectedAliceCobuild);
        assertEq(cobuildToken.balanceOf(bob), expectedBobCobuild);
        assertEq(escrow.totalClaimed(), expectedAlice + expectedBob);
        assertEq(escrow.totalCobuildClaimed(), expectedAliceCobuild + expectedBobCobuild);
        assertEq(rewardToken.balanceOf(address(escrow)), 820e18 - (expectedAlice + expectedBob));
        assertEq(cobuildToken.balanceOf(address(escrow)), 410e18 - (expectedAliceCobuild + expectedBobCobuild));
    }

    function test_finalize_success_capsPointsAtFundingDeadline_whenPostDeadlineCheckpointsOccur() public {
        RewardEscrowMockBudgetTreasury fundingBudget = _registerWarmupBudget(RECIPIENT_WARMUP, 10, 200);
        bytes32[] memory ids = _ids1(RECIPIENT_WARMUP);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        vm.warp(260);
        fundingBudget.setState(IBudgetTreasury.BudgetState.Succeeded);
        fundingBudget.setResolvedAt(260);
        _checkpoint(alice, 100, ids, scaled, 100, ids, scaled);

        vm.warp(320);
        _checkpoint(alice, 100, ids, scaled, 100, ids, scaled);

        rewardToken.mint(address(escrow), 100e18);

        vm.warp(400);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        uint256 expectedCappedPoints = 9_900 * UNIT_WEIGHT_SCALE;
        assertEq(escrow.budgetPoints(address(fundingBudget)), expectedCappedPoints);
        assertEq(escrow.userPointsOnBudget(alice, address(fundingBudget)), expectedCappedPoints);
        assertEq(escrow.totalPointsSnapshot(), expectedCappedPoints);
    }

    function test_finalize_success_delayedFinalizeIncludesBudgetResolvedAfterFrozenGoalFinalizedAt() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        vm.warp(250);
        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(250);

        rewardToken.mint(address(escrow), 100e18);

        uint64 frozenGoalFinalizedAt = 200;
        _resolveFundingBudgetsAsFailed(250);
        vm.warp(300);
        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, frozenGoalFinalizedAt);

        assertEq(escrow.goalFinalizedAt(), frozenGoalFinalizedAt);
        assertEq(escrow.budgetResolvedAtFinalize(address(budgetA)), 250);
        assertGt(escrow.userPointsOnBudget(alice, address(budgetA)), 0);
        assertTrue(escrow.budgetSucceededAtFinalize(address(budgetA)));
        assertGt(escrow.totalPointsSnapshot(), 0);
        assertGt(escrow.userSuccessfulPoints(alice), 0);

        vm.prank(alice);
        (uint256 claimAmount, ) = escrow.claim(alice);
        assertGt(claimAmount, 0);
    }

    function test_finalize_success_removedBudgetCapsPointsAtRemoval_andExcludesRewards() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        vm.warp(200);
        _checkpoint(alice, 100, ids, scaled, 100, ids, scaled);
        uint256 pointsAtRemoval = escrow.budgetPoints(address(budgetA));
        assertGt(pointsAtRemoval, 0);

        budgetB.setResolvedAt(210);
        budgetC.setResolvedAt(210);
        assertFalse(escrow.allTrackedBudgetsResolved());

        ledger.removeBudget(RECIPIENT_A);
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));
        assertTrue(escrow.allTrackedBudgetsResolved());

        // Even if the removed budget later resolves as succeeded, it must be excluded from rewards.
        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(260);

        vm.warp(300);
        _checkpoint(alice, 100, ids, scaled, 100, ids, scaled);
        assertEq(escrow.budgetPoints(address(budgetA)), pointsAtRemoval);

        rewardToken.mint(address(escrow), 100e18);

        vm.warp(400);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        assertEq(escrow.budgetPoints(address(budgetA)), pointsAtRemoval);
        assertEq(escrow.userPointsOnBudget(alice, address(budgetA)), pointsAtRemoval);
        assertFalse(escrow.budgetSucceededAtFinalize(address(budgetA)));
        assertEq(escrow.totalPointsSnapshot(), 0);

        vm.prank(alice);
        (uint256 claimAmount, ) = escrow.claim(alice);
        assertEq(claimAmount, 0);
    }

    function test_finalize_success_usersWithoutSuccessfulBudgetPointsClaimZero() public {
        bytes32[] memory ids = _ids3(RECIPIENT_A, RECIPIENT_B, RECIPIENT_C);

        uint32[] memory aliceScaled = _scaled3(1_000_000, 0, 0);
        uint32[] memory charlieScaled = _scaled3(0, 500_000, 500_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, aliceScaled);
        _checkpointInitial(charlie, 100, ids, charlieScaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(200);

        budgetB.setState(IBudgetTreasury.BudgetState.Failed);
        budgetB.setResolvedAt(200);

        budgetC.setState(IBudgetTreasury.BudgetState.Failed);
        budgetC.setResolvedAt(200);

        rewardToken.mint(address(escrow), 1_000e18);

        vm.warp(250);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        IRewardEscrow.ClaimCursor memory beforeCharlieCursor = escrow.claimCursor(charlie);
        assertFalse(beforeCharlieCursor.snapshotClaimed);
        assertFalse(beforeCharlieCursor.successfulPointsCached);
        assertEq(beforeCharlieCursor.cachedSuccessfulPoints, 0);

        assertEq(escrow.totalPointsSnapshot(), escrow.userPointsOnBudget(alice, address(budgetA)));
        assertGt(escrow.userPointsOnBudget(charlie, address(budgetB)), 0);
        assertGt(escrow.userPointsOnBudget(charlie, address(budgetC)), 0);

        vm.prank(charlie);
        (uint256 charlieClaim, ) = escrow.claim(charlie);

        IRewardEscrow.ClaimCursor memory afterCharlieCursor = escrow.claimCursor(charlie);
        assertTrue(afterCharlieCursor.snapshotClaimed);
        assertTrue(afterCharlieCursor.successfulPointsCached);
        assertEq(afterCharlieCursor.cachedSuccessfulPoints, 0);

        vm.prank(alice);
        (uint256 aliceClaim, ) = escrow.claim(alice);

        assertEq(charlieClaim, 0);
        assertEq(aliceClaim, 1_000e18);
        assertEq(rewardToken.balanceOf(charlie), 0);
        assertEq(rewardToken.balanceOf(alice), 1_000e18);
    }

    function test_warmup_snipingLargeLateStakeUnderperformsLongerHold() public {
        RewardEscrowMockBudgetTreasury warmupBudget = _registerWarmupBudget(RECIPIENT_WARMUP, 1_000, 201); // M = 100s
        bytes32[] memory ids = _ids1(RECIPIENT_WARMUP);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        vm.warp(200);
        _checkpoint(alice, 100, ids, scaled, 100, ids, scaled);

        _checkpointInitial(bob, 10_000, ids, scaled);
        vm.warp(201);
        _checkpoint(bob, 10_000, ids, scaled, 10_000, ids, scaled);

        warmupBudget.setState(IBudgetTreasury.BudgetState.Succeeded);
        warmupBudget.setResolvedAt(201);
        rewardToken.mint(address(escrow), 100e18);

        vm.warp(220);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        uint256 alicePoints = escrow.userPointsOnBudget(alice, address(warmupBudget));
        uint256 bobPoints = escrow.userPointsOnBudget(bob, address(warmupBudget));
        assertGt(alicePoints, bobPoints);
    }

    function test_warmup_decreaseDoesNotInstantlyMatureRemainingStake() public {
        RewardEscrowMockBudgetTreasury warmupBudget = _registerWarmupBudget(RECIPIENT_WARMUP, 1_000); // M = 100s
        bytes32[] memory ids = _ids1(RECIPIENT_WARMUP);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 10_000, ids, scaled);

        vm.warp(110);
        _checkpoint(alice, 10_000, ids, scaled, 1_000, ids, scaled);
        uint256 pointsAtReduction = escrow.userPointsOnBudget(alice, address(warmupBudget));

        vm.warp(111);
        _checkpoint(alice, 1_000, ids, scaled, 1_000, ids, scaled);
        uint256 pointsAfterOneSecond = escrow.userPointsOnBudget(alice, address(warmupBudget));
        uint256 delta = pointsAfterOneSecond - pointsAtReduction;

        assertGt(delta, 0);
        assertLt(delta, _scaledWeight(1_000));
    }

    function test_warmup_budgetPointsApproximatelyMatchSumOfUserPoints() public {
        RewardEscrowMockBudgetTreasury warmupBudget = _registerWarmupBudget(RECIPIENT_WARMUP, 1_000); // M = 100s
        bytes32[] memory ids = _ids1(RECIPIENT_WARMUP);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 5_000, ids, scaled);
        _checkpointInitial(bob, 3_000, ids, scaled);

        vm.warp(130);
        _checkpoint(alice, 5_000, ids, scaled, 4_000, ids, scaled);
        vm.warp(160);
        _checkpoint(bob, 3_000, ids, scaled, 1_000, ids, scaled);
        vm.warp(200);
        _checkpoint(alice, 4_000, ids, scaled, 4_500, ids, scaled);
        _checkpoint(bob, 1_000, ids, scaled, 1_200, ids, scaled);

        warmupBudget.setState(IBudgetTreasury.BudgetState.Succeeded);
        warmupBudget.setResolvedAt(210);
        rewardToken.mint(address(escrow), 100e18);

        vm.warp(220);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        uint256 budgetPoints = escrow.budgetPoints(address(warmupBudget));
        uint256 sumUserPoints = escrow.userPointsOnBudget(alice, address(warmupBudget))
            + escrow.userPointsOnBudget(bob, address(warmupBudget));

        assertEq(escrow.totalPointsSnapshot(), budgetPoints);
        assertApproxEqAbs(budgetPoints, sumUserPoints, 50 * UNIT_WEIGHT_SCALE);
    }

    function test_finalize_success_withNoSuccessfulBudgetsYieldsZeroClaims() public {
        bytes32[] memory ids = _ids2(RECIPIENT_B, RECIPIENT_C);
        uint32[] memory scaled = _scaled2(700_000, 300_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        budgetB.setState(IBudgetTreasury.BudgetState.Failed);
        budgetB.setResolvedAt(200);

        budgetC.setState(IBudgetTreasury.BudgetState.Failed);
        budgetC.setResolvedAt(200);

        rewardToken.mint(address(escrow), 500e18);

        vm.warp(240);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        assertEq(escrow.totalPointsSnapshot(), 0);

        vm.prank(alice);
        (uint256 amount, ) = escrow.claim(alice);

        assertEq(amount, 0);
        assertTrue(escrow.claimed(alice));
        assertEq(escrow.totalClaimed(), 0);
    }

    function test_finalize_success_withNoSuccessfulBudgets_allowsTreasurySweep() public {
        bytes32[] memory ids = _ids1(RECIPIENT_B);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        budgetB.setState(IBudgetTreasury.BudgetState.Failed);
        budgetB.setResolvedAt(200);

        rewardToken.mint(address(escrow), 500e18);
        cobuildToken.mint(address(escrow), 200e18);

        vm.warp(240);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        assertEq(escrow.totalPointsSnapshot(), 0);

        vm.prank(address(goalTreasury));
        uint256 swept = escrow.releaseFailedAssetsToTreasury();

        assertEq(swept, 500e18);
        assertEq(rewardToken.balanceOf(address(goalTreasury)), 500e18);
        assertEq(cobuildToken.balanceOf(address(goalTreasury)), 200e18);
        assertEq(rewardToken.balanceOf(address(escrow)), 0);
        assertEq(cobuildToken.balanceOf(address(escrow)), 0);
    }

    function test_successZeroSnapshotPoints_lateRentInflows_claimPathDoesNotRevertAndSweepStillWorks() public {
        bytes32[] memory ids = _ids1(RECIPIENT_B);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 100, ids, scaled);

        budgetB.setState(IBudgetTreasury.BudgetState.Failed);
        budgetB.setResolvedAt(200);
        budgetC.setState(IBudgetTreasury.BudgetState.Failed);
        budgetC.setResolvedAt(200);

        rewardToken.mint(address(escrow), 500e18);

        vm.warp(240);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        assertEq(escrow.totalPointsSnapshot(), 0);
        assertEq(escrow.goalRentPerPointStored(), 0);
        assertEq(escrow.totalGoalRentClaimed(), 0);

        // Force cumulative > indexedTotal while snapshotPoints stays zero.
        rewardToken.mint(address(escrow), 25e18);
        cobuildToken.mint(address(escrow), 10e18);

        IRewardEscrow.ClaimPreview memory preview = escrow.previewClaim(alice);
        assertEq(preview.goalRentAmount, 0);
        assertEq(preview.cobuildRentAmount, 0);
        assertEq(preview.totalGoalAmount, 0);
        assertEq(preview.totalCobuildAmount, 0);

        vm.prank(alice);
        (uint256 claimAmount, uint256 claimCobuildAmount) = escrow.claim(alice);
        assertEq(claimAmount, 0);
        assertEq(claimCobuildAmount, 0);
        assertEq(escrow.goalRentPerPointStored(), 0);
        assertEq(escrow.totalGoalRentClaimed(), 0);
        assertEq(escrow.totalCobuildRentClaimed(), 0);

        vm.prank(address(goalTreasury));
        uint256 swept = escrow.releaseFailedAssetsToTreasury();

        assertEq(swept, 525e18);
        assertEq(rewardToken.balanceOf(address(goalTreasury)), 525e18);
        assertEq(cobuildToken.balanceOf(address(goalTreasury)), 10e18);
    }

    function test_claim_revertsOnZeroRecipient_andSecondClaimReturnsZeroWithoutNewRent() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 10, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(150);

        rewardToken.mint(address(escrow), 100e18);

        vm.warp(200);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        vm.expectRevert(IRewardEscrow.ADDRESS_ZERO.selector);
        vm.prank(alice);
        escrow.claim(address(0));

        vm.prank(alice);
        (uint256 firstClaim, ) = escrow.claim(alice);
        assertEq(firstClaim, 100e18);

        vm.prank(alice);
        (uint256 secondClaim, ) = escrow.claim(alice);
        assertEq(secondClaim, 0);
    }

    function test_claim_secondClaimCollectsLateGoalRentProRata() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 60, ids, scaled);
        _checkpointInitial(bob, 40, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(200);

        rewardToken.mint(address(escrow), 1_000e18);

        vm.warp(200);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        vm.prank(alice);
        (uint256 aliceFirst, ) = escrow.claim(alice);
        vm.prank(bob);
        (uint256 bobFirst, ) = escrow.claim(bob);
        assertEq(aliceFirst, 600e18);
        assertEq(bobFirst, 400e18);

        rewardToken.mint(address(escrow), 100e18);

        vm.prank(bob);
        (uint256 bobSecond, ) = escrow.claim(bob);
        vm.prank(alice);
        (uint256 aliceSecond, ) = escrow.claim(alice);

        assertApproxEqAbs(bobSecond, 40e18, 1);
        assertApproxEqAbs(aliceSecond, 60e18, 1);
        assertApproxEqAbs(rewardToken.balanceOf(alice), 660e18, 1);
        assertApproxEqAbs(rewardToken.balanceOf(bob), 440e18, 1);
    }

    function test_claim_secondClaimCollectsLateCobuildRentProRata() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 70, ids, scaled);
        _checkpointInitial(bob, 30, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(200);

        rewardToken.mint(address(escrow), 1_000e18);

        vm.warp(200);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        vm.prank(alice);
        (uint256 aliceFirstGoal, uint256 aliceFirstCobuild) = escrow.claim(alice);
        vm.prank(bob);
        (uint256 bobFirstGoal, uint256 bobFirstCobuild) = escrow.claim(bob);
        assertEq(aliceFirstGoal, 700e18);
        assertEq(bobFirstGoal, 300e18);
        assertEq(aliceFirstCobuild, 0);
        assertEq(bobFirstCobuild, 0);

        cobuildToken.mint(address(escrow), 100e18);

        vm.prank(alice);
        (uint256 aliceSecondGoal, uint256 aliceSecondCobuild) = escrow.claim(alice);
        vm.prank(bob);
        (uint256 bobSecondGoal, uint256 bobSecondCobuild) = escrow.claim(bob);

        assertEq(aliceSecondGoal, 0);
        assertEq(bobSecondGoal, 0);
        assertApproxEqAbs(aliceSecondCobuild, 70e18, 1);
        assertApproxEqAbs(bobSecondCobuild, 30e18, 1);
        assertApproxEqAbs(cobuildToken.balanceOf(alice), 70e18, 1);
        assertApproxEqAbs(cobuildToken.balanceOf(bob), 30e18, 1);
    }

    function test_claim_emitsSingleConsolidatedEventWithAllAmounts() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 10, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(150);

        rewardToken.mint(address(escrow), 100e18);
        cobuildToken.mint(address(escrow), 25e18);

        vm.warp(200);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        rewardToken.mint(address(escrow), 10e18);
        cobuildToken.mint(address(escrow), 5e18);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 goalAmount, uint256 cobuildAmount) = escrow.claim(alice);

        assertApproxEqAbs(goalAmount, 110e18, 1);
        assertApproxEqAbs(cobuildAmount, 30e18, 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 claimLogCount;
        Vm.Log memory claimLog;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CLAIMED_EVENT_TOPIC) {
                ++claimLogCount;
                claimLog = logs[i];
            }
        }

        assertEq(claimLogCount, 1);
        assertEq(claimLog.topics.length, 3);
        assertEq(claimLog.topics[1], bytes32(uint256(uint160(alice))));
        assertEq(claimLog.topics[2], bytes32(uint256(uint160(alice))));

        (uint256 rewardAmount, uint256 baseCobuildAmount, uint256 goalRentAmount, uint256 cobuildRentAmount) =
            abi.decode(claimLog.data, (uint256, uint256, uint256, uint256));
        assertEq(rewardAmount, 100e18);
        assertEq(baseCobuildAmount, 25e18);
        assertApproxEqAbs(goalRentAmount, 10e18, 1);
        assertApproxEqAbs(cobuildRentAmount, 5e18, 1);
    }

    function test_claim_secondClaimRentOnly_emitsSingleConsolidatedEvent() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 10, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(150);

        rewardToken.mint(address(escrow), 100e18);
        cobuildToken.mint(address(escrow), 25e18);

        vm.warp(200);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        vm.prank(alice);
        escrow.claim(alice);

        rewardToken.mint(address(escrow), 10e18);
        cobuildToken.mint(address(escrow), 5e18);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 goalAmount, uint256 cobuildAmount) = escrow.claim(alice);

        assertApproxEqAbs(goalAmount, 10e18, 1);
        assertApproxEqAbs(cobuildAmount, 5e18, 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 claimLogCount;
        Vm.Log memory claimLog;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CLAIMED_EVENT_TOPIC) {
                ++claimLogCount;
                claimLog = logs[i];
            }
        }

        assertEq(claimLogCount, 1);
        assertEq(claimLog.topics.length, 3);
        assertEq(claimLog.topics[1], bytes32(uint256(uint160(alice))));
        assertEq(claimLog.topics[2], bytes32(uint256(uint160(alice))));

        (uint256 rewardAmount, uint256 baseCobuildAmount, uint256 goalRentAmount, uint256 cobuildRentAmount) =
            abi.decode(claimLog.data, (uint256, uint256, uint256, uint256));
        assertEq(rewardAmount, 0);
        assertEq(baseCobuildAmount, 0);
        assertApproxEqAbs(goalRentAmount, 10e18, 1);
        assertApproxEqAbs(cobuildRentAmount, 5e18, 1);
    }

    function test_claim_zeroPath_emitsSingleConsolidatedZeroEvent() public {
        rewardToken.mint(address(escrow), 100e18);

        _finalizeAsGoalTreasury(GOAL_EXPIRED);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 goalAmount, uint256 cobuildAmount) = escrow.claim(alice);

        assertEq(goalAmount, 0);
        assertEq(cobuildAmount, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 claimLogCount;
        Vm.Log memory claimLog;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CLAIMED_EVENT_TOPIC) {
                ++claimLogCount;
                claimLog = logs[i];
            }
        }

        assertEq(claimLogCount, 1);
        assertEq(claimLog.topics.length, 3);
        assertEq(claimLog.topics[1], bytes32(uint256(uint160(alice))));
        assertEq(claimLog.topics[2], bytes32(uint256(uint160(alice))));

        (uint256 rewardAmount, uint256 baseCobuildAmount, uint256 goalRentAmount, uint256 cobuildRentAmount) =
            abi.decode(claimLog.data, (uint256, uint256, uint256, uint256));
        assertEq(rewardAmount, 0);
        assertEq(baseCobuildAmount, 0);
        assertEq(goalRentAmount, 0);
        assertEq(cobuildRentAmount, 0);
    }

    function test_sweepFailed_revertsWhenNotFinalized() public {
        rewardToken.mint(address(escrow), 111e18);

        vm.expectRevert(IRewardEscrow.NOT_FINALIZED.selector);
        vm.prank(address(goalTreasury));
        escrow.releaseFailedAssetsToTreasury();

        assertEq(rewardToken.balanceOf(address(escrow)), 111e18);
        assertEq(rewardToken.balanceOf(address(goalTreasury)), 0);
    }

    function test_sweepFailed_onlyGoalTreasury_andGoalFailurePath() public {
        rewardToken.mint(address(escrow), 1_000e18);

        _finalizeAsGoalTreasury(GOAL_EXPIRED);

        vm.prank(alice);
        (uint256 claimAmount, ) = escrow.claim(alice);
        assertEq(claimAmount, 0);
        assertTrue(escrow.claimed(alice));

        vm.expectRevert(IRewardEscrow.ONLY_GOAL_TREASURY.selector);
        vm.prank(alice);
        escrow.releaseFailedAssetsToTreasury();

        vm.prank(address(goalTreasury));
        uint256 swept = escrow.releaseFailedAssetsToTreasury();

        assertEq(swept, 1_000e18);
        assertEq(rewardToken.balanceOf(address(goalTreasury)), 1_000e18);
        assertEq(rewardToken.balanceOf(address(escrow)), 0);

        vm.prank(address(goalTreasury));
        uint256 secondSweep = escrow.releaseFailedAssetsToTreasury();
        assertEq(secondSweep, 0);
    }

    function test_sweepFailed_expiredPath() public {
        rewardToken.mint(address(escrow), 555e18);

        _finalizeAsGoalTreasury(GOAL_EXPIRED);

        vm.prank(bob);
        (uint256 claimAmount, ) = escrow.claim(bob);
        assertEq(claimAmount, 0);

        vm.prank(address(goalTreasury));
        uint256 swept = escrow.releaseFailedAssetsToTreasury();

        assertEq(swept, 555e18);
        assertEq(rewardToken.balanceOf(address(goalTreasury)), 555e18);
        assertEq(rewardToken.balanceOf(address(escrow)), 0);
    }

    function test_sweepFailed_includesLateGoalAndCobuildInflows() public {
        rewardToken.mint(address(escrow), 500e18);
        cobuildToken.mint(address(escrow), 200e18);

        _finalizeAsGoalTreasury(GOAL_EXPIRED);

        // Model rent arriving after finalization.
        rewardToken.mint(address(escrow), 25e18);
        cobuildToken.mint(address(escrow), 10e18);

        vm.prank(alice);
        (uint256 claimAmount, ) = escrow.claim(alice);
        assertEq(claimAmount, 0);
        assertEq(escrow.totalGoalRentClaimed(), 0);
        assertEq(escrow.totalCobuildRentClaimed(), 0);

        vm.prank(address(goalTreasury));
        uint256 swept = escrow.releaseFailedAssetsToTreasury();

        assertEq(swept, 525e18);
        assertEq(rewardToken.balanceOf(address(goalTreasury)), 525e18);
        assertEq(cobuildToken.balanceOf(address(goalTreasury)), 210e18);
        assertEq(rewardToken.balanceOf(address(escrow)), 0);
        assertEq(cobuildToken.balanceOf(address(escrow)), 0);
    }

    function test_sweepFailed_revertsWhenSucceeded() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);
        vm.warp(100);
        _checkpointInitial(alice, 1, ids, scaled);
        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(200);

        vm.warp(250);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);
        assertGt(escrow.totalPointsSnapshot(), 0);

        vm.expectRevert(IRewardEscrow.INVALID_FINAL_STATE.selector);
        vm.prank(address(goalTreasury));
        escrow.releaseFailedAssetsToTreasury();
    }

    function _registerWarmupBudget(
        bytes32 recipientId,
        uint64 executionDuration
    ) internal returns (RewardEscrowMockBudgetTreasury budget) {
        return _registerWarmupBudget(recipientId, executionDuration, type(uint64).max);
    }

    function _registerWarmupBudget(
        bytes32 recipientId,
        uint64 executionDuration,
        uint64 fundingDeadline
    ) internal returns (RewardEscrowMockBudgetTreasury budget) {
        SharedMockFlow budgetFlow = new SharedMockFlow(ISuperToken(address(rewardToken)));
        budgetFlow.setParent(address(goalFlow));
        budget = new RewardEscrowMockBudgetTreasury(address(budgetFlow));
        budget.setExecutionDuration(executionDuration);
        budget.setFundingDeadline(fundingDeadline);

        goalFlow.setRecipient(recipientId, address(budget));
        vm.prank(address(this));
        ledger.registerBudget(recipientId, address(budget));
    }

    function _finalizeAsGoalTreasury(uint8 finalState) internal {
        if (finalState == GOAL_SUCCEEDED) {
            _resolveFundingBudgetsAsFailed(uint64(block.timestamp));
        }
        vm.prank(address(goalTreasury));
        escrow.finalize(finalState, uint64(block.timestamp));
    }

    function _resolveFundingBudgetsAsFailed(uint64 resolvedAt) internal {
        _resolveFundingBudgetAsFailed(budgetA, resolvedAt);
        _resolveFundingBudgetAsFailed(budgetB, resolvedAt);
        _resolveFundingBudgetAsFailed(budgetC, resolvedAt);
    }

    function _resolveFundingBudgetAsFailed(RewardEscrowMockBudgetTreasury budget, uint64 resolvedAt) internal {
        if (budget.resolvedAt() != 0) return;
        if (budget.state() != IBudgetTreasury.BudgetState.Funding) return;

        budget.setState(IBudgetTreasury.BudgetState.Failed);
        budget.setResolvedAt(resolvedAt);
    }

    function _checkpointInitial(address account, uint256 newWeight, bytes32[] memory newIds, uint32[] memory newScaled)
        internal
    {
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);
        _checkpoint(account, 0, emptyIds, emptyScaled, newWeight, newIds, newScaled);
    }

    function _checkpoint(
        address account,
        uint256 prevWeight,
        bytes32[] memory prevIds,
        uint32[] memory prevScaled,
        uint256 newWeight,
        bytes32[] memory newIds,
        uint32[] memory newScaled
    ) internal {
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            account,
            _scaledWeight(prevWeight),
            prevIds,
            prevScaled,
            _scaledWeight(newWeight),
            newIds,
            newScaled
        );
    }

    function _scaledWeight(uint256 weight) internal pure returns (uint256) {
        return weight * UNIT_WEIGHT_SCALE;
    }

    function _ids1(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _ids2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _ids3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }

    function _ids4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](4);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
        ids[3] = d;
    }

    function _scaled1(uint32 a) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](1);
        scaled[0] = a;
    }

    function _scaled2(uint32 a, uint32 b) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](2);
        scaled[0] = a;
        scaled[1] = b;
    }

    function _scaled3(uint32 a, uint32 b, uint32 c) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](3);
        scaled[0] = a;
        scaled[1] = b;
        scaled[2] = c;
    }

    function _scaled4(uint32 a, uint32 b, uint32 c, uint32 d) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](4);
        scaled[0] = a;
        scaled[1] = b;
        scaled[2] = c;
        scaled[3] = d;
    }
}

contract RewardEscrowMockToken is ERC20 {
    constructor() ERC20("Reward Token", "RWD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RewardEscrowMockGoalTreasury {
    address public flow;
    address public rewardEscrow;

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }
}

contract RewardEscrowMockBudgetTreasury {
    IBudgetTreasury.BudgetState public state;
    address public flow;
    uint64 public resolvedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }

    function setFlow(address flow_) external {
        flow = flow_;
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

contract RewardEscrowMockStakeVaultGoalTokenReverts {
    error GOAL_TOKEN_REVERT();

    function goalToken() external pure returns (IERC20) {
        revert GOAL_TOKEN_REVERT();
    }

    function cobuildToken() external pure returns (IERC20) {
        return IERC20(address(0));
    }
}
