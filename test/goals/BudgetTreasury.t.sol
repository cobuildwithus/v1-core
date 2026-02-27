// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IUMATreasurySuccessResolverConfig } from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {
    SharedMockCFA,
    SharedMockSuperfluidHost,
    SharedMockFlow,
    SharedMockSuperToken,
    SharedMockUnderlying
} from "test/goals/helpers/TreasurySharedMocks.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig,
    TreasuryMockUmaResolverConfigWithFinalize
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract BudgetTreasuryTest is Test {
    bytes32 internal constant ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");
    event FlowRateSyncManualInterventionRequired(
        address indexed flow, int96 targetRate, int96 fallbackRate, int96 currentRate
    );

    address internal owner = address(0xA11CE);
    address internal outsider = address(0xBEEF);
    address internal donor = address(0xD0D0);

    SharedMockUnderlying internal underlyingToken;
    SharedMockSuperToken internal superToken;
    SharedMockFlow internal flow;
    SharedMockFlow internal parentFlow;
    TreasuryMockOptimisticOracleV3 internal assertionOracle;
    TreasuryMockUmaResolverConfig internal successResolverConfig;
    BudgetTreasury internal treasury;
    BudgetTreasury internal budgetTreasuryImplementation;

    function setUp() public {
        underlyingToken = new SharedMockUnderlying();
        assertionOracle = new TreasuryMockOptimisticOracleV3();
        successResolverConfig = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            address(0),
            keccak256("budget-test-domain")
        );
        owner = address(successResolverConfig);
        superToken = new SharedMockSuperToken(address(underlyingToken));
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(1);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));
        flow = new SharedMockFlow(ISuperToken(address(superToken)));
        parentFlow = new SharedMockFlow(ISuperToken(address(superToken)));
        flow.setParent(address(parentFlow));
        flow.setMaxSafeFlowRate(type(int96).max);
        budgetTreasuryImplementation = new BudgetTreasury();

        treasury = _deploy(
            uint64(block.timestamp + 3 days),
            uint64(30 days),
            100e18,
            500e18
        );
    }

    function test_initialize_revertsOnZeroAddresses() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.flow = address(0);

        vm.expectRevert(IBudgetTreasury.ADDRESS_ZERO.selector);
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsOnImplementation() public {
        BudgetTreasury implementation = new BudgetTreasury();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsOnSecondInitialize() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        candidate.initialize(owner, _defaultBudgetConfig());

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsOnZeroOwner() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();

        vm.expectRevert(IBudgetTreasury.ADDRESS_ZERO.selector);
        candidate.initialize(address(0), _defaultBudgetConfig());
    }

    function test_initialize_revertsOnZeroSuccessResolverAddress() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.successResolver = address(0);

        vm.expectRevert(IBudgetTreasury.ADDRESS_ZERO.selector);
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsOnZeroFundingDeadline() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.fundingDeadline = 0;

        vm.expectRevert(IBudgetTreasury.INVALID_DEADLINES.selector);
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsWhenFlowSuperTokenIsZero() public {
        flow.setReturnZeroSuperToken(true);
        BudgetTreasury candidate = _cloneBudgetTreasury();

        vm.expectRevert(IBudgetTreasury.ADDRESS_ZERO.selector);
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsOnInvalidDeadlines() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.fundingDeadline = uint64(block.timestamp - 1);

        vm.expectRevert(IBudgetTreasury.INVALID_DEADLINES.selector);
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsWhenFundingDeadlineAndExecutionOverflowUint64() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.fundingDeadline = type(uint64).max;
        config.executionDuration = 1;

        vm.expectRevert(IBudgetTreasury.INVALID_DEADLINES.selector);
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsOnZeroExecutionDuration() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.executionDuration = 0;

        vm.expectRevert(IBudgetTreasury.INVALID_EXECUTION_DURATION.selector);
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsOnInvalidThresholds() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.activationThreshold = 100e18;
        config.runwayCap = 99e18;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTreasury.INVALID_THRESHOLDS.selector, 100e18, 99e18));
        candidate.initialize(owner, config);
    }

    function test_initialize_revertsWhenFlowOperatorIsNotTreasury() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        address unexpectedOperator = address(0xDEAD);
        flow.setFlowOperator(unexpectedOperator);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetTreasury.FLOW_AUTHORITY_MISMATCH.selector,
                address(candidate),
                unexpectedOperator,
                address(candidate)
            )
        );
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsWhenSweeperIsNotTreasury() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        address unexpectedSweeper = address(0xDEAD);
        flow.setSweeper(unexpectedSweeper);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetTreasury.FLOW_AUTHORITY_MISMATCH.selector,
                address(candidate),
                address(candidate),
                unexpectedSweeper
            )
        );
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsWhenParentFlowMissing() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        flow.setParent(address(0));

        vm.expectRevert(IBudgetTreasury.PARENT_FLOW_NOT_CONFIGURED.selector);
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsWhenParentFlowHasNoCode() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        flow.setParent(address(0xBEEF));

        vm.expectRevert(IBudgetTreasury.PARENT_FLOW_NOT_CONFIGURED.selector);
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_initialize_revertsWhenParentFlowMissingMemberRateSurface() public {
        BudgetTreasury candidate = _cloneBudgetTreasury();
        flow.setParent(address(new BudgetParentFlowWithoutMemberRate()));

        vm.expectRevert(IBudgetTreasury.PARENT_FLOW_NOT_CONFIGURED.selector);
        candidate.initialize(owner, _defaultBudgetConfig());
    }

    function test_canAcceptFunding_falseWhenFundingWindowEnds() public {
        vm.warp(treasury.fundingDeadline() + 1);
        assertFalse(treasury.canAcceptFunding());
    }

    function test_canAcceptFunding_trueDuringFunding() public view {
        assertTrue(treasury.canAcceptFunding());
    }

    function test_canAcceptFunding_falseWhenRunwayCapReachedDuringFunding() public {
        superToken.mint(address(flow), treasury.runwayCap());
        assertFalse(treasury.canAcceptFunding());
    }

    function test_donateUnderlyingAndUpgrade_transfersToFlow() public {
        underlyingToken.mint(donor, 40e18);

        vm.startPrank(donor);
        underlyingToken.approve(address(treasury), type(uint256).max);
        uint256 received = treasury.donateUnderlyingAndUpgrade(40e18);
        vm.stopPrank();

        assertEq(received, 40e18);
        assertEq(superToken.balanceOf(address(flow)), 40e18);
        assertEq(superToken.balanceOf(address(treasury)), 0);
    }

    function test_donateUnderlyingAndUpgrade_revertsOnReentrantCall() public {
        BudgetReentrantUnderlying reentrantUnderlying = new BudgetReentrantUnderlying();
        SharedMockSuperToken reentrantSuperToken = new SharedMockSuperToken(address(reentrantUnderlying));
        SharedMockFlow reentrantFlow = new SharedMockFlow(ISuperToken(address(reentrantSuperToken)));
        SharedMockFlow reentrantParentFlow = new SharedMockFlow(ISuperToken(address(reentrantSuperToken)));
        reentrantFlow.setParent(address(reentrantParentFlow));
        reentrantFlow.setMaxSafeFlowRate(type(int96).max);
        BudgetTreasury reentrantTreasury = _cloneBudgetTreasury();
        reentrantFlow.setFlowOperator(address(reentrantTreasury));
        reentrantFlow.setSweeper(address(reentrantTreasury));
        reentrantTreasury.initialize(
            owner,
            IBudgetTreasury.BudgetConfig({
                flow: address(reentrantFlow),
                fundingDeadline: uint64(block.timestamp + 3 days),
                executionDuration: uint64(30 days),
                activationThreshold: 100e18,
                runwayCap: 500e18,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("budget-oracle-spec"),
                successAssertionPolicyHash: keccak256("budget-assertion-policy")
            })
        );

        reentrantUnderlying.mint(donor, 10e18);
        reentrantUnderlying.armReentry(address(reentrantTreasury), 1e18);

        vm.startPrank(donor);
        reentrantUnderlying.approve(address(reentrantTreasury), type(uint256).max);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        reentrantTreasury.donateUnderlyingAndUpgrade(10e18);
        vm.stopPrank();
    }

    function test_donateUnderlyingAndUpgrade_revertsWhenFundingClosed() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();

        underlyingToken.mint(donor, 10e18);
        vm.prank(donor);
        underlyingToken.approve(address(treasury), type(uint256).max);

        vm.prank(donor);
        vm.expectRevert(IBudgetTreasury.INVALID_STATE.selector);
        treasury.donateUnderlyingAndUpgrade(10e18);
    }

    function test_canAcceptFunding_trueWhenActiveBeforeDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        assertTrue(treasury.canAcceptFunding());
    }

    function test_canAcceptFunding_falseWhenActiveDeadlineReached() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.deadline());
        assertFalse(treasury.canAcceptFunding());
    }

    function test_sync_fundingBelowActivationThreshold_isNoop() public {
        superToken.mint(address(flow), 99e18);

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Funding));
        assertFalse(treasury.resolved());
    }

    function test_sync_fundingActivation_setsActiveDeadlineAndFlowRate() public {
        superToken.mint(address(flow), 300e18);
        _setIncomingFlowRate(250);

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(treasury.deadline(), uint64(uint256(treasury.fundingDeadline()) + uint256(treasury.executionDuration())));
        assertEq(treasury.activatedAt(), uint64(block.timestamp));
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_sync_fundingActivation_ignoresFlowMaxSafeRateHint() public {
        BudgetTreasury uncappedTreasury = _deploy(
            uint64(block.timestamp + 3 days),
            uint64(30 days),
            100e18,
            0
        );

        superToken.mint(address(flow), 2_000_000e18);
        _setIncomingFlowRate(2_000);
        flow.setMaxSafeFlowRate(1_000);

        uncappedTreasury.sync();
        assertEq(flow.targetOutflowRate(), 2_000);
    }

    function test_sync_fundingActivation_ignoresZeroFlowMaxSafeRateHint() public {
        BudgetTreasury uncappedTreasury = _deploy(
            uint64(block.timestamp + 3 days),
            uint64(30 days),
            100e18,
            0
        );

        superToken.mint(address(flow), 2_000_000e18);
        _setIncomingFlowRate(2_000);
        flow.setMaxSafeFlowRate(0);

        uncappedTreasury.sync();
        assertEq(flow.targetOutflowRate(), 2_000);
    }

    function test_sync_fundingActivation_ignoresNegativeFlowMaxSafeRateHint() public {
        BudgetTreasury uncappedTreasury = _deploy(
            uint64(block.timestamp + 3 days),
            uint64(30 days),
            100e18,
            0
        );

        superToken.mint(address(flow), 2_000_000e18);
        _setIncomingFlowRate(2_000);
        flow.setMaxSafeFlowRate(-1);

        uncappedTreasury.sync();
        assertEq(flow.targetOutflowRate(), 2_000);
    }

    function test_sync_fundingActivation_clampsToBufferAffordableRateWhenCFAHostConfigured() public {
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(1_000);

        treasury.sync();
        assertEq(flow.targetOutflowRate(), 100);
    }

    function test_sync_fundingActivation_failsClosedWhenHostDependencyMissing() public {
        superToken.setHost(address(0));
        superToken.mint(address(flow), 2_000_000e18);
        _setIncomingFlowRate(2_000);

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_sync_afterFundingDeadline_withThresholdReached_activates() public {
        superToken.mint(address(flow), 300e18);
        _setIncomingFlowRate(50);

        vm.warp(treasury.fundingDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
        assertGt(treasury.deadline(), treasury.fundingDeadline());
        assertEq(treasury.activatedAt(), treasury.fundingDeadline() + 1);
        assertEq(flow.targetOutflowRate(), 50);
    }

    function test_sync_firstCallAfterExecutionWindowWithThresholdReached_finalizesExpired() public {
        superToken.mint(address(flow), 300e18);
        _setIncomingFlowRate(50);

        vm.warp(uint256(treasury.fundingDeadline()) + uint256(treasury.executionDuration()) + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
        assertEq(flow.targetOutflowRate(), 0);
        assertEq(
            treasury.deadline(), uint64(uint256(treasury.fundingDeadline()) + uint256(treasury.executionDuration()))
        );
    }

    function test_sync_afterFundingDeadline_withThresholdReached_keepsFundingAnchoredDeadline() public {
        superToken.mint(address(flow), 300e18);

        vm.warp(treasury.fundingDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(
            treasury.deadline(), uint64(uint256(treasury.fundingDeadline()) + uint256(treasury.executionDuration()))
        );
        assertEq(treasury.timeRemaining(), treasury.executionDuration() - 1);
    }

    function test_sync_fundingBelowThresholdBeforeWindow_isNoop() public {
        superToken.mint(address(flow), 10e18);

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Funding));
    }

    function test_sync_fundingBelowThresholdAfterWindow_expires() public {
        vm.warp(treasury.fundingDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_fundingAtThreshold_activates() public {
        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(50);

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_sync_earlyActivationWithShortExecution_stillAllowsResolveSuccessAfterFundingDeadline() public {
        BudgetTreasury shortExecutionTreasury = _deploy(
            uint64(block.timestamp + 10 days),
            uint64(1 days),
            100e18,
            0
        );

        superToken.mint(address(flow), 100e18);
        shortExecutionTreasury.sync();

        assertEq(uint256(shortExecutionTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(
            shortExecutionTreasury.deadline(),
            uint64(uint256(shortExecutionTreasury.fundingDeadline()) + uint256(shortExecutionTreasury.executionDuration()))
        );
        assertGt(shortExecutionTreasury.deadline(), shortExecutionTreasury.fundingDeadline());

        vm.warp(shortExecutionTreasury.fundingDeadline());
        _registerSuccessAssertion(shortExecutionTreasury);
        vm.prank(owner);
        shortExecutionTreasury.resolveSuccess();
        assertEq(uint256(shortExecutionTreasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
    }

    function test_sync_activeBeforeDeadline_updatesFlowRate() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(75);
        treasury.sync();
        int96 initialRate = flow.targetOutflowRate();

        _setIncomingFlowRate(125);
        vm.warp(block.timestamp + 1 days);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(flow.targetOutflowRate(), 0);
        assertNotEq(flow.targetOutflowRate(), initialRate);
    }

    function test_sync_active_parentZeroMemberRate_forcesZeroOutflowEvenWhenNetFlowSpoofed() public {
        superToken.mint(address(flow), 500e18);

        _setIncomingFlowRate(40);
        treasury.sync();
        assertEq(flow.targetOutflowRate(), 40);

        _setIncomingFlowRate(0);
        vm.prank(outsider);
        flow.setNetFlowRate(type(int96).max - flow.targetOutflowRate());
        vm.prank(outsider);
        treasury.sync();

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_sync_active_parentNegativeMemberRate_clampsTargetToZero() public {
        superToken.mint(address(flow), 500e18);

        _setIncomingFlowRate(40);
        treasury.sync();
        assertEq(flow.targetOutflowRate(), 40);

        _setIncomingFlowRate(-25);
        treasury.sync();

        assertEq(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_sync_active_permissionlessSpoofedNetFlowDoesNotAffectTrustedParentRate() public {
        superToken.mint(address(flow), 500e18);

        int96 trustedIncoming = 40;
        _setIncomingFlowRate(trustedIncoming);
        treasury.sync();
        assertEq(flow.targetOutflowRate(), trustedIncoming);

        vm.prank(outsider);
        flow.setNetFlowRate(type(int96).max - flow.targetOutflowRate());
        vm.prank(outsider);
        treasury.sync();

        assertEq(treasury.targetFlowRate(), trustedIncoming);
        assertEq(flow.targetOutflowRate(), trustedIncoming);
    }

    function test_sync_activeNoRateChange_reappliesCachedTargetOutflow() public {
        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(80);
        treasury.sync();
        _setIncomingFlowRate(flow.targetOutflowRate());

        uint256 callCountBefore = flow.setFlowRateCallCount();
        treasury.sync();
        assertEq(flow.setFlowRateCallCount(), callCountBefore + 1);
    }

    function test_sync_activeNoRateChange_refreshFailure_reportsManualInterventionWithoutRevert() public {
        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(80);
        treasury.sync();
        int96 flowRateBefore = flow.targetOutflowRate();
        _setIncomingFlowRate(flowRateBefore);

        flow.setShouldRevertSetFlowRate(true);
        uint256 callCountBefore = flow.setFlowRateCallCount();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit FlowRateSyncManualInterventionRequired(address(flow), flowRateBefore, flowRateBefore, flowRateBefore);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(flow.setFlowRateCallCount(), callCountBefore);
    }

    function test_sync_active_fallsBackToZeroWhenCappedWriteReverts() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(125);
        treasury.sync();
        assertGt(flow.targetOutflowRate(), 0);

        flow.setMaxSettableFlowRate(0);
        _setIncomingFlowRate(150);

        uint256 callCountBefore = flow.setFlowRateCallCount();
        treasury.sync();

        assertEq(flow.targetOutflowRate(), 0);
        assertEq(flow.setFlowRateCallCount(), callCountBefore + 1);
    }

    function test_sync_active_allWritesFailAndFlowIsNonZero_reportsManualInterventionWithoutRevert() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(125);
        treasury.sync();
        int96 flowRateBefore = flow.targetOutflowRate();
        assertGt(flowRateBefore, 0);

        flow.setShouldRevertSetFlowRate(true);
        _setIncomingFlowRate(150);
        int96 expectedTargetRate = treasury.targetFlowRate();
        uint256 callCountBefore = flow.setFlowRateCallCount();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit FlowRateSyncManualInterventionRequired(address(flow), expectedTargetRate, expectedTargetRate, flowRateBefore);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(flow.setFlowRateCallCount(), callCountBefore);
    }

    function test_sync_active_allWritesFailWithFlowCapHint_keepsCurrentRateWithoutFallbackCap() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(125);
        treasury.sync();
        int96 flowRateBefore = flow.targetOutflowRate();
        assertGt(flowRateBefore, 0);

        int96 cappedRate = 100;
        flow.setMaxSafeFlowRate(cappedRate);
        flow.setShouldRevertSetFlowRate(true);
        _setIncomingFlowRate(150);
        int96 rawTargetRate = treasury.targetFlowRate();
        assertGt(rawTargetRate, cappedRate);
        uint256 callCountBefore = flow.setFlowRateCallCount();

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(flow.setFlowRateCallCount(), callCountBefore);
    }

    function test_sync_activeAfterDeadline_expires() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_activeWithPendingSuccessAssertion_beforeDeadline_updatesFlowRate() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(75);
        treasury.sync();
        int96 initialRate = flow.targetOutflowRate();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        _setIncomingFlowRate(125);
        vm.warp(block.timestamp + 1 days);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
        assertNotEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertGt(flow.targetOutflowRate(), 0);
        assertNotEq(flow.targetOutflowRate(), initialRate);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_setsFlowRateToZeroWithoutFinalizing() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();
        assertGt(flow.targetOutflowRate(), 0);

        vm.warp(treasury.fundingDeadline());
        _registerPendingUnsettledSuccessAssertion(treasury);
        bytes32 pendingAssertionId = treasury.pendingSuccessAssertionId();

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(flow.targetOutflowRate(), 0);
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), pendingAssertionId);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledTruthful_finalizesSuccess() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledFalse_opensReassertGrace() public {
        _openReassertGraceWindow(treasury);

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertEq(flow.targetOutflowRate(), 0);
        assertTrue(treasury.reassertGraceUsed());
        assertGt(treasury.reassertGraceDeadline(), block.timestamp);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledFalse_finalizesResolverAssertion() public {
        TreasuryMockUmaResolverConfigWithFinalize resolverWithFinalize = new TreasuryMockUmaResolverConfigWithFinalize(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            successResolverConfig.escalationManager(),
            successResolverConfig.domainId()
        );

        BudgetTreasury finalizeCleanupTreasury = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.successResolver = address(resolverWithFinalize);
        finalizeCleanupTreasury.initialize(owner, config);

        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        finalizeCleanupTreasury.sync();

        vm.warp(finalizeCleanupTreasury.fundingDeadline());
        bytes32 assertionId = keccak256("budget-finalize-cleanup-assertion");
        vm.prank(address(resolverWithFinalize));
        finalizeCleanupTreasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = finalizeCleanupTreasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + finalizeCleanupTreasury.successAssertionLiveness(),
                settlementResolution: false,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: finalizeCleanupTreasury.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );

        vm.warp(finalizeCleanupTreasury.deadline());
        finalizeCleanupTreasury.sync();

        assertEq(resolverWithFinalize.finalizeCallCount(), 1);
        assertEq(resolverWithFinalize.lastFinalizedAssertionId(), assertionId);
        assertEq(finalizeCleanupTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(finalizeCleanupTreasury.reassertGraceUsed());
        assertEq(finalizeCleanupTreasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledFalse_finalizeRevertStillOpensReassertGrace(
    ) public {
        TreasuryMockUmaResolverConfigWithFinalize resolverWithFinalize = new TreasuryMockUmaResolverConfigWithFinalize(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            successResolverConfig.escalationManager(),
            successResolverConfig.domainId()
        );
        resolverWithFinalize.setShouldRevertFinalize(true);

        BudgetTreasury finalizeCleanupTreasury = _cloneBudgetTreasury();
        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.successResolver = address(resolverWithFinalize);
        finalizeCleanupTreasury.initialize(owner, config);

        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        finalizeCleanupTreasury.sync();

        vm.warp(finalizeCleanupTreasury.fundingDeadline());
        bytes32 assertionId = keccak256("budget-finalize-cleanup-assertion");
        vm.prank(address(resolverWithFinalize));
        finalizeCleanupTreasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = finalizeCleanupTreasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + finalizeCleanupTreasury.successAssertionLiveness(),
                settlementResolution: false,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: finalizeCleanupTreasury.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );

        vm.warp(finalizeCleanupTreasury.deadline());
        finalizeCleanupTreasury.sync();

        assertEq(finalizeCleanupTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(finalizeCleanupTreasury.reassertGraceUsed());
        assertEq(finalizeCleanupTreasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledFalse_emitsGraceEvents() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertionWithSettlement(treasury, true, false);
        bytes32 assertionId = treasury.pendingSuccessAssertionId();

        vm.warp(treasury.deadline());

        vm.expectEmit(true, false, false, false, address(treasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(treasury));
        emit IBudgetTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        treasury.sync();

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(treasury.reassertGraceUsed());
        assertEq(treasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_resolverConfigReadFailure_opensReassertGrace() public {
        RevertingOptimisticOracleResolverConfig revertingResolverConfig =
            new RevertingOptimisticOracleResolverConfig(
                IERC20(address(underlyingToken)), successResolverConfig.escalationManager(), successResolverConfig.domainId()
            );

        BudgetTreasury unresolvedConfigTreasury = _cloneBudgetTreasury();

        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.successResolver = address(revertingResolverConfig);
        unresolvedConfigTreasury.initialize(owner, config);

        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        unresolvedConfigTreasury.sync();

        vm.warp(unresolvedConfigTreasury.fundingDeadline());
        bytes32 assertionId = keccak256("budget-assertion-config-read-failure");
        vm.prank(address(revertingResolverConfig));
        unresolvedConfigTreasury.registerSuccessAssertion(assertionId);

        vm.warp(unresolvedConfigTreasury.deadline());

        vm.expectEmit(true, false, false, false, address(unresolvedConfigTreasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(unresolvedConfigTreasury));
        emit IBudgetTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        unresolvedConfigTreasury.sync();

        assertEq(uint256(unresolvedConfigTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(unresolvedConfigTreasury.resolved());
        assertEq(unresolvedConfigTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(unresolvedConfigTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(unresolvedConfigTreasury.reassertGraceUsed());
        assertEq(unresolvedConfigTreasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_oracleAddressZero_opensReassertGrace() public {
        TreasuryMockUmaResolverConfig zeroOracleResolverConfig = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(0)),
            IERC20(address(underlyingToken)),
            successResolverConfig.escalationManager(),
            successResolverConfig.domainId()
        );

        BudgetTreasury zeroOracleTreasury = _cloneBudgetTreasury();

        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.successResolver = address(zeroOracleResolverConfig);
        zeroOracleTreasury.initialize(owner, config);

        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        zeroOracleTreasury.sync();

        vm.warp(zeroOracleTreasury.fundingDeadline());
        bytes32 assertionId = keccak256("budget-assertion-oracle-zero-address");
        vm.prank(address(zeroOracleResolverConfig));
        zeroOracleTreasury.registerSuccessAssertion(assertionId);

        vm.warp(zeroOracleTreasury.deadline());

        vm.expectEmit(true, false, false, false, address(zeroOracleTreasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(zeroOracleTreasury));
        emit IBudgetTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        zeroOracleTreasury.sync();

        assertEq(uint256(zeroOracleTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(zeroOracleTreasury.resolved());
        assertEq(zeroOracleTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(zeroOracleTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(zeroOracleTreasury.reassertGraceUsed());
        assertEq(zeroOracleTreasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_oracleAssertionReadFailure_opensReassertGrace() public {
        BudgetRevertingGetAssertionOracle revertingOracle = new BudgetRevertingGetAssertionOracle();
        TreasuryMockUmaResolverConfig revertingAssertionReadResolver = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(revertingOracle)),
            IERC20(address(underlyingToken)),
            successResolverConfig.escalationManager(),
            successResolverConfig.domainId()
        );

        BudgetTreasury unresolvedAssertionReadTreasury = _cloneBudgetTreasury();

        IBudgetTreasury.BudgetConfig memory config = _defaultBudgetConfig();
        config.successResolver = address(revertingAssertionReadResolver);
        unresolvedAssertionReadTreasury.initialize(owner, config);

        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        unresolvedAssertionReadTreasury.sync();

        vm.warp(unresolvedAssertionReadTreasury.fundingDeadline());
        bytes32 assertionId = keccak256("budget-assertion-oracle-read-failure");
        vm.prank(address(revertingAssertionReadResolver));
        unresolvedAssertionReadTreasury.registerSuccessAssertion(assertionId);

        vm.warp(unresolvedAssertionReadTreasury.deadline());

        vm.expectEmit(true, false, false, false, address(unresolvedAssertionReadTreasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(unresolvedAssertionReadTreasury));
        emit IBudgetTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        unresolvedAssertionReadTreasury.sync();

        assertEq(uint256(unresolvedAssertionReadTreasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(unresolvedAssertionReadTreasury.resolved());
        assertEq(unresolvedAssertionReadTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(unresolvedAssertionReadTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(unresolvedAssertionReadTreasury.reassertGraceUsed());
        assertEq(unresolvedAssertionReadTreasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_clearSuccessAssertion_afterDeadline_activatesReassertGraceAndSyncStaysActive() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertionWithSettlement(treasury, true, false);
        bytes32 assertionId = treasury.pendingSuccessAssertionId();

        vm.warp(treasury.deadline());

        vm.expectEmit(true, false, false, false, address(treasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(true, true, false, false, address(treasury));
        emit IBudgetTreasury.ReassertGraceActivated(assertionId, uint64(block.timestamp + 1 days));

        vm.prank(owner);
        treasury.clearSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertTrue(treasury.reassertGraceUsed());
        assertEq(treasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
    }

    function test_clearSuccessAssertion_afterDeadline_allowsSingleReassertDuringActivatedGrace() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertionWithSettlement(treasury, true, false);
        bytes32 assertionId = treasury.pendingSuccessAssertionId();

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.clearSuccessAssertion(assertionId);

        bytes32 reassertionId = keccak256("budget-clear-first-reassertion");
        vm.prank(owner);
        treasury.registerSuccessAssertion(reassertionId);

        assertEq(treasury.pendingSuccessAssertionId(), reassertionId);
        assertEq(treasury.reassertGraceDeadline(), 0);
        assertTrue(treasury.reassertGraceUsed());

        vm.prank(owner);
        treasury.clearSuccessAssertion(reassertionId);
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.BUDGET_DEADLINE_PASSED.selector);
        treasury.registerSuccessAssertion(keccak256("budget-clear-first-reassertion-2"));
    }

    function test_clearSuccessAssertion_beforeDeadline_doesNotActivateReassertGrace() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertionWithSettlement(treasury, true, false);
        bytes32 assertionId = treasury.pendingSuccessAssertionId();

        vm.prank(owner);
        treasury.clearSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertFalse(treasury.reassertGraceUsed());
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_registerSuccessAssertion_afterDeadline_revertsWithoutReassertGrace() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.deadline());

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.BUDGET_DEADLINE_PASSED.selector);
        treasury.registerSuccessAssertion(keccak256("budget-after-deadline"));
    }

    function test_registerSuccessAssertion_afterDeadline_allowsSingleReassertDuringGrace() public {
        _openReassertGraceWindow(treasury);

        bytes32 reassertionId = keccak256("budget-reassertion-id");
        vm.prank(owner);
        treasury.registerSuccessAssertion(reassertionId);

        assertEq(treasury.pendingSuccessAssertionId(), reassertionId);
        assertEq(treasury.reassertGraceDeadline(), 0);

        vm.prank(owner);
        treasury.clearSuccessAssertion(reassertionId);
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.BUDGET_DEADLINE_PASSED.selector);
        treasury.registerSuccessAssertion(keccak256("budget-reassertion-2"));
    }

    function test_sync_afterGraceConsumedAndPendingCleared_expiresImmediatelyWithoutWaitingOldGrace() public {
        uint64 graceDeadline = _openReassertGraceWindow(treasury);

        bytes32 reassertionId = keccak256("budget-reassertion-consume-then-clear");
        vm.prank(owner);
        treasury.registerSuccessAssertion(reassertionId);

        vm.prank(owner);
        treasury.clearSuccessAssertion(reassertionId);
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));

        vm.warp(graceDeadline - 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_sync_afterReassertGraceExpiresWithoutPendingAssertion_expires() public {
        uint64 graceDeadline = _openReassertGraceWindow(treasury);

        vm.warp(graceDeadline);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_sync_afterReassertGraceOpens_withoutPending_beforeGraceDeadline_doesNotExpire() public {
        uint64 graceDeadline = _openReassertGraceWindow(treasury);

        vm.warp(graceDeadline - 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.reassertGraceDeadline(), graceDeadline);
    }

    function test_sync_afterGraceReassert_settledFalse_expiresWithoutSecondGrace() public {
        _openReassertGraceWindow(treasury);

        _registerSuccessAssertionWithSettlement(treasury, true, false);
        vm.warp(block.timestamp + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_sync_afterGraceReassert_settledTruthful_finalizesSuccess() public {
        _openReassertGraceWindow(treasury);

        _registerSuccessAssertionWithSettlement(treasury, true, true);
        vm.warp(block.timestamp + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_sync_afterGraceReassert_settledInvalid_expiresWithoutSecondGrace() public {
        _openReassertGraceWindow(treasury);

        bytes32 assertionId = keccak256("budget-reassert-invalid");
        vm.prank(owner);
        treasury.registerSuccessAssertion(assertionId);
        uint64 assertedAt = treasury.pendingSuccessAssertionAt();

        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + treasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: treasury.successAssertionBond(),
                callbackRecipient: outsider,
                disputer: address(0)
            })
        );

        vm.warp(block.timestamp + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_sync_activeWithPendingSuccessAssertion_afterDeadline_settlesLater_finalizesSuccess() public {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerPendingUnsettledSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        uint64 assertedAt = treasury.pendingSuccessAssertionAt();

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), assertionId);
        assertEq(flow.targetOutflowRate(), 0);

        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + treasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: treasury.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );

        vm.warp(block.timestamp + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
    }

    function test_registerSuccessAssertion_onlySuccessResolver() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());

        vm.prank(outsider);
        vm.expectRevert(IBudgetTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.registerSuccessAssertion(keccak256("budget-assertion"));
    }

    function test_registerSuccessAssertion_revertsOnZeroAssertionId() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.INVALID_ASSERTION_ID.selector);
        treasury.registerSuccessAssertion(bytes32(0));
    }

    function test_registerSuccessAssertion_revertsWhenAssertionAlreadyPending() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());

        bytes32 assertionId = keccak256("budget-first-assertion");
        vm.prank(owner);
        treasury.registerSuccessAssertion(assertionId);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTreasury.SUCCESS_ASSERTION_ALREADY_PENDING.selector, assertionId)
        );
        treasury.registerSuccessAssertion(keccak256("budget-second-assertion"));
    }

    function test_clearSuccessAssertion_onlySuccessResolver() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        vm.prank(outsider);
        vm.expectRevert(IBudgetTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.clearSuccessAssertion(assertionId);
    }

    function test_clearSuccessAssertion_revertsWhenNoPendingAssertion() public {
        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.SUCCESS_ASSERTION_NOT_PENDING.selector);
        treasury.clearSuccessAssertion(keccak256("budget-no-pending"));
    }

    function test_clearSuccessAssertion_revertsOnAssertionIdMismatch() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        bytes32 wrongAssertionId = keccak256("budget-wrong-assertion-id");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetTreasury.SUCCESS_ASSERTION_ID_MISMATCH.selector, assertionId, wrongAssertionId
            )
        );
        treasury.clearSuccessAssertion(wrongAssertionId);
    }

    function test_registerAndClearSuccessAssertion_emitsEventsAndResetsPendingState() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());

        bytes32 assertionId = keccak256("budget-register-clear");

        vm.expectEmit(true, true, false, false, address(treasury));
        emit IBudgetTreasury.SuccessAssertionRegistered(assertionId, uint64(block.timestamp));
        vm.prank(owner);
        treasury.registerSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), assertionId);
        assertEq(treasury.pendingSuccessAssertionAt(), uint64(block.timestamp));

        vm.expectEmit(true, false, false, false, address(treasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.prank(owner);
        treasury.clearSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
    }

    function test_resolveSuccess_fromActive_afterFundingDeadline_beforeDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());

        _registerSuccessAssertion(treasury);
        vm.prank(owner);
        treasury.resolveSuccess();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
    }

    function test_resolveSuccess_fromActive_revertsBeforeFundingDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.FUNDING_WINDOW_NOT_ENDED.selector);
        treasury.registerSuccessAssertion(keccak256("early"));
    }

    function test_resolveSuccess_revertsAtDeadlineWithoutPendingAssertion() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.deadline());
        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.SUCCESS_ASSERTION_NOT_PENDING.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_afterDeadline_succeedsWhenAssertionWasPendingPreDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveSuccess();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertTrue(treasury.resolved());
    }

    function test_resolveSuccess_revertsWhenAssertionNotVerified() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        uint64 assertedAt = treasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: false,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + treasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: treasury.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.SUCCESS_ASSERTION_NOT_VERIFIED.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_revertsFromFundingInvalidState() public {
        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.INVALID_STATE.selector);
        treasury.resolveSuccess();
    }

    function test_resolveFailure_fromFunding_revertsBeforeFundingDeadline() public {
        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.FUNDING_WINDOW_NOT_ENDED.selector);
        treasury.resolveFailure();
    }

    function test_resolveFailure_fromFunding_afterFundingDeadline() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
    }

    function test_resolveFailure_fromFunding_succeedsWhenSuccessResolutionDisabled() public {
        vm.prank(owner);
        treasury.disableSuccessResolution();

        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
    }

    function test_resolveFailure_revertsWhenAlreadyResolved() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.INVALID_STATE.selector);
        treasury.resolveFailure();
    }

    function test_resolveFailure_fromActive_revertsBeforeDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.DEADLINE_NOT_REACHED.selector);
        treasury.resolveFailure();
    }

    function test_resolveFailure_fromActive_atDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
    }

    function test_resolveFailure_fromActive_succeedsWhenSuccessResolutionDisabled() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.prank(owner);
        treasury.disableSuccessResolution();

        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
    }

    function test_sync_whenResolved_isNoOp() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
    }

    function test_sync_whenSucceeded_isNoOp() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());

        _registerSuccessAssertion(treasury);
        vm.prank(owner);
        treasury.resolveSuccess();

        uint64 resolvedAtBefore = treasury.resolvedAt();
        uint256 flowRateSetCallsBefore = flow.setFlowRateCallCount();

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.resolvedAt(), resolvedAtBefore);
        assertEq(flow.setFlowRateCallCount(), flowRateSetCallsBefore);
    }

    function test_retryTerminalSideEffects_revertsWhenNotTerminal() public {
        vm.expectRevert(IBudgetTreasury.INVALID_STATE.selector);
        treasury.retryTerminalSideEffects();
    }

    function test_settleLateResidualToParent_revertsWhenUnresolved() public {
        vm.expectRevert(IBudgetTreasury.INVALID_STATE.selector);
        treasury.settleLateResidualToParent();
    }

    function test_settleResidualToParentForFinalize_revertsWhenCallerNotSelf() public {
        vm.expectRevert(BudgetTreasury.ONLY_SELF.selector);
        treasury.settleResidualToParentForFinalize();
    }

    function test_settleLateResidualToParent_sweepsLateInflowAfterFinalize() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();

        address parentFlowAddr = flow.parent();
        uint256 parentBalanceBefore = superToken.balanceOf(parentFlowAddr);
        superToken.mint(address(flow), 40e18);

        vm.prank(outsider);
        uint256 settled = treasury.settleLateResidualToParent();

        assertEq(settled, 40e18);
        assertEq(flow.sweepCallCount(), 2);
        assertEq(flow.lastSweepTo(), parentFlowAddr);
        assertEq(flow.lastSweepAmount(), 40e18);
        assertEq(superToken.balanceOf(parentFlowAddr) - parentBalanceBefore, 40e18);
    }

    function test_targetFlowRate_capsAtInt96Max() public {
        BudgetTreasury uncappedTreasury = _deploy(
            uint64(block.timestamp + 3 days),
            uint64(30 days),
            100e18,
            0
        );

        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(type(int96).max);

        uncappedTreasury.sync();

        assertEq(uncappedTreasury.targetFlowRate(), type(int96).max);
    }

    function test_targetFlowRate_zeroWhenNotActive() public view {
        assertEq(treasury.targetFlowRate(), 0);
    }

    function test_targetFlowRate_zeroAtDeadline() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.deadline());
        assertEq(treasury.targetFlowRate(), 0);
    }

    function test_targetFlowRate_matchesIncomingFlow() public {
        superToken.mint(address(flow), 150e18);
        treasury.sync();

        int96 expectedIncoming = 40;
        _setIncomingFlowRate(expectedIncoming);

        assertEq(treasury.targetFlowRate(), expectedIncoming);
    }

    function test_sync_fromActive_beforeDeadline_keepsActive() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.warp(treasury.deadline() - 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.resolved());
    }

    function test_sync_noOpWhenResolvedByFailure() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
    }
    function test_sync_noOpWhenResolvedByExpiry() public {
        vm.warp(treasury.fundingDeadline() + 1);
        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
    }

    function test_resolveSuccess_onlySuccessResolver() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        vm.prank(outsider);
        vm.expectRevert(IBudgetTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.resolveSuccess();
    }

    function test_disableSuccessResolution_clearsPendingAssertion_andBlocksSuccessResolutionPaths() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        vm.warp(treasury.fundingDeadline());
        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();

        vm.expectEmit(true, false, false, false, address(treasury));
        emit IBudgetTreasury.SuccessAssertionCleared(assertionId);
        vm.expectEmit(false, false, false, false, address(treasury));
        emit IBudgetTreasury.SuccessResolutionDisabled();
        vm.prank(owner);
        treasury.disableSuccessResolution();

        assertTrue(treasury.successResolutionDisabled());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.SUCCESS_RESOLUTION_DISABLED.selector);
        treasury.registerSuccessAssertion(keccak256("budget-disabled-register"));

        vm.prank(owner);
        vm.expectRevert(IBudgetTreasury.SUCCESS_RESOLUTION_DISABLED.selector);
        treasury.resolveSuccess();
    }

    function test_disableSuccessResolution_duringReassertGrace_clearsGraceAndAllowsExpiry() public {
        _openReassertGraceWindow(treasury);

        vm.prank(owner);
        treasury.disableSuccessResolution();

        assertTrue(treasury.successResolutionDisabled());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.reassertGraceDeadline(), 0);

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_resolveFailure_onlyController() public {
        vm.prank(outsider);
        vm.expectRevert(IBudgetTreasury.ONLY_CONTROLLER.selector);
        treasury.resolveFailure();
    }

    function test_finalize_fromFunding_skipsFlowStopWhenAlreadyZero() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();
        assertEq(flow.setFlowRateCallCount(), 0);
    }

    function test_finalize_sweepsResidualToParentFlow() public {
        superToken.mint(address(flow), 125e18);
        treasury.sync();

        address parentBefore = flow.parent();
        uint256 parentBalanceBefore = superToken.balanceOf(parentBefore);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(flow.sweepCallCount(), 1);
        assertEq(flow.lastSweepTo(), parentBefore);
        assertEq(flow.lastSweepAmount(), 125e18);
        assertEq(superToken.balanceOf(parentBefore) - parentBalanceBefore, 125e18);
    }

    function test_finalize_keepsTerminalStateWhenFlowStopFails() public {
        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(100);
        treasury.sync();
        flow.setShouldRevertSetFlowRate(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(treasury.resolvedAt(), uint64(block.timestamp));
        assertEq(flow.targetOutflowRate(), 100);
    }

    function test_finalize_keepsTerminalStateWhenFlowRateReadFails() public {
        superToken.mint(address(flow), 100e18);
        _setIncomingFlowRate(100);
        treasury.sync();
        flow.setShouldRevertTargetOutflowRate(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(treasury.resolvedAt(), uint64(block.timestamp));
        assertEq(flow.sweepCallCount(), 1);
    }

    function test_finalize_keepsTerminalStateWhenParentFlowMissing_andRetrySettlesResidual() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        flow.setParent(address(0));

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveFailure();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(flow.sweepCallCount(), 0);

        address retryParent = address(0xABCD);
        flow.setParent(retryParent);
        vm.prank(outsider);
        treasury.retryTerminalSideEffects();

        assertEq(flow.sweepCallCount(), 1);
        assertEq(flow.lastSweepTo(), retryParent);
        assertEq(flow.lastSweepAmount(), 100e18);
    }

    function test_finalize_keepsTerminalStateWhenResidualSweepFails_andRetrySettlesResidual() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();
        flow.setShouldRevertSweep(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveFailure();

        IBudgetTreasury.BudgetLifecycleStatus memory status = treasury.lifecycleStatus();
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(uint256(status.currentState), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(status.isResolved);
        assertEq(flow.sweepCallCount(), 0);

        flow.setShouldRevertSweep(false);
        vm.prank(outsider);
        treasury.retryTerminalSideEffects();

        assertEq(flow.sweepCallCount(), 1);
        assertEq(flow.lastSweepAmount(), 100e18);
        assertEq(superToken.balanceOf(address(flow)), 0);
    }

    function test_canAcceptFunding_falseWhenActiveAndRunwayCapReached() public {
        superToken.mint(address(flow), 100e18);
        treasury.sync();

        superToken.mint(address(flow), treasury.runwayCap());
        assertFalse(treasury.canAcceptFunding());
    }

    function test_canAcceptFunding_falseAfterFinalized() public {
        vm.warp(treasury.fundingDeadline() + 1);
        vm.prank(owner);
        treasury.resolveFailure();
        assertFalse(treasury.canAcceptFunding());
    }

    function test_lifecycleStatus_resolvedTracksTerminalState_andResolvedAtSetOnFinalize() public {
        IBudgetTreasury.BudgetLifecycleStatus memory fundingStatus = treasury.lifecycleStatus();
        assertEq(uint256(fundingStatus.currentState), uint256(IBudgetTreasury.BudgetState.Funding));
        assertFalse(fundingStatus.isResolved);
        assertEq(fundingStatus.activatedAt, 0);
        assertFalse(treasury.resolved());
        assertEq(treasury.resolvedAt(), 0);

        vm.warp(treasury.fundingDeadline() + 1);
        uint64 expectedResolvedAt = uint64(block.timestamp);
        vm.prank(owner);
        treasury.resolveFailure();

        IBudgetTreasury.BudgetLifecycleStatus memory terminalStatus = treasury.lifecycleStatus();
        assertEq(uint256(terminalStatus.currentState), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(terminalStatus.isResolved);
        assertTrue(treasury.resolved());
        assertEq(treasury.resolvedAt(), expectedResolvedAt);
    }

    function _deploy(
        uint64 fundingDeadline,
        uint64 executionDuration,
        uint256 activationThreshold,
        uint256 runwayCap
    ) internal returns (BudgetTreasury deployed) {
        deployed = _cloneBudgetTreasury();
        deployed.initialize(
            owner,
            IBudgetTreasury.BudgetConfig({
                flow: address(flow),
                fundingDeadline: fundingDeadline,
                executionDuration: executionDuration,
                activationThreshold: activationThreshold,
                runwayCap: runwayCap,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("budget-oracle-spec"),
                successAssertionPolicyHash: keccak256("budget-assertion-policy")
            })
        );
    }

    function _defaultBudgetConfig() internal view returns (IBudgetTreasury.BudgetConfig memory config) {
        config = IBudgetTreasury.BudgetConfig({
            flow: address(flow),
            fundingDeadline: uint64(block.timestamp + 1 days),
            executionDuration: uint64(30 days),
            activationThreshold: 1,
            runwayCap: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("budget-oracle-spec"),
            successAssertionPolicyHash: keccak256("budget-assertion-policy")
        });
    }

    function _cloneBudgetTreasury() internal returns (BudgetTreasury deployed) {
        deployed = BudgetTreasury(Clones.clone(address(budgetTreasuryImplementation)));
        flow.setFlowOperator(address(deployed));
        flow.setSweeper(address(deployed));
    }

    function _openReassertGraceWindow(BudgetTreasury target) internal returns (uint64 graceDeadline) {
        superToken.mint(address(flow), 200e18);
        _setIncomingFlowRate(100);
        target.sync();

        vm.warp(target.fundingDeadline());
        _registerSuccessAssertionWithSettlement(target, true, false);

        vm.warp(target.deadline());
        target.sync();

        graceDeadline = target.reassertGraceDeadline();
    }

    function _registerSuccessAssertion(BudgetTreasury target) internal {
        _registerSuccessAssertionWithSettlement(target, true, true);
    }

    function _registerPendingUnsettledSuccessAssertion(BudgetTreasury target) internal {
        _registerSuccessAssertionWithSettlement(target, false, false);
    }

    function _registerSuccessAssertionWithSettlement(
        BudgetTreasury target,
        bool settled,
        bool settlementResolution
    ) internal {
        bytes32 assertionId = keccak256(abi.encodePacked(address(target), block.timestamp));
        vm.prank(owner);
        target.registerSuccessAssertion(assertionId);

        uint64 assertedAt = target.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: settled,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + target.successAssertionLiveness(),
                settlementResolution: settlementResolution,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: target.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );
    }

    function _setIncomingFlowRate(int96 incomingFlowRate) internal {
        parentFlow.setMemberFlowRate(address(flow), incomingFlowRate);
    }
}

contract RevertingOptimisticOracleResolverConfig is IUMATreasurySuccessResolverConfig {
    IERC20 public immutable override assertionCurrency;
    address public immutable override escalationManager;
    bytes32 public immutable override domainId;

    constructor(IERC20 assertionCurrency_, address escalationManager_, bytes32 domainId_) {
        assertionCurrency = assertionCurrency_;
        escalationManager = escalationManager_;
        domainId = domainId_;
    }

    function optimisticOracle() external pure override returns (OptimisticOracleV3Interface) {
        revert("resolver-config-oracle-read-failed");
    }
}

contract BudgetRevertingGetAssertionOracle {
    error GET_ASSERTION_REVERT();

    function getAssertion(bytes32) external pure returns (OptimisticOracleV3Interface.Assertion memory) {
        revert GET_ASSERTION_REVERT();
    }
}

contract BudgetParentFlowWithoutMemberRate { }

contract BudgetReentrantUnderlying is SharedMockUnderlying {
    bytes4 private constant DONATE_UNDERLYING_AND_UPGRADE_SELECTOR =
        bytes4(keccak256("donateUnderlyingAndUpgrade(uint256)"));

    address private _targetTreasury;
    uint256 private _reentryAmount;
    bool private _armed;
    bool private _reentered;

    function armReentry(address targetTreasury_, uint256 reentryAmount_) external {
        _targetTreasury = targetTreasury_;
        _reentryAmount = reentryAmount_;
        _armed = true;
        _reentered = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_armed && !_reentered && from != address(0) && to != address(0)) {
            _reentered = true;
            (bool ok, bytes memory returndata) = _targetTreasury.call(
                abi.encodeWithSelector(DONATE_UNDERLYING_AND_UPGRADE_SELECTOR, _reentryAmount)
            );
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }

        super._update(from, to, value);
    }
}
