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
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {CobuildPaymentTerminal} from "src/juicebox/CobuildPaymentTerminal.sol";
import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {RoundTestArbitrator} from "test/rounds/helpers/RoundTestMocks.sol";

uint32 constant TEST_ACCOUNTING_CURRENCY = 1;

contract CobuildPaymentTerminalCoreIntegrationTest is Test {
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

    struct WrapperFixture {
        uint256 communityRevnetId;
        MockVotesToken communityToken;
        AsyncCommunityTerminal communityTerminal;
        CobuildPaymentTerminal wrapper;
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

        wrapperFixture = _deployWrapperFixture(HALF_RESERVED_PERCENT);
        manualFixture = _deployManualFixture(FULL_RESERVED_PERCENT);
    }

    function test_wrapperExplicitRoute_fundsSelectedGoalsAndMintsCommunityTokensInSameTransaction() public {
        uint256[] memory goalIds = _goalIds(wrapperFixture.goalIdOne, wrapperFixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        uint256 beneficiaryTokenCount = _payWrapper(
            wrapperFixture, payer, DIRECT_PAY_AMOUNT, payer, "pick-goals", abi.encode(goalIds, weights)
        );

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

    function test_wrapperHistoricalRoute_usesObservedHistoryAndFundsGoalsInSameTransaction() public {
        _seedObservedHistoryForWrapperFixture(wrapperFixture, DIRECT_PAY_AMOUNT);
        uint256 observedVolumeOneBefore = wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = wrapperFixture.hook.cumulativeObservedVolume();

        uint256 beneficiaryTokenCount =
            _payWrapper(wrapperFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "historical-route", bytes(""));

        assertEq(beneficiaryTokenCount, DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.communityToken.balanceOf(payerTwo), DIRECT_PAY_AMOUNT / 2);
        assertFalse(wrapperFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(wrapperFixture.communityRevnetId), 0);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 10e18);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 30e18);
        assertEq(wrapperFixture.goalTerminalOne.lastBeneficiary(), payerTwo);
        assertEq(wrapperFixture.goalTerminalTwo.lastBeneficiary(), payerTwo);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(wrapperFixture.hook.observedVolumeOf(wrapperFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(wrapperFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);
    }

    function test_wrapperHistoricalRoute_withFullReservedMintPreservesBeneficiaryAndFlushesReservedTokens() public {
        WrapperFixture memory fullReservedFixture = _deployWrapperFixture(FULL_RESERVED_PERCENT);
        _seedObservedHistoryForWrapperFixture(fullReservedFixture, DIRECT_PAY_AMOUNT);
        uint256 observedVolumeOneBefore = fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = fullReservedFixture.hook.cumulativeObservedVolume();

        uint256 beneficiaryTokenCount =
            _payWrapper(fullReservedFixture, payerTwo, DIRECT_PAY_AMOUNT, payerTwo, "historical-route", bytes(""));

        assertEq(beneficiaryTokenCount, 0);
        assertEq(fullReservedFixture.communityToken.balanceOf(payerTwo), 0);
        assertFalse(fullReservedFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(fullReservedFixture.communityRevnetId), 0);
        assertEq(fullReservedFixture.goalTerminalOne.totalReceived(), 20e18);
        assertEq(fullReservedFixture.goalTerminalTwo.totalReceived(), 60e18);
        assertEq(fullReservedFixture.goalTerminalOne.lastBeneficiary(), payerTwo);
        assertEq(fullReservedFixture.goalTerminalTwo.lastBeneficiary(), payerTwo);
        assertEq(fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdOne), observedVolumeOneBefore);
        assertEq(fullReservedFixture.hook.observedVolumeOf(fullReservedFixture.goalIdTwo), observedVolumeTwoBefore);
        assertEq(fullReservedFixture.hook.cumulativeObservedVolume(), cumulativeObservedBefore);
    }

    function test_wrapperExplicitRoute_revertsWhenPendingReservedTokensAlreadyExist() public {
        _payCommunityDirect(
            wrapperFixture.communityTerminal, wrapperFixture.communityRevnetId, wrapperFixture.communityToken, payer, DIRECT_PAY_AMOUNT
        );

        uint256[] memory goalIds = _goalIds(wrapperFixture.goalIdOne, wrapperFixture.goalIdTwo);
        uint32[] memory weights = _weights(1, 3);
        _mintCommunityTokens(wrapperFixture.communityRevnetId, wrapperFixture.communityToken, payerTwo, DIRECT_PAY_AMOUNT);

        vm.startPrank(payerTwo);
        wrapperFixture.communityToken.approve(address(wrapperFixture.wrapper), DIRECT_PAY_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.PENDING_RESERVED_TOKENS.selector, DIRECT_PAY_AMOUNT / 2)
        );
        wrapperFixture.wrapper.pay(
            wrapperFixture.communityRevnetId,
            address(wrapperFixture.communityToken),
            DIRECT_PAY_AMOUNT,
            payerTwo,
            0,
            "pick-goals",
            abi.encode(goalIds, weights)
        );
        vm.stopPrank();

        assertEq(controller.pendingReservedTokenBalanceOf(wrapperFixture.communityRevnetId), DIRECT_PAY_AMOUNT / 2);
        assertEq(wrapperFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(wrapperFixture.goalTerminalTwo.totalReceived(), 0);
    }

    function test_directCommunityPayWithoutHistoricalRoute_laterDistributionReverts() public {
        _payCommunityDirect(
            manualFixture.communityTerminal, manualFixture.communityRevnetId, manualFixture.communityToken, payer, DIRECT_PAY_AMOUNT
        );

        assertFalse(manualFixture.hook.hasPendingRoute());
        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 0);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), 0);

        vm.expectRevert(CobuildSplitHook.NO_ROUTE_AVAILABLE.selector);
        controller.sendReservedTokensToSplitsOf(manualFixture.communityRevnetId);

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 0);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 0);
        assertEq(manualFixture.hook.cumulativeObservedVolume(), 0);
    }

    function test_harnessManualRoute_goalFundingOnlyHappensWhenReservedTokensAreSentToSplits() public {
        _seedManualObservedRoute(ROUTE_SEED_AMOUNT);
        uint256 observedVolumeOneBefore = manualFixture.hook.observedVolumeOf(manualFixture.goalIdOne);
        uint256 observedVolumeTwoBefore = manualFixture.hook.observedVolumeOf(manualFixture.goalIdTwo);
        uint256 cumulativeObservedBefore = manualFixture.hook.cumulativeObservedVolume();

        _payCommunityDirect(
            manualFixture.communityTerminal, manualFixture.communityRevnetId, manualFixture.communityToken, payer, DIRECT_PAY_AMOUNT
        );

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), DIRECT_PAY_AMOUNT);
        assertEq(manualFixture.goalTerminalOne.totalReceived(), 25e18);
        assertEq(manualFixture.goalTerminalTwo.totalReceived(), 75e18);

        controller.sendReservedTokensToSplitsOf(manualFixture.communityRevnetId);

        assertEq(controller.pendingReservedTokenBalanceOf(manualFixture.communityRevnetId), 0);
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

        _payCommunityDirect(manualFixture.communityTerminal, manualFixture.communityRevnetId, manualFixture.communityToken, payer, 40e18);
        _payCommunityDirect(
            manualFixture.communityTerminal, manualFixture.communityRevnetId, manualFixture.communityToken, payerTwo, 60e18
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
        fixture.communityTerminal =
            new AsyncCommunityTerminal(controller, fixture.communityRevnetId, fixture.communityToken);
        directory.setPrimaryTerminalOf(
            fixture.communityRevnetId, address(fixture.communityToken), IJBTerminal(address(fixture.communityTerminal))
        );
        vm.prank(multisig);
        controller.setProjectTerminal(fixture.communityRevnetId, address(fixture.communityTerminal), true);

        CommunityGoalRegistry registry =
            _deployCommunityGoalRegistry(fixture.communityRevnetId, address(fixture.communityToken), goalDeploymentRegistry);

        (fixture.goalIdOne, fixture.goalTerminalOne, fixture.goalTreasuryOne) =
            _deployGoal(goalDeploymentRegistry, address(fixture.communityToken), "Wrapper Goal One");
        (fixture.goalIdTwo, fixture.goalTerminalTwo, fixture.goalTreasuryTwo) =
            _deployGoal(goalDeploymentRegistry, address(fixture.communityToken), "Wrapper Goal Two");
        _pinGoals(registry, fixture.goalIdOne, fixture.goalIdTwo);

        fixture.hook = _deployHookClone();
        fixture.wrapper = new CobuildPaymentTerminal(
            IJBDirectory(address(directory)),
            ICobuildSplitHook(address(fixture.hook)),
            address(fixture.communityToken),
            fixture.communityRevnetId,
            fixture.communityRevnetId
        );
        fixture.hook.initialize(
            IJBDirectory(address(directory)),
            fixture.communityRevnetId,
            address(fixture.communityToken),
            address(fixture.wrapper),
            registry
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

        CommunityGoalRegistry registry =
            _deployCommunityGoalRegistry(fixture.communityRevnetId, address(fixture.communityToken), goalDeploymentRegistry);

        (fixture.goalIdOne, fixture.goalTerminalOne, fixture.goalTreasuryOne) =
            _deployGoal(goalDeploymentRegistry, address(fixture.communityToken), "Manual Goal One");
        (fixture.goalIdTwo, fixture.goalTerminalTwo, fixture.goalTreasuryTwo) =
            _deployGoal(goalDeploymentRegistry, address(fixture.communityToken), "Manual Goal Two");
        _pinGoals(registry, fixture.goalIdOne, fixture.goalIdTwo);

        fixture.routeSetter = address(new RouteSetterStub());
        fixture.hook = _deployHookClone();
        fixture.hook.initialize(
            IJBDirectory(address(directory)),
            fixture.communityRevnetId,
            address(fixture.communityToken),
            fixture.routeSetter,
            registry
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
                communityToken: communityToken,
                owner: multisig
            })
        );
    }

    function _deployGoal(
        GoalDeploymentRegistry goalDeploymentRegistry,
        address communityToken,
        string memory nameHint
    ) internal returns (uint256 goalId, GoalRecordingTerminal terminal, GoalTreasuryStub treasury) {
        (goalId,) = controller.createProject(multisig, 0, nameHint, "GOAL");
        terminal = new GoalRecordingTerminal(communityToken);
        treasury = new GoalTreasuryStub(goalId);

        goalDeploymentRegistry.registerGoal(goalId, address(treasury));
        directory.setPrimaryTerminalOf(goalId, communityToken, IJBTerminal(address(terminal)));
    }

    function _pinGoals(CommunityGoalRegistry registry, uint256 goalIdOne, uint256 goalIdTwo) internal {
        vm.startPrank(multisig);
        registry.pinSystemGoal(goalIdOne, "ipfs://goal-one");
        registry.pinSystemGoal(goalIdTwo, "ipfs://goal-two");
        vm.stopPrank();
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
        _payCommunityDirect(manualFixture.communityTerminal, manualFixture.communityRevnetId, manualFixture.communityToken, payer, amount);
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
        hook.beginPendingRoute(pendingPayer, beneficiary, goalIds, weights);
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
        beneficiaryTokenCount = fixture.wrapper.pay(
            fixture.communityRevnetId,
            address(fixture.communityToken),
            amount,
            beneficiary,
            0,
            memo,
            metadata
        );
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

    function _mintCommunityTokens(
        uint256 projectId,
        MockVotesToken communityToken,
        address beneficiary,
        uint256 amount
    ) internal {
        uint256 balanceBefore = communityToken.balanceOf(beneficiary);

        vm.prank(multisig);
        controller.mintTokensOf(projectId, amount, beneficiary, false);

        assertEq(communityToken.balanceOf(beneficiary) - balanceBefore, amount);
    }

    function _deployHookClone() internal returns (CobuildSplitHook hook) {
        CobuildSplitHook implementation = new CobuildSplitHook();
        hook = CobuildSplitHook(payable(Clones.clone(address(implementation))));
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

    uint256 public projectCount;
    mapping(uint256 projectId => uint256) public pendingReservedTokenBalanceOf;

    mapping(uint256 projectId => ProjectConfig) internal _projectConfigOf;
    mapping(uint256 projectId => mapping(address terminal => bool)) internal _isProjectTerminal;

    constructor(AsyncDirectory directory_) {
        directory = directory_;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }

    function createProject(
        address owner,
        uint16 reservedPercent,
        string memory tokenName,
        string memory tokenSymbol
    ) external returns (uint256 projectId, MockVotesToken token) {
        projectId = ++projectCount;
        token = new MockVotesToken(tokenName, tokenSymbol);

        _projectConfigOf[projectId] =
            ProjectConfig({owner: owner, token: token, reservedPercent: reservedPercent, reservedSplitHook: IJBSplitHook(address(0))});
        directory.setControllerOf(projectId, IERC165(address(this)));
    }

    function setProjectTerminal(uint256 projectId, address terminal, bool allowed) external {
        if (msg.sender != _projectConfigOf[projectId].owner) revert UNAUTHORIZED();
        _isProjectTerminal[projectId][terminal] = allowed;
    }

    function setReservedSplitHook(uint256 projectId, IJBSplitHook hook) external {
        if (msg.sender != _projectConfigOf[projectId].owner) revert UNAUTHORIZED();
        _projectConfigOf[projectId].reservedSplitHook = hook;
    }

    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        bool useReservedPercent
    ) external returns (uint256 beneficiaryTokenCount) {
        ProjectConfig storage config = _projectConfigOf[projectId];
        if (address(config.token) == address(0)) revert INVALID_PROJECT();
        if (msg.sender != config.owner && !_isProjectTerminal[projectId][msg.sender]) revert UNAUTHORIZED();

        uint256 reservedPercent = useReservedPercent ? config.reservedPercent : 0;
        beneficiaryTokenCount = (tokenCount * (JBConstants.MAX_RESERVED_PERCENT - reservedPercent)) / JBConstants.MAX_RESERVED_PERCENT;

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

        config.reservedSplitHook.processSplitWith(
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
    IJBProjects public constant override PROJECTS = IJBProjects(address(0));

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

    function setIsAllowedToSetFirstController(address account, bool flag) external override {
        isAllowedToSetFirstController[account] = flag;
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) public override {
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
    }
}

contract GoalTreasuryStub {
    uint256 public immutable goalRevnetId;

    constructor(uint256 goalRevnetId_) {
        goalRevnetId = goalRevnetId_;
    }
}
