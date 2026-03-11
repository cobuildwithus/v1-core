// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v5/interfaces/IJBProjects.sol";
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {CobuildCommunityTerminal} from "src/juicebox/CobuildCommunityTerminal.sol";
import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {MockTerminalStore} from "test/juicebox/helpers/MockTerminalStore.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {RoundTestArbitrator} from "test/rounds/helpers/RoundTestMocks.sol";

uint32 constant TEST_ACCOUNTING_CURRENCY = 1;

contract CobuildCommunityTerminalCoreIntegrationTest is Test {
    uint16 internal constant HALF_RESERVED_PERCENT = JBConstants.MAX_RESERVED_PERCENT / 2;
    uint16 internal constant FULL_RESERVED_PERCENT = JBConstants.MAX_RESERVED_PERCENT;
    uint256 internal constant ROUTE_SEED_AMOUNT = 100e18;
    uint256 internal constant DIRECT_PAY_AMOUNT = 40e18;
    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant CHALLENGE_PERIOD = 7 days;
    uint256 internal constant SUBMISSION_DEPOSIT = 1e18;

    address internal multisig = makeAddr("multisig");
    address internal routeBeneficiary = makeAddr("route-beneficiary");
    address internal payer = makeAddr("payer");
    address internal payerTwo = makeAddr("payer-two");

    AsyncDirectory internal directory;
    AsyncReservedController internal controller;
    MockTerminalStore internal terminalStore;

    struct WrapperFixture {
        uint256 communityRevnetId;
        MockVotesToken communityToken;
        CommunityGoalRegistry registry;
        AsyncCommunityTerminal communityTerminal;
        CobuildCommunityTerminal wrapper;
        CobuildSplitHook hook;
        uint256 goalIdOne;
        uint256 goalIdTwo;
        GoalRecordingTerminal goalTerminalOne;
        GoalRecordingTerminal goalTerminalTwo;
        GoalTreasuryStub goalTreasuryOne;
        GoalTreasuryStub goalTreasuryTwo;
    }

    struct ManualFixture {
        uint256 communityRevnetId;
        MockVotesToken communityToken;
        CommunityGoalRegistry registry;
        AsyncCommunityTerminal communityTerminal;
        CobuildSplitHook hook;
        address routeSetter;
        uint256 goalIdOne;
        uint256 goalIdTwo;
        GoalRecordingTerminal goalTerminalOne;
        GoalRecordingTerminal goalTerminalTwo;
        GoalTreasuryStub goalTreasuryOne;
        GoalTreasuryStub goalTreasuryTwo;
    }

    WrapperFixture internal wrapperFixture;
    ManualFixture internal manualFixture;

    function setUp() public {
        directory = new AsyncDirectory();
        controller = new AsyncReservedController(directory);
        terminalStore = new MockTerminalStore(IJBDirectory(address(directory)));

        wrapperFixture = _deployWrapperFixture(HALF_RESERVED_PERCENT);
        manualFixture = _deployManualFixture(FULL_RESERVED_PERCENT);
    }

    function test_wrapperExplicitRoute_fundsSelectedGoalsAndMintsCommunityTokensInSameTransaction() public {
        uint256[] memory goalIds = _goalIds(wrapperFixture.goalIdOne, wrapperFixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        uint256 beneficiaryTokenCount =
            _payWrapper(wrapperFixture, payer, DIRECT_PAY_AMOUNT, payer, "pick-goals", abi.encode(goalIds, weights));

        assertEq(beneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.communityToken.balanceOf(payer), DIRECT_PAY_AMOUNT / 2);
        assertFalse(wrapperFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(wrapperFixture.communityRevnetId), 0);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 5e18);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 15e18);
        assertEq(wrapperFixture.goalTerminalOne.lastBeneficiary(), payer);
        assertEq(wrapperFixture.goalTerminalTwo.lastBeneficiary(), payer);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne), 5e18);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo), 15e18);
        assertEq(wrapperFixture.hook.cumulativeObservedVolume(), 20e18);
    }

    function test_wrapperWithoutExplicitRoute_defersReservedTokensIntoBacklogEvenWhenHistoryExists() public {
        _seedObservedHistoryForWrapperFixture(wrapperFixture, DIRECT_PAY_AMOUNT);
        uint256 goalTerminalOneReceivedBefore = wrapperFixture.goalTerminalOne.totalReceived();
        uint256 goalTerminalTwoReceivedBefore = wrapperFixture.goalTerminalTwo.totalReceived();
        uint256 observedVolumeOneBefore = wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = wrapperFixture.hook.cumulativeObservedVolume();

        uint256 beneficiaryTokenCount =
            _payWrapper(wrapperFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "defer-to-backlog", bytes(""));

        assertEq(beneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.communityToken.balanceOf(payerTwo), DIRECT_PAY_AMOUNT / 2);
        assertFalse(wrapperFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(wrapperFixture.communityRevnetId), 0);
        assertEq(wrapperFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), goalTerminalOneReceivedBefore);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), goalTerminalTwoReceivedBefore);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(wrapperFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);
    }

    function test_wrapperWithoutExplicitRoute_flushesExistingControllerBacklogIntoHookBacklog() public {
        _seedObservedHistoryForWrapperFixture(wrapperFixture, DIRECT_PAY_AMOUNT);
        _payCommunityDirect(
            wrapperFixture.communityTerminal,
            wrapperFixture.communityRevnetId,
            wrapperFixture.communityToken,
            payer,
            DIRECT_PAY_AMOUNT
        );

        uint256 goalTerminalOneReceivedBefore = wrapperFixture.goalTerminalOne.totalReceived();
        uint256 goalTerminalTwoReceivedBefore = wrapperFixture.goalTerminalTwo.totalReceived();
        uint256 observedVolumeOneBefore = wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = wrapperFixture.hook.cumulativeObservedVolume();

        uint256 beneficiaryTokenCount =
            _payWrapper(wrapperFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "defer-to-backlog", bytes(""));

        assertEq(beneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.communityToken.balanceOf(payerTwo), DIRECT_PAY_AMOUNT / 2);
        assertFalse(wrapperFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(wrapperFixture.communityRevnetId), 0);
        assertEq(wrapperFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), goalTerminalOneReceivedBefore);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), goalTerminalTwoReceivedBefore);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(wrapperFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);
    }

    function test_wrapperWithoutExplicitRoute_withFullReservedMintDefersAllReservedTokensIntoBacklog() public {
        WrapperFixture memory fullReservedFixture = _deployWrapperFixture(FULL_RESERVED_PERCENT);
        _seedObservedHistoryForWrapperFixture(fullReservedFixture, DIRECT_PAY_AMOUNT);
        uint256 goalTerminalOneReceivedBefore = fullReservedFixture.goalTerminalOne.totalReceived();
        uint256 goalTerminalTwoReceivedBefore = fullReservedFixture.goalTerminalTwo.totalReceived();
        uint256 observedVolumeOneBefore = fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = fullReservedFixture.hook.cumulativeObservedVolume();

        uint256 beneficiaryTokenCount =
            _payWrapper(fullReservedFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "defer-to-backlog", bytes(""));

        assertEq(beneficiaryTokenCount, 0);
        assertEq(fullReservedFixture.communityToken.balanceOf(payerTwo), 0);
        assertFalse(fullReservedFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(fullReservedFixture.communityRevnetId), 0);
        assertEq(fullReservedFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT);
        assertEq(fullReservedFixture.goalTerminalOne.totalReceived(), goalTerminalOneReceivedBefore);
        assertEq(fullReservedFixture.goalTerminalTwo.totalReceived(), goalTerminalTwoReceivedBefore);
        assertEq(fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(fullReservedFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);
    }

    function test_wrapperExplicitRoute_routesOnlyNewDelta_andDefersOlderBacklogForPermissionlessFlush() public {
        _payCommunityDirect(
            wrapperFixture.communityTerminal,
            wrapperFixture.communityRevnetId,
            wrapperFixture.communityToken,
            payer,
            DIRECT_PAY_AMOUNT
        );

        uint256[] memory goalIds = _goalIds(wrapperFixture.goalIdOne, wrapperFixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        uint256 beneficiaryTokenCount = _payWrapper(
            wrapperFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "pick-goals", abi.encode(goalIds, weights)
        );

        assertEq(beneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.communityToken.balanceOf(payerTwo), DIRECT_PAY_AMOUNT / 2);
        assertEq(controller.pendingReservedTokenBalanceOf(wrapperFixture.communityRevnetId), 0);
        assertEq(wrapperFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 5e18);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 15e18);
        assertEq(wrapperFixture.goalTerminalOne.lastBeneficiary(), payerTwo);
        assertEq(wrapperFixture.goalTerminalTwo.lastBeneficiary(), payerTwo);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne), 5e18);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo), 15e18);
        assertEq(wrapperFixture.hook.cumulativeObservedVolume(), 20e18);

        uint256 flushedBacklogAmount = wrapperFixture.hook.flushHistoricalBacklog(2);

        assertEq(flushedBacklogAmount, DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.hook.historicalBacklogAmount(), 0);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 10e18);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 30e18);
        assertEq(wrapperFixture.goalTerminalOne.lastBeneficiary(), address(wrapperFixture.goalTreasuryOne));
        assertEq(wrapperFixture.goalTerminalTwo.lastBeneficiary(), address(wrapperFixture.goalTreasuryTwo));
    }

    function test_wrapperExplicitRoute_permissionlessHistoricalBacklogFlushCanResumeAcrossPages() public {
        _payCommunityDirect(
            wrapperFixture.communityTerminal,
            wrapperFixture.communityRevnetId,
            wrapperFixture.communityToken,
            payer,
            DIRECT_PAY_AMOUNT
        );

        uint256[] memory goalIds = _goalIds(wrapperFixture.goalIdOne, wrapperFixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        _payWrapper(wrapperFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "pick-goals", abi.encode(goalIds, weights));

        uint256 firstPageAmount = wrapperFixture.hook.flushHistoricalBacklog(1);

        assertEq(firstPageAmount, 5e18);
        assertEq(wrapperFixture.hook.historicalBacklogAmount(), 15e18);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 10e18);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 15e18);

        uint256 secondPageAmount = wrapperFixture.hook.flushHistoricalBacklog(1);

        assertEq(secondPageAmount, 15e18);
        assertEq(wrapperFixture.hook.historicalBacklogAmount(), 0);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 10e18);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 30e18);
        assertEq(wrapperFixture.goalTerminalOne.lastBeneficiary(), address(wrapperFixture.goalTreasuryOne));
        assertEq(wrapperFixture.goalTerminalTwo.lastBeneficiary(), address(wrapperFixture.goalTreasuryTwo));
    }

    function test_sharedTerminal_childNativePay_canUseRootCommunityAsSelfSource() public {
        CobuildCommunityTerminal sharedTerminal =
            new CobuildCommunityTerminal(IJBDirectory(address(directory)), IJBTerminalStore(address(terminalStore)));

        GoalDeploymentRegistry rootDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        (uint256 rootRevnetId, MockVotesToken rootToken) =
            controller.createProject(multisig, HALF_RESERVED_PERCENT, "Root Community", "ROOT");
        directory.setPrimaryTerminalOf(rootRevnetId, address(rootToken), IJBTerminal(address(sharedTerminal)));
        directory.setPrimaryTerminalOf(rootRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sharedTerminal)));
        vm.startPrank(multisig);
        controller.setProjectTerminal(rootRevnetId, address(sharedTerminal), true);
        vm.stopPrank();

        CommunityGoalRegistry rootRegistry =
            _deployCommunityGoalRegistry(rootRevnetId, address(rootToken), rootDeploymentRegistry);
        CobuildSplitHook rootHook = _deployHookClone();
        rootHook.initialize(
            IJBDirectory(address(directory)), rootRevnetId, address(rootToken), address(sharedTerminal), rootRegistry
        );
        vm.startPrank(multisig);
        sharedTerminal.registerCommunity(
            rootRevnetId, ICobuildSplitHook(address(rootHook)), address(rootToken), rootRevnetId, true
        );
        controller.setReservedSplitHook(rootRevnetId, IJBSplitHook(address(rootHook)));
        vm.stopPrank();

        GoalDeploymentRegistry childDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        (uint256 childRevnetId, MockVotesToken childToken) =
            controller.createProject(multisig, HALF_RESERVED_PERCENT, "Child Community", "CHILD");
        directory.setPrimaryTerminalOf(childRevnetId, address(rootToken), IJBTerminal(address(sharedTerminal)));
        directory.setPrimaryTerminalOf(childRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sharedTerminal)));
        vm.startPrank(multisig);
        controller.setProjectTerminal(childRevnetId, address(sharedTerminal), true);
        vm.stopPrank();

        CommunityGoalRegistry childRegistry =
            _deployCommunityGoalRegistry(childRevnetId, address(childToken), childDeploymentRegistry);
        CobuildSplitHook childHook = _deployHookClone();
        childHook.initialize(
            IJBDirectory(address(directory)), childRevnetId, address(childToken), address(sharedTerminal), childRegistry
        );
        vm.startPrank(multisig);
        sharedTerminal.registerCommunity(
            childRevnetId, ICobuildSplitHook(address(childHook)), address(rootToken), rootRevnetId, false
        );
        controller.setReservedSplitHook(childRevnetId, IJBSplitHook(address(childHook)));
        vm.stopPrank();

        vm.deal(payer, DIRECT_PAY_AMOUNT);
        vm.prank(payer);
        uint256 beneficiaryTokenCount = sharedTerminal.pay{value: DIRECT_PAY_AMOUNT}(
            childRevnetId, JBConstants.NATIVE_TOKEN, DIRECT_PAY_AMOUNT, payer, 0, "child-native-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, DIRECT_PAY_AMOUNT / 4);
        assertEq(rootToken.balanceOf(address(sharedTerminal)), DIRECT_PAY_AMOUNT / 2);
        assertEq(childToken.balanceOf(payer), DIRECT_PAY_AMOUNT / 4);
        assertEq(rootHook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT / 2);
        assertEq(childHook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT / 4);
        assertEq(controller.pendingReservedTokenBalanceOf(rootRevnetId), 0);
        assertEq(controller.pendingReservedTokenBalanceOf(childRevnetId), 0);
    }

    function test_directCommunityPayWithoutHistoricalRoute_permissionlessControllerFlushDefersBacklog() public {
        _payCommunityDirect(
            manualFixture.communityTerminal,
            manualFixture.communityRevnetId,
            manualFixture.communityToken,
            payer,
            DIRECT_PAY_AMOUNT
        );

        assertFalse(manualFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 0);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), 0);

        controller.sendReservedTokensToSplitsOf(manualFixture.communityRevnetId);

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), 0);
        assertEq(manualFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 0);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), 0);

        uint256 flushedBacklogAmount = manualFixture.hook.flushHistoricalBacklog(2);

        assertEq(flushedBacklogAmount, 0);
        assertEq(manualFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT);
    }

    function test_wrapperWithoutExplicitRoute_defersBacklog_untilExplicitRouteSeedsHistoryAndFlushes() public {
        WrapperFixture memory freshFixture = _deployWrapperFixture(HALF_RESERVED_PERCENT);

        uint256 initialBeneficiaryTokenCount =
            _payWrapper(freshFixture, payer, DIRECT_PAY_AMOUNT, payer, "defer-to-backlog", bytes(""));

        assertEq(initialBeneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(freshFixture.communityToken.balanceOf(payer), DIRECT_PAY_AMOUNT / 2);
        assertFalse(freshFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(freshFixture.communityRevnetId), 0);
        assertEq(freshFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT / 2);
        assertEq(freshFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(freshFixture.goalTerminalTwo.totalReceived(), 0);
        assertEq(freshFixture.hook.observedVolumeOf(freshFixture.goalIdOne), 0);
        assertEq(freshFixture.hook.observedVolumeOf(freshFixture.goalIdTwo), 0);
        assertEq(freshFixture.hook.cumulativeObservedVolume(), 0);

        uint256[] memory goalIds = _goalIds(freshFixture.goalIdOne, freshFixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        uint256 explicitBeneficiaryTokenCount = _payWrapper(
            freshFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "pick-goals", abi.encode(goalIds, weights)
        );

        assertEq(explicitBeneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(freshFixture.communityToken.balanceOf(payerTwo), DIRECT_PAY_AMOUNT / 2);
        assertFalse(freshFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(freshFixture.communityRevnetId), 0);
        assertEq(freshFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT / 2);
        assertEq(freshFixture.goalTerminalOne.totalReceived(), 5e18);
        assertEq(freshFixture.goalTerminalTwo.totalReceived(), 15e18);
        assertEq(freshFixture.goalTerminalOne.lastBeneficiary(), payerTwo);
        assertEq(freshFixture.goalTerminalTwo.lastBeneficiary(), payerTwo);
        assertEq(freshFixture.hook.observedVolumeOf(freshFixture.goalIdOne), 5e18);
        assertEq(freshFixture.hook.observedVolumeOf(freshFixture.goalIdTwo), 15e18);
        assertEq(freshFixture.hook.cumulativeObservedVolume(), 20e18);

        uint256 flushedBacklogAmount = freshFixture.hook.flushHistoricalBacklog(2);

        assertEq(flushedBacklogAmount, DIRECT_PAY_AMOUNT / 2);
        assertEq(freshFixture.hook.historicalBacklogAmount(), 0);
        assertEq(freshFixture.goalTerminalOne.totalReceived(), 10e18);
        assertEq(freshFixture.goalTerminalTwo.totalReceived(), 30e18);
        assertEq(freshFixture.goalTerminalOne.lastBeneficiary(), address(freshFixture.goalTreasuryOne));
        assertEq(freshFixture.goalTerminalTwo.lastBeneficiary(), address(freshFixture.goalTreasuryTwo));
        assertEq(freshFixture.hook.observedVolumeOf(freshFixture.goalIdOne), 5e18);
        assertEq(freshFixture.hook.observedVolumeOf(freshFixture.goalIdTwo), 15e18);
        assertEq(freshFixture.hook.cumulativeObservedVolume(), 20e18);
    }

    function test_harnessManualRoute_goalFundingOnlyHappensWhenReservedTokensAreSentToSplits() public {
        _seedManualObservedRoute(ROUTE_SEED_AMOUNT);
        uint256 observedVolumeOneBefore = manualFixture.hook.observedVolumeOf(manualFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = manualFixture.hook.observedVolumeOf(manualFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = manualFixture.hook.cumulativeObservedVolume();

        _payCommunityDirect(
            manualFixture.communityTerminal,
            manualFixture.communityRevnetId,
            manualFixture.communityToken,
            payer,
            DIRECT_PAY_AMOUNT
        );

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 25e18);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 75e18);

        controller.sendReservedTokensToSplitsOf(manualFixture.communityRevnetId);

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), 0);
        assertEq(manualFixture.hook.historicalBacklogAmount(), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 25e18);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 75e18);
        assertEq(manualFixture.hook.observedVolumeOf(manualFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(manualFixture.hook.observedVolumeOf(manualFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);

        uint256 flushedBacklogAmount = manualFixture.hook.flushHistoricalBacklog(2);

        assertEq(flushedBacklogAmount, DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.hook.historicalBacklogAmount(), 0);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 35e18);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 105e18);
        assertEq(manualFixture.goalTerminalOne.lastBeneficiary(), address(manualFixture.goalTreasuryOne));
        assertEq(manualFixture.goalTerminalTwo.lastBeneficiary(), address(manualFixture.goalTreasuryTwo));
        assertEq(manualFixture.hook.observedVolumeOf(manualFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(manualFixture.hook.observedVolumeOf(manualFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);
    }

    function test_harnessManualRouteAtSplitDistributionAppliesToAggregateReservedBalance() public {
        _beginPendingRoute(
            manualFixture.hook,
            manualFixture.routeSetter,
            payer,
            routeBeneficiary,
            manualFixture.goalIdOne,
            manualFixture.goalIdTwo
        );

        _payCommunityDirect(
            manualFixture.communityTerminal, manualFixture.communityRevnetId, manualFixture.communityToken, payer, 40e18
        );
        _payCommunityDirect(
            manualFixture.communityTerminal,
            manualFixture.communityRevnetId,
            manualFixture.communityToken,
            payerTwo,
            60e18
        );

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), 100e18);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 0);

        controller.sendReservedTokensToSplitsOf(manualFixture.communityRevnetId);

        assertFalse(manualFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), 0);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 25e18);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 75e18);
        assertEq(manualFixture.goalTerminalOne.lastBeneficiary(), routeBeneficiary);
        assertEq(manualFixture.goalTerminalTwo.lastBeneficiary(), routeBeneficiary);
        assertEq(manualFixture.hook.observedVolumeOf(manualFixture.goalIdOne), 25e18);
        assertEq(manualFixture.hook.observedVolumeOf(manualFixture.goalIdTwo), 75e18);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), 100e18);
    }

    function _deployWrapperFixture(uint16 reservedPercent) internal returns (WrapperFixture memory fixture) {
        GoalDeploymentRegistry goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));

        (fixture.communityRevnetId, fixture.communityToken) =
            controller.createProject(multisig, reservedPercent, "Wrapper Community", "WCOMM");
        fixture.wrapper =
            new CobuildCommunityTerminal(IJBDirectory(address(directory)), IJBTerminalStore(address(terminalStore)));
        fixture.communityTerminal =
            new AsyncCommunityTerminal(controller, fixture.communityRevnetId, fixture.communityToken);
        directory.setPrimaryTerminalOf(
            fixture.communityRevnetId, address(fixture.communityToken), IJBTerminal(address(fixture.wrapper))
        );
        directory.setPrimaryTerminalOf(
            fixture.communityRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(address(fixture.wrapper))
        );
        vm.prank(multisig);
        controller.setProjectTerminal(fixture.communityRevnetId, address(fixture.wrapper), true);
        vm.prank(multisig);
        controller.setProjectTerminal(fixture.communityRevnetId, address(fixture.communityTerminal), true);

        fixture.registry = _deployCommunityGoalRegistry(
            fixture.communityRevnetId, address(fixture.communityToken), goalDeploymentRegistry
        );

        (fixture.goalIdOne, fixture.goalTerminalOne, fixture.goalTreasuryOne) = _deployGoal(
            goalDeploymentRegistry, fixture.communityRevnetId, address(fixture.communityToken), "Wrapper Goal One"
        );
        (fixture.goalIdTwo, fixture.goalTerminalTwo, fixture.goalTreasuryTwo) = _deployGoal(
            goalDeploymentRegistry, fixture.communityRevnetId, address(fixture.communityToken), "Wrapper Goal Two"
        );
        _listGoals(
            fixture.registry, fixture.communityRevnetId, fixture.communityToken, fixture.goalIdOne, fixture.goalIdTwo
        );

        fixture.hook = _deployHookClone();
        fixture.hook
            .initialize(
                IJBDirectory(address(directory)),
                fixture.communityRevnetId,
                address(fixture.communityToken),
                address(fixture.wrapper),
                fixture.registry
            );
        vm.prank(multisig);
        fixture.wrapper
            .registerCommunity(
                fixture.communityRevnetId,
                ICobuildSplitHook(address(fixture.hook)),
                address(fixture.communityToken),
                fixture.communityRevnetId,
                true
            );

        vm.prank(multisig);
        controller.setReservedSplitHook(fixture.communityRevnetId, IJBSplitHook(address(fixture.hook)));
    }

    function _deployManualFixture(uint16 reservedPercent) internal returns (ManualFixture memory fixture) {
        GoalDeploymentRegistry goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));

        (fixture.communityRevnetId, fixture.communityToken) =
            controller.createProject(multisig, reservedPercent, "Manual Community", "MCOMM");
        fixture.communityTerminal =
            new AsyncCommunityTerminal(controller, fixture.communityRevnetId, fixture.communityToken);
        directory.setPrimaryTerminalOf(
            fixture.communityRevnetId, address(fixture.communityToken), IJBTerminal(address(fixture.communityTerminal))
        );
        vm.prank(multisig);
        controller.setProjectTerminal(fixture.communityRevnetId, address(fixture.communityTerminal), true);

        fixture.registry = _deployCommunityGoalRegistry(
            fixture.communityRevnetId, address(fixture.communityToken), goalDeploymentRegistry
        );

        (fixture.goalIdOne, fixture.goalTerminalOne, fixture.goalTreasuryOne) = _deployGoal(
            goalDeploymentRegistry, fixture.communityRevnetId, address(fixture.communityToken), "Manual Goal One"
        );
        (fixture.goalIdTwo, fixture.goalTerminalTwo, fixture.goalTreasuryTwo) = _deployGoal(
            goalDeploymentRegistry, fixture.communityRevnetId, address(fixture.communityToken), "Manual Goal Two"
        );
        _listGoals(
            fixture.registry, fixture.communityRevnetId, fixture.communityToken, fixture.goalIdOne, fixture.goalIdTwo
        );

        fixture.routeSetter = address(new RouteSetterStub());
        fixture.hook = _deployHookClone();
        fixture.hook
            .initialize(
                IJBDirectory(address(directory)),
                fixture.communityRevnetId,
                address(fixture.communityToken),
                fixture.routeSetter,
                fixture.registry
            );

        vm.prank(multisig);
        controller.setReservedSplitHook(fixture.communityRevnetId, IJBSplitHook(address(fixture.hook)));
    }

    function _deployCommunityGoalRegistry(
        uint256 communityRevnetId,
        address communityToken,
        GoalDeploymentRegistry goalDeploymentRegistry
    ) internal returns (CommunityGoalRegistry registry) {
        CommunityGoalRegistry implementation = new CommunityGoalRegistry();
        registry = CommunityGoalRegistry(Clones.clone(address(implementation)));

        RoundTestArbitrator arbitrator =
            new RoundTestArbitrator(IVotes(communityToken), address(registry), 1, 1, 1, ARBITRATION_COST);
        EscrowSubmissionDepositStrategy depositStrategy = new EscrowSubmissionDepositStrategy(IERC20(communityToken));

        registry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(arbitrator, IVotes(communityToken), depositStrategy),
                directory: IJBDirectory(address(directory)),
                goalDeploymentRegistry: IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
                communityRevnetId: communityRevnetId,
                communityToken: communityToken
            })
        );
    }

    function _deployGoal(
        GoalDeploymentRegistry goalDeploymentRegistry,
        uint256 communityRevnetId,
        address communityToken,
        string memory nameHint
    ) internal returns (uint256 goalId, GoalRecordingTerminal terminal, GoalTreasuryStub treasury) {
        (goalId,) = controller.createProject(multisig, 0, nameHint, "GOAL");
        terminal = new GoalRecordingTerminal(communityToken);
        treasury = new GoalTreasuryStub(goalId, communityRevnetId, address(new StakeVaultStub(communityToken)));

        goalDeploymentRegistry.registerGoal(goalId, address(treasury));
        directory.setPrimaryTerminalOf(goalId, communityToken, IJBTerminal(address(terminal)));
    }

    function _listGoals(
        CommunityGoalRegistry registry,
        uint256 communityRevnetId,
        MockVotesToken communityToken,
        uint256 goalIdOne,
        uint256 goalIdTwo
    ) internal {
        _mintCommunityTokens(communityRevnetId, communityToken, multisig, 2 * (SUBMISSION_DEPOSIT + ARBITRATION_COST));

        vm.startPrank(multisig);
        communityToken.approve(address(registry), type(uint256).max);
        bytes32 itemIdOne = registry.addItem(_goalItem(goalIdOne, "ipfs://goal-one"));
        bytes32 itemIdTwo = registry.addItem(_goalItem(goalIdTwo, "ipfs://goal-two"));
        vm.stopPrank();

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(itemIdOne);
        registry.executeRequest(itemIdTwo);
    }

    function _seedManualObservedRoute(uint256 amount) internal {
        _beginPendingRoute(
            manualFixture.hook,
            manualFixture.routeSetter,
            payer,
            routeBeneficiary,
            manualFixture.goalIdOne,
            manualFixture.goalIdTwo
        );
        _payCommunityDirect(
            manualFixture.communityTerminal,
            manualFixture.communityRevnetId,
            manualFixture.communityToken,
            payer,
            amount
        );
        controller.sendReservedTokensToSplitsOf(manualFixture.communityRevnetId);
    }

    function _seedObservedHistoryForWrapperFixture(WrapperFixture memory fixture, uint256 amount) internal {
        uint256[] memory goalIds = _goalIds(fixture.goalIdOne, fixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        _payWrapper(fixture, payer, amount, routeBeneficiary, "seed-history", abi.encode(goalIds, weights));
    }

    function _beginPendingRoute(
        ICobuildSplitHook hook,
        address routeSetter,
        address pendingPayer,
        address beneficiary,
        uint256 goalIdOne,
        uint256 goalIdTwo
    ) internal {
        uint256[] memory goalIds = _goalIds(goalIdOne, goalIdTwo);
        uint32[] memory weights = _weights(1, 3);

        vm.prank(routeSetter);
        hook.beginPendingRoute(pendingPayer, beneficiary, 0, goalIds, weights);
    }

    function _payWrapper(
        WrapperFixture memory fixture,
        address from,
        uint256 amount,
        address beneficiary,
        string memory memo,
        bytes memory metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        _mintCommunityTokens(fixture.communityRevnetId, fixture.communityToken, from, amount);

        vm.startPrank(from);
        fixture.communityToken.approve(address(fixture.wrapper), amount);
        beneficiaryTokenCount = fixture.wrapper
            .pay(fixture.communityRevnetId, address(fixture.communityToken), amount, beneficiary, 0, memo, metadata);
        vm.stopPrank();
    }

    function _payCommunityDirect(
        AsyncCommunityTerminal communityTerminal,
        uint256 communityRevnetId,
        MockVotesToken communityToken,
        address from,
        uint256 amount
    ) internal {
        _mintCommunityTokens(communityRevnetId, communityToken, from, amount);

        vm.startPrank(from);
        communityToken.approve(address(communityTerminal), amount);
        communityTerminal.pay(communityRevnetId, address(communityToken), amount, from, 0, "community-pay", bytes(""));
        vm.stopPrank();
    }

    function _mintCommunityTokens(uint256 projectId, MockVotesToken communityToken, address beneficiary, uint256 amount)
        internal
    {
        uint256 balanceBefore = communityToken.balanceOf(beneficiary);

        vm.prank(multisig);
        controller.mintTokensOf(projectId, amount, beneficiary, false);

        assertEq(communityToken.balanceOf(beneficiary) - balanceBefore, amount);
    }

    function _deployHookClone() internal returns (CobuildSplitHook hook) {
        CobuildSplitHook implementation = new CobuildSplitHook();
        hook = CobuildSplitHook(payable(Clones.clone(address(implementation))));
    }

    function _goalItem(uint256 goalId, string memory metadataURI) internal pure returns (bytes memory item) {
        item = abi.encode(ICommunityGoalRegistry.GoalItemData({goalId: goalId, metadataURI: metadataURI}));
    }

    function _registryConfig(
        RoundTestArbitrator arbitrator,
        IVotes communityToken,
        EscrowSubmissionDepositStrategy depositStrategy
    ) internal pure returns (IGeneralizedTCRConfig.RegistryConfig memory config) {
        config = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: arbitrator,
            votingToken: communityToken,
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

    function _goalIds(uint256 goalIdOne, uint256 goalIdTwo) internal pure returns (uint256[] memory goalIds) {
        goalIds = new uint256[](2);
        goalIds[0] = goalIdOne;
        goalIds[1] = goalIdTwo;
    }

    function _weights(uint32 first, uint32 second) internal pure returns (uint32[] memory weights) {
        weights = new uint32[](2);
        weights[0] = first;
        weights[1] = second;
    }
}

contract RouteSetterStub {}

contract AsyncTokens {
    mapping(uint256 projectId => MockVotesToken token) public tokenOf;

    function setTokenOf(uint256 projectId, MockVotesToken token) external {
        tokenOf[projectId] = token;
    }
}

contract AsyncReservedController is IERC165 {
    error UNAUTHORIZED();
    error INVALID_PROJECT();
    error NO_RESERVED_TOKENS();
    error NO_RESERVED_SPLIT_HOOK();

    struct ProjectConfig {
        address owner;
        MockVotesToken token;
        uint16 reservedPercent;
        IJBSplitHook reservedSplitHook;
    }

    AsyncDirectory public immutable directory;
    AsyncTokens public immutable TOKENS;

    uint256 public projectCount;
    mapping(uint256 projectId => uint256) public pendingReservedTokenBalanceOf;

    mapping(uint256 projectId => ProjectConfig) internal _projectConfigOf;
    mapping(uint256 projectId => mapping(address terminal => bool)) internal _isProjectTerminal;

    constructor(AsyncDirectory directory_) {
        directory = directory_;
        TOKENS = new AsyncTokens();
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }

    function createProject(address owner, uint16 reservedPercent, string memory tokenName, string memory tokenSymbol)
        external
        returns (uint256 projectId, MockVotesToken token)
    {
        projectId = ++projectCount;
        token = new MockVotesToken(tokenName, tokenSymbol);

        _projectConfigOf[projectId] = ProjectConfig({
            owner: owner, token: token, reservedPercent: reservedPercent, reservedSplitHook: IJBSplitHook(address(0))
        });
        TOKENS.setTokenOf(projectId, token);
        directory.setControllerOf(projectId, IERC165(address(this)));
        directory.setProjectOwner(projectId, owner);
    }

    function setProjectTerminal(uint256 projectId, address terminal, bool allowed) external {
        if (msg.sender != _projectConfigOf[projectId].owner) revert UNAUTHORIZED();
        _isProjectTerminal[projectId][terminal] = allowed;
    }

    function setReservedSplitHook(uint256 projectId, IJBSplitHook hook) external {
        if (msg.sender != _projectConfigOf[projectId].owner) revert UNAUTHORIZED();
        _projectConfigOf[projectId].reservedSplitHook = hook;
    }

    function mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary, bool useReservedPercent)
        external
        returns (uint256 beneficiaryTokenCount)
    {
        return _mintTokensOf(projectId, tokenCount, beneficiary, useReservedPercent);
    }

    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        string calldata,
        bool useReservedPercent
    ) external returns (uint256 beneficiaryTokenCount) {
        return _mintTokensOf(projectId, tokenCount, beneficiary, useReservedPercent);
    }

    function _mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary, bool useReservedPercent)
        internal
        returns (uint256 beneficiaryTokenCount)
    {
        ProjectConfig storage config = _projectConfigOf[projectId];
        if (address(config.token) == address(0)) revert INVALID_PROJECT();
        if (msg.sender != config.owner && !_isProjectTerminal[projectId][msg.sender]) revert UNAUTHORIZED();

        uint256 reservedPercent = useReservedPercent ? config.reservedPercent : 0;
        beneficiaryTokenCount =
            (tokenCount * (JBConstants.MAX_RESERVED_PERCENT - reservedPercent)) / JBConstants.MAX_RESERVED_PERCENT;

        if (beneficiaryTokenCount != 0) {
            config.token.mint(beneficiary, beneficiaryTokenCount);
        }

        uint256 reservedTokenCount = tokenCount - beneficiaryTokenCount;
        if (reservedTokenCount != 0) {
            pendingReservedTokenBalanceOf[projectId] += reservedTokenCount;
        }
    }

    function sendReservedTokensToSplitsOf(uint256 projectId) external returns (uint256 tokenCount) {
        ProjectConfig storage config = _projectConfigOf[projectId];
        if (address(config.token) == address(0)) revert INVALID_PROJECT();

        tokenCount = pendingReservedTokenBalanceOf[projectId];
        if (tokenCount == 0) revert NO_RESERVED_TOKENS();
        if (address(config.reservedSplitHook) == address(0)) revert NO_RESERVED_SPLIT_HOOK();

        pendingReservedTokenBalanceOf[projectId] = 0;
        config.token.mint(address(config.reservedSplitHook), tokenCount);

        config.reservedSplitHook
            .processSplitWith(
                JBSplitHookContext({
                    token: address(config.token),
                    amount: tokenCount,
                    decimals: 18,
                    projectId: projectId,
                    groupId: 1,
                    split: JBSplit({
                        percent: JBConstants.SPLITS_TOTAL_PERCENT,
                        projectId: 0,
                        beneficiary: payable(address(0)),
                        preferAddToBalance: false,
                        lockedUntil: 0,
                        hook: config.reservedSplitHook
                    })
                })
            );
    }
}

