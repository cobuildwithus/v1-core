// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

contract CobuildSplitHookTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 77;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;
    uint256 internal constant ROUTING_SCORE_HALF_LIFE = 30 days;
    uint256 internal constant GOAL_ID_ONE = 101;
    uint256 internal constant GOAL_ID_TWO = 202;

    address internal controller = makeAddr("controller");
    address internal routeSetter;
    address internal beneficiary = makeAddr("beneficiary");

    CobuildSplitHookMockToken internal communityToken;
    CobuildSplitHookMockDirectory internal directory;
    CobuildSplitHookMockGoalTerminal internal goalTerminalOne;
    CobuildSplitHookMockGoalTerminal internal goalTerminalTwo;
    CobuildSplitHookMockGoalTreasury internal goalTreasuryOne;
    CobuildSplitHookMockGoalTreasury internal goalTreasuryTwo;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildSplitHookMockGoalRegistry internal goalRegistry;
    CobuildSplitHook internal hook;

    function setUp() public {
        routeSetter = address(new CobuildSplitHookRouteSetterStub());
        communityToken = new CobuildSplitHookMockToken("Community", "COMM");
        directory = new CobuildSplitHookMockDirectory();
        goalTerminalOne = new CobuildSplitHookMockGoalTerminal(communityToken);
        goalTerminalTwo = new CobuildSplitHookMockGoalTerminal(communityToken);
        goalTreasuryOne = new CobuildSplitHookMockGoalTreasury(GOAL_ID_ONE);
        goalTreasuryTwo = new CobuildSplitHookMockGoalTreasury(GOAL_ID_TWO);
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        goalDeploymentRegistry.registerGoal(GOAL_ID_ONE, address(goalTreasuryOne));
        goalDeploymentRegistry.registerGoal(GOAL_ID_TWO, address(goalTreasuryTwo));
        goalRegistry = new CobuildSplitHookMockGoalRegistry(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );

        hook = _deployHook(goalRegistry);

        directory.setController(COMMUNITY_REVNET_ID, controller);
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(communityToken), IJBTerminal(address(goalTerminalOne)));
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(goalTerminalTwo)));

        goalRegistry.setGoalSelectable(GOAL_ID_ONE, true);
        goalRegistry.setGoalSelectable(GOAL_ID_TWO, true);
    }

    function test_initialize_revertsWhenRouteSetterIsNotContract() public {
        address eoaRouteSetter = makeAddr("route-setter-eoa");
        CobuildSplitHook implementation = new CobuildSplitHook();
        CobuildSplitHook deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.NOT_A_CONTRACT.selector, eoaRouteSetter));
        deployedHook.initialize(
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            eoaRouteSetter,
            ICommunityGoalRegistry(address(goalRegistry))
        );
    }

    function test_initialize_revertsWhenGoalRegistryCommunityMismatch() public {
        CobuildSplitHookMockGoalRegistry mismatchedRegistry = new CobuildSplitHookMockGoalRegistry(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID + 1,
            address(communityToken)
        );

        CobuildSplitHook implementation = new CobuildSplitHook();
        CobuildSplitHook deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildSplitHook.INVALID_PROJECT.selector, COMMUNITY_REVNET_ID, COMMUNITY_REVNET_ID + 1
            )
        );
        deployedHook.initialize(
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            routeSetter,
            ICommunityGoalRegistry(address(mismatchedRegistry))
        );
    }

    function test_initialize_revertsWhenGoalRegistryTokenMismatch() public {
        CobuildSplitHookMockToken wrongToken = new CobuildSplitHookMockToken("Wrong", "WRONG");
        CobuildSplitHookMockGoalRegistry mismatchedRegistry = new CobuildSplitHookMockGoalRegistry(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(wrongToken)
        );

        CobuildSplitHook implementation = new CobuildSplitHook();
        CobuildSplitHook deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildSplitHook.INVALID_SOURCE_TOKEN.selector, address(communityToken), address(wrongToken)
            )
        );
        deployedHook.initialize(
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            routeSetter,
            ICommunityGoalRegistry(address(mismatchedRegistry))
        );
    }

    function test_initialize_revertsWhenGoalRegistryDirectoryMismatch() public {
        CobuildSplitHookMockDirectory mismatchedDirectory = new CobuildSplitHookMockDirectory();
        CobuildSplitHookMockGoalRegistry mismatchedRegistry = new CobuildSplitHookMockGoalRegistry(
            IJBDirectory(address(mismatchedDirectory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );

        CobuildSplitHook implementation = new CobuildSplitHook();
        CobuildSplitHook deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildSplitHook.INVALID_DIRECTORY.selector, address(directory), address(mismatchedDirectory)
            )
        );
        deployedHook.initialize(
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            routeSetter,
            ICommunityGoalRegistry(address(mismatchedRegistry))
        );
    }

    function test_processSplitWith_consumesPendingRoute_andRecordsRoutingScores() public {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 100e18);

        vm.prank(controller);
        hook.processSplitWith(_context(100e18));

        assertFalse(hook.hasPendingRoute());
        assertEq(goalTerminalOne.totalReceived(), 25e18);
        assertEq(goalTerminalTwo.totalReceived(), 75e18);
        assertEq(goalTerminalOne.lastBeneficiary(), beneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), beneficiary);
        assertEq(communityToken.balanceOf(address(hook)), 0);
        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 25e18);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 75e18);
        assertEq(hook.currentRoutingMass(), 100e18);
    }

    function test_processSplitWith_defersDirectPayEvenWhenHistoricalRouteExists() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        communityToken.mint(address(hook), 50e18);

        vm.prank(controller);
        hook.processSplitWith(_context(50e18));

        assertEq(goalTerminalOne.totalReceived(), 40e18);
        assertEq(goalTerminalTwo.totalReceived(), 60e18);
        assertEq(hook.historicalBacklogAmount(), 50e18);
        assertEq(communityToken.balanceOf(address(hook)), 50e18);
        assertEq(hook.currentRoutingMass(), 100e18);
    }

    function test_processSplitWith_routesOnlyPendingExplicitDelta_andDefersSnapshottedBacklog() public {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 100e18);

        vm.prank(controller);
        hook.processSplitWith(_context(100e18));

        assertFalse(hook.hasPendingRoute());
        assertEq(goalTerminalOne.totalReceived(), 15e18);
        assertEq(goalTerminalTwo.totalReceived(), 45e18);
        assertEq(goalTerminalOne.lastBeneficiary(), beneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), beneficiary);
        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 15e18);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 45e18);
        assertEq(hook.currentRoutingMass(), 60e18);
        assertEq(hook.historicalBacklogAmount(), 40e18);
        assertEq(communityToken.balanceOf(address(hook)), 40e18);
    }

    function test_processSplitWith_consumesPendingRoute_intoBacklogWhenSnapshotMatchesAmount() public {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        assertFalse(hook.hasPendingRoute());
        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(goalTerminalTwo.totalReceived(), 0);
        assertEq(hook.historicalBacklogAmount(), 40e18);
        assertEq(communityToken.balanceOf(address(hook)), 40e18);
        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 0);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 0);
        assertEq(hook.currentRoutingMass(), 0);
    }

    function test_routingScoreOf_decaysByHalfEachSeason() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        vm.warp(block.timestamp + ROUTING_SCORE_HALF_LIFE);

        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 12_500_000_000_000_000_000);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 37_500_000_000_000_000_000);
        assertEq(hook.currentRoutingMass(), 50e18);
    }

    function test_processSplitWith_addsToDecayedRoutingScore() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        vm.warp(block.timestamp + ROUTING_SCORE_HALF_LIFE);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        communityToken.mint(address(hook), 20e18);

        vm.prank(controller);
        hook.processSplitWith(_context(20e18));

        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 32_500_000_000_000_000_000);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 37_500_000_000_000_000_000);
        assertEq(hook.currentRoutingMass(), 70e18);
    }

    function test_routingScoreOf_decaysAtGlobalSeasonBoundary_evenAfterSameSeasonHeartbeat() public {
        _seedRoutingScores(120e18, 1, 3, beneficiary);

        vm.warp(ROUTING_SCORE_HALF_LIFE - 1);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        communityToken.mint(address(hook), 2e18);

        vm.prank(controller);
        hook.processSplitWith(_context(2e18));

        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 32e18);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 90e18);
        assertEq(hook.currentRoutingMass(), 122e18);

        vm.warp(ROUTING_SCORE_HALF_LIFE);

        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 16e18);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 45e18);
        assertEq(hook.currentRoutingMass(), 61e18);
    }

    function test_flushHistoricalBacklog_routesDeferredBalanceUsingHistoricalGoalTreasuries() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        assertEq(hook.historicalBacklogAmount(), 40e18);
        assertEq(goalTerminalOne.totalReceived(), 40e18);
        assertEq(goalTerminalTwo.totalReceived(), 60e18);

        uint256 routedAmount = hook.flushHistoricalBacklog(2);

        assertEq(routedAmount, 40e18);
        assertEq(hook.historicalBacklogAmount(), 0);
        assertEq(goalTerminalOne.totalReceived(), 56e18);
        assertEq(goalTerminalTwo.totalReceived(), 84e18);
        assertEq(goalTerminalOne.lastBeneficiary(), address(goalTreasuryOne));
        assertEq(goalTerminalTwo.lastBeneficiary(), address(goalTreasuryTwo));
        assertEq(communityToken.balanceOf(address(hook)), 0);
    }

    function test_flushHistoricalBacklog_pagesAcrossGoalsAndTracksProgress() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        uint256 firstPageAmount = hook.flushHistoricalBacklog(1);

        assertEq(firstPageAmount, 16e18);
        assertEq(hook.historicalBacklogAmount(), 24e18);
        assertEq(goalTerminalOne.totalReceived(), 56e18);
        assertEq(goalTerminalTwo.totalReceived(), 60e18);

        ICobuildSplitHook.HistoricalBacklogProgressView memory progress = hook.historicalBacklogProgress();
        assertTrue(progress.active);
        assertEq(progress.epoch, 1);
        assertEq(progress.remainingAmount, 24e18);
        assertEq(progress.processedGoalCount, 1);

        uint256 secondPageAmount = hook.flushHistoricalBacklog(1);

        assertEq(secondPageAmount, 24e18);
        assertEq(hook.historicalBacklogAmount(), 0);
        assertEq(goalTerminalOne.totalReceived(), 56e18);
        assertEq(goalTerminalTwo.totalReceived(), 84e18);

        progress = hook.historicalBacklogProgress();
        assertFalse(progress.active);
        assertEq(progress.remainingAmount, 0);
        assertEq(progress.processedGoalCount, 0);
    }

    function test_flushHistoricalBacklog_resetsPaginationWhenNewBacklogArrives() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        assertEq(hook.flushHistoricalBacklog(1), 16e18);
        assertEq(hook.historicalBacklogAmount(), 24e18);

        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        hook.processSplitWith(_context(10e18));

        ICobuildSplitHook.HistoricalBacklogProgressView memory progress = hook.historicalBacklogProgress();
        assertFalse(progress.active);
        assertEq(hook.historicalBacklogAmount(), 34e18);

        uint256 restartedPageAmount = hook.flushHistoricalBacklog(1);

        assertEq(restartedPageAmount, 13_600_000_000_000_000_000);
        assertEq(hook.historicalBacklogAmount(), 20_400_000_000_000_000_000);
        assertEq(goalTerminalOne.totalReceived(), 69_600_000_000_000_000_000);
        assertEq(goalTerminalTwo.totalReceived(), 60e18);

        progress = hook.historicalBacklogProgress();
        assertTrue(progress.active);
        assertEq(progress.epoch, 2);
        assertEq(progress.remainingAmount, 20_400_000_000_000_000_000);
        assertEq(progress.processedGoalCount, 1);
    }

    function test_flushHistoricalBacklog_resetsPaginationWhenExplicitHistoryChanges() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        assertEq(hook.flushHistoricalBacklog(1), 16e18);
        assertEq(hook.historicalBacklogAmount(), 24e18);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 20e18);

        vm.prank(controller);
        hook.processSplitWith(_context(20e18));

        ICobuildSplitHook.HistoricalBacklogProgressView memory progress = hook.historicalBacklogProgress();
        assertFalse(progress.active);
        assertEq(hook.historicalBacklogAmount(), 24e18);
        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 45e18);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 75e18);

        uint256 restartedPageAmount = hook.flushHistoricalBacklog(1);

        assertEq(restartedPageAmount, 9e18);
        assertEq(hook.historicalBacklogAmount(), 15e18);
        assertEq(goalTerminalOne.totalReceived(), 70e18);
        assertEq(goalTerminalTwo.totalReceived(), 75e18);

        progress = hook.historicalBacklogProgress();
        assertTrue(progress.active);
        assertEq(progress.epoch, 2);
        assertEq(progress.remainingAmount, 15e18);
        assertEq(progress.processedGoalCount, 1);
    }

    function test_flushHistoricalBacklog_usesCurrentDecayedRoutingScores() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        vm.warp(block.timestamp + ROUTING_SCORE_HALF_LIFE);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        communityToken.mint(address(hook), 20e18);

        vm.prank(controller);
        hook.processSplitWith(_context(20e18));

        communityToken.mint(address(hook), 70e18);

        vm.prank(controller);
        hook.processSplitWith(_context(70e18));

        uint256 routedAmount = hook.flushHistoricalBacklog(2);

        assertEq(routedAmount, 70e18);
        assertEq(hook.historicalBacklogAmount(), 0);
        assertEq(goalTerminalOne.totalReceived(), 77_500_000_000_000_000_000);
        assertEq(goalTerminalTwo.totalReceived(), 112_500_000_000_000_000_000);
        assertEq(goalTerminalOne.lastBeneficiary(), address(goalTreasuryOne));
        assertEq(goalTerminalTwo.lastBeneficiary(), address(goalTreasuryTwo));
    }

    function test_flushHistoricalBacklog_keepsBacklogWhenAllDecayedRoutingScoresReachZero() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        uint256 goalTerminalOneReceivedBefore = goalTerminalOne.totalReceived();
        uint256 goalTerminalTwoReceivedBefore = goalTerminalTwo.totalReceived();

        vm.warp(block.timestamp + (ROUTING_SCORE_HALF_LIFE * 256));

        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 0);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 0);
        assertEq(hook.currentRoutingMass(), 0);

        (uint256[] memory historicalGoalIds, uint256[] memory routingScores) = hook.historicalRoute();
        assertEq(historicalGoalIds.length, 0);
        assertEq(routingScores.length, 0);

        uint256 routedAmount = hook.flushHistoricalBacklog(2);

        assertEq(routedAmount, 0);
        assertEq(hook.historicalBacklogAmount(), 40e18);
        assertEq(goalTerminalOne.totalReceived(), goalTerminalOneReceivedBefore);
        assertEq(goalTerminalTwo.totalReceived(), goalTerminalTwoReceivedBefore);

        ICobuildSplitHook.HistoricalBacklogProgressView memory progress = hook.historicalBacklogProgress();
        assertFalse(progress.active);
        assertEq(progress.remainingAmount, 0);
        assertEq(progress.processedGoalCount, 0);
    }

    function test_flushHistoricalBacklog_revertsWhenPageSizeIsZero() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        vm.expectRevert(CobuildSplitHook.INVALID_HISTORICAL_FLUSH_PAGE_SIZE.selector);
        hook.flushHistoricalBacklog(0);
    }

    function test_processSplitWith_revertsWhenBacklogSnapshotExceedsSourceAmount() public {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 101e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 100e18);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.INVALID_BACKLOG_SNAPSHOT.selector, 101e18, 100e18));
        hook.processSplitWith(_context(100e18));

        ICobuildSplitHook.PendingRouteView memory pending = hook.pendingRoute();
        assertTrue(hook.hasPendingRoute());
        assertEq(pending.payer, beneficiary);
        assertEq(pending.beneficiary, beneficiary);
        assertEq(pending.backlogTokenCount, 101e18);
        assertEq(pending.goalIds.length, 2);
        assertEq(pending.goalIds[0], GOAL_ID_ONE);
        assertEq(pending.goalIds[1], GOAL_ID_TWO);
        assertEq(pending.weights.length, 2);
        assertEq(pending.weights[0], 1);
        assertEq(pending.weights[1], 3);
        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(goalTerminalTwo.totalReceived(), 0);
        assertEq(hook.historicalBacklogAmount(), 0);
        assertEq(communityToken.balanceOf(address(hook)), 100e18);
        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 0);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 0);
        assertEq(hook.currentRoutingMass(), 0);
    }

    function test_processSplitWith_defersDirectPayWhenNoHistoryExists() public {
        communityToken.mint(address(hook), 50e18);

        vm.prank(controller);
        hook.processSplitWith(_context(50e18));

        assertEq(hook.historicalBacklogAmount(), 50e18);
        assertEq(communityToken.balanceOf(address(hook)), 50e18);
        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(goalTerminalTwo.totalReceived(), 0);
    }

    function test_processSplitWith_defersDirectPayWhenHistoricalBacklogAlreadyExists() public {
        _seedRoutingScores(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 40e18, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        hook.processSplitWith(_context(10e18));

        assertEq(hook.historicalBacklogAmount(), 50e18);
        assertEq(goalTerminalOne.totalReceived(), 40e18);
        assertEq(goalTerminalTwo.totalReceived(), 60e18);
        assertEq(communityToken.balanceOf(address(hook)), 50e18);
    }

    function test_processSplitWith_ignoresGoalsRemovedFromRegistryWhenDerivingHistoricalRoute() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        goalRegistry.removeGoal(GOAL_ID_TWO);

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        assertEq(goalTerminalOne.totalReceived(), 25e18);
        assertEq(goalTerminalTwo.totalReceived(), 75e18);
        assertEq(hook.historicalBacklogAmount(), 40e18);

        (uint256[] memory historicalGoalIds, uint256[] memory routingScores) = hook.historicalRoute();
        assertEq(historicalGoalIds.length, 1);
        assertEq(historicalGoalIds[0], GOAL_ID_ONE);
        assertEq(routingScores.length, 1);
        assertEq(routingScores[0], 25e18);
        assertEq(hook.currentRoutingMass(), 25e18);
    }

    function test_historicalRoute_omitsGoalsWithoutPrimaryTerminal() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(0)));

        (uint256[] memory historicalGoalIds, uint256[] memory routingScores) = hook.historicalRoute();

        assertEq(historicalGoalIds.length, 1);
        assertEq(historicalGoalIds[0], GOAL_ID_ONE);
        assertEq(routingScores.length, 1);
        assertEq(routingScores[0], 25e18);
        assertEq(hook.currentRoutingMass(), 25e18);
    }

    function test_historicalRoute_reusesRetainedRoutingScoreWhenGoalTerminalIsRestored() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(0)));

        assertEq(hook.currentRoutingMass(), 25e18);

        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(goalTerminalTwo)));

        (uint256[] memory historicalGoalIds, uint256[] memory routingScores) = hook.historicalRoute();

        assertEq(historicalGoalIds.length, 2);
        assertEq(routingScores.length, 2);
        assertEq(hook.currentRoutingMass(), 100e18);

        uint256 goalOneRoutingScore;
        uint256 goalTwoRoutingScore;
        for (uint256 i = 0; i < historicalGoalIds.length; i++) {
            if (historicalGoalIds[i] == GOAL_ID_ONE) {
                goalOneRoutingScore = routingScores[i];
                continue;
            }
            if (historicalGoalIds[i] == GOAL_ID_TWO) {
                goalTwoRoutingScore = routingScores[i];
            }
        }

        assertEq(goalOneRoutingScore, 25e18);
        assertEq(goalTwoRoutingScore, 75e18);
    }

    function test_currentRoutingMass_excludesUnselectableGoals_andMatchesLiveRoute()
        public
    {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        goalRegistry.removeGoal(GOAL_ID_TWO);

        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 25e18);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 75e18);
        assertEq(hook.currentRoutingMass(), 25e18);
    }

    function test_historicalRoute_reusesRetainedRoutingScoreWhenGoalBecomesSelectableAgain() public {
        _seedRoutingScores(100e18, 1, 3, beneficiary);

        goalRegistry.removeGoal(GOAL_ID_TWO);
        goalRegistry.setGoalSelectable(GOAL_ID_TWO, true);

        (uint256[] memory historicalGoalIds, uint256[] memory routingScores) = hook.historicalRoute();

        assertEq(historicalGoalIds.length, 2);
        assertEq(routingScores.length, 2);
        assertEq(hook.currentRoutingMass(), 100e18);

        uint256 goalOneRoutingScore;
        uint256 goalTwoRoutingScore;
        for (uint256 i = 0; i < historicalGoalIds.length; i++) {
            if (historicalGoalIds[i] == GOAL_ID_ONE) {
                goalOneRoutingScore = routingScores[i];
                continue;
            }
            if (historicalGoalIds[i] == GOAL_ID_TWO) {
                goalTwoRoutingScore = routingScores[i];
            }
        }

        assertEq(goalOneRoutingScore, 25e18);
        assertEq(goalTwoRoutingScore, 75e18);
    }

    function test_processSplitWith_revertsWhenSelectedGoalHasNoPrimaryTerminal() public {
        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        directory.setPrimaryTerminal(GOAL_ID_ONE, address(communityToken), IJBTerminal(address(0)));

        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.NO_GOAL_TERMINAL.selector, GOAL_ID_ONE));
        hook.processSplitWith(_context(10e18));
    }

    function test_processSplitWith_acceptsFractionalReservedSplitPercent() public {
        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        hook.processSplitWith(_contextWithPercent(10e18, 1));

        assertEq(hook.historicalBacklogAmount(), 10e18);
        assertEq(communityToken.balanceOf(address(hook)), 10e18);
        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(goalTerminalTwo.totalReceived(), 0);
    }

    function test_processSplitWith_revertsWhenSelectedGoalTerminalHasNoCode() public {
        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        address noCodeTerminal = makeAddr("no-code-terminal");
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(communityToken), IJBTerminal(noCodeTerminal));

        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.NOT_A_CONTRACT.selector, noCodeTerminal));
        hook.processSplitWith(_context(10e18));
    }

    function test_processSplitWith_revertsWhenGoalTerminalDoesNotSpendFullAmount() public {
        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        CobuildSplitHookMockShortPullTerminal shortPullTerminal =
            new CobuildSplitHookMockShortPullTerminal(communityToken, 4e18);
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(communityToken), IJBTerminal(address(shortPullTerminal)));

        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(CobuildSplitHook.GOAL_PAYMENT_OUTFLOW_MISMATCH.selector, GOAL_ID_ONE, 10e18, 4e18)
        );
        hook.processSplitWith(_context(10e18));
    }

    function test_processSplitWith_revertsAtomicallyWhenLaterGoalTerminalDoesNotSpendFullAmount() public {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, _goalIds(), _weights(1, 3));

        CobuildSplitHookMockShortPullTerminal shortPullTerminal =
            new CobuildSplitHookMockShortPullTerminal(communityToken, 50e18);
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(shortPullTerminal)));

        communityToken.mint(address(hook), 100e18);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(CobuildSplitHook.GOAL_PAYMENT_OUTFLOW_MISMATCH.selector, GOAL_ID_TWO, 75e18, 50e18)
        );
        hook.processSplitWith(_context(100e18));

        assertTrue(hook.hasPendingRoute());
        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(shortPullTerminal.tokenBalance(), 0);
        assertEq(communityToken.balanceOf(address(hook)), 100e18);
        assertEq(hook.routingScoreOf(GOAL_ID_ONE), 0);
        assertEq(hook.routingScoreOf(GOAL_ID_TWO), 0);
        assertEq(hook.currentRoutingMass(), 0);
    }

    function test_beginPendingRoute_revertsForUnapprovedGoal() public {
        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 999;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.GOAL_NOT_APPROVED.selector, 999));
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);
    }

    function test_processSplitWith_revertsWhenCallerIsNotController() public {
        communityToken.mint(address(hook), 10e18);

        vm.expectRevert(CobuildSplitHook.UNAUTHORIZED.selector);
        hook.processSplitWith(_context(10e18));
    }

    function test_processSplitWith_revertsWhenCanonicalGoalTreasuryIsMissing() public {
        uint256 missingGoalId = 303;
        CobuildSplitHookMockGoalTerminal goalTerminalThree = new CobuildSplitHookMockGoalTerminal(communityToken);
        directory.setPrimaryTerminal(missingGoalId, address(communityToken), IJBTerminal(address(goalTerminalThree)));
        goalRegistry.setGoalSelectable(missingGoalId, true);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = missingGoalId;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, 0, goalIds, weights);

        communityToken.mint(address(hook), 100e18);

        vm.prank(controller);
        hook.processSplitWith(_context(100e18));

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.NO_GOAL_TREASURY.selector, missingGoalId));
        hook.flushHistoricalBacklog(1);
    }

    function test_selectableGoalIds_followRegistrySelectabilityIncludingTerminalPresence() public {
        uint256[] memory goalIds = hook.selectableGoalIds();

        assertEq(goalIds.length, 2);
        assertEq(goalIds[0], GOAL_ID_ONE);
        assertEq(goalIds[1], GOAL_ID_TWO);

        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(0)));

        uint256[] memory filteredGoalIds = hook.selectableGoalIds();
        assertEq(filteredGoalIds.length, 1);
        assertEq(filteredGoalIds[0], GOAL_ID_ONE);
    }

    function _deployHook(CobuildSplitHookMockGoalRegistry goalRegistry_)
        internal
        returns (CobuildSplitHook deployedHook)
    {
        CobuildSplitHook implementation = new CobuildSplitHook();
        deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));
        deployedHook.initialize(
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            routeSetter,
            ICommunityGoalRegistry(address(goalRegistry_))
        );
    }

    function _seedRoutingScores(uint256 amount, uint32 firstWeight, uint32 secondWeight, address beneficiary_)
        internal
    {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary_, beneficiary_, 0, _goalIds(), _weights(firstWeight, secondWeight));

        communityToken.mint(address(hook), amount);

        vm.prank(controller);
        hook.processSplitWith(_context(amount));
    }

    function _goalIds() internal pure returns (uint256[] memory goalIds) {
        goalIds = new uint256[](2);
        goalIds[0] = GOAL_ID_ONE;
        goalIds[1] = GOAL_ID_TWO;
    }

    function _weights(uint32 firstWeight, uint32 secondWeight) internal pure returns (uint32[] memory weights) {
        weights = new uint32[](2);
        weights[0] = firstWeight;
        weights[1] = secondWeight;
    }

    function _context(uint256 amount) internal view returns (JBSplitHookContext memory context) {
        return _contextWithPercent(amount, uint32(JBConstants.SPLITS_TOTAL_PERCENT));
    }

    function _contextWithPercent(uint256 amount, uint32 splitPercent)
        internal
        view
        returns (JBSplitHookContext memory context)
    {
        context = JBSplitHookContext({
            token: address(communityToken),
            amount: amount,
            decimals: 18,
            projectId: COMMUNITY_REVNET_ID,
            groupId: RESERVED_TOKENS_GROUP_ID,
            split: JBSplit({
                percent: splitPercent,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            })
        });
    }
}

