// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {FlowProtocolConstants} from "src/library/FlowProtocolConstants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {
    ISuperToken,
    ISuperfluidPool
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";

contract PremiumEscrowTest is Test {
    uint32 internal constant SLASH_PPM = 200_000; // 20%
    event LateResidualSettlementFailed(address indexed goalTreasury, bytes reason);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    PremiumEscrowMockHost internal host;
    PremiumEscrowMockGDA internal gda;
    PremiumEscrowMockToken internal premiumToken;
    PremiumEscrowMockBudgetStakeLedger internal ledger;
    PremiumEscrowMockBudgetTreasury internal budgetTreasury;
    PremiumEscrowMockBudgetFlow internal budgetFlow;
    PremiumEscrowMockPool internal managerRewardPool;
    PremiumEscrowMockGoalFlow internal goalFlow;
    PremiumEscrowMockGoalTreasury internal goalTreasury;
    PremiumEscrowMockRouter internal router;
    PremiumEscrow internal escrow;

    function setUp() public {
        gda = new PremiumEscrowMockGDA();
        host = new PremiumEscrowMockHost(address(gda));
        premiumToken = new PremiumEscrowMockToken(address(host));
        ledger = new PremiumEscrowMockBudgetStakeLedger();
        budgetTreasury = new PremiumEscrowMockBudgetTreasury(address(premiumToken));
        budgetFlow = new PremiumEscrowMockBudgetFlow();
        managerRewardPool = new PremiumEscrowMockPool();
        budgetFlow.setManagerRewardDistributionPool(address(managerRewardPool));
        goalFlow = new PremiumEscrowMockGoalFlow(address(premiumToken));
        goalTreasury = new PremiumEscrowMockGoalTreasury();
        router = new PremiumEscrowMockRouter();

        // Set flow before initialize so budgetFlow gets cached.
        budgetTreasury.setFlow(address(budgetFlow));

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(address(budgetTreasury), address(ledger), address(goalFlow), address(router), SLASH_PPM);
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(managerRewardPool));

        goalFlow.setFlowOperator(address(goalTreasury));
    }

    function test_initializeRevertsWhenSuperTokenMismatch() public {
        PremiumEscrowMockToken otherToken = new PremiumEscrowMockToken(address(host));
        PremiumEscrowMockBudgetTreasury mismatchedBudgetTreasury =
            new PremiumEscrowMockBudgetTreasury(address(otherToken));

        PremiumEscrow implementation = new PremiumEscrow();
        PremiumEscrow mismatchedEscrow = PremiumEscrow(Clones.clone(address(implementation)));

        vm.expectRevert(
            abi.encodeWithSelector(
                PremiumEscrow.SUPER_TOKEN_MISMATCH.selector, address(premiumToken), address(otherToken)
            )
        );
        mismatchedEscrow.initialize(
            address(mismatchedBudgetTreasury), address(ledger), address(goalFlow), address(router), SLASH_PPM
        );
    }

    function test_initializeRevertsWhenSlashPpmExceedsProtocolScale() public {
        PremiumEscrow implementation = new PremiumEscrow();
        PremiumEscrow overflowEscrow = PremiumEscrow(Clones.clone(address(implementation)));
        uint32 invalidSlashPpm = FlowProtocolConstants.PPM_SCALE + 1;

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_SLASH_PPM.selector, invalidSlashPpm));
        overflowEscrow.initialize(
            address(budgetTreasury), address(ledger), address(goalFlow), address(router), invalidSlashPpm
        );
    }

    function test_initializeAllowsSlashPpmAtProtocolScale() public {
        PremiumEscrow implementation = new PremiumEscrow();
        PremiumEscrow maxEscrow = PremiumEscrow(Clones.clone(address(implementation)));

        maxEscrow.initialize(
            address(budgetTreasury),
            address(ledger),
            address(goalFlow),
            address(router),
            FlowProtocolConstants.PPM_SCALE
        );

        assertEq(maxEscrow.budgetSlashPpm(), FlowProtocolConstants.PPM_SCALE);
    }

    function test_initializeRevertsWhenGoalFlowBaselineReadFails() public {
        goalFlow.setRevertTotalReceivedByMemberRead(true);

        PremiumEscrow implementation = new PremiumEscrow();
        PremiumEscrow failingEscrow = PremiumEscrow(Clones.clone(address(implementation)));

        vm.expectRevert(
            abi.encodeWithSelector(
                PremiumEscrow.GOAL_FLOW_BASELINE_READ_FAILED.selector, address(goalFlow), address(budgetFlow)
            )
        );
        failingEscrow.initialize(
            address(budgetTreasury), address(ledger), address(goalFlow), address(router), SLASH_PPM
        );
    }

    function test_checkpointRevertsWhenGoalFlowReceiptReadFails() public {
        goalFlow.setRevertTotalReceivedByMemberRead(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                PremiumEscrow.GOAL_FLOW_RECEIPT_READ_FAILED.selector, address(goalFlow), address(budgetFlow)
            )
        );
        escrow.checkpoint(ALICE);
    }

    function test_slashRevertsWhenGoalFlowReceiptReadFails() public {
        _prepareStandardFailedSlashScenario();
        goalFlow.setRevertTotalReceivedByMemberRead(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                PremiumEscrow.GOAL_FLOW_RECEIPT_READ_FAILED.selector, address(goalFlow), address(budgetFlow)
            )
        );
        escrow.slash(ALICE);
    }

    function test_premiumAccrualCoverageIncreaseDecrease_splitsCorrectly() public {
        _setCoverageAndCheckpointBoth(100, 100);
        assertEq(escrow.totalCoverage(), 200);

        _mintEscrowPremiumAndCheckpointBoth(200e18);

        ledger.setCoverage(ALICE, address(budgetTreasury), 150);
        escrow.checkpoint(ALICE);
        assertEq(escrow.totalCoverage(), 250);

        _mintEscrowPremiumAndCheckpointBoth(250e18);

        ledger.setCoverage(ALICE, address(budgetTreasury), 50);
        escrow.checkpoint(ALICE);
        assertEq(escrow.totalCoverage(), 150);

        _mintEscrowPremiumAndCheckpointBoth(150e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.prank(ALICE);
        uint256 aliceClaim = escrow.claim(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = escrow.claim(BOB);

        assertEq(aliceClaim, 300e18);
        assertEq(bobClaim, 300e18);
        assertEq(premiumToken.balanceOf(ALICE), 300e18);
        assertEq(premiumToken.balanceOf(BOB), 300e18);
    }

    function test_premiumFairnessUnderChurn_alternatingCoverageMatchesArrivalPeriodShares() public {
        // Period 1: ALICE 100%, BOB 0%.
        _setCoverageAndCheckpointBoth(100, 0);
        _mintEscrowPremiumAndCheckpointBoth(100e18);

        // Period 2: ALICE 25%, BOB 75%.
        _setCoverageAndCheckpointBoth(25, 75);
        _mintEscrowPremiumAndCheckpointBoth(200e18);

        // Period 3: ALICE 80%, BOB 20%.
        _setCoverageAndCheckpointBoth(80, 20);
        _mintEscrowPremiumAndCheckpointBoth(300e18);

        // Period 4: ALICE 0%, BOB 100%.
        _setCoverageAndCheckpointBoth(0, 100);
        _mintEscrowPremiumAndCheckpointBoth(400e18);

        uint256 aliceExpected = 390e18; // 100 + 50 + 240 + 0
        uint256 bobExpected = 610e18; // 0 + 150 + 60 + 400

        assertEq(escrow.claimable(ALICE), aliceExpected);
        assertEq(escrow.claimable(BOB), bobExpected);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.prank(ALICE);
        uint256 aliceClaim = escrow.claim(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = escrow.claim(BOB);

        assertEq(aliceClaim, aliceExpected);
        assertEq(bobClaim, bobExpected);
        assertEq(premiumToken.balanceOf(ALICE), aliceExpected);
        assertEq(premiumToken.balanceOf(BOB), bobExpected);
    }

    function test_premiumIndexUsesOldTotalCoverageOnCheckpoint() public {
        _setCoverageAndCheckpointBoth(100, 100);

        _distributePremium(200e18);

        // Coverage change is already written in ledger before checkpoint.
        ledger.setCoverage(ALICE, address(budgetTreasury), 0);

        _checkpointBoth();

        assertEq(escrow.claimable(ALICE), 100e18);
        assertEq(escrow.claimable(BOB), 100e18);
    }

    function test_claimIsIdempotentAndNeverOverpays() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        _distributePremium(50e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.prank(ALICE);
        uint256 firstClaim = escrow.claim(ALICE);
        vm.prank(ALICE);
        uint256 secondClaim = escrow.claim(ALICE);

        assertEq(firstClaim, 50e18);
        assertEq(secondClaim, 0);
        assertEq(premiumToken.balanceOf(ALICE), 50e18);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));
        _distributePremium(25e18);
        vm.prank(ALICE);
        uint256 thirdClaim = escrow.claim(ALICE);

        assertEq(thirdClaim, 0);
        assertEq(premiumToken.balanceOf(ALICE), 50e18);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 25e18);
    }

    function test_claimRevertsWhenGoalStateIsNotSucceeded() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 10e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        goalTreasury.setState(IGoalTreasury.GoalState.Active);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.GOAL_NOT_SUCCEEDED.selector, IGoalTreasury.GoalState.Active)
        );
        vm.prank(ALICE);
        escrow.claim(ALICE);
    }

    function test_claimRevertsWhenGoalTreasuryUnavailable() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 10e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        goalFlow.setFlowOperator(address(0));

        vm.expectRevert(PremiumEscrow.GOAL_TREASURY_UNAVAILABLE.selector);
        vm.prank(ALICE);
        escrow.claim(ALICE);
    }

    function test_claimRevertsWhenBudgetFinalStateIsNotSucceeded() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 10e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.BUDGET_NOT_SUCCEEDED.selector, IBudgetTreasury.BudgetState.Failed)
        );
        vm.prank(ALICE);
        escrow.claim(ALICE);
    }

    function test_claimRevertsWhenEscrowNotClosed() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 10e18);

        vm.expectRevert(PremiumEscrow.NOT_CLOSED.selector);
        vm.prank(ALICE);
        escrow.claim(ALICE);
    }

    function test_burnOnGoalFailureSweepsEscrowBalanceAndSettlesLateResidualBestEffort() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 50e18);

        goalTreasury.setState(IGoalTreasury.GoalState.Expired);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));
        uint256 amount = escrow.burnOnGoalFailure();

        assertEq(amount, 50e18);
        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 50e18);
        assertEq(goalTreasury.settleLateResidualCalls(), 1);
    }

    function test_burnOnGoalFailureRequiresExpiredGoalState() public {
        goalTreasury.setState(IGoalTreasury.GoalState.Succeeded);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.GOAL_NOT_EXPIRED.selector, IGoalTreasury.GoalState.Succeeded)
        );
        escrow.burnOnGoalFailure();
    }

    function test_burnOnGoalFailureWithZeroEscrowBalanceReturnsZeroAndStillAttemptsLateResidualSettle() public {
        goalTreasury.setState(IGoalTreasury.GoalState.Expired);

        uint256 amount = escrow.burnOnGoalFailure();

        assertEq(amount, 0);
        assertEq(goalTreasury.settleLateResidualCalls(), 1);
    }

    function test_burnOnGoalFailureWithOrphanRecycledPremiumStillAttemptsLateResidualSettle() public {
        goalTreasury.setState(IGoalTreasury.GoalState.Expired);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));
        _distributePremium(33e18);

        uint256 amount = escrow.burnOnGoalFailure();

        assertEq(amount, 0);
        assertEq(goalTreasury.settleLateResidualCalls(), 1);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 33e18);
    }

    function test_burnOnGoalFailureRevertsWhenGoalTreasuryUnavailable() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 25e18);

        goalFlow.setFlowOperator(address(0));

        vm.expectRevert(PremiumEscrow.GOAL_TREASURY_UNAVAILABLE.selector);
        escrow.burnOnGoalFailure();
    }

    function test_burnOnGoalFailureSwallowSettleLateResidualRevert() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 25e18);

        goalTreasury.setState(IGoalTreasury.GoalState.Expired);
        goalTreasury.setRevertSettleLateResidual(true);
        bytes memory expectedReason =
            abi.encodeWithSelector(PremiumEscrowMockGoalTreasury.SETTLE_LATE_RESIDUAL_REVERT.selector);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit LateResidualSettlementFailed(address(goalTreasury), expectedReason);

        uint256 amount = escrow.burnOnGoalFailure();

        assertEq(amount, 25e18);
        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(goalTreasury.settleLateResidualCalls(), 0);
    }

    function test_exposureIntegralTracksPiecewiseCoverageAndClampsOnClose() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        budgetTreasury.setActivatedAt(10);

        vm.warp(15);
        escrow.checkpoint(ALICE);
        assertEq(escrow.exposureIntegral(ALICE), 500);

        ledger.setCoverage(ALICE, address(budgetTreasury), 40);
        escrow.checkpoint(ALICE);

        vm.warp(25);
        escrow.checkpoint(ALICE);
        assertEq(escrow.exposureIntegral(ALICE), 900);

        vm.warp(35);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 30);

        escrow.checkpoint(ALICE);
        assertEq(escrow.exposureIntegral(ALICE), 1100);
    }

    function test_slashUsesCreditDrawnFirstLossCapAndIsIdempotent() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        budgetTreasury.setActivatedAt(10);

        vm.warp(20);
        ledger.setCoverage(ALICE, address(budgetTreasury), 200);
        escrow.checkpoint(ALICE);

        // creditDrawn=300; first-loss slash caps at peakCov=200 * 20% = 40.
        _setGoalFlowReceipts(300);
        escrow.checkpoint(ALICE);

        vm.warp(35);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 firstSlash = escrow.slash(ALICE);
        uint256 secondSlash = escrow.slash(ALICE);

        assertEq(firstSlash, 40);
        assertEq(secondSlash, 0);
        assertEq(escrow.exposureIntegral(ALICE), 3000);
        assertTrue(escrow.slashed(ALICE));

        assertEq(router.slashCalls(), 1);
        assertEq(router.lastUnderwriter(), ALICE);
        assertEq(router.lastWeight(), 40);
    }

    function test_slashWithCoverageChurn_capsByPeakCoverageRatherThanAverageCoverage() public {
        budgetTreasury.setExecutionDuration(60);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        vm.warp(20);
        escrow.checkpoint(ALICE);
        ledger.setCoverage(ALICE, address(budgetTreasury), 220);
        escrow.checkpoint(ALICE);

        vm.warp(35);
        escrow.checkpoint(ALICE);
        ledger.setCoverage(ALICE, address(budgetTreasury), 40);
        escrow.checkpoint(ALICE);

        vm.warp(45);
        escrow.checkpoint(ALICE);
        ledger.setCoverage(ALICE, address(budgetTreasury), 160);
        escrow.checkpoint(ALICE);

        // creditDrawn=870; first-loss slash caps at peakCov=220 * 20% = 44.
        _setGoalFlowReceipts(870);
        escrow.checkpoint(ALICE);

        vm.warp(70);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 70);

        uint256 slashWeight = escrow.slash(ALICE);

        uint256 expectedExposure = 100 * 10 + 220 * 15 + 40 * 10 + 160 * 25; // 8,700
        uint256 expectedSlashWeight = 44;

        assertEq(escrow.exposureIntegral(ALICE), expectedExposure);
        assertEq(slashWeight, expectedSlashWeight);
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastWeight(), expectedSlashWeight);
    }

    function test_slashRouterRevert_rollsBackSlashedState_andCanBeRetried() public {
        budgetTreasury.setExecutionDuration(10);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        // creditDrawn=100; first-loss slash caps at peakCov=100 * 20% = 20.
        _setGoalFlowReceipts(100);
        escrow.checkpoint(ALICE);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        router.setShouldRevertSlash(true);
        vm.expectRevert(PremiumEscrowMockRouter.SLASH_REVERT.selector);
        escrow.slash(ALICE);

        assertFalse(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 0);

        router.setShouldRevertSlash(false);
        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastUnderwriter(), ALICE);
        assertEq(router.lastWeight(), 20);
    }

    function test_slashUsesCreditDrawn_andCapsAtPeakCoverageSlashPercent() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        // Accrue creditDrawn=1200; first-loss slash caps at peakCov=100 * 20% = 20.
        _setGoalFlowReceipts(1200);
        escrow.checkpoint(ALICE);

        _distributePremium(120);
        escrow.checkpoint(ALICE);

        ledger.setCoverage(ALICE, address(budgetTreasury), 60);
        escrow.checkpoint(ALICE);

        assertEq(escrow.creditDrawn(ALICE), 1200);
        assertEq(escrow.peakCov(ALICE), 100);

        budgetTreasury.setActivatedAt(10);
        vm.warp(30);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit PremiumEscrow.UnderwriterSlashCalculated(ALICE, true, 1200, 120, 20, 1200, 20, 20);
        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, 20);
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastUnderwriter(), ALICE);
        assertEq(router.lastWeight(), 20);
    }

    function test_slashIgnoresGoalFlowOperatorReadFailureWhenNoCreditWasDrawn() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        goalFlow.setRevertFlowOperator(true);

        budgetTreasury.setActivatedAt(10);
        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, 0);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 0);
    }

    function test_slashIgnoresGoalFlowOperatorReadFailure_andStillSlashes() public {
        _prepareStandardFailedSlashScenario();

        goalFlow.setRevertFlowOperator(true);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 1);
    }

    function test_slashIgnoresGoalTreasuryOperatorWithNoCode() public {
        _prepareStandardFailedSlashScenario();

        goalFlow.setFlowOperator(address(0xBEEF));
        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 1);
    }

    function test_slashIgnoresManagerRewardPoolFlowRatePpmReadRevert_characterization() public {
        _prepareStandardFailedSlashScenario();

        // Slash path does not depend on managerRewardPoolFlowRatePpm() reads.
        budgetFlow.setRevertManagerRewardPoolFlowRateRead(true);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 1);
    }

    function test_slashRevertsWhenBudgetWasNeverActivated() public {
        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Expired, 0, 20);

        vm.expectRevert(PremiumEscrow.NOT_SLASHABLE.selector);
        escrow.slash(ALICE);
    }

    function test_closeOnlyBudgetTreasury_idempotentForSameArgs_revertsForMismatchedReplay() public {
        vm.warp(20);

        vm.expectRevert(PremiumEscrow.ONLY_BUDGET_TREASURY.selector);
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        assertTrue(escrow.closed());
        assertEq(uint256(escrow.finalState()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(escrow.activatedAt(), 10);
        assertEq(escrow.closedAt(), 20);

        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        vm.expectRevert(PremiumEscrow.ALREADY_CLOSED.selector);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 21);
    }

    function test_closeRejectsInvalidStateTimestampAndWindow() public {
        vm.warp(50);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_STATE.selector, IBudgetTreasury.BudgetState.Active)
        );
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Active, 10, 40);

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_TIMESTAMP.selector, uint64(0)));
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 0);

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_TIMESTAMP.selector, uint64(51)));
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 51);

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_WINDOW.selector, uint64(41), uint64(40)));
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 41, 40);
    }

    function test_closeCheckpointsPendingPremiumBeforeFreeze() public {
        _setCoverageAndCheckpointBoth(100, 100);

        _distributePremium(200e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.prank(ALICE);
        uint256 aliceClaim = escrow.claim(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = escrow.claim(BOB);

        assertEq(aliceClaim, 100e18);
        assertEq(bobClaim, 100e18);
        assertEq(premiumToken.balanceOf(address(escrow)), 0);
    }

    function test_postClosePremium_characterization_recycledAndDoesNotIncreaseClaimable() public {
        _setCoverageAndCheckpointBoth(100, 100);

        _mintEscrowPremiumAndCheckpointBoth(200e18);
        assertEq(escrow.claimable(ALICE), 100e18);
        assertEq(escrow.claimable(BOB), 100e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        uint256 aliceBefore = escrow.claimable(ALICE);
        uint256 bobBefore = escrow.claimable(BOB);
        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));

        // Strict invariant: premium that arrives after close should not accrue to underwriters.
        _mintEscrowPremiumAndCheckpointBoth(80e18);

        assertEq(escrow.claimable(ALICE), aliceBefore);
        assertEq(escrow.claimable(BOB), bobBefore);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 80e18);
    }

    function test_claimHandlesEscrowBalanceShortfallWithoutOverpaying() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        _distributePremium(100e18);
        escrow.checkpoint(ALICE);
        assertEq(escrow.claimable(ALICE), 100e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        deal(address(premiumToken), address(escrow), 40e18);

        vm.prank(ALICE);
        uint256 firstClaim = escrow.claim(ALICE);
        assertEq(firstClaim, 40e18);
        assertEq(escrow.claimable(ALICE), 60e18);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));
        _distributePremium(60e18);

        vm.prank(ALICE);
        uint256 secondClaim = escrow.claim(ALICE);
        assertEq(secondClaim, 0);
        assertEq(escrow.claimable(ALICE), 60e18);
        assertEq(premiumToken.balanceOf(ALICE), 40e18);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 60e18);
    }

    function test_closeFailedSweepsEscrowedPremiumToGoalFlow() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 50e18);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 50e18);
    }

    function test_closeExpiredSweepsEscrowedPremiumToGoalFlow_andClaimReverts() public {
        _setCoverageAndCheckpointClaimable(ALICE, 100, 50e18);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Expired, 10, 20);

        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 50e18);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.BUDGET_NOT_SUCCEEDED.selector, IBudgetTreasury.BudgetState.Expired)
        );
        vm.prank(ALICE);
        escrow.claim(ALICE);
    }

    function test_slashRevertsWhenNotClosed_orWhenFinalStateNotSlashable() public {
        vm.expectRevert(PremiumEscrow.NOT_CLOSED.selector);
        escrow.slash(ALICE);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.expectRevert(PremiumEscrow.NOT_SLASHABLE.selector);
        escrow.slash(ALICE);
    }

    function test_slashWithZeroDurationAndZeroCreditReturnsZeroWithoutRouterCall() public {
        budgetTreasury.setExecutionDuration(0);
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(20);

        vm.warp(25);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 20, 20);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 0);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 0);
    }

    function test_slashWithZeroDurationStillUsesCreditDrawnFirstLossCap() public {
        budgetTreasury.setExecutionDuration(0);
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(20);

        _setGoalFlowReceipts(100);
        escrow.checkpoint(ALICE);

        vm.warp(25);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 20, 20);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastWeight(), 20);
    }

    function test_slashWithZeroSlashPpmMarksUnderwriterWithoutRouterCall() public {
        PremiumEscrow implementation = new PremiumEscrow();
        PremiumEscrow zeroSlashEscrow = PremiumEscrow(Clones.clone(address(implementation)));
        zeroSlashEscrow.initialize(address(budgetTreasury), address(ledger), address(goalFlow), address(router), 0);
        vm.prank(address(budgetTreasury));
        zeroSlashEscrow.connectManagerRewardPool(address(managerRewardPool));

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        zeroSlashEscrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        _setGoalFlowReceipts(100);
        zeroSlashEscrow.checkpoint(ALICE);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        zeroSlashEscrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        vm.expectEmit(true, false, false, true, address(zeroSlashEscrow));
        emit PremiumEscrow.UnderwriterSlashCalculated(ALICE, false, 100, 0, 20, 0, 0, 0);
        uint256 slashWeight = zeroSlashEscrow.slash(ALICE);
        assertEq(slashWeight, 0);
        assertEq(zeroSlashEscrow.creditDrawn(ALICE), 100);
        assertTrue(zeroSlashEscrow.slashed(ALICE));
        assertEq(router.slashCalls(), 0);
    }

    function test_slashIgnoresConfiguredExecutionDuration_whenCloseIsDelayed() public {
        budgetTreasury.setExecutionDuration(20);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        // creditDrawn=100; first-loss slash ignores execution duration and caps at peakCov=100 * 20% = 20.
        _setGoalFlowReceipts(100);
        escrow.checkpoint(ALICE);

        vm.warp(70);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 70);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastWeight(), 20);
    }

    function test_slashIgnoresConfiguredExecutionDuration_whenCloseIsDelayed_andStillCapsByPeakCoverage() public {
        budgetTreasury.setExecutionDuration(20);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        // creditDrawn=400; first-loss slash ignores execution duration and caps at peakCov=100 * 20% = 20.
        _setGoalFlowReceipts(400);
        escrow.checkpoint(ALICE);

        vm.warp(70);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 70);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 20);
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastWeight(), 20);
    }

    function test_orphanPremiumIsRecycledWhenCoverageIsZero() public {
        _distributePremium(77e18);
        escrow.checkpoint(ALICE);

        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(address(goalFlow)), 77e18);
    }

    function _checkpointBoth() internal {
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);
    }

    function _setCoverageAndCheckpointBoth(uint256 aliceCoverage, uint256 bobCoverage) internal {
        ledger.setCoverage(ALICE, address(budgetTreasury), aliceCoverage);
        ledger.setCoverage(BOB, address(budgetTreasury), bobCoverage);
        _checkpointBoth();
    }

    function _mintEscrowPremiumAndCheckpointBoth(uint256 amount) internal {
        _distributePremium(amount);
        _checkpointBoth();
    }

    function _setCoverageAndCheckpointClaimable(address account, uint256 coverage, uint256 premiumAmount) internal {
        ledger.setCoverage(account, address(budgetTreasury), coverage);
        escrow.checkpoint(account);
        _distributePremium(premiumAmount);
        escrow.checkpoint(account);
    }

    function _prepareStandardFailedSlashScenario() internal {
        budgetTreasury.setExecutionDuration(10);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        // creditDrawn=100; first-loss slash caps at peakCov=100 * 20% = 20.
        _setGoalFlowReceipts(100);
        escrow.checkpoint(ALICE);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);
    }

    function _distributePremium(uint256 amount) internal {
        managerRewardPool.increaseTotalAmountReceivedByMember(address(escrow), amount);
        premiumToken.mint(address(escrow), amount);
    }

    /// @dev Sets goal flow receipts so that on next checkpoint, creditDrawn accrues for accounts with coverage.
    function _setGoalFlowReceipts(uint256 totalReceived) internal {
        goalFlow.setTotalReceivedByMember(address(budgetFlow), totalReceived);
    }
}

contract PremiumEscrowRealLifecycleTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 88;
    uint32 internal constant SLASH_PPM = 200_000;
    uint256 internal constant TARGET_SLASH_WEIGHT = 20e18;

    address internal constant ALICE = address(0xA11CE);
    address internal constant PREMIUM_RECIPIENT = address(0xB0B);
    address internal constant GOAL_FUNDING_TARGET = address(0xF00D);

    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    PremiumEscrowRealSuperToken internal goalSuperToken;
    PremiumEscrowMockHost internal host;
    PremiumEscrowMockGDA internal gda;
    PremiumEscrowRealDirectory internal directory;
    PremiumEscrowRealTokens internal tokens;
    PremiumEscrowRealController internal controller;
    PremiumEscrowRealRulesets internal rulesets;
    PremiumEscrowRealTerminal internal terminal;
    StakeVault internal stakeVault;
    UnderwriterSlasherRouter internal router;
    PremiumEscrowMockBudgetStakeLedger internal ledger;
    PremiumEscrowMockBudgetTreasury internal budgetTreasury;
    PremiumEscrowMockBudgetFlow internal budgetFlow;
    PremiumEscrowMockPool internal managerRewardPool;
    PremiumEscrowMockGoalFlow internal goalFlow;
    PremiumEscrowMockGoalTreasury internal goalTreasury;
    PremiumEscrow internal escrow;

    function setUp() public {
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");

        gda = new PremiumEscrowMockGDA();
        host = new PremiumEscrowMockHost(address(gda));
        goalSuperToken = new PremiumEscrowRealSuperToken(address(goalToken), address(host));

        directory = new PremiumEscrowRealDirectory();
        tokens = new PremiumEscrowRealTokens();
        controller = new PremiumEscrowRealController(IJBTokens(address(tokens)));
        rulesets = new PremiumEscrowRealRulesets(IJBDirectory(address(directory)), 1e18);
        terminal = new PremiumEscrowRealTerminal(IERC20(address(cobuildToken)), IERC20(address(goalToken)));

        tokens.setProjectIdFor(address(goalToken), GOAL_REVNET_ID);
        directory.setController(GOAL_REVNET_ID, IJBController(address(controller)));
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(terminal)));

        stakeVault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(rulesets)),
            GOAL_REVNET_ID,
            18
        );
        router = new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            GOAL_FUNDING_TARGET
        );
        stakeVault.setUnderwriterSlasher(address(router));

        ledger = new PremiumEscrowMockBudgetStakeLedger();
        budgetTreasury = new PremiumEscrowMockBudgetTreasury(address(goalSuperToken));
        budgetFlow = new PremiumEscrowMockBudgetFlow();
        managerRewardPool = new PremiumEscrowMockPool();
        goalFlow = new PremiumEscrowMockGoalFlow(address(goalSuperToken));
        goalTreasury = new PremiumEscrowMockGoalTreasury();

        budgetFlow.setManagerRewardDistributionPool(address(managerRewardPool));
        budgetTreasury.setFlow(address(budgetFlow));
        goalFlow.setFlowOperator(address(goalTreasury));

        goalToken.mint(ALICE, 70e18);
        cobuildToken.mint(ALICE, 50e18);
        goalToken.mint(address(terminal), 1_000_000e18);

        vm.startPrank(ALICE);
        goalToken.approve(address(stakeVault), type(uint256).max);
        cobuildToken.approve(address(stakeVault), type(uint256).max);
        stakeVault.depositGoal(70e18);
        stakeVault.depositCobuild(50e18);
        vm.stopPrank();

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(address(budgetTreasury), address(ledger), address(goalFlow), address(router), SLASH_PPM);
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(managerRewardPool));
        router.setAuthorizedPremiumEscrow(address(escrow), true);
    }

    function test_claimSucceeded_realSuperTokenPathTransfersToRecipient() public {
        _setCoverageAndCheckpoint(100e18);
        _distributePremium(45e18);
        escrow.checkpoint(ALICE);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 0, 20);

        vm.prank(ALICE);
        uint256 claimed = escrow.claim(PREMIUM_RECIPIENT);

        assertEq(claimed, 45e18);
        assertEq(goalSuperToken.balanceOf(PREMIUM_RECIPIENT), 45e18);
        assertEq(goalSuperToken.balanceOf(address(escrow)), 0);
    }

    function test_burnOnGoalFailure_realGoalFlowPathSweepsAndSettles() public {
        _setCoverageAndCheckpoint(100e18);
        _distributePremium(50e18);
        escrow.checkpoint(ALICE);

        goalTreasury.setState(IGoalTreasury.GoalState.Expired);
        uint256 goalFlowBefore = goalSuperToken.balanceOf(address(goalFlow));

        uint256 amount = escrow.burnOnGoalFailure();

        assertEq(amount, 50e18);
        assertEq(goalSuperToken.balanceOf(address(escrow)), 0);
        assertEq(goalSuperToken.balanceOf(address(goalFlow)), goalFlowBefore + 50e18);
        assertEq(goalTreasury.settleLateResidualCalls(), 1);
    }

    function test_slashFailedBudget_realStakeVaultRouterPathSlashesAndFundsGoal() public {
        _setCoverageAndCheckpoint(100e18);

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        _setGoalFlowCreditForTargetSlash(TARGET_SLASH_WEIGHT);

        vm.warp(30);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 stakedGoalBefore = stakeVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBefore = stakeVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, TARGET_SLASH_WEIGHT);
        assertLt(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertLt(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertEq(terminal.payCallCount(), 1);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
    }

    function _setCoverageAndCheckpoint(uint256 coverage) internal {
        ledger.setCoverage(ALICE, address(budgetTreasury), coverage);
        escrow.checkpoint(ALICE);
    }

    function _distributePremium(uint256 amount) internal {
        managerRewardPool.increaseTotalAmountReceivedByMember(address(escrow), amount);
        goalSuperToken.mint(address(escrow), amount);
    }

    function _setGoalFlowCreditForTargetSlash(uint256 targetSlashWeight) internal {
        goalFlow.setTotalReceivedByMember(address(budgetFlow), targetSlashWeight);
    }
}

