// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {CobuildCommunityTerminal} from "src/juicebox/CobuildCommunityTerminal.sol";
import {CobuildExitRouter} from "src/juicebox/CobuildExitRouter.sol";
import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {MockTerminalStore} from "test/juicebox/helpers/MockTerminalStore.sol";
import {
    AsyncDirectory,
    AsyncReservedController,
    GoalRecordingTerminal,
    GoalTreasuryStub,
    StakeVaultStub
} from "test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {RoundTestArbitrator} from "test/rounds/helpers/RoundTestMocks.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBCashOutHook} from "@bananapus/core-v5/interfaces/IJBCashOutHook.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v5/interfaces/IJBCashOutTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

uint32 constant TEST_ACCOUNTING_CURRENCY = 1;

contract CobuildExitRouterTest is Test {
    uint256 internal constant GOAL_ID = 1;
    uint256 internal constant CHILD_COMMUNITY_ID = 2;
    uint256 internal constant COMMUNITY_ID = 3;
    uint256 internal constant COBUILD_ID = 4;
    uint256 internal constant UNREGISTERED_COMMUNITY_ID = 5;
    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant CHALLENGE_PERIOD = 7 days;
    uint256 internal constant SUBMISSION_DEPOSIT = 1e18;

    address internal multisig = makeAddr("multisig");

    RouterAsyncDirectory internal directory;
    RouterAsyncReservedController internal controller;
    MockTerminalStore internal terminalStore;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildCommunityTerminal internal sharedTerminal;
    CobuildSplitHook internal hookImplementation;
    CommunityGoalRegistry internal registryImplementation;

    MockVotesToken internal goalToken;
    MockVotesToken internal childCommunityToken;
    MockVotesToken internal communityToken;
    MockVotesToken internal cobuildToken;
    MockVotesToken internal unregisteredCommunityToken;

    SeededCashOutTerminal internal goalCashOutTerminal;

    CobuildExitRouter internal router;

    function setUp() public {
        vm.deal(address(this), 200 ether);

        directory = new RouterAsyncDirectory();
        controller = new RouterAsyncReservedController(directory);
        terminalStore = new MockTerminalStore(IJBDirectory(address(directory)));
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        sharedTerminal = new CobuildCommunityTerminal(
            IJBDirectory(address(directory)), IJBTerminalStore(address(terminalStore)), address(0)
        );
        hookImplementation = new CobuildSplitHook();
        registryImplementation = new CommunityGoalRegistry();

        (uint256 goalId, MockVotesToken goalToken_) = controller.createProject(multisig, 0, "Goal", "GOAL");
        (uint256 childId, MockVotesToken childToken_) =
            controller.createProject(multisig, 0, "Child Community", "CHILD");
        (uint256 communityId, MockVotesToken communityToken_) =
            controller.createProject(multisig, 0, "Community", "COMM");
        (uint256 cobuildId, MockVotesToken cobuildToken_) =
            controller.createProject(multisig, 0, "Cobuild", "COBUILD");
        (uint256 unregisteredId, MockVotesToken unregisteredToken_) =
            controller.createProject(multisig, 0, "Unregistered Community", "UNREG");

        assertEq(goalId, GOAL_ID);
        assertEq(childId, CHILD_COMMUNITY_ID);
        assertEq(communityId, COMMUNITY_ID);
        assertEq(cobuildId, COBUILD_ID);
        assertEq(unregisteredId, UNREGISTERED_COMMUNITY_ID);

        goalToken = goalToken_;
        childCommunityToken = childToken_;
        communityToken = communityToken_;
        cobuildToken = cobuildToken_;
        unregisteredCommunityToken = unregisteredToken_;

        goalCashOutTerminal = new SeededCashOutTerminal(controller, GOAL_ID);

        vm.prank(multisig);
        controller.setProjectTerminal(GOAL_ID, address(goalCashOutTerminal), true);

        router = new CobuildExitRouter(
            IJBDirectory(address(directory)),
            goalDeploymentRegistry,
            sharedTerminal,
            cobuildToken,
            COBUILD_ID
        );
    }

    function test_exitToCommunityToken_transfersImmediateCommunityToken() public {
        _registerGoal(COMMUNITY_ID, communityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _setGoalPrimaryTerminal(address(communityToken));
        _seedGoalCashOut(COMMUNITY_ID, 5 ether);
        _mintGoalTokens(address(this), 5 ether);

        goalToken.approve(address(router), 5 ether);

        address beneficiary = makeAddr("beneficiary");
        uint256 amountOut = router.exitToCommunityToken(
            GOAL_ID, 5 ether, 5 ether, beneficiary, block.timestamp + 1, bytes("goal-exit")
        );

        assertEq(amountOut, 5 ether);
        assertEq(communityToken.balanceOf(beneficiary), 5 ether);
        assertEq(goalToken.balanceOf(address(router)), 0);
    }

    function test_exitToCobuildToken_walksConfiguredCommunityLineage() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCobuildRoot();
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(cobuildToken), COBUILD_ID, false);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 4 ether);
        _seedSharedTokenCashOut(CHILD_COMMUNITY_ID, COMMUNITY_ID, 4 ether);
        _seedSharedTokenCashOut(COMMUNITY_ID, COBUILD_ID, 4 ether);
        _mintGoalTokens(address(this), 4 ether);

        goalToken.approve(address(router), 4 ether);

        address beneficiary = makeAddr("beneficiary");
        uint256 amountOut =
            router.exitToCobuildToken(GOAL_ID, 4 ether, 4 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 4 ether);
        assertEq(cobuildToken.balanceOf(beneficiary), 4 ether);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(childCommunityToken.balanceOf(address(router)), 0);
        assertEq(communityToken.balanceOf(address(router)), 0);
    }

    function test_exitToEth_cashesOutFinalRootToNative() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCobuildRoot();
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(cobuildToken), COBUILD_ID, false);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 3 ether);
        _seedSharedTokenCashOut(CHILD_COMMUNITY_ID, COMMUNITY_ID, 3 ether);
        _seedSharedTokenCashOut(COMMUNITY_ID, COBUILD_ID, 3 ether);
        _seedSharedNativeCashOut(COBUILD_ID, 3 ether);
        _mintGoalTokens(address(this), 3 ether);

        goalToken.approve(address(router), 3 ether);

        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 amountOut =
            router.exitToEth(GOAL_ID, 3 ether, 3 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 3 ether);
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, 3 ether);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(childCommunityToken.balanceOf(address(router)), 0);
        assertEq(communityToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
    }

    function test_exitToEth_reusesSameMetadataAcrossGoalAndCommunityCashOutHops() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCobuildRoot();
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(cobuildToken), COBUILD_ID, false);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 3 ether);
        _seedSharedTokenCashOut(CHILD_COMMUNITY_ID, COMMUNITY_ID, 3 ether);
        _seedSharedTokenCashOut(COMMUNITY_ID, COBUILD_ID, 3 ether);
        _seedSharedNativeCashOut(COBUILD_ID, 3 ether);
        _mintGoalTokens(address(this), 3 ether);

        goalToken.approve(address(router), 3 ether);

        bytes memory metadata = bytes("goal-exit-metadata");
        address payable beneficiary = payable(makeAddr("beneficiary"));
        router.exitToEth(GOAL_ID, 3 ether, 3 ether, beneficiary, block.timestamp + 1, metadata);

        assertEq(goalCashOutTerminal.cashOutCallCount(), 1);
        assertEq(terminalStore.cashOutCallCountOf(CHILD_COMMUNITY_ID), 1);
        assertEq(terminalStore.cashOutCallCountOf(COMMUNITY_ID), 1);
        assertEq(terminalStore.cashOutCallCountOf(COBUILD_ID), 1);
        assertEq(keccak256(goalCashOutTerminal.lastCashOutMetadata()), keccak256(metadata));
        assertEq(keccak256(terminalStore.lastCashOutMetadataOf(CHILD_COMMUNITY_ID)), keccak256(metadata));
        assertEq(keccak256(terminalStore.lastCashOutMetadataOf(COMMUNITY_ID)), keccak256(metadata));
        assertEq(keccak256(terminalStore.lastCashOutMetadataOf(COBUILD_ID)), keccak256(metadata));
    }

    function test_exitToCommunityToken_revertsWhenImmediateLayerIsCobuildRoot() public {
        _registerGoal(COBUILD_ID, cobuildToken);
        _registerCobuildRoot();
        _setGoalPrimaryTerminal(address(cobuildToken));
        _seedGoalCashOut(COBUILD_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.NO_COMMUNITY_LAYER.selector, GOAL_ID));
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenImmediateLayerIsNotRegisteredCommunity() public {
        _registerGoal(UNREGISTERED_COMMUNITY_ID, unregisteredCommunityToken);
        _setGoalPrimaryTerminal(address(unregisteredCommunityToken));
        _seedGoalCashOut(UNREGISTERED_COMMUNITY_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.INVALID_COMMUNITY_LAYER.selector,
                UNREGISTERED_COMMUNITY_ID,
                address(unregisteredCommunityToken)
            )
        );
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenImmediateLayerTokenDoesNotMatchRegisteredCommunityToken() public {
        _registerGoal(COMMUNITY_ID, childCommunityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.INVALID_COMMUNITY_LAYER.selector, COMMUNITY_ID, address(childCommunityToken)
            )
        );
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenGoalPrimaryTerminalIsNotCashOutTerminal() public {
        _registerGoal(COMMUNITY_ID, communityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);

        GoalRecordingTerminal goalRecordingTerminal = new GoalRecordingTerminal(address(communityToken));
        directory.setPrimaryTerminalOf(GOAL_ID, address(communityToken), IJBTerminal(address(goalRecordingTerminal)));
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildExitRouter.TERMINAL_NOT_CASH_OUT.selector, address(goalRecordingTerminal))
        );
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenBeneficiaryIsRouter() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.SELF_BENEFICIARY.selector));
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(router), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenDeadlineExpired() public {
        uint256 deadline = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.DEADLINE_EXPIRED.selector, deadline, block.timestamp));
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), deadline, bytes("goal-exit"));
    }

    function test_exitToEth_supportsDirectNativeCommunityRoot() public {
        _registerGoal(COMMUNITY_ID, communityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _setGoalPrimaryTerminal(address(communityToken));
        _seedGoalCashOut(COMMUNITY_ID, 2 ether);
        _seedSharedNativeCashOut(COMMUNITY_ID, 2 ether);
        _mintGoalTokens(address(this), 2 ether);

        goalToken.approve(address(router), 2 ether);

        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 amountOut =
            router.exitToEth(GOAL_ID, 2 ether, 2 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 2 ether);
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, 2 ether);
    }

    function test_exitToEth_revertsWhenOutputBelowMinimum() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCobuildRoot();
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(cobuildToken), COBUILD_ID, false);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 2 ether);
        _seedSharedTokenCashOut(CHILD_COMMUNITY_ID, COMMUNITY_ID, 2 ether);
        _seedSharedTokenCashOut(COMMUNITY_ID, COBUILD_ID, 2 ether);
        _seedSharedNativeCashOut(COBUILD_ID, 2 ether);
        _mintGoalTokens(address(this), 2 ether);

        goalToken.approve(address(router), 2 ether);

        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.UNDER_MIN_OUTPUT.selector, 2 ether, 2 ether + 1));
        router.exitToEth(GOAL_ID, 2 ether, 2 ether + 1, payable(address(this)), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_revertsWhenDirectNativeCommunityRootLacksSeatedNativeLiquidity() public {
        _registerGoal(COMMUNITY_ID, communityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _setGoalPrimaryTerminal(address(communityToken));
        _seedGoalCashOut(COMMUNITY_ID, 2 ether);
        _seedSharedNativeCashOut(COMMUNITY_ID, 2 ether);
        vm.deal(address(sharedTerminal), 1 ether);
        _mintGoalTokens(address(this), 2 ether);

        goalToken.approve(address(router), 2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INSUFFICIENT_RECLAIM_LIQUIDITY.selector,
                JBConstants.NATIVE_TOKEN,
                2 ether,
                1 ether
            )
        );
        router.exitToEth(GOAL_ID, 2 ether, 0, payable(address(this)), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_revertsWhenDirectNativeCommunityRootTerminalIsRetargeted() public {
        _registerGoal(COMMUNITY_ID, communityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _setGoalPrimaryTerminal(address(communityToken));
        _seedGoalCashOut(COMMUNITY_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        SeededCashOutTerminal rogueCommunityCashOutTerminal = new SeededCashOutTerminal(controller, COMMUNITY_ID);
        vm.prank(multisig);
        controller.setProjectTerminal(COMMUNITY_ID, address(rogueCommunityCashOutTerminal), true);
        directory.setPrimaryTerminalOf(
            COMMUNITY_ID,
            JBConstants.NATIVE_TOKEN,
            IJBTerminal(address(rogueCommunityCashOutTerminal))
        );

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.INVALID_COMMUNITY_TERMINAL.selector,
                COMMUNITY_ID,
                JBConstants.NATIVE_TOKEN,
                address(rogueCommunityCashOutTerminal)
            )
        );
        router.exitToEth(GOAL_ID, 1 ether, 0, payable(address(this)), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_revertsWhenBeneficiaryIsRouter() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.SELF_BENEFICIARY.selector));
        router.exitToEth(GOAL_ID, 1 ether, 0, payable(address(router)), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_revertsWhenDeadlineExpired() public {
        uint256 deadline = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.DEADLINE_EXPIRED.selector, deadline, block.timestamp));
        router.exitToEth(GOAL_ID, 1 ether, 0, payable(address(this)), deadline, bytes("goal-exit"));
    }

    function test_exitToEth_revertsWhenCobuildNativeTerminalMissing() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCobuildRoot();
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(cobuildToken), COBUILD_ID, false);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);

        directory.clearPrimaryTerminalOf(COBUILD_ID, JBConstants.NATIVE_TOKEN);
        directory.setTerminalsOf(COBUILD_ID, new IJBTerminal[](0));

        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 1 ether);
        _seedSharedTokenCashOut(CHILD_COMMUNITY_ID, COMMUNITY_ID, 1 ether);
        _seedSharedTokenCashOut(COMMUNITY_ID, COBUILD_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildExitRouter.TERMINAL_NOT_FOUND.selector, COBUILD_ID, JBConstants.NATIVE_TOKEN)
        );
        router.exitToEth(GOAL_ID, 1 ether, 0, payable(address(this)), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_supportsMaxCommunityHopsBeforeCobuild() public {
        _registerCobuildRoot();

        uint256 hopCount = router.MAX_COMMUNITY_HOPS();
        (uint256[] memory hopIds, MockVotesToken[] memory hopTokens) = _createCobuildHopLineage(hopCount);

        _registerGoal(hopIds[0], hopTokens[0]);
        _setGoalPrimaryTerminal(address(hopTokens[0]));
        _seedGoalCashOut(hopIds[0], 1 ether);
        _seedCobuildHopCashOuts(hopIds, 1 ether);
        _seedSharedNativeCashOut(COBUILD_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 amountOut =
            router.exitToEth(GOAL_ID, 1 ether, 1 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 1 ether);
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, 1 ether);
    }

    function test_exitToCobuildToken_revertsWhenCommunityRootOnlySupportsDirectNativeExit() public {
        _registerGoal(COMMUNITY_ID, communityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _setGoalPrimaryTerminal(address(communityToken));
        _seedGoalCashOut(COMMUNITY_ID, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.COBUILD_ROUTE_UNAVAILABLE.selector, COMMUNITY_ID, address(communityToken)
            )
        );
        router.exitToCobuildToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCobuildToken_revertsWhenOutputBelowMinimum() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCobuildRoot();
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(cobuildToken), COBUILD_ID, false);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 4 ether);
        _seedSharedTokenCashOut(CHILD_COMMUNITY_ID, COMMUNITY_ID, 4 ether);
        _seedSharedTokenCashOut(COMMUNITY_ID, COBUILD_ID, 4 ether);
        _mintGoalTokens(address(this), 4 ether);

        goalToken.approve(address(router), 4 ether);

        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.UNDER_MIN_OUTPUT.selector, 4 ether, 4 ether + 1));
        router.exitToCobuildToken(GOAL_ID, 4 ether, 4 ether + 1, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCobuildToken_revertsWhenCommunityHopTerminalIsRetargeted() public {
        _registerGoal(CHILD_COMMUNITY_ID, childCommunityToken);
        _registerCommunityProject(COMMUNITY_ID, communityToken, address(communityToken), COMMUNITY_ID, true);
        _registerCommunityProject(CHILD_COMMUNITY_ID, childCommunityToken, address(communityToken), COMMUNITY_ID, false);
        _setGoalPrimaryTerminal(address(childCommunityToken));
        _seedGoalCashOut(CHILD_COMMUNITY_ID, 1 ether);
        SeededCashOutTerminal rogueCommunityCashOutTerminal = new SeededCashOutTerminal(controller, CHILD_COMMUNITY_ID);
        vm.prank(multisig);
        controller.setProjectTerminal(CHILD_COMMUNITY_ID, address(rogueCommunityCashOutTerminal), true);
        directory.setPrimaryTerminalOf(
            CHILD_COMMUNITY_ID, address(communityToken), IJBTerminal(address(rogueCommunityCashOutTerminal))
        );
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.INVALID_COMMUNITY_TERMINAL.selector,
                CHILD_COMMUNITY_ID,
                address(communityToken),
                address(rogueCommunityCashOutTerminal)
            )
        );
        router.exitToCobuildToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCobuildToken_revertsWhenCommunityLineageExceedsMaxHops() public {
        _registerCobuildRoot();

        uint256 hopCount = router.MAX_COMMUNITY_HOPS() + 1;
        (uint256[] memory hopIds, MockVotesToken[] memory hopTokens) = _createCobuildHopLineage(hopCount);

        _registerGoal(hopIds[0], hopTokens[0]);
        _setGoalPrimaryTerminal(address(hopTokens[0]));
        _seedGoalCashOut(hopIds[0], 1 ether);
        _seedCobuildHopCashOuts(hopIds, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildExitRouter.MAX_COMMUNITY_HOPS_EXCEEDED.selector, router.MAX_COMMUNITY_HOPS())
        );
        router.exitToCobuildToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_revertsWhenCommunityLineageExceedsMaxHops() public {
        _registerCobuildRoot();

        uint256 hopCount = router.MAX_COMMUNITY_HOPS() + 1;
        (uint256[] memory hopIds, MockVotesToken[] memory hopTokens) = _createCobuildHopLineage(hopCount);

        _registerGoal(hopIds[0], hopTokens[0]);
        _setGoalPrimaryTerminal(address(hopTokens[0]));
        _seedGoalCashOut(hopIds[0], 1 ether);
        _seedCobuildHopCashOuts(hopIds, 1 ether);
        _mintGoalTokens(address(this), 1 ether);

        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildExitRouter.MAX_COMMUNITY_HOPS_EXCEEDED.selector, router.MAX_COMMUNITY_HOPS())
        );
        router.exitToEth(GOAL_ID, 1 ether, 0, payable(address(this)), block.timestamp + 1, bytes("goal-exit"));
    }

    function _registerGoal(uint256 cobuildRevnetId, MockVotesToken paymentToken) internal {
        GoalTreasuryStub goalTreasury =
            new GoalTreasuryStub(GOAL_ID, cobuildRevnetId, address(new StakeVaultStub(address(paymentToken))));
        goalDeploymentRegistry.registerGoal(GOAL_ID, address(goalTreasury));
    }

    function _registerCobuildRoot() internal {
        _registerCommunityProject(COBUILD_ID, cobuildToken, address(cobuildToken), COBUILD_ID, true);
    }

    function _registerCommunityProject(
        uint256 communityRevnetId,
        MockVotesToken communityProjectToken,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed
    ) internal {
        directory.setPrimaryTerminalOf(communityRevnetId, paymentToken, IJBTerminal(address(sharedTerminal)));
        directory.setPrimaryTerminalOf(communityRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sharedTerminal)));

        vm.prank(multisig);
        controller.setProjectTerminal(communityRevnetId, address(sharedTerminal), true);

        CommunityGoalRegistry registry =
            _deployCommunityGoalRegistry(communityRevnetId, IVotes(address(communityProjectToken)));
        CobuildSplitHook hook = CobuildSplitHook(payable(Clones.clone(address(hookImplementation))));
        hook.initialize(
            IJBDirectory(address(directory)),
            communityRevnetId,
            address(communityProjectToken),
            address(sharedTerminal),
            registry
        );

        vm.prank(multisig);
        controller.setReservedSplitHook(communityRevnetId, IJBSplitHook(address(hook)));

        vm.prank(multisig);
        sharedTerminal.registerCommunity(
            communityRevnetId, ICobuildSplitHook(address(hook)), paymentToken, paymentSourceRevnetId, directNativeAllowed
        );
    }

    function _deployCommunityGoalRegistry(
        uint256 communityRevnetId,
        IVotes votingToken
    ) internal returns (CommunityGoalRegistry registry) {
        registry = CommunityGoalRegistry(Clones.clone(address(registryImplementation)));

        RoundTestArbitrator arbitrator =
            new RoundTestArbitrator(votingToken, address(registry), 1, 1, 1, ARBITRATION_COST);
        EscrowSubmissionDepositStrategy depositStrategy = new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)));

        registry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(arbitrator, votingToken, depositStrategy),
                directory: IJBDirectory(address(directory)),
                goalDeploymentRegistry: goalDeploymentRegistry,
                communityRevnetId: communityRevnetId,
                communityToken: address(votingToken)
            })
        );
    }

    function _registryConfig(
        RoundTestArbitrator arbitrator,
        IVotes votingToken,
        EscrowSubmissionDepositStrategy depositStrategy
    ) internal pure returns (IGeneralizedTCRConfig.RegistryConfig memory config) {
        config = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: arbitrator,
            votingToken: votingToken,
            submissionDepositStrategy: depositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://registration",
                clearingMetaEvidence: "ipfs://clearing",
                submissionBaseDeposit: SUBMISSION_DEPOSIT,
                removalBaseDeposit: SUBMISSION_DEPOSIT,
                submissionChallengeBaseDeposit: SUBMISSION_DEPOSIT,
                removalChallengeBaseDeposit: SUBMISSION_DEPOSIT,
                challengePeriodDuration: CHALLENGE_PERIOD
            })
        });
    }

    function _setGoalPrimaryTerminal(address token) internal {
        directory.setPrimaryTerminalOf(GOAL_ID, token, IJBTerminal(address(goalCashOutTerminal)));
    }

    function _createCobuildHopLineage(uint256 hopCount)
        internal
        returns (uint256[] memory hopIds, MockVotesToken[] memory hopTokens)
    {
        hopIds = new uint256[](hopCount);
        hopTokens = new MockVotesToken[](hopCount);

        for (uint256 i; i < hopCount; i++) {
            (hopIds[i], hopTokens[i]) = controller.createProject(multisig, 0, "Hop", "HOP");
        }

        for (uint256 i = hopCount; i > 0; i--) {
            uint256 hopIndex = i - 1;
            address paymentToken = hopIndex + 1 == hopCount ? address(cobuildToken) : address(hopTokens[hopIndex + 1]);
            uint256 paymentSourceRevnetId = hopIndex + 1 == hopCount ? COBUILD_ID : hopIds[hopIndex + 1];

            _registerCommunityProject(
                hopIds[hopIndex], hopTokens[hopIndex], paymentToken, paymentSourceRevnetId, false
            );
        }
    }

    function _mintGoalTokens(address beneficiary, uint256 amount) internal {
        _mintProjectTokens(GOAL_ID, beneficiary, amount);
    }

    function _mintProjectTokens(uint256 projectId, address beneficiary, uint256 amount) internal {
        vm.prank(multisig);
        controller.mintTokensOf(projectId, amount, beneficiary, false);
    }

    function _seedGoalCashOut(uint256 paymentProjectId, uint256 amount) internal {
        _mintProjectTokens(paymentProjectId, address(goalCashOutTerminal), amount);
    }

    function _seedCobuildHopCashOuts(uint256[] memory hopIds, uint256 amount) internal {
        uint256 hopCount = hopIds.length;
        for (uint256 i; i < hopCount; i++) {
            uint256 paymentProjectId = i + 1 == hopCount ? COBUILD_ID : hopIds[i + 1];
            _seedSharedTokenCashOut(hopIds[i], paymentProjectId, amount);
        }
    }

    function _seedSharedTokenCashOut(uint256 projectId, uint256 paymentProjectId, uint256 amount) internal {
        MockVotesToken paymentToken = controller.TOKENS().tokenOf(paymentProjectId);
        _mintProjectTokens(paymentProjectId, address(this), amount);
        paymentToken.approve(address(sharedTerminal), amount);
        sharedTerminal.addToBalanceOf(projectId, address(paymentToken), amount, false, "seed", bytes(""));
        terminalStore.setCashOutConfig(
            projectId, address(paymentToken), amount, 0, IJBCashOutHook(address(0)), 0, bytes("")
        );
    }

    function _seedSharedNativeCashOut(uint256 projectId, uint256 amount) internal {
        sharedTerminal.addToBalanceOf{value: amount}(projectId, JBConstants.NATIVE_TOKEN, amount, false, "seed", bytes(""));
        terminalStore.setCashOutConfig(
            projectId, JBConstants.NATIVE_TOKEN, amount, 0, IJBCashOutHook(address(0)), 0, bytes("")
        );
    }
}

