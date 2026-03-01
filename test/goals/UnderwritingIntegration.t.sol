// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {IUnderwriterSlasherRouter} from "src/interfaces/IUnderwriterSlasherRouter.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {JBApprovalStatus} from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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

contract UnderwritingPremiumSlashIntegrationTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 77;
    uint32 internal constant BUDGET_SLASH_PPM = 200_000; // 20%

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
    UnderwritingMockGoalFlow internal goalFlow;

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
        goalFlow = new UnderwritingMockGoalFlow(ISuperToken(address(goalSuperToken)));

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(
            address(budgetTreasury),
            address(budgetStakeLedger),
            address(goalFlow),
            address(router),
            BUDGET_SLASH_PPM
        );

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
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        _assertDelayedSlashOutcome(
            delayedVault, delayedRouter, stakedGoalBeforeSlash, stakedCobuildBeforeSlash, fundingBefore, slashWeight
        );
    }

    function test_goalResolvedDuringPendingSuccessAssertionDelay_ifWithdrawGateOpens_thenSlashCannotRecoverPrincipal()
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

        delayedBudgetStakeLedger.setAllTrackedBudgetsResolved(true);

        vm.startPrank(ALICE);
        delayedVault.withdrawGoal(delayedVault.stakedGoalOf(ALICE), ALICE);
        delayedVault.withdrawCobuild(delayedVault.stakedCobuildOf(ALICE), ALICE);
        vm.stopPrank();

        assertEq(delayedVault.stakedGoalOf(ALICE), 0);
        assertEq(delayedVault.stakedCobuildOf(ALICE), 0);
        assertEq(goalToken.balanceOf(ALICE), goalStake);
        assertEq(cobuildToken.balanceOf(ALICE), cobuildStake);
        assertEq(delayedBudgetTreasury.pendingSuccessAssertionId(), assertionId);

        vm.warp(budgetClosedAt);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        assertEq(slashWeight, 20e18);
        assertEq(delayedVault.stakedGoalOf(ALICE), 0);
        assertEq(delayedVault.stakedCobuildOf(ALICE), 0);
        assertEq(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(goalToken.balanceOf(address(delayedRouter)), 0);
        assertEq(cobuildToken.balanceOf(address(delayedRouter)), 0);
        assertEq(goalToken.balanceOf(ALICE), goalStake);
        assertEq(cobuildToken.balanceOf(ALICE), cobuildStake);
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
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);

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
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        _assertDelayedSlashOutcome(
            delayedVault, delayedRouter, stakedGoalBeforeSlash, stakedCobuildBeforeSlash, fundingBefore, slashWeight
        );
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
        delayedBudgetStakeLedger.setAllTrackedBudgetsResolved(false);
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
        UnderwritingMockGoalFlow delayedGoalFlow = new UnderwritingMockGoalFlow(ISuperToken(address(goalSuperToken)));

        PremiumEscrow implementation = new PremiumEscrow();
        delayedEscrow = PremiumEscrow(Clones.clone(address(implementation)));
        delayedEscrow.initialize(
            address(delayedBudgetTreasury),
            address(delayedBudgetStakeLedger),
            address(delayedGoalFlow),
            address(delayedRouter),
            BUDGET_SLASH_PPM
        );
        delayedRouter.setAuthorizedPremiumEscrow(address(delayedEscrow), true);
        delayedBudgetStakeLedger.setCoverage(ALICE, address(delayedBudgetTreasury), budgetCoverage);
    }

    function _expectWithdrawLocked(StakeVault delayedVault) internal {
        uint256 goalStakeBeforeWithdraw = delayedVault.stakedGoalOf(ALICE);
        uint256 cobuildStakeBeforeWithdraw = delayedVault.stakedCobuildOf(ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_LOCKED.selector);
        delayedVault.withdrawGoal(goalStakeBeforeWithdraw, ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_LOCKED.selector);
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
}

contract UnderwritingCoverageCapIntegrationTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 9001;
    bytes32 internal constant TERMINAL_BURN_MEMO_HASH = keccak256(bytes("GOAL_TERMINAL_RESIDUAL_BURN"));

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

        rulesets.setDirectory(IJBDirectory(address(directory)));
        rulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 30 days), 1e18);
        rulesets.setWeight(GOAL_REVNET_ID, 1e18);

        directory.setController(GOAL_REVNET_ID, address(controller));
        tokens.setProjectIdOf(address(underlyingToken), GOAL_REVNET_ID);

        address predictedTreasury = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predictedTreasury);
        budgetStakeLedger.setGoalTreasury(predictedTreasury);
        flow.setFlowOperator(predictedTreasury);
        flow.setSweeper(predictedTreasury);

        treasury = new GoalTreasury(
            address(this),
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                budgetStakeLedger: address(budgetStakeLedger),
                hook: address(hook),
                goalRulesets: address(rulesets),
                goalRevnetId: GOAL_REVNET_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                coverageLambda: 10,
                budgetPremiumPpm: 0,
                budgetSlashPpm: 0,
                successResolver: address(this),
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_sync_clampsOutflowUntilCoverageIncreases() public {
        distributionPool.setTotalUnits(9);

        superToken.mint(address(flow), 100e18);
        vm.prank(address(hook));
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);

        distributionPool.setTotalUnits(40);
        treasury.sync();

        assertEq(treasury.targetFlowRate(), 4);
        assertEq(flow.targetOutflowRate(), 4);
    }

    function test_initialize_revertsWhenBudgetStakeLedgerGoalTreasuryMismatch() public {
        UnderwritingMockBudgetStakeLedger mismatchedLedger = new UnderwritingMockBudgetStakeLedger();

        address predictedTreasury = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predictedTreasury);
        flow.setFlowOperator(predictedTreasury);
        flow.setSweeper(predictedTreasury);

        address mismatchedGoalTreasury = address(0xBEEF);
        mismatchedLedger.setGoalTreasury(mismatchedGoalTreasury);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.BUDGET_STAKE_LEDGER_GOAL_MISMATCH.selector, predictedTreasury, mismatchedGoalTreasury
            )
        );
        new GoalTreasury(
            address(this),
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                budgetStakeLedger: address(mismatchedLedger),
                hook: address(hook),
                goalRulesets: address(rulesets),
                goalRevnetId: GOAL_REVNET_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                coverageLambda: 10,
                budgetPremiumPpm: 0,
                budgetSlashPpm: 0,
                successResolver: address(this),
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_sync_characterizesCoverageDropLag_withoutSyncAppliedOutflowRemainsStaleUntilSync() public {
        distributionPool.setTotalUnits(80);

        superToken.mint(address(flow), 100e18);
        vm.prank(address(hook));
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        assertEq(treasury.targetFlowRate(), 8);
        assertEq(flow.targetOutflowRate(), 8);

        distributionPool.setTotalUnits(1);

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 8);

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
}

contract UnderwritingMockBudgetStakeLedger {
    mapping(address account => mapping(address budgetTreasury => uint256 coverage)) internal _coverage;
    address internal _goalTreasury;
    bool internal _allTrackedBudgetsResolved = true;

    function setCoverage(address account, address budgetTreasury, uint256 coverage) external {
        _coverage[account][budgetTreasury] = coverage;
    }

    function setGoalTreasury(address goalTreasury_) external {
        _goalTreasury = goalTreasury_;
    }

    function goalTreasury() external view returns (address) {
        return _goalTreasury;
    }

    function setAllTrackedBudgetsResolved(bool resolved_) external {
        _allTrackedBudgetsResolved = resolved_;
    }

    function allTrackedBudgetsResolved() external view returns (bool) {
        return _allTrackedBudgetsResolved;
    }

    function userAllocatedStakeOnBudget(address account, address budgetTreasury) external view returns (uint256) {
        return _coverage[account][budgetTreasury];
    }
}

contract UnderwritingMockBudgetTreasury {
    ISuperToken internal immutable _superToken;
    uint64 public activatedAt;
    bytes32 public pendingSuccessAssertionId;
    uint64 public pendingSuccessAssertionAt;
    uint64 public reassertGraceDeadline;
    bool public reassertGraceUsed;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        activatedAt = activatedAt_;
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

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }
}

contract UnderwritingMockGoalTreasuryResolutionReporter {
    bool public resolved;
    address public immutable authority;
    address public immutable budgetStakeLedger;

    constructor(address authority_, address budgetStakeLedger_) {
        authority = authority_;
        budgetStakeLedger = budgetStakeLedger_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
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

    function DIRECTORY() external view returns (IJBDirectory) {
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