contract PremiumEscrowMockToken is ERC20 {
    address internal _host;

    constructor(address host_) ERC20("PremiumToken", "PRM") {
        _host = host_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getHost() external view returns (address) {
        return _host;
    }
}

contract PremiumEscrowMockHost {
    address internal _gda;

    constructor(address gda_) {
        _gda = gda_;
    }

    function getAgreementClass(bytes32) external view returns (address) {
        return _gda;
    }

    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata)
        external
        returns (bytes memory returnedData)
    {
        (bool success, bytes memory data) = agreementClass.call(callData);
        require(success, "callAgreement failed");
        return data;
    }
}

contract PremiumEscrowMockGDA {
    address internal _lastConnectedPool;

    function connectPool(ISuperfluidPool pool, bytes calldata) external returns (bytes memory) {
        _lastConnectedPool = address(pool);
        return bytes("");
    }

    function lastConnectedPool() external view returns (address) {
        return _lastConnectedPool;
    }
}

contract PremiumEscrowMockBudgetStakeLedger {
    mapping(address => mapping(address => uint256)) internal _coverageByBudget;
    mapping(address => uint256) internal _totalCoverageByBudget;

    function setCoverage(address account, address budget, uint256 coverage) external {
        uint256 current = _coverageByBudget[account][budget];
        if (coverage > current) {
            _totalCoverageByBudget[budget] += coverage - current;
        } else if (current > coverage) {
            _totalCoverageByBudget[budget] -= current - coverage;
        }
        _coverageByBudget[account][budget] = coverage;
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256) {
        return _coverageByBudget[account][budget];
    }

    function budgetTotalAllocatedStake(address budget) external view returns (uint256) {
        return _totalCoverageByBudget[budget];
    }
}

