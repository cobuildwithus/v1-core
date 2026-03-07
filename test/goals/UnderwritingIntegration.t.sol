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
import {IBudgetStackTopologyReader} from "src/interfaces/IBudgetStackTopologyReader.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
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
import {
    ISuperToken,
    ISuperfluidPool
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {
    SharedMockCFA,
    SharedMockFlow,
    SharedMockGDA,
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

contract UnderwritingPremiumSlashIntegrationTest is Test, IBudgetStackTopologyReader {
    uint256 internal constant GOAL_REVNET_ID = 77;
    uint256 internal constant COBUILD_REVNET_ID = 78;
    uint32 internal constant BUDGET_SLASH_PPM = 200_000; // 20%
    uint32 internal constant BUDGET_PREMIUM_PPM = 100_000;
    uint256 internal constant TARGET_SLASH_WEIGHT = 20e18;
    bytes32 internal constant ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");

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
    UnderwritingMockHook internal goalHook;
    UnderwritingMockTerminal internal conversionTerminal;

    StakeVault internal stakeVault;
    UnderwriterSlasherRouter internal router;
    PremiumEscrow internal escrow;
    UnderwritingMockBudgetStakeLedger internal budgetStakeLedger;
    UnderwritingMockBudgetTreasury internal budgetTreasury;
    UnderwritingMockBudgetFlow internal budgetFlow;
    UnderwritingMockGoalFlow internal goalFlow;
    UnderwritingMockGoalTreasuryResolutionReporter internal goalTreasury;
    UnderwritingBudgetTopologyStrategy internal topologyStrategy;

    mapping(bytes32 itemId => BudgetStackTopology topology) private _topologyByItemId;
    mapping(bytes32 itemId => bool active) private _activeByItemId;
    mapping(address budgetTreasury => bytes32 itemId) private _itemIdByBudgetTreasury;
    mapping(address childFlow => bytes32 itemId) private _itemIdByChildFlow;

    struct RealGoalBudgetEscrowStack {
        StakeVault vault;
        UnderwriterSlasherRouter router;
        PremiumEscrow escrow;
        BudgetStakeLedger budgetStakeLedger;
        BudgetTreasury budgetTreasury;
        SharedMockFlow budgetFlow;
        GoalTreasury goalTreasury;
        SharedMockFlow goalFlow;
        TreasuryMockOptimisticOracleV3 goalAssertionOracle;
        TreasuryMockUmaResolverConfig goalSuccessResolver;
        TreasuryMockOptimisticOracleV3 budgetAssertionOracle;
        TreasuryMockUmaResolverConfig budgetSuccessResolver;
    }

    function setUp() public {
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        goalSuperToken = new SharedMockSuperToken(address(goalToken));
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(0);
        host.setCFA(address(cfa));
        host.setGDA(address(new SharedMockGDA()));
        goalSuperToken.setHost(address(host));

        rulesets = new UnderwritingMockRulesets();
        directory = new UnderwritingMockDirectory();
        tokens = new UnderwritingMockTokens();
        controller = new UnderwritingMockController(tokens);
        goalHook = new UnderwritingMockHook(directory);
        conversionTerminal = new UnderwritingMockTerminal(IERC20(address(cobuildToken)), IERC20(address(goalToken)));

        rulesets.setDirectory(IJBDirectory(address(directory)));
        rulesets.setWeight(GOAL_REVNET_ID, 2e18);
        rulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 30 days), 2e18);
        directory.setController(GOAL_REVNET_ID, address(controller));
        directory.setController(COBUILD_REVNET_ID, address(controller));
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(conversionTerminal)));
        tokens.setProjectIdOf(address(goalToken), GOAL_REVNET_ID);
        tokens.setProjectIdOf(address(cobuildToken), COBUILD_REVNET_ID);

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
        SharedMockSuperfluidPool managerRewardPool = new SharedMockSuperfluidPool();
        budgetFlow.setManagerRewardDistributionPool(address(managerRewardPool));
        budgetTreasury.setFlow(address(budgetFlow));
        goalFlow = new UnderwritingMockGoalFlow(ISuperToken(address(goalSuperToken)));
        goalTreasury = new UnderwritingMockGoalTreasuryResolutionReporter(address(this), address(budgetStakeLedger));
        topologyStrategy = new UnderwritingBudgetTopologyStrategy();
        goalFlow.setFlowOperator(address(goalTreasury));

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(
            address(budgetTreasury), address(budgetStakeLedger), address(goalFlow), address(router), BUDGET_SLASH_PPM
        );
        budgetTreasury.setPremiumEscrow(address(escrow));
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(managerRewardPool));

        router.setAuthorizedPremiumEscrow(address(escrow), true);
    }

    function budgetStackTopology(bytes32 itemId)
        external
        view
        returns (BudgetStackTopology memory topology, bool active)
    {
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function budgetStackTopologyForBudgetTreasury(address budgetTreasury_)
        external
        view
        returns (BudgetStackTopology memory topology, bool active)
    {
        bytes32 itemId = _itemIdByBudgetTreasury[budgetTreasury_];
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function budgetStackTopologyForChildFlow(address childFlow)
        external
        view
        returns (BudgetStackTopology memory topology, bool active)
    {
        bytes32 itemId = _itemIdByChildFlow[childFlow];
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function itemIdForBudgetTreasury(address budgetTreasury_) external view returns (bytes32 itemId) {
        itemId = _itemIdByBudgetTreasury[budgetTreasury_];
    }

    function itemIdForChildFlow(address childFlow) external view returns (bytes32 itemId) {
        itemId = _itemIdByChildFlow[childFlow];
    }

    function _setBudgetTopology(bytes32 itemId, BudgetStackTopology memory topology, bool active) internal {
        _topologyByItemId[itemId] = topology;
        _activeByItemId[itemId] = active;
        _itemIdByBudgetTreasury[topology.budgetTreasury] = itemId;
        _itemIdByChildFlow[topology.childFlow] = itemId;
    }

    function test_underwriterCoverage_premiumAccruesAndClaims() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        escrow.checkpoint(ALICE);
        _distributeEscrowPremium(escrow, 45e18);
        escrow.checkpoint(ALICE);
        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 0, 20);

        vm.prank(ALICE);
        uint256 claimed = escrow.claim(PREMIUM_RECIPIENT);

        assertEq(claimed, 45e18);
        assertEq(goalSuperToken.balanceOf(PREMIUM_RECIPIENT), 45e18);
    }

    function test_underwriterCoverage_claimRevertsWhenGoalNotSucceeded() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        escrow.checkpoint(ALICE);
        _distributeEscrowPremium(escrow, 45e18);
        escrow.checkpoint(ALICE);
        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 0, 20);

        goalTreasury.setState(IGoalTreasury.GoalState.Active);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.GOAL_NOT_SUCCEEDED.selector, IGoalTreasury.GoalState.Active)
        );
        vm.prank(ALICE);
        escrow.claim(PREMIUM_RECIPIENT);
    }

    function test_failedBudgetAfterActivation_slashesStake_convertsCobuild_andFundsGoalPath() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        escrow.checkpoint(ALICE);

        vm.warp(30);
        _fundEscrowForTargetSlash(escrow, TARGET_SLASH_WEIGHT);
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

    function test_regression_systemCheckpointedCoverage_noManualCheckpoint_stillSlashes() public {
        uint256 coverage = 100e18;
        uint64 activatedAt = 10;
        uint64 closedAt = 30;

        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), coverage);

        // Model the canonical allocation-pipeline checkpoint at allocation-change time.
        escrow.checkpoint(ALICE);
        assertEq(escrow.userCov(ALICE), coverage);
        assertEq(escrow.creditDrawn(ALICE), 0);

        vm.warp(activatedAt);
        budgetTreasury.setActivatedAt(activatedAt);

        vm.warp(closedAt);
        _setGoalFlowCreditForTargetSlashWithoutCheckpoint(escrow, TARGET_SLASH_WEIGHT);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, activatedAt, closedAt);

        uint256 stakedGoalBefore = stakeVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBefore = stakeVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, TARGET_SLASH_WEIGHT);
        assertLt(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertLt(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
    }

    function test_failedBudgetAfterActivation_slashStillFundsGoal_whenCobuildConversionUnavailable() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(0)));

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        escrow.checkpoint(ALICE);

        vm.warp(30);
        _fundEscrowForTargetSlash(escrow, TARGET_SLASH_WEIGHT);
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

    function test_failedBudgetAfterActivation_goalFlowOperatorUnavailable_stillSlashes() public {
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 100e18);

        vm.warp(10);
        budgetTreasury.setActivatedAt(10);
        escrow.checkpoint(ALICE);

        vm.warp(30);
        _fundEscrowForTargetSlash(escrow, TARGET_SLASH_WEIGHT);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 stakedGoalBefore = stakeVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBefore = stakeVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        goalFlow.setFlowOperator(address(0));

        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, TARGET_SLASH_WEIGHT);
        assertTrue(escrow.slashed(ALICE));
        assertLt(stakeVault.stakedGoalOf(ALICE), stakedGoalBefore);
        assertLt(stakeVault.stakedCobuildOf(ALICE), stakedCobuildBefore);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(conversionTerminal.payCallCount(), 1);
    }

    function test_bridgeCoverageCoverageExitBeforeActivation_postActivationSpendYieldsZeroSlash() public {
        uint256 initialCoverage = 100e18;
        uint64 activatedAt = 10;
        uint64 closedAt = 30;
        uint256 postActivationPremium = 25e18;

        // Underwriter covers during funding.
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), initialCoverage);
        escrow.checkpoint(ALICE);
        assertEq(escrow.userCov(ALICE), initialCoverage);
        assertEq(escrow.peakCov(ALICE), initialCoverage);

        // Coverage exits before activation, so execution runs uncovered.
        budgetStakeLedger.setCoverage(ALICE, address(budgetTreasury), 0);
        escrow.checkpoint(ALICE);
        assertEq(escrow.userCov(ALICE), 0);
        assertEq(escrow.totalCoverage(), 0);

        vm.warp(activatedAt);
        budgetTreasury.setActivatedAt(activatedAt);

        // Post-activation premium inflow while total coverage is zero is recycled, not accrued.
        _distributeEscrowPremium(escrow, postActivationPremium);
        escrow.checkpoint(ALICE);
        assertEq(goalSuperToken.balanceOf(address(goalFlow)), postActivationPremium);
        assertEq(escrow.premiumEarned(ALICE), 0);
        assertEq(escrow.claimable(ALICE), 0);

        vm.warp(closedAt);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, activatedAt, closedAt);

        uint256 slashWeight = escrow.slash(ALICE);

        assertEq(slashWeight, 0);
        assertTrue(escrow.slashed(ALICE));
        assertEq(escrow.peakCov(ALICE), initialCoverage);
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
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Failed, budgetActivatedAt, budgetClosedAt);
        delayedBudgetTreasury.setResolvedAt(budgetClosedAt, IBudgetTreasury.BudgetState.Failed);

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);
        uint256 slashWeight = delayedEscrow.slash(ALICE);

        _assertDelayedSlashOutcome(
            delayedVault, delayedRouter, stakedGoalBeforeSlash, stakedCobuildBeforeSlash, fundingBefore, slashWeight
        );
    }

    function test_goalResolvedDuringPendingSuccessAssertionDelay_prepareBlocksWithdrawalUntilBudgetResolves() public {
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
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);
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
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);
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
            StakeVault delayedVault,,
            PremiumEscrow delayedEscrow,,
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
            StakeVault delayedVault,,
            PremiumEscrow delayedEscrow,,
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
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);
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
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);
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
        assertEq(
            delayedBudgetStakeLedger.userAllocatedStakeOnBudget(ALICE, address(delayedBudgetTreasury)), budgetCoverage
        );

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
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);
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

    function test_realBudgetTreasury_pendingSuccessAssertion_keepsWithdrawalBlockedUntilClearedAndFailed() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        bytes32 budgetRecipientId = keccak256("underwriting-real-budget-pending-assertion");
        bytes32 assertionId = keccak256("underwriting-real-budget-success-assertion");
        uint64 budgetActivatedAt = 10;
        uint64 assertionRegisteredAt = 25;
        uint64 budgetResolvedAt = 45;

        (
            StakeVault delayedVault,,
            PremiumEscrow delayedEscrow,
            BudgetStakeLedger delayedBudgetStakeLedger,
            BudgetTreasury delayedBudgetTreasury,
            SharedMockFlow delayedBudgetFlow,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStackWithRealBudget(goalStake, cobuildStake, budgetCoverage, budgetRecipientId);

        assertEq(
            delayedBudgetStakeLedger.userAllocatedStakeOnBudget(ALICE, address(delayedBudgetTreasury)), budgetCoverage
        );

        goalSuperToken.mint(address(delayedBudgetFlow), 2e18);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.sync();
        delayedEscrow.checkpoint(ALICE);

        vm.warp(assertionRegisteredAt);
        delayedBudgetTreasury.registerSuccessAssertion(assertionId);

        assertEq(delayedBudgetTreasury.pendingSuccessAssertionId(), assertionId);
        assertEq(delayedBudgetTreasury.pendingSuccessAssertionAt(), assertionRegisteredAt);

        delayedGoalTreasury.setResolved(true);
        vm.prank(address(0xDEAD));
        delayedVault.markGoalResolved();

        _expectWithdrawLocked(delayedVault);

        vm.prank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        delayedVault.prepareUnderwriterWithdrawal(type(uint256).max);

        vm.warp(budgetResolvedAt);
        _fundEscrowForTargetSlash(delayedEscrow, TARGET_SLASH_WEIGHT);

        vm.expectRevert(IBudgetTreasury.SUCCESS_ASSERTION_PENDING.selector);
        delayedBudgetTreasury.resolveFailure();

        delayedBudgetTreasury.clearSuccessAssertion(assertionId);

        assertEq(delayedBudgetTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(delayedBudgetTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(delayedBudgetTreasury.reassertGraceUsed());
        assertEq(delayedBudgetTreasury.reassertGraceDeadline(), budgetResolvedAt + 1 days);

        uint256 stakedGoalBeforePrepare = delayedVault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforePrepare = delayedVault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        delayedBudgetTreasury.resolveFailure();

        assertTrue(delayedBudgetTreasury.resolved());
        assertEq(uint256(delayedBudgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(delayedEscrow.closed());

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
    }

    function test_realBudgetTreasury_goalResolvedBeforeActivation_prepareAllowsWithdrawWithCurrentCoverageOnly()
        public
    {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        bytes32 budgetRecipientId = keccak256("underwriting-real-budget-preactivation-withdraw");

        (
            StakeVault delayedVault,,
            PremiumEscrow delayedEscrow,
            BudgetStakeLedger delayedBudgetStakeLedger,
            BudgetTreasury delayedBudgetTreasury,,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStackWithRealBudget(goalStake, cobuildStake, budgetCoverage, budgetRecipientId);

        assertEq(delayedBudgetTreasury.activatedAt(), 0);
        assertEq(delayedBudgetStakeLedger.registeredBudgetCount(), 1);
        assertEq(
            delayedBudgetStakeLedger.userAllocatedStakeOnBudget(ALICE, address(delayedBudgetTreasury)), budgetCoverage
        );

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

    function test_realBudgetTreasury_goalResolvedBeforeActivation_withEscrowCheckpointedExposure_prepareRemainsBlocked()
        public
    {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        bytes32 budgetRecipientId = keccak256("underwriting-real-budget-preactivation-blocked");

        (
            StakeVault delayedVault,,
            PremiumEscrow delayedEscrow,
            BudgetStakeLedger delayedBudgetStakeLedger,
            BudgetTreasury delayedBudgetTreasury,,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStackWithRealBudget(goalStake, cobuildStake, budgetCoverage, budgetRecipientId);

        assertEq(delayedBudgetTreasury.activatedAt(), 0);
        assertEq(
            delayedBudgetStakeLedger.userAllocatedStakeOnBudget(ALICE, address(delayedBudgetTreasury)), budgetCoverage
        );

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

    function test_realBudgetTreasuryAndLedger_successPath_claimsPremiumThroughRealBudgetState() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        uint256 budgetCoverage = 100e18;
        uint256 premiumAmount = 45e18;
        bytes32 budgetRecipientId = keccak256("underwriting-real-budget-success-path");
        uint64 budgetActivatedAt = 10;
        uint64 budgetClosedAt = 30;

        (
            ,,
            PremiumEscrow delayedEscrow,
            BudgetStakeLedger delayedBudgetStakeLedger,
            BudgetTreasury delayedBudgetTreasury,
            SharedMockFlow delayedBudgetFlow,
            UnderwritingMockGoalTreasuryResolutionReporter delayedGoalTreasury
        ) = _deployDelayedEscrowStackWithRealBudget(goalStake, cobuildStake, budgetCoverage, budgetRecipientId);

        assertEq(
            delayedBudgetStakeLedger.userAllocatedStakeOnBudget(ALICE, address(delayedBudgetTreasury)), budgetCoverage
        );

        goalSuperToken.mint(address(delayedBudgetFlow), 2e18);

        vm.warp(budgetActivatedAt);
        delayedBudgetTreasury.sync();
        delayedEscrow.checkpoint(ALICE);

        assertEq(delayedBudgetTreasury.activatedAt(), budgetActivatedAt);
        assertEq(uint256(delayedBudgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));

        _distributeEscrowPremium(delayedEscrow, premiumAmount);
        delayedEscrow.checkpoint(ALICE);

        delayedGoalTreasury.setState(IGoalTreasury.GoalState.Succeeded);

        vm.warp(budgetClosedAt);
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.close(IBudgetTreasury.BudgetState.Succeeded, budgetActivatedAt, budgetClosedAt);

        vm.prank(ALICE);
        uint256 claimed = delayedEscrow.claim(PREMIUM_RECIPIENT);

        assertEq(claimed, premiumAmount);
        assertEq(goalSuperToken.balanceOf(PREMIUM_RECIPIENT), premiumAmount);
        assertEq(delayedBudgetStakeLedger.budgetTotalAllocatedStake(address(delayedBudgetTreasury)), budgetCoverage);
    }

    function test_realGoalAndBudget_successPath_claimsPremiumAfterRealAssertions() public {
        uint256 premiumAmount = 45e18;
        RealGoalBudgetEscrowStack memory stack =
            _deployActivatedRealGoalBudgetStack(keccak256("underwriting-real-goal-budget-success"));

        _distributeEscrowPremium(stack.escrow, premiumAmount);
        stack.escrow.checkpoint(ALICE);

        _resolveRealGoalSuccess(stack, keccak256("underwriting-real-goal-success-assertion"));
        _warpBudgetFundingWindow(stack.budgetTreasury);
        _resolveRealBudgetSuccess(stack, keccak256("underwriting-real-budget-success-assertion"));

        vm.prank(ALICE);
        uint256 claimed = stack.escrow.claim(PREMIUM_RECIPIENT);

        assertEq(claimed, premiumAmount);
        assertTrue(stack.vault.goalResolved());
        assertTrue(stack.escrow.closed());
        assertEq(uint8(stack.escrow.finalState()), uint8(IBudgetTreasury.BudgetState.Succeeded));
        assertEq(uint256(stack.goalTreasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertEq(uint256(stack.budgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertEq(goalSuperToken.balanceOf(PREMIUM_RECIPIENT), premiumAmount);
    }

    function test_realGoalAndBudget_successPath_prepareAndWithdrawReturnsFullPrincipalWithoutSlash() public {
        uint256 goalStake = 120e18;
        uint256 cobuildStake = 80e18;
        RealGoalBudgetEscrowStack memory stack =
            _deployActivatedRealGoalBudgetStack(keccak256("underwriting-real-goal-budget-success-withdraw"));

        _resolveRealGoalSuccess(stack, keccak256("underwriting-real-goal-success-withdraw-assertion"));
        _warpBudgetFundingWindow(stack.budgetTreasury);
        _resolveRealBudgetSuccess(stack, keccak256("underwriting-real-budget-success-withdraw-assertion"));

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        vm.prank(ALICE);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            stack.vault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, budgetCount);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertFalse(stack.escrow.slashed(ALICE));
        assertEq(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(stack.vault.stakedGoalOf(ALICE), goalStake);
        assertEq(stack.vault.stakedCobuildOf(ALICE), cobuildStake);
        assertEq(goalToken.balanceOf(ALICE), 0);
        assertEq(cobuildToken.balanceOf(ALICE), 0);

        vm.startPrank(ALICE);
        stack.vault.withdrawGoal(goalStake, ALICE);
        stack.vault.withdrawCobuild(cobuildStake, ALICE);
        vm.stopPrank();

        assertEq(stack.vault.stakedGoalOf(ALICE), 0);
        assertEq(stack.vault.stakedCobuildOf(ALICE), 0);
        assertEq(goalToken.balanceOf(ALICE), goalStake);
        assertEq(cobuildToken.balanceOf(ALICE), cobuildStake);
    }

    function test_realGoalAndBudget_goalSuccessThenBudgetFailure_prepareAndSlashUsesRealTerminalState() public {
        RealGoalBudgetEscrowStack memory stack =
            _deployActivatedRealGoalBudgetStack(keccak256("underwriting-real-goal-budget-failure"));

        _resolveRealGoalSuccess(stack, keccak256("underwriting-real-goal-for-failure-assertion"));

        _expectWithdrawLocked(stack.vault);
        _expectPrepareWithdrawalLocked(stack.vault);

        uint256 stakedGoalBeforePrepare = stack.vault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforePrepare = stack.vault.stakedCobuildOf(ALICE);

        vm.warp(stack.budgetTreasury.deadline() + 1);
        _fundEscrowForTargetSlash(stack.escrow, TARGET_SLASH_WEIGHT);
        stack.budgetTreasury.resolveFailure();

        assertTrue(stack.budgetTreasury.resolved());
        assertEq(uint256(stack.budgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(stack.escrow.closed());

        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        _prepareWithdrawalAndAssertSlash(stack, stakedGoalBeforePrepare, stakedCobuildBeforePrepare, fundingBefore);
    }

    function test_realGoalAndBudget_pendingBudgetSuccessAssertion_blocksWithdrawalUntilClearedThenFailed() public {
        RealGoalBudgetEscrowStack memory stack =
            _deployActivatedRealGoalBudgetStack(keccak256("underwriting-real-goal-budget-pending"));

        _resolveRealGoalSuccess(stack, keccak256("underwriting-real-goal-pending-assertion"));

        _expectWithdrawLocked(stack.vault);
        _expectPrepareWithdrawalLocked(stack.vault);

        _warpBudgetFundingWindow(stack.budgetTreasury);
        bytes32 assertionId = keccak256("underwriting-real-budget-pending-assertion");
        vm.prank(address(stack.budgetSuccessResolver));
        stack.budgetTreasury.registerSuccessAssertion(assertionId);

        vm.warp(stack.budgetTreasury.deadline() + 1);
        _fundEscrowForTargetSlash(stack.escrow, TARGET_SLASH_WEIGHT);

        vm.expectRevert(IBudgetTreasury.SUCCESS_ASSERTION_PENDING.selector);
        stack.budgetTreasury.resolveFailure();

        vm.prank(address(stack.budgetSuccessResolver));
        stack.budgetTreasury.clearSuccessAssertion(assertionId);

        uint256 stakedGoalBeforePrepare = stack.vault.stakedGoalOf(ALICE);
        uint256 stakedCobuildBeforePrepare = stack.vault.stakedCobuildOf(ALICE);
        uint256 fundingBefore = goalSuperToken.balanceOf(GOAL_FUNDING_TARGET);

        stack.budgetTreasury.resolveFailure();

        assertTrue(stack.budgetTreasury.reassertGraceUsed());
        assertTrue(stack.budgetTreasury.resolved());
        assertEq(uint256(stack.budgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));

        _prepareWithdrawalAndAssertSlash(stack, stakedGoalBeforePrepare, stakedCobuildBeforePrepare, fundingBefore);
    }

    function _deployDelayedEscrowStack(uint256 goalStake, uint256 cobuildStake, uint256 budgetCoverage)
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
        vm.prank(address(delayedGoalTreasury));
        delayedVault.setUnderwriterSlasher(address(delayedRouter));

        delayedBudgetTreasury = new UnderwritingMockBudgetTreasury(ISuperToken(address(goalSuperToken)));
        UnderwritingMockBudgetFlow delayedBudgetFlow = new UnderwritingMockBudgetFlow();
        delayedBudgetFlow.setManagerRewardPoolFlowRatePpm(BUDGET_PREMIUM_PPM);
        SharedMockSuperfluidPool delayedManagerRewardPool = new SharedMockSuperfluidPool();
        delayedBudgetFlow.setManagerRewardDistributionPool(address(delayedManagerRewardPool));
        delayedBudgetTreasury.setFlow(address(delayedBudgetFlow));
        UnderwritingMockGoalFlow delayedGoalFlow = new UnderwritingMockGoalFlow(ISuperToken(address(goalSuperToken)));
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
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.connectManagerRewardPool(address(delayedManagerRewardPool));
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
        vm.prank(address(delayedGoalTreasury));
        delayedVault.setUnderwriterSlasher(address(delayedRouter));

        delayedBudgetFlow = new UnderwritingTopologyAwareMockFlow(
            ISuperToken(address(goalSuperToken)), IAllocationStrategy(address(topologyStrategy))
        );
        delayedBudgetFlow.setParent(address(delayedGoalFlow));
        delayedBudgetFlow.setManagerRewardPoolFlowRatePpm(BUDGET_PREMIUM_PPM);
        SharedMockSuperfluidPool delayedManagerRewardPool = new SharedMockSuperfluidPool();
        delayedBudgetFlow.setManagerRewardDistributionPool(ISuperfluidPool(address(delayedManagerRewardPool)));

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
        vm.prank(address(delayedBudgetTreasury));
        delayedEscrow.connectManagerRewardPool(address(delayedManagerRewardPool));

        _setBudgetTopology(
            budgetRecipientId,
            BudgetStackTopology({
                childFlow: address(delayedBudgetFlow),
                budgetTreasury: address(delayedBudgetTreasury),
                premiumEscrow: address(delayedEscrow),
                strategy: address(topologyStrategy),
                allocationMechanism: address(0),
                allocationMechanismArbitrator: address(0)
            }),
            true
        );
        delayedBudgetStakeLedger.registerBudget(budgetRecipientId, address(delayedBudgetTreasury));

        if (budgetCoverage != 0) {
            bytes32[] memory recipientIds = new bytes32[](1);
            recipientIds[0] = budgetRecipientId;
            uint32[] memory scaled = new uint32[](1);
            scaled[0] = 1_000_000;

            vm.prank(address(delayedGoalFlow));
            delayedBudgetStakeLedger.checkpointAllocation(
                ALICE, 0, new bytes32[](0), new uint32[](0), budgetCoverage, recipientIds, scaled
            );
        }

        delayedRouter.setAuthorizedPremiumEscrow(address(delayedEscrow), true);
    }

    function _deployDelayedEscrowStackWithRealGoalAndBudget(
        uint256 goalStake,
        uint256 cobuildStake,
        uint256 budgetCoverage,
        bytes32 budgetRecipientId
    ) internal returns (RealGoalBudgetEscrowStack memory stack) {
        stack.goalFlow = new SharedMockFlow(ISuperToken(address(goalSuperToken)));
        stack.goalFlow.setRecipientAdmin(address(this));
        SharedMockSuperfluidPool goalDistributionPool = new SharedMockSuperfluidPool();
        goalDistributionPool.setTotalUnits(1);
        stack.goalFlow.setDistributionPool(ISuperfluidPool(address(goalDistributionPool)));

        stack.goalAssertionOracle = new TreasuryMockOptimisticOracleV3();
        stack.goalSuccessResolver = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(stack.goalAssertionOracle)),
            IERC20(address(goalToken)),
            address(0xAA11CE),
            keccak256("underwriting-real-goal-domain")
        );
        stack.budgetAssertionOracle = new TreasuryMockOptimisticOracleV3();
        stack.budgetSuccessResolver = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(stack.budgetAssertionOracle)),
            IERC20(address(goalToken)),
            address(0xBB0B),
            keccak256("underwriting-real-budget-domain")
        );

        GoalTreasury goalTreasuryImplementation = new GoalTreasury();
        stack.goalTreasury = GoalTreasury(Clones.clone(address(goalTreasuryImplementation)));
        stack.budgetStakeLedger = new BudgetStakeLedger(address(stack.goalTreasury));
        stack.vault = new StakeVault(
            address(stack.goalTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(rulesets)),
            GOAL_REVNET_ID,
            18
        );

        goalToken.mint(ALICE, goalStake);
        cobuildToken.mint(ALICE, cobuildStake);

        vm.startPrank(ALICE);
        goalToken.approve(address(stack.vault), type(uint256).max);
        cobuildToken.approve(address(stack.vault), type(uint256).max);
        stack.vault.depositGoal(goalStake);
        stack.vault.depositCobuild(cobuildStake);
        vm.stopPrank();

        stack.router = new UnderwriterSlasherRouter(
            IStakeVault(address(stack.vault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            GOAL_FUNDING_TARGET
        );

        stack.budgetFlow = new UnderwritingTopologyAwareMockFlow(
            ISuperToken(address(goalSuperToken)), IAllocationStrategy(address(topologyStrategy))
        );
        stack.budgetFlow.setParent(address(stack.goalFlow));
        stack.budgetFlow.setManagerRewardPoolFlowRatePpm(BUDGET_PREMIUM_PPM);
        SharedMockSuperfluidPool delayedManagerRewardPool = new SharedMockSuperfluidPool();
        stack.budgetFlow.setManagerRewardDistributionPool(ISuperfluidPool(address(delayedManagerRewardPool)));

        BudgetTreasury budgetTreasuryImplementation = new BudgetTreasury();
        stack.budgetTreasury = BudgetTreasury(Clones.clone(address(budgetTreasuryImplementation)));

        PremiumEscrow escrowImplementation = new PremiumEscrow();
        stack.escrow = PremiumEscrow(Clones.clone(address(escrowImplementation)));

        stack.goalFlow.setFlowOperator(address(stack.goalTreasury));
        stack.goalFlow.setSweeper(address(stack.goalTreasury));
        stack.budgetFlow.setFlowOperator(address(stack.budgetTreasury));
        stack.budgetFlow.setSweeper(address(stack.budgetTreasury));

        stack.goalTreasury
            .initialize(
                address(this),
                IGoalTreasury.GoalConfig({
                    flow: address(stack.goalFlow),
                    stakeVault: address(stack.vault),
                    jurorSlasher: address(this),
                    underwriterSlasher: address(stack.router),
                    budgetStakeLedger: address(stack.budgetStakeLedger),
                    hook: address(goalHook),
                    goalRulesets: address(rulesets),
                    goalRevnetId: GOAL_REVNET_ID,
                    minRaiseDeadline: uint64(block.timestamp + 3 days),
                    minRaise: 100e18,
                    budgetPremiumPpm: BUDGET_PREMIUM_PPM,
                    budgetSlashPpm: BUDGET_SLASH_PPM,
                    successResolver: address(stack.goalSuccessResolver),
                    successAssertionLiveness: uint64(1 days),
                    successAssertionBond: 10e18,
                    successOracleSpecHash: keccak256("underwriting-real-goal-success-oracle-spec"),
                    successAssertionPolicyHash: keccak256("underwriting-real-goal-success-policy")
                })
            );

        stack.budgetTreasury
            .initialize(
                address(this),
                IBudgetTreasury.BudgetConfig({
                    flow: address(stack.budgetFlow),
                    premiumEscrow: address(stack.escrow),
                    fundingDeadline: uint64(block.timestamp + 20),
                    executionDuration: 20,
                    activationThreshold: 1e18,
                    runwayCap: 0,
                    successResolver: address(stack.budgetSuccessResolver),
                    successAssertionLiveness: uint64(1 days),
                    successAssertionBond: 10e18,
                    successOracleSpecHash: keccak256("underwriting-real-budget-success-oracle-spec"),
                    successAssertionPolicyHash: keccak256("underwriting-real-budget-success-policy")
                })
            );

        stack.escrow
            .initialize(
                address(stack.budgetTreasury),
                address(stack.budgetStakeLedger),
                address(stack.goalFlow),
                address(stack.router),
                BUDGET_SLASH_PPM
            );
        vm.prank(address(stack.budgetTreasury));
        stack.escrow.connectManagerRewardPool(address(delayedManagerRewardPool));

        _setBudgetTopology(
            budgetRecipientId,
            BudgetStackTopology({
                childFlow: address(stack.budgetFlow),
                budgetTreasury: address(stack.budgetTreasury),
                premiumEscrow: address(stack.escrow),
                strategy: address(topologyStrategy),
                allocationMechanism: address(0),
                allocationMechanismArbitrator: address(0)
            }),
            true
        );
        stack.budgetStakeLedger.registerBudget(budgetRecipientId, address(stack.budgetTreasury));
        if (budgetCoverage != 0) {
            bytes32[] memory recipientIds = new bytes32[](1);
            recipientIds[0] = budgetRecipientId;
            uint32[] memory scaled = new uint32[](1);
            scaled[0] = 1_000_000;

            vm.prank(address(stack.goalFlow));
            stack.budgetStakeLedger
                .checkpointAllocation(ALICE, 0, new bytes32[](0), new uint32[](0), budgetCoverage, recipientIds, scaled);
        }

        stack.router.setAuthorizedPremiumEscrow(address(stack.escrow), true);
    }

    function _deployActivatedRealGoalBudgetStack(bytes32 budgetRecipientId)
        internal
        returns (RealGoalBudgetEscrowStack memory stack)
    {
        stack = _deployDelayedEscrowStackWithRealGoalAndBudget(120e18, 80e18, 100e18, budgetRecipientId);
        _activateRealGoal(stack, 100e18);
        _activateRealBudget(stack, 10, 2e18);
        stack.escrow.checkpoint(ALICE);
    }

    function _activateRealGoal(RealGoalBudgetEscrowStack memory stack, uint256 amount) internal {
        goalSuperToken.mint(address(stack.goalFlow), amount);
        vm.prank(address(goalHook));
        assertTrue(stack.goalTreasury.recordHookFunding(amount));
        stack.goalTreasury.sync();
        assertEq(uint256(stack.goalTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
    }

    function _activateRealBudget(RealGoalBudgetEscrowStack memory stack, uint64 activatedAt, uint256 amount) internal {
        goalSuperToken.mint(address(stack.budgetFlow), amount);
        vm.warp(activatedAt);
        stack.budgetTreasury.sync();
        assertEq(stack.budgetTreasury.activatedAt(), activatedAt);
        assertEq(uint256(stack.budgetTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
    }

    function _warpBudgetFundingWindow(BudgetTreasury budgetTreasury_) internal {
        vm.warp(budgetTreasury_.fundingDeadline() + 1);
    }

    function _expectPrepareWithdrawalLocked(StakeVault vault) internal {
        vm.prank(ALICE);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        vault.prepareUnderwriterWithdrawal(type(uint256).max);
    }

    function _resolveRealGoalSuccess(RealGoalBudgetEscrowStack memory stack, bytes32 assertionId) internal {
        vm.prank(address(stack.goalSuccessResolver));
        stack.goalTreasury.registerSuccessAssertion(assertionId);
        _setTruthfulAssertion(
            stack.goalAssertionOracle,
            stack.goalSuccessResolver,
            assertionId,
            stack.goalTreasury.pendingSuccessAssertionAt(),
            stack.goalTreasury.successAssertionLiveness(),
            stack.goalTreasury.successAssertionBond()
        );
        vm.prank(address(stack.goalSuccessResolver));
        stack.goalTreasury.resolveSuccess();
    }

    function _resolveRealBudgetSuccess(RealGoalBudgetEscrowStack memory stack, bytes32 assertionId) internal {
        vm.prank(address(stack.budgetSuccessResolver));
        stack.budgetTreasury.registerSuccessAssertion(assertionId);
        _setTruthfulAssertion(
            stack.budgetAssertionOracle,
            stack.budgetSuccessResolver,
            assertionId,
            stack.budgetTreasury.pendingSuccessAssertionAt(),
            stack.budgetTreasury.successAssertionLiveness(),
            stack.budgetTreasury.successAssertionBond()
        );
        vm.prank(address(stack.budgetSuccessResolver));
        stack.budgetTreasury.resolveSuccess();
    }

    function _setTruthfulAssertion(
        TreasuryMockOptimisticOracleV3 oracle,
        TreasuryMockUmaResolverConfig resolver,
        bytes32 assertionId,
        uint64 assertedAt,
        uint64 liveness,
        uint256 bond
    ) internal {
        oracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: address(resolver),
                    escalationManager: resolver.escalationManager()
                }),
                asserter: address(resolver),
                assertionTime: assertedAt,
                settled: true,
                currency: resolver.assertionCurrency(),
                expirationTime: assertedAt + liveness,
                settlementResolution: true,
                domainId: resolver.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: bond,
                callbackRecipient: address(resolver),
                disputer: address(0)
            })
        );
    }

    function _prepareWithdrawalAndAssertSlash(
        RealGoalBudgetEscrowStack memory stack,
        uint256 stakedGoalBeforePrepare,
        uint256 stakedCobuildBeforePrepare,
        uint256 fundingBefore
    ) internal {
        vm.prank(ALICE);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            stack.vault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, budgetCount);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertTrue(stack.escrow.slashed(ALICE));
        assertLt(stack.vault.stakedGoalOf(ALICE), stakedGoalBeforePrepare);
        assertLt(stack.vault.stakedCobuildOf(ALICE), stakedCobuildBeforePrepare);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
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
    ) internal {
        assertEq(slashWeight, 20e18);
        assertLt(delayedVault.stakedGoalOf(ALICE), stakedGoalBeforeSlash);
        assertLt(delayedVault.stakedCobuildOf(ALICE), stakedCobuildBeforeSlash);
        assertGt(goalSuperToken.balanceOf(GOAL_FUNDING_TARGET), fundingBefore);
        assertEq(goalToken.balanceOf(address(delayedRouter)), 0);
        assertEq(cobuildToken.balanceOf(address(delayedRouter)), 0);
        assertEq(goalToken.balanceOf(ALICE), 0);
        assertEq(cobuildToken.balanceOf(ALICE), 0);
    }

    function _setGoalFlowCreditForTargetSlash(PremiumEscrow escrow_, uint256 targetSlashWeight) internal {
        address budgetFlow_ = escrow_.budgetFlow();
        (bool ok,) = escrow_.goalFlow()
            .call(abi.encodeWithSignature("setTotalReceivedByMember(address,uint256)", budgetFlow_, targetSlashWeight));
        require(ok, "_setGoalFlowCreditForTargetSlash: setTotalReceivedByMember failed");
    }

    function _fundEscrowForTargetSlash(PremiumEscrow escrow_, uint256 targetSlashWeight) internal {
        _setGoalFlowCreditForTargetSlash(escrow_, targetSlashWeight);
        escrow_.checkpoint(ALICE);
    }

    function _setGoalFlowCreditForTargetSlashWithoutCheckpoint(PremiumEscrow escrow_, uint256 targetSlashWeight)
        internal
    {
        _setGoalFlowCreditForTargetSlash(escrow_, targetSlashWeight);
    }

    function _distributeEscrowPremium(PremiumEscrow escrow_, uint256 amount) internal {
        SharedMockSuperfluidPool(address(escrow_.managerRewardPool()))
            .increaseTotalAmountReceivedByMember(address(escrow_), amount);
        goalSuperToken.mint(address(escrow_), amount);
    }
}

contract UnderwritingCoverageCapIntegrationTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 9001;
    bytes32 internal constant ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");
    bytes32 internal constant TERMINAL_BURN_MEMO_HASH = keccak256(bytes("GOAL_TERMINAL_RESIDUAL_BURN"));
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
        treasury.initialize(
            address(this), _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger))
        );
    }

    function test_initialize_wiresConfiguredSlashersOnStakeVault() public view {
        assertEq(stakeVault.jurorSlasher(), address(successResolverConfig));
        assertEq(stakeVault.underwriterSlasher(), address(hook));
    }

    function test_goalTreasuryCloneInitialize_emitsExpandedGoalConfiguredEvent() public {
        GoalTreasury candidateTreasury = _cloneGoalTreasuryWithPredictedAddress();
        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.jurorSlasher = address(assertionOracle);
        (JBRuleset memory terminal,) = rulesets.latestQueuedOf(config.goalRevnetId);

        vm.expectEmit(true, false, false, true, address(candidateTreasury));
        emit IGoalTreasury.GoalConfigured(
            address(this),
            config.flow,
            config.stakeVault,
            config.budgetStakeLedger,
            config.hook,
            config.goalRulesets,
            config.goalRevnetId,
            config.minRaiseDeadline,
            uint64(terminal.start),
            config.minRaise,
            config.jurorSlasher,
            config.underwriterSlasher,
            config.successResolver,
            address(stakeVault.goalToken()),
            address(stakeVault.cobuildToken())
        );

        candidateTreasury.initialize(address(this), config);
        assertEq(candidateTreasury.successResolver(), config.successResolver);
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
            IJBDirectory(address(directory)), IGoalTreasury(address(treasury)), IFlow(address(flow)), GOAL_REVNET_ID
        );
    }

    function test_goalRevnetSplitHookCloneInitialize_setsCriticalState() public {
        GoalRevnetSplitHook splitHookImplementation = new GoalRevnetSplitHook();
        GoalRevnetSplitHook splitHookClone =
            GoalRevnetSplitHook(payable(Clones.clone(address(splitHookImplementation))));

        splitHookClone.initialize(
            IJBDirectory(address(directory)), IGoalTreasury(address(treasury)), IFlow(address(flow)), GOAL_REVNET_ID
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
        GoalRevnetSplitHook splitHookClone =
            GoalRevnetSplitHook(payable(Clones.clone(address(splitHookImplementation))));

        splitHookClone.initialize(
            IJBDirectory(address(directory)), IGoalTreasury(address(treasury)), IFlow(address(flow)), GOAL_REVNET_ID
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        splitHookClone.initialize(
            IJBDirectory(address(directory)), IGoalTreasury(address(treasury)), IFlow(address(flow)), GOAL_REVNET_ID
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

    function test_sync_characterizesZeroUnitsRestartDeadZone_outflowRemainsZeroUntilNextSyncAfterUnitsRestore() public {
        distributionPool.setTotalUnits(80);

        superToken.mint(address(flow), 100e18);
        vm.prank(address(hook));
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        int96 rateBeforeClamp = flow.targetOutflowRate();
        assertGt(rateBeforeClamp, 0);
        assertEq(treasury.targetFlowRate(), rateBeforeClamp);

        distributionPool.setTotalUnits(0);
        treasury.sync();

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);

        // Simulate budget re-enable via restored pool units (for example after credit headroom returns).
        distributionPool.setTotalUnits(80);

        int96 unclampedTarget = treasury.targetFlowRate();
        assertGt(unclampedTarget, 0);

        // Cached outflow is zero, so refresh is a no-op until treasury sync applies a new target.
        flow.refreshTargetOutflowRate();
        assertEq(flow.targetOutflowRate(), 0);

        treasury.sync();

        assertEq(treasury.targetFlowRate(), unclampedTarget);
        assertEq(flow.targetOutflowRate(), unclampedTarget);
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_processHookSplit_afterTerminalization_burnsEntireAmount() public {
        vm.warp(block.timestamp + 4 days);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));

        uint256 sourceAmount = 15e18;
        underlyingToken.mint(address(treasury), sourceAmount);

        vm.prank(address(hook));
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), sourceAmount);

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

    function test_sync_atDeadline_flowStopFailure_emitsTerminalFlowStopFailed() public {
        distributionPool.setTotalUnits(40);
        _activateGoal();
        flow.setShouldRevertSetFlowRate(true);

        vm.warp(treasury.deadline());
        vm.expectEmit(false, false, false, true, address(treasury));
        emit IGoalTreasury.TerminalFlowStopFailed(abi.encodeWithSelector(SharedMockFlow.SET_FLOW_RATE_REVERT.selector));
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_atDeadline_stakeVaultResolveFailure_emitsTerminalStakeVaultResolutionFailed() public {
        distributionPool.setTotalUnits(40);
        _activateGoal();
        stakeVault.setShouldRevertMark(true);

        vm.warp(treasury.deadline());
        vm.expectEmit(false, false, false, true, address(treasury));
        emit IGoalTreasury.TerminalStakeVaultResolutionFailed(abi.encodeWithSelector(
                SharedMockStakeVault.MARK_REVERT.selector
            ));
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertFalse(stakeVault.goalResolved());
    }

    function test_sync_atDeadline_residualSettlementFailure_emitsTerminalResidualSettlementFailed() public {
        uint256 residual = 9e18;
        controller.setShouldRevertBurn(true);
        superToken.mint(address(flow), residual);

        vm.warp(block.timestamp + 4 days);
        vm.expectEmit(false, false, false, true, address(treasury));
        emit IGoalTreasury.TerminalResidualSettlementFailed(abi.encodeWithSelector(
                UnderwritingMockController.BURN_REVERT.selector
            ));
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertEq(superToken.balanceOf(address(flow)), residual);
        assertEq(controller.burnCallCount(), 0);
    }

    function test_processHookSplit_deferredFundingSettlementFailure_emitsTerminalDeferredHookFundingSettlementFailed()
        public
    {
        uint256 deferredAmount = 15e18;

        vm.warp(block.timestamp + 4 days);
        underlyingToken.mint(address(treasury), deferredAmount);
        vm.prank(address(hook));
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), deferredAmount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.Deferred));
        assertEq(superTokenAmount, deferredAmount);
        assertEq(burnAmount, 0);
        assertEq(treasury.deferredHookSuperTokenAmount(), deferredAmount);

        controller.setShouldRevertBurn(true);

        vm.expectEmit(false, false, false, true, address(treasury));
        emit IGoalTreasury.TerminalDeferredHookFundingSettlementFailed(abi.encodeWithSelector(
                UnderwritingMockController.BURN_REVERT.selector
            ));
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertEq(treasury.deferredHookSuperTokenAmount(), deferredAmount);
        assertEq(controller.burnCallCount(), 0);
    }

    function test_sync_falseAssertionFinalizeCleanupRevert_emitsSuccessAssertionFinalizeFailed() public {
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
        emit IGoalTreasury.SuccessAssertionFinalizeFailed(
            assertionId, abi.encodeWithSelector(TreasuryMockUmaResolverConfigWithFinalize.FINALIZE_REVERT.selector)
        );
        treasury.sync();

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(treasury.reassertGraceUsed());
    }

    function test_clearSuccessAssertion_afterDeadline_activatesGoalReassertGrace() public {
        distributionPool.setTotalUnits(40);
        _activateGoal();

        bytes32 assertionId = keccak256("goal-clear-after-deadline");
        vm.prank(address(successResolverConfig));
        treasury.registerSuccessAssertion(assertionId);

        vm.warp(treasury.deadline());
        vm.expectEmit(true, false, false, false, address(treasury));
        emit IGoalTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(treasury));
        emit IGoalTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        vm.prank(address(successResolverConfig));
        treasury.clearSuccessAssertion(assertionId);

        _assertGoalFailClosedGraceState(treasury);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_resolverConfigReadFailure_emitsFailClosedTelemetry()
        public
    {
        UnderwritingRevertingOptimisticOracleResolverConfig revertingResolverConfig = new UnderwritingRevertingOptimisticOracleResolverConfig(
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

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_oracleAddressZero_emitsFailClosedTelemetry()
        public
    {
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
            address(this),
            _defaultGoalConfig(address(revertingRulesets), address(invalidHook), address(budgetStakeLedger))
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
            address(this),
            _defaultGoalConfig(address(revertingRulesets), address(invalidHook), address(budgetStakeLedger))
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
            jurorSlasher: address(successResolverConfig),
            underwriterSlasher: hookAddr,
            budgetStakeLedger: budgetStakeLedgerAddr,
            hook: hookAddr,
            goalRulesets: rulesetsAddr,
            goalRevnetId: GOAL_REVNET_ID,
            minRaiseDeadline: uint64(block.timestamp + 3 days),
            minRaise: 100e18,
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

    contract UnderwritingTopologyAwareMockFlow is SharedMockFlow {
        IAllocationStrategy[] internal _strategies;

        constructor(ISuperToken superToken_, IAllocationStrategy strategy_) SharedMockFlow(superToken_) {
            _strategies.push(strategy_);
        }

        function strategies() external view returns (IAllocationStrategy[] memory strategies_) {
            strategies_ = _strategies;
        }
    }

    contract UnderwritingBudgetTopologyStrategy {}

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
        uint64 public executionDuration = 20;
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

        function controller() external pure returns (address) {
            return address(0);
        }

        function setExecutionDuration(uint64 executionDuration_) external {
            executionDuration = executionDuration_;
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
        mapping(address => uint256) internal _totalReceivedByMember;

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

        function setTotalReceivedByMember(address member, uint256 amount) external {
            _totalReceivedByMember[member] = amount;
        }

        function getTotalReceivedByMember(address member) external view returns (uint256) {
            return _totalReceivedByMember[member];
        }
    }

    contract UnderwritingMockGoalTreasuryResolutionReporter {
        bool public resolved;
        address public immutable authority;
        address public immutable budgetStakeLedger;
        address public flow;
        IGoalTreasury.GoalState internal _state = IGoalTreasury.GoalState.Succeeded;
        uint256 public settleLateResidualCalls;

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

        function setState(IGoalTreasury.GoalState state_) external {
            _state = state_;
        }

        function state() external view returns (IGoalTreasury.GoalState) {
            return _state;
        }

        function settleLateResidual() external {
            settleLateResidualCalls += 1;
        }
    }

    contract UnderwritingMockBudgetFlow {
        uint32 internal _managerRewardPoolFlowRatePpm;
        address internal _managerRewardDistributionPool;

        function setManagerRewardPoolFlowRatePpm(uint32 ppm_) external {
            _managerRewardPoolFlowRatePpm = ppm_;
        }

        function managerRewardPoolFlowRatePpm() external view returns (uint32) {
            return _managerRewardPoolFlowRatePpm;
        }

        function setManagerRewardDistributionPool(address pool_) external {
            _managerRewardDistributionPool = pool_;
        }

        function managerRewardDistributionPool() external view returns (ISuperfluidPool) {
            return ISuperfluidPool(_managerRewardDistributionPool);
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

        function latestQueuedOf(uint256 projectId)
            external
            view
            returns (JBRuleset memory ruleset, JBApprovalStatus status)
        {
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
        error BURN_REVERT();

        UnderwritingMockTokens internal _tokens;
        uint256 internal _burnCallCount;
        uint256 internal _lastBurnProjectId;
        uint256 internal _lastBurnAmount;
        bytes32 internal _lastBurnMemoHash;
        bool internal _shouldRevertBurn;

        constructor(UnderwritingMockTokens tokens_) {
            _tokens = tokens_;
        }

        function TOKENS() external view returns (UnderwritingMockTokens) {
            return _tokens;
        }

        function setShouldRevertBurn(bool shouldRevertBurn_) external {
            _shouldRevertBurn = shouldRevertBurn_;
        }

        function burnTokensOf(address, uint256 projectId, uint256 tokenCount, string calldata memo) external {
            if (_shouldRevertBurn) revert BURN_REVERT();
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

        function pay(
            uint256,
            address token,
            uint256 amount,
            address beneficiary,
            uint256,
            string calldata,
            bytes calldata
        ) external returns (uint256 beneficiaryTokenCount) {
            require(token == address(cobuildToken), "INVALID_TOKEN");
            payCallCount += 1;
            cobuildToken.transferFrom(msg.sender, address(this), amount);
            goalToken.transfer(beneficiary, amount);
            return amount;
        }
    }