contract CobuildSplitHookMockDirectory {
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

contract CobuildSplitHookMockGoalTerminal {
    CobuildSplitHookMockToken internal immutable _token;

    uint256 public totalReceived;
    uint256 public lastProjectId;
    address public lastBeneficiary;
    uint256 public lastAmount;
    mapping(address beneficiary => uint256 amount) public receivedByBeneficiary;

    constructor(CobuildSplitHookMockToken token_) {
        _token = token_;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    ) external returns (uint256 beneficiaryTokenCount) {
        require(token == address(_token), "token");
        _token.transferFrom(msg.sender, address(this), amount);

        totalReceived += amount;
        lastProjectId = projectId;
        lastBeneficiary = beneficiary;
        lastAmount = amount;
        receivedByBeneficiary[beneficiary] += amount;

        return amount;
    }
}

contract CobuildSplitHookMockGoalTreasury {
    uint256 public immutable goalRevnetId;

    constructor(uint256 goalRevnetId_) {
        goalRevnetId = goalRevnetId_;
    }
}

contract CobuildSplitHookMockGoalRegistry {
    IJBDirectory public directory;
    IGoalDeploymentRegistry public goalDeploymentRegistry;
    uint256 public communityRevnetId;
    address public communityToken;

    uint256[] internal _selectableGoalIds;
    mapping(uint256 goalId => bool selectable) internal _isSelectable;

    constructor(
        IJBDirectory directory_,
        IGoalDeploymentRegistry goalDeploymentRegistry_,
        uint256 communityRevnetId_,
        address communityToken_
    ) {
        directory = directory_;
        goalDeploymentRegistry = goalDeploymentRegistry_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
    }

    function setGoalSelectable(uint256 goalId, bool selectable) external {
        bool wasSelectable = _isSelectable[goalId];
        _isSelectable[goalId] = selectable;

        if (!wasSelectable && selectable) {
            _selectableGoalIds.push(goalId);
            return;
        }
        if (wasSelectable && !selectable) {
            _removeGoal(goalId);
        }
    }

    function removeGoal(uint256 goalId) external {
        _isSelectable[goalId] = false;
        _removeGoal(goalId);
    }

    function selectableGoalIds() external view returns (uint256[] memory goalIds) {
        uint256 length = _selectableGoalIds.length;
        uint256 count;
        for (uint256 i = 0; i < length; i++) {
            if (_isSelectableGoal(_selectableGoalIds[i])) count++;
        }

        goalIds = new uint256[](count);
        uint256 cursor;
        for (uint256 i = 0; i < length; i++) {
            uint256 goalId = _selectableGoalIds[i];
            if (!_isSelectableGoal(goalId)) continue;
            goalIds[cursor] = goalId;
            cursor++;
        }
    }

    function isSelectable(uint256 goalId) external view returns (bool) {
        return _isSelectableGoal(goalId);
    }

    function _isSelectableGoal(uint256 goalId) internal view returns (bool) {
        address terminalAddress = address(directory.primaryTerminalOf(goalId, communityToken));
        return _isSelectable[goalId] && terminalAddress.code.length != 0;
    }

    function _removeGoal(uint256 goalId) internal {
        uint256 length = _selectableGoalIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (_selectableGoalIds[i] != goalId) continue;

            uint256 lastIndex = length - 1;
            if (i != lastIndex) _selectableGoalIds[i] = _selectableGoalIds[lastIndex];
            _selectableGoalIds.pop();
            return;
        }
    }
}

contract CobuildSplitHookMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract CobuildSplitHookRouteSetterStub {}

contract CobuildSplitHookMockShortPullTerminal {
    CobuildSplitHookMockToken internal immutable _token;
    uint256 internal immutable _amountToPull;

    constructor(CobuildSplitHookMockToken token_, uint256 amountToPull_) {
        _token = token_;
        _amountToPull = amountToPull_;
    }

    function pay(uint256, address token, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        returns (uint256 beneficiaryTokenCount)
    {
        require(token == address(_token), "token");
        if (_amountToPull != 0) {
            _token.transferFrom(msg.sender, address(this), _amountToPull);
        }

        return amount;
    }

    function tokenBalance() external view returns (uint256) {
        return _token.balanceOf(address(this));
    }
}