contract PremiumEscrowMockBudgetTreasury {
    ISuperToken internal _superToken;
    uint64 public activatedAt;
    uint64 public executionDuration = 20;
    address internal _flow;

    constructor(address superToken_) {
        _superToken = ISuperToken(superToken_);
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        activatedAt = activatedAt_;
    }

    function setExecutionDuration(uint64 executionDuration_) external {
        executionDuration = executionDuration_;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function controller() external pure returns (address) {
        return address(0);
    }
}

contract PremiumEscrowMockBudgetFlow {
    error MANAGER_REWARD_RATE_READ_REVERT();

    uint32 internal _managerRewardPoolFlowRatePpm;
    address internal _managerRewardDistributionPool;
    bool internal _revertManagerRewardPoolFlowRateRead;

    function setManagerRewardPoolFlowRatePpm(uint32 ppm_) external {
        _managerRewardPoolFlowRatePpm = ppm_;
    }

    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        if (_revertManagerRewardPoolFlowRateRead) revert MANAGER_REWARD_RATE_READ_REVERT();
        return _managerRewardPoolFlowRatePpm;
    }

    function setRevertManagerRewardPoolFlowRateRead(bool shouldRevert) external {
        _revertManagerRewardPoolFlowRateRead = shouldRevert;
    }

    function setManagerRewardDistributionPool(address pool_) external {
        _managerRewardDistributionPool = pool_;
    }

    function managerRewardDistributionPool() external view returns (ISuperfluidPool) {
        return ISuperfluidPool(_managerRewardDistributionPool);
    }
}