contract AsyncDirectory is IJBDirectory {
    IJBProjects public override PROJECTS = IJBProjects(address(new AsyncProjects()));

    mapping(uint256 projectId => IERC165 controller) public override controllerOf;
    mapping(address account => bool) public override isAllowedToSetFirstController;
    mapping(uint256 projectId => IJBTerminal[]) internal _terminalsOfProject;
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _primaryTerminalOf;
    mapping(uint256 projectId => mapping(address terminal => bool allowed)) internal _isTerminalOfProject;

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view override returns (bool) {
        return _isTerminalOfProject[projectId][address(terminal)];
    }

    function primaryTerminalOf(uint256 projectId, address token) external view override returns (IJBTerminal) {
        IJBTerminal terminal = _primaryTerminalOf[projectId][token];
        if (address(terminal) != address(0)) return terminal;

        IJBTerminal[] memory terminals = _terminalsOfProject[projectId];
        for (uint256 i = 0; i < terminals.length; i++) {
            if (terminals[i].accountingContextForTokenOf(projectId, token).token != address(0)) {
                return terminals[i];
            }
        }

        return IJBTerminal(address(0));
    }

    function terminalsOf(uint256 projectId) external view override returns (IJBTerminal[] memory) {
        return _terminalsOfProject[projectId];
    }

    function setControllerOf(uint256 projectId, IERC165 controller) public override {
        controllerOf[projectId] = controller;
    }

    function setProjectOwner(uint256 projectId, address owner) public {
        AsyncProjects(address(PROJECTS)).setOwner(projectId, owner);
    }

    function setIsAllowedToSetFirstController(address account, bool flag) external override {
        isAllowedToSetFirstController[account] = flag;
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) public override {
        if (terminal.accountingContextForTokenOf(projectId, token).token == address(0)) {
            revert("TOKEN_NOT_ACCEPTED");
        }

        if (!_isTerminalOfProject[projectId][address(terminal)]) {
            _isTerminalOfProject[projectId][address(terminal)] = true;
            _terminalsOfProject[projectId].push(terminal);
        }

        _primaryTerminalOf[projectId][token] = terminal;
    }

    function setTerminalsOf(uint256 projectId, IJBTerminal[] calldata terminals) external override {
        delete _terminalsOfProject[projectId];

        for (uint256 i = 0; i < terminals.length; i++) {
            _terminalsOfProject[projectId].push(terminals[i]);
            _isTerminalOfProject[projectId][address(terminals[i])] = true;
        }
    }
}