contract RouterAsyncDirectory is AsyncDirectory {
    function clearPrimaryTerminalOf(uint256 projectId, address token) external {
        delete _primaryTerminalOf[projectId][token];
    }
}

contract RouterAsyncReservedController is AsyncReservedController {
    constructor(AsyncDirectory directory_) AsyncReservedController(directory_) {}

    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata) external {
        ProjectConfig storage config = _projectConfigOf[projectId];
        if (address(config.token) == address(0)) revert INVALID_PROJECT();
        if (msg.sender != config.owner && !_isProjectTerminal[projectId][msg.sender]) revert UNAUTHORIZED();
        config.token.burn(holder, tokenCount);
    }
}

contract SeededCashOutTerminal is IJBCashOutTerminal {
    using SafeERC20 for IERC20;

    RouterAsyncReservedController internal immutable _controller;
    uint256 internal immutable _projectId;
    uint256 public cashOutCallCount;
    bytes public lastCashOutMetadata;

    constructor(RouterAsyncReservedController controller_, uint256 projectId_) {
        _controller = controller_;
        _projectId = projectId_;
    }

    receive() external payable {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IJBCashOutTerminal).interfaceId ||
            interfaceId == type(IJBTerminal).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    ) external override returns (uint256 reclaimAmount) {
        require(projectId == _projectId, "INVALID_PROJECT");

        cashOutCallCount += 1;
        lastCashOutMetadata = metadata;
        _controller.burnTokensOf(holder, projectId, cashOutCount, "");
        reclaimAmount = cashOutCount;
        require(reclaimAmount >= minTokensReclaimed, "MIN");

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: reclaimAmount}("");
            require(success, "NATIVE");
        } else {
            IERC20(tokenToReclaim).safeTransfer(beneficiary, reclaimAmount);
        }

        emit CashOutTokens(1, 1, projectId, holder, beneficiary, cashOutCount, 0, reclaimAmount, metadata, msg.sender);
    }

    function accountingContextForTokenOf(uint256 projectId, address token)
        external
        pure
        override
        returns (JBAccountingContext memory context)
    {
        if (projectId == 0 || token == address(0)) {
            return JBAccountingContext({token: address(0), decimals: 0, currency: 0});
        }

        context = JBAccountingContext({token: token, decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256, uint256)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata)
        external
        payable
        override
    {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(uint256, address, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        override
        returns (uint256)
    {
        return amount;
    }
}
