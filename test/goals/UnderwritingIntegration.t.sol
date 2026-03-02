// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {IUnderwriterSlasherRouter} from "src/interfaces/IUnderwriterSlasherRouter.sol";
import {IUMATreasurySuccessResolverConfig} from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {TreasurySuccessAssertions} from "src/goals/library/TreasurySuccessAssertions.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {JBApprovalStatus} from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ISuperToken, ISuperfluidPool} from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {
    SharedMockCFA,
    SharedMockFlow,
    SharedMockStakeVault,
    SharedMockSuperfluidHost,
    SharedMockSuperfluidPool,
    SharedMockSuperToken,
    SharedMockUnderlying
} from "test/goals/helpers/TreasurySharedMocks.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig,
    TreasuryMockUmaResolverConfigWithFinalize
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";

contract UnderwritingPremiumSlashIntegrationTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 77;
    uint32 internal constant BUDGET_SLASH_PPM = 200_000; // 20%
    uint32 internal constant BUDGET_PREMIUM_PPM = 100_000;
    uint256 internal constant COVERAGE_LAMBDA = 10;
    uint256 internal constant TARGET_SLASH_WEIGHT = 20e18;

    address internal constant ALICE = address(0xA11CE);
    address internal constant PREMIUM_RECIPIENT = address(0xB0B);
    address internal constant GOAL_FUNDING_TARGET = address(0xF00D);

    event CobuildConversionFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 cobuildAmount, bytes reason
    );

    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    SharedMockSuperToken internal goalSuperToken;

    UnderwritingMockRulesets internal rulesets;
    UnderwritingMockDirectory internal directory;
    UnderwritingMockTokens internal tokens;
    UnderwritingMockController internal controller;
    UnderwritingMockTerminal internal conversionTerminal;

    StakeVault internal stakeVault;
    UnderwriterSlasherRouter internal router;
    PremiumEscrow internal escrow;
    UnderwritingMockBudgetStakeLedger internal budgetStakeLedger;
    UnderwritingMockBudgetTreasury internal budgetTreasury;
    UnderwritingMockBudgetFlow internal budgetFlow;
    UnderwritingMockGoalFlow internal goalFlow;
    UnderwritingMockGoalTreasuryResolutionReporter internal goalTreasury;

    function setUp() public {
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        goalSuperToken = new SharedMockSuperToken(address(goalToken));

        rulesets = new UnderwritingMockRulesets();
        directory = new UnderwritingMockDirectory();
        tokens = new UnderwritingMockTokens();
        controller = new UnderwritingMockController(tokens);
        conversionTerminal = new UnderwritingMockTerminal(IERC20(address(cobuildToken)), IERC20(address(goalToken)));

        rulesets.setDirectory(IJBDirectory(address(directory)));
        rulesets.setWeight(GOAL_REVNET_ID, 2e18);
        directory.setController(GOAL_REVNET_ID, address(controller));
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(conversionTerminal)));
        tokens.setProjectIdOf(address(goalToken), GOAL_REVNET_ID);

        stakeVault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(rulesets)),
            GOAL_REVNET_ID,
            18
        );

        goalToken.mint(ALICE, 120e18);
        cobuildToken.mint(ALICE, 80e18);
        goalToken.mint(address(conversionTerminal), 1_000_000e18);

        vm.startPrank(ALICE);
        goalToken.approve(address(stakeVault), type(uint256).max);
        cobuildToken.approve(address(stakeVault), type(uint256).max);
        stakeVault.depositGoal(120e18);
        stakeVault.depositCobuild(80e18);
        vm.stopPrank();

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

        budgetStakeLedger = new UnderwritingMockBudgetStakeLedger();
        budgetTreasury = new UnderwritingMockBudgetTreasury(ISuperToken(address(goalSuperToken)));
        budgetFlow = new UnderwritingMockBudgetFlow();
        budgetFlow.setManagerRewardPoolFlowRatePpm(BUDGET_PREMIUM_PPM);
        budgetTreasury.setFlow(address(budgetFlow));
        goalFlow = new UnderwritingMockGoalFlow(ISuperToken(address(goalSuperToken)));
        goalTreasury = new UnderwritingMockGoalTreasuryResolutionReporter(address(this), address(budgetStakeLedger));
        goalTreasury.setCoverageLambda(COVERAGE_LAMBDA);
        goalFlow.setFlowOperator(address(goalTreasury));

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(
            address(budgetTreasury),
            address(budgetStakeLedger),
            address(goalFlow),
            address(router),
            BUDGET_SLASH_PPM
        );
        budgetTreasury.setPremiumEscrow(address(escrow));

        router.setAuthorizedPremiumEscrow(address(escrow), true);
    }

    function test_underwriterCoverage_premiumAccruesAndClaims() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        escrow.checkpoint(ALICE);
        goalSuperToken.mint(address(escrow), 45e18);
        escrow.checkpoint(ALICE);

        vm.prank(ALICE);
        uint256 claimed = escrow.claim(PREMIUM_RECIPIENT);

        assertEq(claimed, 45e18);
        assertEq(goalSuperToken.balanceOf(PREMIUM_RECIPIENT), 45e18);
    }

    function test_failedBudgetAfterActivation_slashesStake_convertsCobuild_andFundsGoalPath() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        escrow.checkpoint(ALICE);

        vm.warp(30);
        _fundEscrowForTargetSlash(escrow, 10, 30, TARGET_SLASH_WEIGHT);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 stakedGoalBefore = stakeVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBefore = stakeVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, 20e18);
        assertLt(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertLt(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertEq(conversionTerminal.payCallCount(), 1);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
    }

    function test_failedBudgetAfterActivation_slashStillFundsGoal_whenCobuildConversionUnavailable() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(0)));

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        escrow.checkpoint(ALICE);

        vm.warp(30);
        _fundEscrowForTargetSlash(escrow, 10, 30, TARGET_SLASH_WEIGHT);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 stakedGoalBefore = stakeVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBefore = stakeVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        vm.expectEmit(true, true, false, false, address(router));
        emit CobuildConversionFailed(
            address(escrow),
            ALICE,
            0,
            abi.encodeWithSelector(IUnderwriterSlasherRouter.INVALID_GOAL_TERMINAL.selector, address(0))
        );
        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, 20e18);
        assertLt(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertLt(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertEq(conversionTerminal.payCallCount(), 0);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertGt(cobuildToken.balanceOf(address(router)), 0);
    }

    function test_failedBudgetAfterActivation_whenSpendParamsUnresolved_revertsAndCanRetryAfterParamsRestore() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        escrow.checkpoint(ALICE);

        vm.warp(30);
        _fundEscrowForTargetSlash(escrow, 10, 30, TARGET_SLASH_WEIGHT);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 stakedGoalBefore = stakeVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBefore = stakeVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        goalFlow.setFlowOperator(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.UNRESOLVED_SPEND_FORMULA_PARAMS.selector, BUDGET_PREMIUM_PPM, 0)
        );
        escrow.slash(ALICE);

        assertFalse(escrow.slashed(ALICE));
        assertEq(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertEq(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertEq(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(conversionTerminal.payCallCount(), 0);

        goalFlow.setFlowOperator(address(goalTreasury));
        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, TARGET_SLASH_WEIGHT);
        assertTrue(escrow.slashed(ALICE));
        assertLt(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertLt(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(conversionTerminal.payCallCount(), 1);
    }

    function test_goalResolvedBeforeBudgetClose_withdrawBlocked_thenSlashStillCutsPrincipal() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        uint64 budgetActivatedAt = 10;
        uint64 budgetClosedAt = 30;

        (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            UnderwritingMockBudgetStakeLedger delayedBudgetStakeLedger,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.setActivatedAt(budgetActivatedAt);
        delayedEscrow.checkpoint(ALICE);

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        uint256 stakedGoalBeforeSlash = delayedVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforeSlash = delayedVault.stakedCobuildOf(ALICE);
        assertEq(stakedGoalBeforeSlash, goalStake);
        assertEq(stakedCobuildBeforeSlash, cobuildStake);
        assertEq(goalToken.balanceOf(ALICE), 0);
        assertEq(cobuildToken.balanceOf(ALICE), 0);

        vm.warp(budgetClosedAt);
        _fundEscrowForTargetSlash(delayedEscrow, budgetActivatedAt, budgetClosedAt, TARGET_SLASH_WEIGHT);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);
        delayedBudgetTreasury.setResolvedAt(budgetClosedAt, IBudgetTreasury.BudgetState.Failed);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        _assertDelayedSlashOutcome(
            delayedVault, delayedRouter, stakedGoalBeforeSlash, stakedCobuildBeforeSlash, fundingBefore, slashWeight
        );
    }

    function test_goalResolvedDuringPendingSuccessAssertionDelay_prepareBlocksWithdrawalUntilBudgetResolves()
        public
    {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        uint64 budgetActivatedAt = 10;
        uint64 pendingAssertionAt = 28;
        uint64 budgetClosedAt = 45;

        (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            UnderwritingMockBudgetStakeLedger delayedBudgetStakeLedger,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.setActivatedAt(budgetActivatedAt);
        delayedEscrow.checkpoint(ALICE);

        vm.warp(pendingAssertionAt);
        bytes32 assertionId = keccak256("underwriting-pending-success-assertion-delay");
        delayedBudgetTreasury.registerSuccessAssertion(assertionId);
        assertEq(delayedBudgetTreasury.pendingSuccessAssertionId(), assertionId);
        assertEq(delayedBudgetTreasury.pendingSuccessAssertionAt(), pendingAssertionAt);

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        vm.prank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        vm.warp(budgetClosedAt);
        _fundEscrowForTargetSlash(delayedEscrow, budgetActivatedAt, budgetClosedAt, TARGET_SLASH_WEIGHT);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);
        delayedBudgetTreasury.setResolvedAt(budgetClosedAt, IBudgetTreasury.BudgetState.Failed);

        vm.prank(ALICE);
        delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(delayedBudgetTreasury.pendingSuccessAssertionId(), assertionId);
        assertLt(delayedVault.stakedGoalOf(ALICE), goalStake);
        assertLt(delayedVault.stakedCobuildOf(ALICE), cobuildStake);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);

        vm.startPrank(ALICE);
        delayedVault.withdrawGoal(delayedVault.stakedGoalOf(ALICE), ALICE);
        delayedVault.withdrawCobuild(delayedVault.stakedCobuildOf(ALICE), ALICE);
        vm.stopPrank();

        assertEq(delayedVault.stakedGoalOf(ALICE), 0);
        assertEq(delayedVault.stakedCobuildOf(ALICE), 0);
        assertLt(goalToken.balanceOf(ALICE), goalStake);
        assertLt(cobuildToken.balanceOf(ALICE), cobuildStake);
    }

    function test_regression_budgetResolvedBeforeWithdraw_prepareSlashesBeforePrincipalExit() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        uint64 budgetActivatedAt = 10;
        uint64 budgetClosedAt = 30;

        (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            UnderwritingMockBudgetStakeLedger delayedBudgetStakeLedger,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.setActivatedAt(budgetActivatedAt);
        delayedEscrow.checkpoint(ALICE);

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        vm.warp(budgetClosedAt);
        _fundEscrowForTargetSlash(delayedEscrow, budgetActivatedAt, budgetClosedAt, TARGET_SLASH_WEIGHT);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);
        delayedBudgetTreasury.setResolvedAt(budgetClosedAt, IBudgetTreasury.BudgetState.Failed);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        vm.prank(ALICE);
        delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertLt(delayedVault.stakedGoalOf(ALICE), goalStake);
        assertLt(delayedVault.stakedCobuildOf(ALICE), cobuildStake);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);

        vm.startPrank(ALICE);
        delayedVault.withdrawGoal(delayedVault.stakedGoalOf(ALICE), ALICE);
        delayedVault.withdrawCobuild(delayedVault.stakedCobuildOf(ALICE), ALICE);
        vm.stopPrank();

        assertEq(delayedVault.stakedGoalOf(ALICE), 0);
        assertEq(delayedVault.stakedCobuildOf(ALICE), 0);
        assertLt(goalToken.balanceOf(ALICE), goalStake);
        assertLt(cobuildToken.balanceOf(ALICE), cobuildStake);

        uint256 slashWeight = delayedEscrow.slash(ALICE);
        assertEq(slashWeight, 0);
    }

    function test_goalResolvedBeforeBudgetActivation_prepareAllowsWithdrawWithCurrentCoverageOnly() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;

        (
            StakeVault delayedVault,
            ,
            PremiumEscrow delayedEscrow,
            ,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        assertEq(delayedBudgetTreasury.activatedAt(), 0);

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        vm.prank(ALICE);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, budgetCount);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertFalse(delayedEscrow.slashed(ALICE));
        assertEq(delayedVault.stakedGoalOf(ALICE), goalStake);
        assertEq(delayedVault.stakedCobuildOf(ALICE), cobuildStake);

        vm.startPrank(ALICE);
        delayedVault.withdrawGoal(goalStake, ALICE);
        delayedVault.withdrawCobuild(cobuildStake, ALICE);
        vm.stopPrank();

        assertEq(delayedVault.stakedGoalOf(ALICE), 0);
        assertEq(delayedVault.stakedCobuildOf(ALICE), 0);
        assertEq(goalToken.balanceOf(ALICE), goalStake);
        assertEq(cobuildToken.balanceOf(ALICE), cobuildStake);
    }

    function test_goalResolvedBeforeBudgetActivation_withEscrowCheckpointedExposure_prepareRemainsBlocked() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;

        (
            StakeVault delayedVault,
            ,
            PremiumEscrow delayedEscrow,
            ,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        assertEq(delayedBudgetTreasury.activatedAt(), 0);
        delayedEscrow.checkpoint(ALICE);
        assertEq(delayedEscrow.userCov(ALICE), budgetCoverage);
        assertEq(delayedEscrow.exposureIntegral(ALICE), 0);

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        vm.prank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);
    }

    function test_goalResolvedDuringReassertGraceDelay_withdrawBlocked_thenSlashStillCutsPrincipal() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        uint64 budgetActivatedAt = 10;
        uint64 assertionAt = 28;
        uint64 graceDuration = 1 days;

        (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            UnderwritingMockBudgetStakeLedger delayedBudgetStakeLedger,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.setActivatedAt(budgetActivatedAt);
        delayedEscrow.checkpoint(ALICE);

        vm.warp(assertionAt);
        bytes32 assertionId = keccak256("underwriting-reassert-grace-delay");
        delayedBudgetTreasury.registerSuccessAssertion(assertionId);
        delayedBudgetTreasury.clearSuccessAssertion(assertionId, graceDuration);

        uint64 graceDeadline = delayedBudgetTreasury.reassertGraceDeadline();
        assertEq(delayedBudgetTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(delayedBudgetTreasury.reassertGraceUsed());
        assertTrue(delayedBudgetTreasury.isReassertGraceActive());
        assertGt(graceDeadline, assertionAt);

        vm.warp(graceDeadline - 1);
        assertTrue(delayedBudgetTreasury.isReassertGraceActive());

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        uint256 stakedGoalBeforeSlash = delayedVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforeSlash = delayedVault.stakedCobuildOf(ALICE);
        assertEq(stakedGoalBeforeSlash, goalStake);
        assertEq(stakedCobuildBeforeSlash, cobuildStake);
        assertEq(goalToken.balanceOf(ALICE), 0);
        assertEq(cobuildToken.balanceOf(ALICE), 0);

        vm.warp(graceDeadline + 1);
        assertFalse(delayedBudgetTreasury.isReassertGraceActive());

        uint64 budgetClosedAt = uint64(block.timestamp);
        _fundEscrowForTargetSlash(delayedEscrow, budgetActivatedAt, budgetClosedAt, TARGET_SLASH_WEIGHT);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);
        delayedBudgetTreasury.setResolvedAt(budgetClosedAt, IBudgetTreasury.BudgetState.Failed);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        _assertDelayedSlashOutcome(
            delayedVault, delayedRouter, stakedGoalBeforeSlash, stakedCobuildBeforeSlash, fundingBefore, slashWeight
        );
    }

    function test_goalResolvedBeforeBudgetClose_withoutWithdraw_slashStillCutsPrincipal() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        uint64 budgetActivatedAt = 10;
        uint64 budgetClosedAt = 30;

        (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            UnderwritingMockBudgetStakeLedger delayedBudgetStakeLedger,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStack(goalStake, cobuildStake, budgetCoverage);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.setActivatedAt(budgetActivatedAt);
        delayedEscrow.checkpoint(ALICE);

        delayedGoalTreasury.setResolved(true);

        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        uint256 stakedGoalBeforeSlash = delayedVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforeSlash = delayedVault.stakedCobuildOf(ALICE);
        assertEq(goalToken.balanceOf(ALICE), 0);
        assertEq(cobuildToken.balanceOf(ALICE), 0);

        vm.warp(budgetClosedAt);
        _fundEscrowForTargetSlash(delayedEscrow, budgetActivatedAt, budgetClosedAt, TARGET_SLASH_WEIGHT);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);
        delayedBudgetTreasury.setResolvedAt(budgetClosedAt, IBudgetTreasury.BudgetState.Failed);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        _assertDelayedSlashOutcome(
            delayedVault, delayedRouter, stakedGoalBeforeSlash, stakedCobuildBeforeSlash, fundingBefore, slashWeight
        );
    }

    function test_realBudgetTreasuryAndLedger_goalResolvedThenTerminalFailure_prepareAndWithdrawGated_slashBeforeExit()
        public
    {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        bytes32 budgetRecipientId = keccak256("underwriting-real-budget-risk-path");
        uint64 budgetActivatedAt = 10;
        uint64 budgetClosedAt = 45;

        (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            BudgetStakeLedger delayedBudgetStakeLedger,
            BudgetTreasury delayedBudgetTreasury,
            SharedMockFlow delayedBudgetFlow,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStackWithRealBudget(goalStake, cobuildStake, budgetCoverage, budgetRecipientId);

        assertEq(delayedBudgetStakeLedger.registeredBudgetCount(), 1);
        assertEq(delayedBudgetStakeLedger.registeredBudgetAt(0), address(delayedBudgetTreasury));
        assertEq(delayedBudgetStakeLedger.userAllocatedStakeOnBudget(ALICE, address(delayedBudgetTreasury)), budgetCoverage);

        goalSuperToken.mint(address(delayedBudgetFlow), 2e18);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.sync();
        delayedEscrow.checkpoint(ALICE);

        assertEq(delayedBudgetTreasury.activatedAt(), budgetActivatedAt);
        assertEq(uint256(delayedBudgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));

        delayedGoalTreasury.setResolved(true);
        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        vm.prank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        uint256 stakedGoalBeforePrepare = delayedVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforePrepare = delayedVault.stakedCobuildOf(ALICE);

        vm.warp(budgetClosedAt);
        _fundEscrowForTargetSlash(delayedEscrow, budgetActivatedAt, budgetClosedAt, TARGET_SLASH_WEIGHT);
        delayedBudgetTreasury.resolveFailure();

        assertTrue(delayedBudgetTreasury.resolved());
        assertEq(uint256(delayedBudgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(delayedEscrow.closed());

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        vm.prank(ALICE);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, budgetCount);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertTrue(delayedEscrow.slashed(ALICE));
        assertLt(delayedVault.stakedGoalOf(ALICE), stakedGoalBeforePrepare);
        assertLt(delayedVault.stakedCobuildOf(ALICE), stakedCobuildBeforePrepare);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);

        vm.startPrank(ALICE);
        delayedVault.withdrawGoal(delayedVault.stakedGoalOf(ALICE), ALICE);
        delayedVault.withdrawCobuild(delayedVault.stakedCobuildOf(ALICE), ALICE);
        vm.stopPrank();

        assertEq(delayedVault.stakedGoalOf(ALICE), 0);
        assertEq(delayedVault.stakedCobuildOf(ALICE), 0);
        assertLt(goalToken.balanceOf(ALICE), goalStake);
        assertLt(cobuildToken.balanceOf(ALICE), cobuildStake);
        assertEq(goalToken.balanceOf(address(delayedRouter)), 0);
        assertEq(cobuildToken.balanceOf(address(delayedRouter)), 0);
    }

    function _deployDelayedEscrowStack(
        uint256 goalStake,
        uint256 cobuildStake,
        uint256 budgetCoverage
    )
        internal
        returns (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            UnderwritingMockBudgetStakeLedger delayedBudgetStakeLedger,
            UnderwritingMockBudgetTreasury delayedBudgetTreasury,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        )
    {
        delayedBudgetStakeLedger = new UnderwritingMockBudgetStakeLedger();
        delayedGoalTreasury =
            new UnderwritingMockGoalTreasuryResolutionReporter(address(this), address(delayedBudgetStakeLedger));
        delayedVault = new StakeVault(
            address(delayedGoalTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(rulesets)),
            GOAL_REVNET_ID,
            18
        );

        goalToken.mint(ALICE, goalStake);
        cobuildToken.mint(ALICE, cobuildStake);

        vm.startPrank(ALICE);
        goalToken.approve(address(delayedVault), type(uint256).max);
        cobuildToken.approve(address(delayedVault), type(uint256).max);
        delayedVault.depositGoal(goalStake);
        delayedVault.depositCobuild(cobuildStake);
        vm.stopPrank();

        delayedRouter = new UnderwriterSlasherRouter(
            IStakeVault(address(delayedVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            GOAL_FUNDING_TARGET
        );
        delayedVault.setUnderwriterSlasher(address(delayedRouter));

        delayedBudgetTreasury = new UnderwritingMockBudgetTreasury(ISuperToken(address(goalSuperToken)));
        UnderwritingMockBudgetFlow delayedBudgetFlow = new UnderwritingMockBudgetFlow();
        delayedBudgetFlow.setManagerRewardPoolFlowRatePpm(BUDGET_PREMIUM_PPM);
        delayedBudgetTreasury.setFlow(address(delayedBudgetFlow));
        UnderwritingMockGoalFlow delayedGoalFlow = new UnderwritingMockGoalFlow(ISuperToken(address(goalSuperToken)));
        delayedGoalTreasury.setCoverageLambda(COVERAGE_LAMBDA);
        delayedGoalFlow.setFlowOperator(address(delayedGoalTreasury));
        delayedBudgetStakeLedger.registerBudget(address(delayedBudgetTreasury));

        PremiumEscrow implementation = new PremiumEscrow();
        delayedEscrow = PremiumEscrow(Clones.clone(address(implementation)));
        delayedEscrow.initialize(
            address(delayedBudgetTreasury),
            address(delayedBudgetStakeLedger),
            address(delayedGoalFlow),
            address(delayedRouter),
            BUDGET_SLASH_PPM
        );
        delayedBudgetTreasury.setPremiumEscrow(address(delayedEscrow));
        delayedRouter.setAuthorizedPremiumEscrow(address(delayedEscrow), true);
        delayedBudgetStakeLedger.setCoverage(ALICE, address(delayedBudgetTreasury), budgetCoverage);
    }

    function _deployDelayedEscrowStackWithRealBudget(
        uint256 goalStake,
        uint256 cobuildStake,
        uint256 budgetCoverage,
        bytes32 budgetRecipientId
    )
        internal
        returns (
            StakeVault delayedVault,
            UnderwriterSlasherRouter delayedRouter,
            PremiumEscrow delayedEscrow,
            BudgetStakeLedger delayedBudgetStakeLedger,
            BudgetTreasury delayedBudgetTreasury,
            SharedMockFlow delayedBudgetFlow,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        )
    {
        SharedMockFlow delayedGoalFlow = new SharedMockFlow(ISuperToken(address(goalSuperToken)));
        delayedGoalFlow.setRecipientAdmin(address(this));

        uint256 deploymentNonce = vm.getNonce(address(this));
        address predictedBudgetStakeLedger = vm.computeCreateAddress(address(this), deploymentNonce + 1);

        delayedGoalTreasury =
            new UnderwritingMockGoalTreasuryResolutionReporter(address(this), predictedBudgetStakeLedger);
        delayedGoalTreasury.setCoverageLambda(COVERAGE_LAMBDA);
        delayedGoalTreasury.setFlow(address(delayedGoalFlow));
        delayedGoalFlow.setFlowOperator(address(delayedGoalTreasury));
        delayedBudgetStakeLedger = new BudgetStakeLedger(address(delayedGoalTreasury));

        delayedVault = new StakeVault(
            address(delayedGoalTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(rulesets)),
            GOAL_REVNET_ID,
            18
        );

        goalToken.mint(ALICE, goalStake);
        cobuildToken.mint(ALICE, cobuildStake);

        vm.startPrank(ALICE);
        goalToken.approve(address(delayedVault), type(uint256).max);
        cobuildToken.approve(address(delayedVault), type(uint256).max);
        delayedVault.depositGoal(goalStake);
        delayedVault.depositCobuild(cobuildStake);
        vm.stopPrank();

        delayedRouter = new UnderwriterSlasherRouter(
            IStakeVault(address(delayedVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            GOAL_FUNDING_TARGET
        );
        delayedVault.setUnderwriterSlasher(address(delayedRouter));

        delayedBudgetFlow = new SharedMockFlow(ISuperToken(address(goalSuperToken)));
        delayedBudgetFlow.setParent(address(delayedGoalFlow));
        delayedBudgetFlow.setManagerRewardPoolFlowRatePpm(BUDGET_PREMIUM_PPM);

        BudgetTreasury budgetTreasuryImplementation = new BudgetTreasury();
        delayedBudgetTreasury = BudgetTreasury(Clones.clone(address(budgetTreasuryImplementation)));

        PremiumEscrow escrowImplementation = new PremiumEscrow();
        delayedEscrow = PremiumEscrow(Clones.clone(address(escrowImplementation)));

        delayedBudgetFlow.setFlowOperator(address(delayedBudgetTreasury));
        delayedBudgetFlow.setSweeper(address(delayedBudgetTreasury));

        delayedBudgetTreasury.initialize(
            address(this),
            IBudgetTreasury.BudgetConfig({
                flow: address(delayedBudgetFlow),
                premiumEscrow: address(delayedEscrow),
                fundingDeadline: uint64(block.timestamp + 20),
                executionDuration: 20,
                activationThreshold: 1e18,
                runwayCap: 0,
                successResolver: address(this),
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("underwriting-budget-success-oracle-spec"),
                successAssertionPolicyHash: keccak256("underwriting-budget-success-policy")
            })
        );

        delayedEscrow.initialize(
            address(delayedBudgetTreasury),
            address(delayedBudgetStakeLedger),
            address(delayedGoalFlow),
            address(delayedRouter),
            BUDGET_SLASH_PPM
        );

        delayedBudgetStakeLedger.registerBudget(budgetRecipientId, address(delayedBudgetTreasury));

        if (budgetCoverage != 0) {
            bytes32[] memory recipientIds = new bytes32[](1);
            recipientIds[0] = budgetRecipientId;
            uint32[] memory scaled = new uint32[](1);
            scaled[0] = 1_000_000;

            vm.prank(address(delayedGoalFlow));
            delayedBudgetStakeLedger.checkpointAllocation(
                ALICE,
                0,
                new bytes32[](0),
                new uint32[](0),
                budgetCoverage,
                recipientIds,
                scaled
            );
        }

        delayedRouter.setAuthorizedPremiumEscrow(address(delayedEscrow), true);
    }

    function _expectWithdrawLocked(StakeVault delayedVault) internal {
        uint256 goalStakeBeforeWithdraw = delayedVault.stakedGoalOf(ALICE);
        uint256 cobuildStakeBeforeWithdraw = delayedVault.stakedCobuildOf(ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        delayedVault.withdrawGoal(goalStakeBeforeWithdraw, ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        delayedVault.withdrawCobuild(cobuildStakeBeforeWithdraw, ALICE);
        vm.stopPrank();
    }

    function _assertDelayedSlashOutcome(
        StakeVault delayedVault,
        UnderwriterSlasherRouter delayedRouter,
        uint256 stakedGoalBeforeSlash,
        uint256 stakedCobuildBeforeSlash,
        uint256 fundingBefore,
        uint256 slashWeight
    )
        internal
    {
        assertEq(slashWeight, 20e18);
        assertLt(delayedVault.stakedGoalOf(ALICE), stakedGoalBeforeSlash);
        assertLt(delayedVault.stakedCobuildOf(ALICE), stakedCobuildBeforeSlash);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(goalToken.balanceOf(address(delayedRouter)), 0);
        assertEq(cobuildToken.balanceOf(address(delayedRouter)), 0);
        assertEq(goalToken.balanceOf(ALICE), 0);
        assertEq(cobuildToken.balanceOf(ALICE), 0);
    }

    function _fundEscrowForTargetSlash(
        PremiumEscrow escrow_,
        uint64 activatedAt_,
        uint64 closedAt_,
        uint256 targetSlashWeight
    )
        internal
    {
        uint256 duration = uint256(closedAt_ - activatedAt_);
        uint256 premiumNeeded =
            (targetSlashWeight * duration * uint256(BUDGET_PREMIUM_PPM)) / (COVERAGE_LAMBDA * uint256(BUDGET_SLASH_PPM));
        goalSuperToken.mint(address(escrow_), premiumNeeded);
    }
}

contract UnderwritingCoverageCapIntegrationTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 9001;
    bytes32 internal constant ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");
    bytes32 internal constant TERMINAL_BURN_MEMO_HASH = keccak256(bytes("GOAL_TERMINAL_RESIDUAL_BURN"));
    uint8 internal constant TERMINAL_OP_ASSERTION_FINALIZE = 5;
    uint8 internal constant DIRECTORY_FAILURE_INVALID = 1;
    uint8 internal constant DIRECTORY_FAILURE_REVERT = 2;

    SharedMockUnderlying internal underlyingToken;
    SharedMockSuperToken internal superToken;
    SharedMockFlow internal flow;
    SharedMockSuperfluidPool internal distributionPool;
    SharedMockStakeVault internal stakeVault;

    UnderwritingMockRulesets internal rulesets;
    UnderwritingMockDirectory internal directory;
    UnderwritingMockTokens internal tokens;
    UnderwritingMockController internal controller;
    UnderwritingMockHook internal hook;
    UnderwritingMockBudgetStakeLedger internal budgetStakeLedger;
    TreasuryMockOptimisticOracleV3 internal assertionOracle;
    TreasuryMockUmaResolverConfigWithFinalize internal successResolverConfig;

    GoalTreasury internal goalTreasuryImplementation;
    GoalTreasury internal treasury;

    function setUp() public {
        underlyingToken = new SharedMockUnderlying();
        superToken = new SharedMockSuperToken(address(underlyingToken));
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(0);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        flow = new SharedMockFlow(ISuperToken(address(superToken)));
        distributionPool = new SharedMockSuperfluidPool();
        flow.setDistributionPool(ISuperfluidPool(address(distributionPool)));
        flow.setMaxSafeFlowRate(type(int96).max);

        stakeVault = new SharedMockStakeVault();
        stakeVault.setGoalToken(IERC20(address(underlyingToken)));

        rulesets = new UnderwritingMockRulesets();
        directory = new UnderwritingMockDirectory();
        tokens = new UnderwritingMockTokens();
        controller = new UnderwritingMockController(tokens);
        hook = new UnderwritingMockHook(directory);
        budgetStakeLedger = new UnderwritingMockBudgetStakeLedger();
        assertionOracle = new TreasuryMockOptimisticOracleV3();
        successResolverConfig = new TreasuryMockUmaResolverConfigWithFinalize(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            address(0xA11CE),
            keccak256("goal-test-domain")
        );

        rulesets.setDirectory(IJBDirectory(address(directory)));
        rulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 30 days), 1e18);
        rulesets.setWeight(GOAL_REVNET_ID, 1e18);

        directory.setController(GOAL_REVNET_ID, address(controller));
        tokens.setProjectIdOf(address(underlyingToken), GOAL_REVNET_ID);

        goalTreasuryImplementation = new GoalTreasury();
        treasury = _cloneGoalTreasuryWithPredictedAddress();
        treasury.initialize(address(this), _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger)));
    }

    function test_goalTreasuryImplementation_initializeRevertsInvalidInitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        goalTreasuryImplementation.initialize(
            address(this), _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger))
        );
    }

    function test_goalTreasuryCloneInitialize_revertsOnSecondCall() public {
        GoalTreasury candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();
        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        candidateTreasury.initialize(address(this), config);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        candidateTreasury.initialize(address(this), config);
    }

    function test_goalRevnetSplitHookImplementation_initializeRevertsInvalidInitialization() public {
        GoalRevnetSplitHook splitHookImplementation = new GoalRevnetSplitHook();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        splitHookImplementation.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            GOAL_REVNET_ID
        );
    }

    function test_goalRevnetSplitHookCloneInitialize_setsCriticalState() public {
        GoalRevnetSplitHook splitHookImplementation = new GoalRevnetSplitHook();
        GoalRevnetSplitHook splitHookClone = GoalRevnetSplitHook(payable(Clones.clone(address(splitHookImplementation))));

        splitHookClone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            GOAL_REVNET_ID
        );

        assertEq(address(splitHookClone.directory()), address(directory));
        assertEq(address(splitHookClone.goalTreasury()), address(treasury));
        assertEq(address(splitHookClone.flow()), address(flow));
        assertEq(address(splitHookClone.superToken()), address(superToken));
        assertEq(splitHookClone.underlyingToken(), address(underlyingToken));
        assertEq(splitHookClone.goalRevnetId(), GOAL_REVNET_ID);
    }

    function test_goalRevnetSplitHookCloneInitialize_revertsOnSecondCall() public {
        GoalRevnetSplitHook splitHookImplementation = new GoalRevnetSplitHook();
        GoalRevnetSplitHook splitHookClone = GoalRevnetSplitHook(payable(Clones.clone(address(splitHookImplementation))));

        splitHookClone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            GOAL_REVNET_ID
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        splitHookClone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            GOAL_REVNET_ID
        );
    }

    function test_sync_clampsOutflowUntilCoverageIncreases() public {
        distributionPool.setTotalUnits(9);

        superToken.mint(address(flow), 100e18);
        vm.prank(address(hook));
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        int96 initialTargetRate = treasury.targetFlowRate();
        assertGt(initialTargetRate, 0);
        assertEq(flow.targetOutflowRate(), initialTargetRate);

        distributionPool.setTotalUnits(40);
        treasury.sync();

        // Non-zero distribution units should not clamp spend-down target by coverage.
        assertEq(treasury.targetFlowRate(), initialTargetRate);
        assertEq(flow.targetOutflowRate(), initialTargetRate);
    }

    function test_initialize_revertsWhenBudgetStakeLedgerGoalTreasuryMismatch() public {
        UnderwritingMockBudgetStakeLedger mismatchedLedger = new UnderwritingMockBudgetStakeLedger();
        GoalTreasury candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();

        address predictedTreasury = address(candidateTreasury);

        address mismatchedGoalTreasury = address(0xBEEF);
        mismatchedLedger.setGoalTreasury(mismatchedGoalTreasury);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.BUDGET_STAKE_LEDGER_GOAL_MISMATCH.selector, predictedTreasury, mismatchedGoalTreasury
            )
        );
        candidateTreasury.initialize(
            address(this), _defaultGoalConfig(address(rulesets), address(hook), address(mismatchedLedger))
        );
    }

    function test_initialize_revertsWhenBudgetStakeLedgerHasNoCode() public {
        GoalTreasury candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();

        address invalidLedger = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.NOT_A_CONTRACT.selector, invalidLedger));
        candidateTreasury.initialize(address(this), _defaultGoalConfig(address(rulesets), address(hook), invalidLedger));
    }

    function test_sync_characterizesCoverageDropLag_withoutSyncAppliedOutflowRemainsStaleUntilSync() public {
        distributionPool.setTotalUnits(80);

        superToken.mint(address(flow), 100e18);
        vm.prank(address(hook));
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        int96 previousAppliedRate = flow.targetOutflowRate();
        assertGt(previousAppliedRate, 0);
        assertEq(treasury.targetFlowRate(), previousAppliedRate);

        distributionPool.setTotalUnits(0);

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), previousAppliedRate);

        treasury.sync();

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_processHookSplit_afterTerminalization_burnsEntireAmount() public {
        vm.warp(block.timestamp + 4 days);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));

        uint256 sourceAmount = 15e18;
        underlyingToken.mint(address(treasury), sourceAmount);

        vm.prank(address(hook));
        (
            IGoalTreasury.HookSplitAction action,
            uint256 superTokenAmount,
            uint256 burnAmount
        ) = treasury.processHookSplit(address(underlyingToken), sourceAmount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.TerminalSettled));
        assertEq(superTokenAmount, sourceAmount);
        assertEq(burnAmount, sourceAmount);
        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnProjectId(), GOAL_REVNET_ID);
        assertEq(controller.lastBurnAmount(), sourceAmount);
        assertEq(controller.lastBurnMemoHash(), TERMINAL_BURN_MEMO_HASH);
    }

    function test_settleLateResidual_burnsSweptFlowBalance() public {
        vm.warp(block.timestamp + 4 days);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));

        uint256 residual = 9e18;
        superToken.mint(address(flow), residual);

        treasury.settleLateResidual();

        assertEq(superToken.balanceOf(address(flow)), 0);
        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnProjectId(), GOAL_REVNET_ID);
        assertEq(controller.lastBurnAmount(), residual);
        assertEq(controller.lastBurnMemoHash(), TERMINAL_BURN_MEMO_HASH);
    }

    function test_sync_falseAssertionFinalizeCleanupRevert_emitsTerminalSideEffectFailed() public {
        distributionPool.setTotalUnits(40);
        _activateGoal();

        bytes32 assertionId = keccak256("goal-finalize-cleanup-assertion");
        vm.prank(address(successResolverConfig));
        treasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = treasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: address(successResolverConfig),
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: address(successResolverConfig),
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + treasury.successAssertionLiveness(),
                settlementResolution: false,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: treasury.successAssertionBond(),
                callbackRecipient: address(successResolverConfig),
                disputer: address(0)
            })
        );

        successResolverConfig.setShouldRevertFinalize(true);

        vm.warp(treasury.deadline());
        vm.expectEmit(true, false, false, true, address(treasury));
        emit IGoalTreasury.TerminalSideEffectFailed(
            TERMINAL_OP_ASSERTION_FINALIZE,
            abi.encodeWithSelector(TreasuryMockUmaResolverConfigWithFinalize.FINALIZE_REVERT.selector)
        );
        treasury.sync();

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(treasury.reassertGraceUsed());
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_resolverConfigReadFailure_emitsFailClosedTelemetry()
        public
    {
        UnderwritingRevertingOptimisticOracleResolverConfig revertingResolverConfig =
            new UnderwritingRevertingOptimisticOracleResolverConfig(
                IERC20(address(underlyingToken)),
                successResolverConfig.escalationManager(),
                successResolverConfig.domainId()
            );
        GoalTreasury unresolvedConfigTreasury = _deployGoalTreasuryWithResolver(address(revertingResolverConfig));

        distributionPool.setTotalUnits(40);
        _activateGoal(unresolvedConfigTreasury);

        bytes32 assertionId = keccak256("goal-assertion-config-read-failure");
        vm.prank(address(revertingResolverConfig));
        unresolvedConfigTreasury.registerSuccessAssertion(assertionId);

        vm.warp(unresolvedConfigTreasury.deadline());

        vm.expectEmit(true, true, false, false, address(unresolvedConfigTreasury));
        emit GoalTreasury.SuccessAssertionResolutionFailClosed(
            assertionId, TreasurySuccessAssertions.FailClosedReason.ResolverConfigOracleReadFailed
        );
        vm.expectEmit(true, false, false, false, address(unresolvedConfigTreasury));
        emit IGoalTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(unresolvedConfigTreasury));
        emit IGoalTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        unresolvedConfigTreasury.sync();

        _assertGoalFailClosedGraceState(unresolvedConfigTreasury);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_oracleAddressZero_emitsFailClosedTelemetry() public {
        TreasuryMockUmaResolverConfig zeroOracleResolverConfig = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(0)),
            IERC20(address(underlyingToken)),
            successResolverConfig.escalationManager(),
            successResolverConfig.domainId()
        );
        GoalTreasury zeroOracleTreasury = _deployGoalTreasuryWithResolver(address(zeroOracleResolverConfig));

        distributionPool.setTotalUnits(40);
        _activateGoal(zeroOracleTreasury);

        bytes32 assertionId = keccak256("goal-assertion-oracle-zero-address");
        vm.prank(address(zeroOracleResolverConfig));
        zeroOracleTreasury.registerSuccessAssertion(assertionId);

        vm.warp(zeroOracleTreasury.deadline());

        vm.expectEmit(true, true, false, false, address(zeroOracleTreasury));
        emit GoalTreasury.SuccessAssertionResolutionFailClosed(
            assertionId, TreasurySuccessAssertions.FailClosedReason.OracleAddressZero
        );
        vm.expectEmit(true, false, false, false, address(zeroOracleTreasury));
        emit IGoalTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(zeroOracleTreasury));
        emit IGoalTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        zeroOracleTreasury.sync();

        _assertGoalFailClosedGraceState(zeroOracleTreasury);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_oracleAssertionReadFailure_emitsFailClosedTelemetry()
        public
    {
        UnderwritingRevertingGetAssertionOracle revertingOracle = new UnderwritingRevertingGetAssertionOracle();
        TreasuryMockUmaResolverConfig revertingAssertionReadResolver = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(revertingOracle)),
            IERC20(address(underlyingToken)),
            successResolverConfig.escalationManager(),
            successResolverConfig.domainId()
        );
        GoalTreasury unresolvedAssertionReadTreasury =
            _deployGoalTreasuryWithResolver(address(revertingAssertionReadResolver));

        distributionPool.setTotalUnits(40);
        _activateGoal(unresolvedAssertionReadTreasury);

        bytes32 assertionId = keccak256("goal-assertion-oracle-read-failure");
        vm.prank(address(revertingAssertionReadResolver));
        unresolvedAssertionReadTreasury.registerSuccessAssertion(assertionId);

        vm.warp(unresolvedAssertionReadTreasury.deadline());

        vm.expectEmit(true, true, false, false, address(unresolvedAssertionReadTreasury));
        emit GoalTreasury.SuccessAssertionResolutionFailClosed(
            assertionId, TreasurySuccessAssertions.FailClosedReason.OracleAssertionReadFailed
        );
        vm.expectEmit(true, false, false, false, address(unresolvedAssertionReadTreasury));
        emit IGoalTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(unresolvedAssertionReadTreasury));
        emit IGoalTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        unresolvedAssertionReadTreasury.sync();

        _assertGoalFailClosedGraceState(unresolvedAssertionReadTreasury);
    }

    function test_initialize_rulesetsDirectoryRevertAndHookInvalid_surfacesDiagnosticReason() public {
        UnderwritingMockRulesetsDirectoryReverting revertingRulesets = new UnderwritingMockRulesetsDirectoryReverting();
        revertingRulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 30 days), 1e18);
        revertingRulesets.setWeight(GOAL_REVNET_ID, 1e18);

        UnderwritingMockHook invalidHook = new UnderwritingMockHook(UnderwritingMockDirectory(address(0)));
        GoalTreasury candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();

        bytes memory expectedReason = abi.encode(
            address(revertingRulesets),
            DIRECTORY_FAILURE_REVERT,
            abi.encodeWithSignature("Error(string)", "RULESETS_DIRECTORY_REVERT"),
            address(invalidHook),
            DIRECTORY_FAILURE_INVALID,
            bytes("")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE_WITH_REASON.selector,
                address(underlyingToken),
                expectedReason
            )
        );
        candidateTreasury.initialize(
            address(this), _defaultGoalConfig(address(revertingRulesets), address(invalidHook), address(budgetStakeLedger))
        );
    }

    function test_initialize_cobuildDirectoryRevertAndHookInvalid_surfacesDiagnosticReason() public {
        UnderwritingMockRulesetsDirectoryReverting revertingRulesets = new UnderwritingMockRulesetsDirectoryReverting();
        revertingRulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 30 days), 1e18);
        revertingRulesets.setWeight(GOAL_REVNET_ID, 1e18);

        UnderwritingMockHook invalidHook = new UnderwritingMockHook(UnderwritingMockDirectory(address(0)));
        SharedMockUnderlying cobuildToken = new SharedMockUnderlying();
        GoalTreasury candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();

        stakeVault.setCobuildToken(IERC20(address(cobuildToken)));

        bytes memory expectedReason = abi.encode(
            address(revertingRulesets),
            DIRECTORY_FAILURE_REVERT,
            abi.encodeWithSignature("Error(string)", "RULESETS_DIRECTORY_REVERT"),
            address(invalidHook),
            DIRECTORY_FAILURE_INVALID,
            bytes("")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE_WITH_REASON.selector,
                address(cobuildToken),
                expectedReason
            )
        );
        candidateTreasury.initialize(
            address(this), _defaultGoalConfig(address(revertingRulesets), address(invalidHook), address(budgetStakeLedger))
        );
    }

    function _activateGoal() internal {
        _activateGoal(treasury);
    }

    function _activateGoal(GoalTreasury targetTreasury) internal {
        superToken.mint(address(flow), 100e18);
        vm.prank(address(hook));
        assertTrue(targetTreasury.recordHookFunding(100e18));
        targetTreasury.sync();
        assertEq(uint256(targetTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
    }

    function _deployGoalTreasuryWithResolver(address resolver) internal returns (GoalTreasury candidateTreasury) {
        candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.successResolver = resolver;

        candidateTreasury.initialize(address(this), config);
    }

    function _cloneGoalTreasuryWithPredictedAddress() internal returns (GoalTreasury candidateTreasury) {
        address predictedTreasury = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predictedTreasury);
        budgetStakeLedger.setGoalTreasury(predictedTreasury);
        flow.setFlowOperator(predictedTreasury);
        flow.setSweeper(predictedTreasury);
        candidateTreasury = GoalTreasury(Clones.clone(address(goalTreasuryImplementation)));
    }

    function _assertGoalFailClosedGraceState(GoalTreasury targetTreasury) internal view {
        assertEq(uint256(targetTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(targetTreasury.resolved());
        assertEq(targetTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(targetTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(targetTreasury.reassertGraceUsed());
        assertEq(targetTreasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function _defaultGoalConfig(address rulesetsAddr, address hookAddr, address budgetStakeLedgerAddr)
        internal
        view
        returns (IGoalTreasury.GoalConfig memory config)
    {
        config = IGoalTreasury.GoalConfig({
            flow: address(flow),
            stakeVault: address(stakeVault),
            budgetStakeLedger: budgetStakeLedgerAddr,
            hook: hookAddr,
            goalRulesets: rulesetsAddr,
            goalRevnetId: GOAL_REVNET_ID,
            minRaiseDeadline: uint64(block.timestamp + 3 days),
            minRaise: 100e18,
            coverageLambda: 10,
            budgetPremiumPpm: 0,
            budgetSlashPpm: 0,
            successResolver: address(successResolverConfig),
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
        });
    }
}

contract UnderwritingRevertingOptimisticOracleResolverConfig is IUMATreasurySuccessResolverConfig {
    IERC20 public immutable override assertionCurrency;
    address public immutable override escalationManager;
    bytes32 public immutable override domainId;

    error OPTIMISTIC_ORACLE_REVERT();

    constructor(IERC20 assertionCurrency_, address escalationManager_, bytes32 domainId_) {
        assertionCurrency = assertionCurrency_;
        escalationManager = escalationManager_;
        domainId = domainId_;
    }

    function optimisticOracle() external pure returns (OptimisticOracleV3Interface) {
        revert OPTIMISTIC_ORACLE_REVERT();
    }
}

contract UnderwritingRevertingGetAssertionOracle {
    error GET_ASSERTION_REVERT();

    function getAssertion(bytes32) external pure returns (OptimisticOracleV3Interface.Assertion memory) {
        revert GET_ASSERTION_REVERT();
    }
}

contract UnderwritingMockBudgetStakeLedger {
    mapping(address account => mapping(address budgetTreasury => uint256 coverage)) internal _coverage;
    address internal _goalTreasury;
    address[] internal _registeredBudgets;
    mapping(address budget => bool exists) internal _isRegisteredBudget;

    function setCoverage(address account, address budgetTreasury, uint256 coverage) external {
        _coverage[account][budgetTreasury] = coverage;
    }

    function setGoalTreasury(address goalTreasury_) external {
        _goalTreasury = goalTreasury_;
    }

    function goalTreasury() external view returns (address) {
        return _goalTreasury;
    }

    function registerBudget(address budget) external {
        if (_isRegisteredBudget[budget]) return;
        _isRegisteredBudget[budget] = true;
        _registeredBudgets.push(budget);
    }

    function registeredBudgetCount() external view returns (uint256) {
        return _registeredBudgets.length;
    }

    function registeredBudgetAt(uint256 index) external view returns (address) {
        return _registeredBudgets[index];
    }

    function userAllocatedStakeOnBudget(address account, address budgetTreasury) external view returns (uint256) {
        return _coverage[account][budgetTreasury];
    }
}

contract UnderwritingMockBudgetTreasury {
    ISuperToken internal immutable _superToken;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Funding;
    address public premiumEscrow;
    uint64 public activatedAt;
    uint64 public resolvedAt;
    bytes32 public pendingSuccessAssertionId;
    uint64 public pendingSuccessAssertionAt;
    uint64 public reassertGraceDeadline;
    bool public reassertGraceUsed;
    address public flow;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function setPremiumEscrow(address premiumEscrow_) external {
        premiumEscrow = premiumEscrow_;
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        activatedAt = activatedAt_;
        if (activatedAt_ != 0 && state == IBudgetTreasury.BudgetState.Funding) {
            state = IBudgetTreasury.BudgetState.Active;
        }
    }

    function setResolvedAt(uint64 resolvedAt_, IBudgetTreasury.BudgetState state_) external {
        resolvedAt = resolvedAt_;
        state = state_;
    }

    function resolved() external view returns (bool) {
        return resolvedAt != 0;
    }

    function registerSuccessAssertion(bytes32 assertionId) external {
        pendingSuccessAssertionId = assertionId;
        pendingSuccessAssertionAt = uint64(block.timestamp);
    }

    function clearSuccessAssertion(bytes32 assertionId, uint64 graceDuration) external {
        require(pendingSuccessAssertionId == assertionId, "ASSERTION_ID_MISMATCH");

        pendingSuccessAssertionId = bytes32(0);
        pendingSuccessAssertionAt = 0;
        if (reassertGraceUsed || graceDuration == 0) return;

        reassertGraceUsed = true;
        uint256 computedDeadline = block.timestamp + uint256(graceDuration);
        if (computedDeadline > type(uint64).max) computedDeadline = type(uint64).max;
        reassertGraceDeadline = uint64(computedDeadline);
    }

    function isReassertGraceActive() external view returns (bool) {
        uint64 graceDeadline = reassertGraceDeadline;
        return graceDeadline != 0 && block.timestamp < graceDeadline;
    }
}

contract UnderwritingMockGoalFlow {
    ISuperToken internal immutable _superToken;
    address internal _flowOperator;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function setFlowOperator(address flowOperator_) external {
        _flowOperator = flowOperator_;
    }
}

contract UnderwritingMockGoalTreasuryResolutionReporter {
    bool public resolved;
    address public immutable authority;
    address public immutable budgetStakeLedger;
    address public flow;
    uint256 public coverageLambda;

    constructor(address authority_, address budgetStakeLedger_) {
        authority = authority_;
        budgetStakeLedger = budgetStakeLedger_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setCoverageLambda(uint256 coverageLambda_) external {
        coverageLambda = coverageLambda_;
    }
}

contract UnderwritingMockBudgetFlow {
    uint32 internal _managerRewardPoolFlowRatePpm;

    function setManagerRewardPoolFlowRatePpm(uint32 ppm_) external {
        _managerRewardPoolFlowRatePpm = ppm_;
    }

    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        return _managerRewardPoolFlowRatePpm;
    }
}

contract UnderwritingMockRulesets {
    struct RulesetPair {
        JBRuleset base;
        JBRuleset terminal;
        bool configured;
    }

    mapping(uint256 => uint112) internal _weightOf;
    mapping(uint256 => RulesetPair) internal _pairOf;
    IJBDirectory internal _directory;

    function setDirectory(IJBDirectory directory_) external {
        _directory = directory_;
    }

    function DIRECTORY() external view virtual returns (IJBDirectory) {
        return _directory;
    }

    function setWeight(uint256 projectId, uint112 weight) external {
        _weightOf[projectId] = weight;
    }

    function configureTwoRulesetSchedule(uint256 projectId, uint48 terminalStart, uint112 openWeight) external {
        uint48 nowTs = uint48(block.timestamp);
        RulesetPair storage pair = _pairOf[projectId];
        pair.base = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: nowTs,
            duration: 0,
            weight: openWeight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.terminal = JBRuleset({
            cycleNumber: 2,
            id: 2,
            basedOnId: 1,
            start: terminalStart,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.configured = true;
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        ruleset.weight = _weightOf[projectId];
    }

    function latestQueuedOf(uint256 projectId) external view returns (JBRuleset memory ruleset, JBApprovalStatus status) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return (ruleset, JBApprovalStatus.Empty);
        return (pair.terminal, JBApprovalStatus.Approved);
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory ruleset) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return ruleset;
        if (rulesetId == pair.base.id) return pair.base;
        if (rulesetId == pair.terminal.id) return pair.terminal;
        return ruleset;
    }
}

contract UnderwritingMockRulesetsDirectoryReverting is UnderwritingMockRulesets {
    function DIRECTORY() external pure override returns (IJBDirectory) {
        revert("RULESETS_DIRECTORY_REVERT");
    }
}

contract UnderwritingMockDirectory {
    mapping(uint256 projectId => address controller) internal _controllerOf;
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _primaryTerminalOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract UnderwritingMockTokens {
    mapping(address token => uint256 projectId) internal _projectIdOf;

    function setProjectIdOf(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}

contract UnderwritingMockController {
    UnderwritingMockTokens internal _tokens;
    uint256 internal _burnCallCount;
    uint256 internal _lastBurnProjectId;
    uint256 internal _lastBurnAmount;
    bytes32 internal _lastBurnMemoHash;

    constructor(UnderwritingMockTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (UnderwritingMockTokens) {
        return _tokens;
    }

    function burnTokensOf(address, uint256 projectId, uint256 tokenCount, string calldata memo) external {
        _burnCallCount += 1;
        _lastBurnProjectId = projectId;
        _lastBurnAmount = tokenCount;
        _lastBurnMemoHash = keccak256(bytes(memo));
    }

    function burnCallCount() external view returns (uint256) {
        return _burnCallCount;
    }

    function lastBurnProjectId() external view returns (uint256) {
        return _lastBurnProjectId;
    }

    function lastBurnAmount() external view returns (uint256) {
        return _lastBurnAmount;
    }

    function lastBurnMemoHash() external view returns (bytes32) {
        return _lastBurnMemoHash;
    }
}

contract UnderwritingMockHook {
    UnderwritingMockDirectory internal immutable _directory;

    constructor(UnderwritingMockDirectory directory_) {
        _directory = directory_;
    }

    function directory() external view returns (UnderwritingMockDirectory) {
        return _directory;
    }
}

contract UnderwritingMockTerminal {
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