contract AsyncProjects {
    mapping(uint256 projectId => address owner) internal _ownerOf;

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }
}

contract AsyncCommunityTerminal is IJBTerminal {
    using SafeERC20 for IERC20;

    AsyncReservedController public immutable controller;
    uint256 public immutable projectId;
    MockVotesToken public immutable acceptedToken;

    constructor(AsyncReservedController controller_, uint256 projectId_, MockVotesToken acceptedToken_) {
        controller = controller_;
        projectId = projectId_;
        acceptedToken = acceptedToken_;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextForTokenOf(
        uint256 projectId_,
        address token
    ) external view override returns (JBAccountingContext memory context) {
        if (projectId_ != projectId || token != address(acceptedToken)) {
            return JBAccountingContext({token: address(0), decimals: 0, currency: 0});
        }

        return JBAccountingContext({token: address(acceptedToken), decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function accountingContextsOf(uint256 projectId_) external view override returns (JBAccountingContext[] memory contexts) {
        if (projectId_ != projectId) return new JBAccountingContext[](0);

        contexts = new JBAccountingContext[](1);
        contexts[0] =
            JBAccountingContext({token: address(acceptedToken), decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    ) external payable override {
        revert("UNSUPPORTED");
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256 projectId_,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    ) external payable override returns (uint256 beneficiaryTokenCount) {
        if (projectId_ != projectId || token != address(acceptedToken)) revert("INVALID_PAY");

        IERC20(address(acceptedToken)).safeTransferFrom(msg.sender, address(this), amount);
        return controller.mintTokensOf(projectId, amount, beneficiary, true);
    }
}

contract GoalRecordingTerminal is IJBTerminal {
    using SafeERC20 for IERC20;

    address public immutable acceptedToken;

    uint256 public totalReceived;
    uint256 public lastAmount;
    uint256 public lastProjectId;
    address public lastBeneficiary;
    bytes public lastMetadata;
    mapping(address beneficiary => uint256 amount) public receivedByBeneficiary;

    constructor(address acceptedToken_) {
        acceptedToken = acceptedToken_;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    ) external view override returns (JBAccountingContext memory context) {
        if (token != acceptedToken) {
            return JBAccountingContext({token: address(0), decimals: 0, currency: 0});
        }

        return JBAccountingContext({token: acceptedToken, decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function accountingContextsOf(uint256) external view override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: acceptedToken, decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    ) external payable override {
        revert("UNSUPPORTED");
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata metadata
    ) external payable override returns (uint256 beneficiaryTokenCount) {
        if (token != acceptedToken) revert("INVALID_TOKEN");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
        lastAmount = amount;
        lastProjectId = projectId;
        lastBeneficiary = beneficiary;
        lastMetadata = metadata;
        receivedByBeneficiary[beneficiary] += amount;
    }
}

contract GoalTreasuryStub {
    uint256 public immutable goalRevnetId;
    uint256 public immutable cobuildRevnetId;
    address public immutable stakeVault;
    IGoalTreasury.GoalState internal _state;
    bool internal _canAcceptHookFunding = true;

    constructor(uint256 goalRevnetId_, uint256 cobuildRevnetId_, address stakeVault_) {
        goalRevnetId = goalRevnetId_;
        cobuildRevnetId = cobuildRevnetId_;
        stakeVault = stakeVault_;
        _state = IGoalTreasury.GoalState.Funding;
    }

    function canAcceptHookFunding() external view returns (bool) {
        return _canAcceptHookFunding;
    }

    function state() external view returns (IGoalTreasury.GoalState) {
        return _state;
    }

    function setCanAcceptHookFunding(bool canAcceptHookFunding_) external {
        _canAcceptHookFunding = canAcceptHookFunding_;
    }

    function setGoalState(IGoalTreasury.GoalState state_) external {
        _state = state_;
    }
}

contract StakeVaultStub {
    IERC20 public immutable cobuildToken;

    constructor(address cobuildToken_) {
        cobuildToken = IERC20(cobuildToken_);
    }
}

contract NoopNativeTerminal is IJBTerminal {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    ) external pure override returns (JBAccountingContext memory context) {
        if (token != JBConstants.NATIVE_TOKEN) {
            return JBAccountingContext({token: address(0), decimals: 0, currency: 0});
        }

        return JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
            JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: TEST_ACCOUNTING_CURRENCY});
    }

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    ) external payable override {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256,
        address token,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    ) external payable override returns (uint256) {
        if (token != JBConstants.NATIVE_TOKEN || msg.value != amount) revert("INVALID_PAY");
        return amount;
    }
}