contract PremiumEscrowMockGoalFlow {
    error FLOW_OPERATOR_REVERT();
    error TOTAL_RECEIVED_BY_MEMBER_REVERT();

    ISuperToken internal _superToken;
    address internal _flowOperator;
    bool internal _revertFlowOperator;
    bool internal _revertTotalReceivedByMemberRead;
    mapping(address => uint256) internal _totalReceivedByMember;

    constructor(address superToken_) {
        _superToken = ISuperToken(superToken_);
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function setFlowOperator(address flowOperator_) external {
        _flowOperator = flowOperator_;
    }

    function setRevertFlowOperator(bool shouldRevert_) external {
        _revertFlowOperator = shouldRevert_;
    }

    function setRevertTotalReceivedByMemberRead(bool shouldRevert_) external {
        _revertTotalReceivedByMemberRead = shouldRevert_;
    }

    function flowOperator() external view returns (address) {
        if (_revertFlowOperator) revert FLOW_OPERATOR_REVERT();
        return _flowOperator;
    }

    function setTotalReceivedByMember(address member, uint256 amount) external {
        _totalReceivedByMember[member] = amount;
    }

    function getTotalReceivedByMember(address member) external view returns (uint256) {
        if (_revertTotalReceivedByMemberRead) revert TOTAL_RECEIVED_BY_MEMBER_REVERT();
        return _totalReceivedByMember[member];
    }
}

contract PremiumEscrowMockGoalTreasury {
    IGoalTreasury.GoalState internal _state = IGoalTreasury.GoalState.Succeeded;
    bool internal _revertSettleLateResidual;
    uint256 public settleLateResidualCalls;

    error SETTLE_LATE_RESIDUAL_REVERT();

    function setState(IGoalTreasury.GoalState state_) external {
        _state = state_;
    }

    function state() external view returns (IGoalTreasury.GoalState) {
        return _state;
    }

    function setRevertSettleLateResidual(bool shouldRevert_) external {
        _revertSettleLateResidual = shouldRevert_;
    }

    function settleLateResidual() external {
        if (_revertSettleLateResidual) revert SETTLE_LATE_RESIDUAL_REVERT();
        settleLateResidualCalls += 1;
    }
}

contract PremiumEscrowMockPool {
    mapping(address => uint256) internal _totalAmountReceivedByMember;

    function increaseTotalAmountReceivedByMember(address member, uint256 amount) external {
        _totalAmountReceivedByMember[member] += amount;
    }

    function getTotalAmountReceivedByMember(address member) external view returns (uint256) {
        return _totalAmountReceivedByMember[member];
    }
}

contract PremiumEscrowMockRouter {
    error SLASH_REVERT();

    address public lastUnderwriter;
    uint256 public lastWeight;
    uint256 public slashCalls;
    bool public shouldRevertSlash;

    function setShouldRevertSlash(bool shouldRevert) external {
        shouldRevertSlash = shouldRevert;
    }

    function slashUnderwriter(address underwriter, uint256 weight) external {
        if (shouldRevertSlash) revert SLASH_REVERT();
        lastUnderwriter = underwriter;
        lastWeight = weight;
        slashCalls++;
    }
}

contract PremiumEscrowRealSuperToken is ERC20 {
    address private immutable _underlying;
    address private immutable _host;

    constructor(address underlying_, address host_) ERC20("Goal Super", "gSUP") {
        _underlying = underlying_;
        _host = host_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getHost() external view returns (address) {
        return _host;
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlying;
    }

    function upgrade(uint256 amount) external {
        IERC20(_underlying).transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }
}

contract PremiumEscrowRealRulesets {
    IJBDirectory private immutable _directory;
    uint112 private immutable _weight;

    constructor(IJBDirectory directory_, uint112 weight_) {
        _directory = directory_;
        _weight = weight_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function currentOf(uint256) external view returns (JBRuleset memory ruleset) {
        ruleset.weight = _weight;
    }
}

contract PremiumEscrowRealDirectory {
    mapping(uint256 => IJBController) private _controllerOf;
    mapping(uint256 => mapping(address => IJBTerminal)) private _primaryTerminalOf;

    function setController(uint256 projectId, IJBController controller_) external {
        _controllerOf[projectId] = controller_;
    }

    function controllerOf(uint256 projectId) external view returns (IJBController) {
        return _controllerOf[projectId];
    }

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal_) external {
        _primaryTerminalOf[projectId][token] = terminal_;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract PremiumEscrowRealTokens {
    mapping(address => uint256) private _projectIdOf;

    function setProjectIdFor(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}

contract PremiumEscrowRealController {
    IJBTokens private immutable _tokens;

    constructor(IJBTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (IJBTokens) {
        return _tokens;
    }
}

contract PremiumEscrowRealTerminal {
    IERC20 public immutable cobuildToken;
    IERC20 public immutable goalToken;

    uint256 public payCallCount;

    constructor(IERC20 cobuildToken_, IERC20 goalToken_) {
        cobuildToken = cobuildToken_;
        goalToken = goalToken_;
    }

    function pay(uint256, address token, uint256 amount, address beneficiary, uint256, string calldata, bytes calldata)
        external
        returns (uint256 beneficiaryTokenCount)
    {
        require(token == address(cobuildToken), "INVALID_TOKEN");
        payCallCount += 1;
        cobuildToken.transferFrom(msg.sender, address(this), amount);
        goalToken.transfer(beneficiary, amount);
        return amount;
    }
}
