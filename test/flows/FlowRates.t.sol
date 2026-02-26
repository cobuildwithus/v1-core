// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {FlowRates} from "src/library/FlowRates.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperTokenV1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

contract FlowRatesStrictHarness {
    FlowTypes.Config internal cfg;

    constructor(ISuperToken superToken_) {
        cfg.superToken = superToken_;
    }

    function strictCalculateFlowRates(int96 flowRate) external view returns (int96, int96) {
        return FlowRates.calculateFlowRates(cfg, flowRate);
    }
}

contract FlowRatesTest is FlowTestBase {
    using SuperTokenV1Library for ISuperToken;

    event TargetOutflowRateUpdated(address indexed caller, int96 oldRate, int96 newRate);

    event TargetOutflowRefreshFailed(int96 targetOutflowRate, bytes reason);

    bytes4 internal constant ONLY_SELF_OUTFLOW_REFRESH_SELECTOR = bytes4(keccak256("ONLY_SELF_OUTFLOW_REFRESH()"));
    bytes32 internal constant TARGET_OUTFLOW_RATE_UPDATED_SIG =
        keccak256("TargetOutflowRateUpdated(address,int96,int96)");
    bytes32 internal constant TARGET_OUTFLOW_REFRESH_FAILED_SIG =
        keccak256("TargetOutflowRefreshFailed(int96,bytes)");

    function _deployAndFundFlowWithRewardPpm(uint32 rewardPpm) internal returns (CustomFlow deployed) {
        deployed = _deployAndFundFlowWithRewardPpmAndParent(rewardPpm, address(0));
    }

    function _bootstrapRecipientOnFlow(CustomFlow targetFlow, bytes32 recipientId, address recipient) internal {
        vm.prank(manager);
        targetFlow.addRecipient(recipientId, recipient, recipientMetadata);
    }

    function _deployAndFundFlowWithRewardPpmAndParent(uint32 rewardPpm, address parent)
        internal
        returns (CustomFlow deployed)
    {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        IFlow.FlowParams memory params = IFlow.FlowParams({managerRewardPoolFlowRatePpm: rewardPpm});

        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            parent,
            connectPoolAdmin,
            params,
            flowMetadata,
            strategies
        );
        deployed = CustomFlow(proxy);

        vm.prank(owner);
        superToken.transfer(address(deployed), 200_000e18);
    }

    function test_flowRateSplit_allNonManagerGoesToDistribution() public {
        int96 total = 1_000;

        _bootstrapRecipientOnFlow(flow, bytes32(uint256(1)), address(0x1001));
        vm.prank(owner);
        flow.setTargetOutflowRate(total);

        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 100);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        CustomFlow flow25 = _deployAndFundFlowWithRewardPpm(250_000);
        _bootstrapRecipientOnFlow(flow25, bytes32(uint256(2)), address(0x1002));
        vm.prank(owner);
        flow25.setTargetOutflowRate(total);

        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow25), managerRewardPool), 250);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow25), flow25.distributionPool()), 0);

        CustomFlow flow100 = _deployAndFundFlowWithRewardPpm(1_000_000);
        _bootstrapRecipientOnFlow(flow100, bytes32(uint256(3)), address(0x1003));
        vm.prank(owner);
        flow100.setTargetOutflowRate(total);

        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow100), managerRewardPool), 1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow100), flow100.distributionPool()), 0);
    }

    function test_calculateFlowRates_libraryStrictRevertsOnNegativeRate() public {
        FlowRatesStrictHarness strictHarness = new FlowRatesStrictHarness(ISuperToken(address(superToken)));

        vm.expectRevert(IFlow.FLOW_RATE_NEGATIVE.selector);
        strictHarness.strictCalculateFlowRates(-1);
    }

    function test_targetOutflowRateUpdated_emitsWhenCachedRateChanges() public {
        _makeIncomingFlow(other, 2_000);
        _bootstrapRecipientOnFlow(flow, bytes32(uint256(901)), address(0x1901));

        vm.expectEmit(true, false, false, true, address(flow));
        emit TargetOutflowRateUpdated(owner, 0, 1_000);
        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        vm.expectEmit(true, false, false, true, address(flow));
        emit TargetOutflowRateUpdated(owner, 1_000, 1_200);
        vm.prank(owner);
        flow.setTargetOutflowRate(1_200);

        vm.expectEmit(true, false, false, true, address(flow));
        emit TargetOutflowRateUpdated(owner, 1_200, 10_000);
        vm.prank(owner);
        flow.setTargetOutflowRate(10_000);

        vm.recordLogs();
        vm.prank(owner);
        flow.setTargetOutflowRate(10_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_RATE_UPDATED_SIG), 0);
    }

    function test_rateMutationEntryPoints_revertForUnauthorized() public {
        vm.startPrank(other);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        flow.setTargetOutflowRate(1);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        flow.refreshTargetOutflowRate();
        vm.stopPrank();
    }

    function test_managerRewardFlow_createUpdateDeleteTransitions() public {
        _makeIncomingFlow(other, 2_000);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 100);

        vm.prank(owner);
        flow.setTargetOutflowRate(2_000);
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 200);

        vm.prank(owner);
        flow.setTargetOutflowRate(0);
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 0);
    }

    function test_managerRewardFlow_skipsUpdate_whenComputedRewardRateUnchanged() public {
        _makeIncomingFlow(other, 2_000);
        _bootstrapRecipientOnFlow(flow, bytes32(uint256(4)), address(0x1004));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        bytes memory managerUpdateCallData = abi.encodeWithSelector(
            sf.cfa.updateFlow.selector, ISuperToken(address(superToken)), managerRewardPool, int96(100), new bytes(0)
        );
        bytes memory hostCallData =
            abi.encodeWithSelector(sf.host.callAgreement.selector, sf.cfa, managerUpdateCallData, new bytes(0));
        vm.expectCall(address(sf.host), hostCallData, 0);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_009);

        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 100);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_setTargetOutflowRate_noopWhenUnchanged_skipsDistributionHostCall() public {
        _makeIncomingFlow(other, 2_000);
        _bootstrapRecipientOnFlow(flow, bytes32(uint256(5)), address(0x1005));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        bytes memory distributeCallData = abi.encodeWithSelector(
            sf.gda.distributeFlow.selector,
            ISuperToken(address(superToken)),
            address(flow),
            flow.distributionPool(),
            int96(0),
            new bytes(0)
        );
        bytes memory hostCallData =
            abi.encodeWithSelector(sf.host.callAgreement.selector, sf.gda, distributeCallData, new bytes(0));
        vm.expectCall(address(sf.host), hostCallData, 0);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        assertEq(flow.targetOutflowRate(), 1_000);
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 100);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_setTargetOutflowRate_noopWhenUnchanged_skipsManagerRewardLookupPath() public {
        _makeIncomingFlow(other, 2_000);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        bytes memory managerGetFlowCallData = abi.encodeWithSelector(
            sf.cfa.getFlow.selector, ISuperToken(address(superToken)), address(flow), managerRewardPool
        );
        // Only the explicit assertion below should query CFA flow state.
        vm.expectCall(address(sf.cfa), managerGetFlowCallData, 1);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        assertEq(flow.targetOutflowRate(), 1_000);
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 100);
    }

    function test_managerRewardPoolSetterSelector_isNotExposed() public {
        vm.prank(owner);
        _assertCallFails(address(flow), abi.encodeWithSignature("setManagerRewardPool(address)", address(0xB0B)));
    }

    function test_flowRateSplit_smallTotal_roundingFloorsDistributionByUnitGranularity() public {
        int96 total = 7;

        CustomFlow flow333 = _deployAndFundFlowWithRewardPpm(333_333);
        _bootstrapRecipientOnFlow(flow333, bytes32(uint256(6)), address(0x1006));
        vm.prank(owner);
        flow333.setTargetOutflowRate(total);

        int96 managerRate = ISuperToken(address(superToken)).getFlowRate(address(flow333), managerRewardPool);
        int96 distributionRate = ISuperToken(address(superToken)).getFlowDistributionFlowRate(
            address(flow333),
            flow333.distributionPool()
        );

        assertEq(managerRate, 2);
        assertEq(distributionRate, 0);

        CustomFlow flow857 = _deployAndFundFlowWithRewardPpm(857_143);
        _bootstrapRecipientOnFlow(flow857, bytes32(uint256(7)), address(0x1007));
        vm.prank(owner);
        flow857.setTargetOutflowRate(total);

        distributionRate = ISuperToken(address(superToken)).getFlowDistributionFlowRate(
            address(flow857),
            flow857.distributionPool()
        );
        managerRate = ISuperToken(address(superToken)).getFlowRate(address(flow857), managerRewardPool);

        assertEq(managerRate, 6);
        assertEq(distributionRate, 0);
    }

    function test_addRecipient_withoutAllocations_keepsDistributionZero() public {
        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        vm.prank(manager);
        flow.addRecipient(bytes32(uint256(101)), address(0x1101), recipientMetadata);

        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_addRecipient_withZeroCachedTarget_skipsRefreshAttempt() public {
        vm.mockCallRevert(
            address(sf.host),
            abi.encodeWithSelector(sf.host.callAgreement.selector),
            bytes("refresh-should-not-run")
        );

        vm.recordLogs();
        vm.prank(manager);
        flow.addRecipient(bytes32(uint256(1001)), address(0x1A01), recipientMetadata);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_addRecipient_nonBootstrapTransition_skipsRefreshAttempt() public {
        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        vm.prank(manager);
        flow.addRecipient(bytes32(uint256(1002)), address(0x1A02), recipientMetadata);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        vm.mockCallRevert(
            address(sf.host),
            abi.encodeWithSelector(sf.host.callAgreement.selector),
            bytes("refresh-should-not-run")
        );

        vm.recordLogs();
        vm.prank(manager);
        flow.addRecipient(bytes32(uint256(1003)), address(0x1A03), recipientMetadata);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_addFlowRecipient_withoutAllocations_keepsDistributionZero() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            bytes32(uint256(102)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
        assertEq(flow.getMemberFlowRate(childAddr), 0);
    }

    function test_addFlowRecipient_forwardsExplicitRolesToChildInitialization() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        address childRecipientAdmin = makeAddr("childRecipientAdmin");
        address childFlowOperator = makeAddr("childFlowOperator");
        address childSweeper = makeAddr("childSweeper");

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            bytes32(uint256(1210)),
            recipientMetadata,
            childRecipientAdmin,
            childFlowOperator,
            childSweeper,
            managerRewardPool,
            strategies
        );

        CustomFlow child = CustomFlow(childAddr);
        assertEq(child.recipientAdmin(), childRecipientAdmin);
        assertEq(child.flowOperator(), childFlowOperator);
        assertEq(child.sweeper(), childSweeper);

        vm.prank(manager);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        child.setTargetOutflowRate(0);

        vm.prank(childFlowOperator);
        child.setTargetOutflowRate(0);

        vm.prank(childFlowOperator);
        vm.expectRevert(IFlow.NOT_SWEEPER.selector);
        child.sweepSuperToken(address(0xCAFE), 0);

        vm.prank(childSweeper);
        assertEq(child.sweepSuperToken(address(0xCAFE), 0), 0);
    }

    function test_addFlowRecipient_withZeroCachedTarget_skipsRefreshAttempt() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        _mockDistributionRefreshFailure(flow, 0, bytes("refresh-should-not-run"));

        vm.recordLogs();
        vm.prank(manager);
        flow.addFlowRecipient(
            bytes32(uint256(1207)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_addFlowRecipient_nonBootstrapTransition_skipsRefreshAttempt() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        vm.prank(manager);
        flow.addFlowRecipient(
            bytes32(uint256(1208)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        _mockDistributionRefreshFailure(flow, 0, bytes("refresh-should-not-run"));

        vm.recordLogs();
        vm.prank(manager);
        flow.addFlowRecipient(
            bytes32(uint256(1209)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_addRecipient_doesNotAttemptOutflowRefresh() public {
        address recipient = address(0x1103);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        vm.mockCallRevert(
            address(sf.host),
            abi.encodeWithSelector(sf.host.callAgreement.selector),
            bytes("refresh-failed")
        );

        vm.recordLogs();
        vm.prank(manager);
        flow.addRecipient(bytes32(uint256(103)), recipient, recipientMetadata);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.getMemberUnits(recipient), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
    }

    function test_refreshTargetOutflowRate_recoversAfterAllocationRefreshFailure() public {
        bytes32 recipientId = bytes32(uint256(203));
        address recipient = address(0x1203);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        vm.prank(manager);
        flow.addRecipient(recipientId, recipient, recipientMetadata);
        assertEq(flow.getMemberUnits(recipient), 0);

        _mockDistributionRefreshFailure(flow, 900, bytes("refresh-failed"));

        vm.recordLogs();
        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
        _assertSingleRefreshFailure(logs, address(flow), 1_000, bytes("refresh-failed"));

        vm.clearMockedCalls();

        vm.prank(owner);
        flow.refreshTargetOutflowRate();

        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_refreshTargetOutflowRate_allowsParentCaller_afterChildAllocationRefreshFailure() public {
        bytes32 childRecipientId = bytes32(uint256(204));
        address childRecipient = address(0x1204);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = childRecipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        CustomFlow child = _deployAndFundFlowWithRewardPpmAndParent(0, address(this));

        vm.prank(owner);
        child.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(child), child.distributionPool()), 0);

        vm.prank(manager);
        child.addRecipient(childRecipientId, childRecipient, recipientMetadata);

        _mockDistributionRefreshFailure(child, 1_000, bytes("refresh-failed"));
        vm.prank(allocator);
        child.allocate(recipientIds, scaled);

        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(child), child.distributionPool()), 0);

        vm.clearMockedCalls();

        child.refreshTargetOutflowRate();

        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(child), child.distributionPool()), 0);
    }

    function test_addFlowRecipient_doesNotAttemptOutflowRefresh() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        _mockDistributionRefreshFailure(flow, 0, bytes("refresh-failed"));

        vm.recordLogs();
        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            bytes32(uint256(104)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.getMemberUnits(childAddr), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
    }

    function test_addFlowRecipient_zeroBootstrap_skipsMemberUnitWrites() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.mockCallRevert(
            address(flow.distributionPool()),
            abi.encodeWithSelector(bytes4(keccak256("updateMemberUnits(address,uint128)"))),
            bytes("units-write-should-not-run")
        );

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            bytes32(uint256(1304)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        assertEq(flow.getMemberUnits(childAddr), 0);
    }

    function test_allocate_zeroToNonZeroUnits_refreshesCachedOutflow() public {
        bytes32 recipientId = bytes32(uint256(905));
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        vm.prank(manager);
        flow.addRecipient(recipientId, address(0x1905), recipientMetadata);
        assertEq(flow.getMemberUnits(address(0x1905)), 0);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);

        assertGt(flow.getMemberUnits(address(0x1905)), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_allocate_nonZeroToNonZeroUnits_skipsRefreshAttempt() public {
        bytes32 recipientId = bytes32(uint256(907));
        address recipient = address(0x1907);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        vm.prank(manager);
        flow.addRecipient(recipientId, recipient, recipientMetadata);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        assertGt(flow.getMemberUnits(recipient), 0);

        _mockDistributionRefreshFailure(flow, 900, bytes("refresh-should-not-run"));

        vm.recordLogs();
        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(flow.getMemberUnits(recipient), 0);
        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
    }

    function test_allocate_nonZeroToZeroUnits_refreshesCachedOutflow() public {
        bytes32 recipientId = bytes32(uint256(906));
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        vm.prank(manager);
        flow.addRecipient(recipientId, address(0x1906), recipientMetadata);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);

        strategy.setWeight(allocatorKey, 0);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);

        assertEq(flow.getMemberUnits(address(0x1906)), 0);
        assertEq(ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), flow.distributionPool()), 0);
    }

    function test_syncAllocation_zeroToNonZeroUnits_refreshesCachedOutflow() public {
        bytes32 recipientId = bytes32(uint256(908));
        address recipient = address(0x1908);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        vm.prank(manager);
        flow.addRecipient(recipientId, recipient, recipientMetadata);

        strategy.setWeight(allocatorKey, 0);
        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        assertEq(flow.getMemberUnits(recipient), 0);

        strategy.setWeight(allocatorKey, DEFAULT_WEIGHT);
        _mockDistributionRefreshFailure(flow, 900, bytes("refresh-failed"));

        vm.recordLogs();
        vm.prank(other);
        flow.syncAllocation(address(strategy), allocatorKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(flow.getMemberUnits(recipient), 0);
        _assertSingleRefreshFailure(logs, address(flow), 1_000, bytes("refresh-failed"));
    }

    function test_syncAllocation_nonZeroToNonZeroUnits_skipsRefreshAttempt() public {
        bytes32 recipientId = bytes32(uint256(909));
        address recipient = address(0x1909);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        vm.prank(manager);
        flow.addRecipient(recipientId, recipient, recipientMetadata);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        assertGt(flow.getMemberUnits(recipient), 0);

        strategy.setWeight(allocatorKey, DEFAULT_WEIGHT / 2);
        _mockDistributionRefreshFailure(flow, 900, bytes("refresh-should-not-run"));

        vm.recordLogs();
        vm.prank(other);
        flow.syncAllocation(address(strategy), allocatorKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(flow.getMemberUnits(recipient), 0);
        assertEq(_countEvents(logs, address(flow), TARGET_OUTFLOW_REFRESH_FAILED_SIG), 0);
    }

    function test_clearStaleAllocation_nonZeroToZeroUnits_refreshesCachedOutflow() public {
        bytes32 recipientId = bytes32(uint256(910));
        address recipient = address(0x1910);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        vm.prank(manager);
        flow.addRecipient(recipientId, recipient, recipientMetadata);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        assertGt(flow.getMemberUnits(recipient), 0);

        strategy.setWeight(allocatorKey, 0);
        _mockDistributionRefreshFailure(flow, 900, bytes("refresh-failed"));

        vm.recordLogs();
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), allocatorKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.getMemberUnits(recipient), 0);
        _assertSingleRefreshFailure(logs, address(flow), 1_000, bytes("refresh-failed"));
    }

    function test_refreshOutflowFromCachedTarget_revertsWhenCallerIsNotSelf() public {
        vm.prank(other);
        vm.expectRevert(ONLY_SELF_OUTFLOW_REFRESH_SELECTOR);
        flow._refreshOutflowFromCachedTarget(0);
    }

    function test_getClaimableBalance_handlesNegativePoolValues() public {
        address member = address(0x1234);

        vm.mockCall(
            address(flow.distributionPool()),
            abi.encodeWithSelector(bytes4(keccak256("getClaimableNow(address)")), member),
            abi.encode(int256(25), uint256(block.timestamp))
        );

        assertEq(flow.getClaimableBalance(member), 25);
        vm.mockCall(
            address(flow.distributionPool()),
            abi.encodeWithSelector(bytes4(keccak256("getClaimableNow(address)")), member),
            abi.encode(int256(-3), uint256(block.timestamp))
        );

        assertEq(flow.getClaimableBalance(member), 0);
    }

    function test_addRecipient_ignoresLegacyBootstrapUpdateMemberUnitsFailure() public {
        bytes32 recipientId = bytes32(uint256(1));
        address recipient = address(0x111);
        vm.mockCall(
            address(flow.distributionPool()),
            abi.encodeWithSelector(bytes4(keccak256("updateMemberUnits(address,uint128)")), recipient, uint128(0)),
            abi.encode(false)
        );

        vm.prank(manager);
        flow.addRecipient(recipientId, recipient, recipientMetadata);
        assertEq(flow.getMemberUnits(recipient), 0);
    }

    function _countEvents(Vm.Log[] memory logs, address emitter, bytes32 eventSig) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSig) continue;
            unchecked {
                ++count;
            }
        }
    }

    function _mockDistributionRefreshFailure(CustomFlow targetFlow, int96 distributionFlowRate, bytes memory reason) internal {
        bytes memory distributeCallData = abi.encodeWithSelector(
            sf.gda.distributeFlow.selector,
            ISuperToken(address(superToken)),
            address(targetFlow),
            targetFlow.distributionPool(),
            distributionFlowRate,
            new bytes(0)
        );
        bytes memory hostCallData =
            abi.encodeWithSelector(sf.host.callAgreement.selector, sf.gda, distributeCallData, new bytes(0));
        vm.mockCallRevert(address(sf.host), hostCallData, reason);
    }

    function _assertSingleRefreshFailure(
        Vm.Log[] memory logs,
        address emitter,
        int96 expectedTargetOutflowRate,
        bytes memory expectedReason
    ) internal {
        uint256 matches;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != TARGET_OUTFLOW_REFRESH_FAILED_SIG) continue;

            (int96 targetOutflowRate, bytes memory reason) = abi.decode(logs[i].data, (int96, bytes));
            assertEq(targetOutflowRate, expectedTargetOutflowRate);
            assertEq(reason, expectedReason);
            unchecked {
                ++matches;
            }
        }
        assertEq(matches, 1);
    }
}
