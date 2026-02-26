// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {MockChildFlow} from "test/mocks/MockChildFlow.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import {FlowRecipients} from "src/library/FlowRecipients.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract FlowRecipientsTest is FlowTestBase {
    bytes32 internal constant RECIPIENT_CREATED_SIG =
        keccak256("RecipientCreated(bytes32,(address,uint32,bool,uint8,(string,string,string,string,string)),address)");
    bytes32 internal constant FLOW_RECIPIENT_CREATED_SIG =
        keccak256("FlowRecipientCreated(bytes32,address,address,uint32)");
    bytes32 internal constant CHILD_FLOW_DEPLOYED_SIG =
        keccak256("ChildFlowDeployed(bytes32,address,address,address,address,address,address)");
    bytes32 internal constant FLOW_INITIALIZED_SIG =
        keccak256("FlowInitialized(address,address,address,address,address,address,address,address,address,uint32,address)");

    function _isChildFlow(address childAddr) internal view returns (bool) {
        address[] memory children = flow.getChildFlows();
        for (uint256 i = 0; i < children.length; ++i) {
            if (children[i] == childAddr) return true;
        }
        return false;
    }

    function test_addRecipient_happyPath() public {
        bytes32 recipientId = bytes32(uint256(1));
        address recipientAddr = address(0x111);

        vm.prank(manager);
        flow.addRecipient(recipientId, recipientAddr, recipientMetadata);

        FlowTypes.FlowRecipient memory r = flow.getRecipientById(recipientId);
        assertEq(r.recipient, recipientAddr);
        assertEq(r.isRemoved, false);
        assertEq(uint8(r.recipientType), uint8(FlowTypes.RecipientType.ExternalAccount));
        assertEq(flow.recipientExists(recipientAddr), true);
        assertEq(flow.distributionPool().getUnits(recipientAddr), 0);
    }

    function test_addRecipient_revertCases() public {
        bytes32 recipientId = bytes32(uint256(1));
        address recipientAddr = address(0x111);

        vm.prank(other);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.addRecipient(recipientId, recipientAddr, recipientMetadata);

        vm.prank(manager);
        vm.expectRevert(IFlow.ADDRESS_ZERO.selector);
        flow.addRecipient(recipientId, address(0), recipientMetadata);

        FlowTypes.RecipientMetadata memory bad = recipientMetadata;
        bad.description = "";

        vm.prank(manager);
        vm.expectRevert(IFlow.INVALID_METADATA.selector);
        flow.addRecipient(recipientId, recipientAddr, bad);

        _addRecipient(recipientId, recipientAddr);

        vm.prank(manager);
        vm.expectRevert(IFlow.RECIPIENT_ALREADY_EXISTS.selector);
        flow.addRecipient(recipientId, address(0x222), recipientMetadata);

        vm.prank(manager);
        vm.expectRevert(IFlow.RECIPIENT_ALREADY_EXISTS.selector);
        flow.addRecipient(bytes32(uint256(2)), recipientAddr, recipientMetadata);
    }

    function test_addRecipient_revertsWhenRecipientIsManagerRewardPool() public {
        bytes32 recipientId = bytes32(uint256(3));

        vm.prank(manager);
        vm.expectRevert(FlowRecipients.MANAGER_REWARD_POOL_RECIPIENT_NOT_ALLOWED.selector);
        flow.addRecipient(recipientId, managerRewardPool, recipientMetadata);

        assertFalse(flow.recipientExists(managerRewardPool));
        assertEq(flow.distributionPool().getUnits(managerRewardPool), 0);
    }

    function test_removedBulkAddRecipients_selector_notExposed_andCannotMutateState() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(41));
        ids[1] = bytes32(uint256(42));

        address[] memory addrs = new address[](2);
        addrs[0] = address(0x111);
        addrs[1] = address(0x222);

        FlowTypes.RecipientMetadata[] memory metas = new FlowTypes.RecipientMetadata[](2);
        metas[0] = recipientMetadata;
        metas[1] = recipientMetadata;

        bytes memory legacyCallData = abi.encodeWithSignature(
            "bulkAddRecipients(bytes32[],address[],(string,string,string,string,string)[])",
            ids,
            addrs,
            metas
        );

        vm.prank(manager);
        _assertCallFails(address(flow), legacyCallData);

        assertFalse(flow.recipientExists(addrs[0]));
        assertFalse(flow.recipientExists(addrs[1]));
        assertEq(flow.distributionPool().getUnits(addrs[0]), 0);
        assertEq(flow.distributionPool().getUnits(addrs[1]), 0);

        vm.expectRevert(IFlow.RECIPIENT_NOT_FOUND.selector);
        flow.getRecipientById(ids[0]);
        vm.expectRevert(IFlow.RECIPIENT_NOT_FOUND.selector);
        flow.getRecipientById(ids[1]);
    }

    function test_removedActiveRecipientCount_selector_notExposed_andCannotMutateState() public {
        bytes32 recipientId = bytes32(uint256(43));
        address recipientAddr = address(0x143);
        _addRecipient(recipientId, recipientAddr);

        bytes memory legacyCallData = abi.encodeWithSignature("activeRecipientCount()");
        _assertCallFails(address(flow), legacyCallData);

        FlowTypes.FlowRecipient memory recipient = flow.getRecipientById(recipientId);
        assertEq(recipient.recipient, recipientAddr);
        assertEq(recipient.isRemoved, false);
        assertEq(flow.recipientExists(recipientAddr), true);
        assertEq(flow.distributionPool().getUnits(recipientAddr), 0);
    }

    function test_removeRecipient_eoa_happyAndReverts() public {
        bytes32 recipientId = bytes32(uint256(1));
        address recipientAddr = address(0x111);
        _addRecipient(recipientId, recipientAddr);

        vm.prank(manager);
        flow.removeRecipient(recipientId);

        FlowTypes.FlowRecipient memory r = flow.getRecipientById(recipientId);
        assertEq(r.isRemoved, true);
        assertEq(flow.recipientExists(recipientAddr), false);
        assertEq(flow.distributionPool().getUnits(recipientAddr), 0);

        vm.prank(manager);
        vm.expectRevert(IFlow.RECIPIENT_ALREADY_REMOVED.selector);
        flow.removeRecipient(recipientId);

        vm.prank(manager);
        vm.expectRevert(IFlow.INVALID_RECIPIENT_ID.selector);
        flow.removeRecipient(bytes32(uint256(2)));
    }

    function test_removeRecipient_tailOutflowRefreshRevert_isBestEffort() public {
        bytes32 recipientId = bytes32(uint256(501));
        address recipientAddr = address(0x501);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        _addRecipient(recipientId, recipientAddr);

        _mockDistributionRefreshFailure(900, bytes("remove-refresh-failed"));

        vm.prank(manager);
        flow.removeRecipient(recipientId);

        FlowTypes.FlowRecipient memory r = flow.getRecipientById(recipientId);
        assertEq(r.isRemoved, true);
        assertEq(flow.recipientExists(recipientAddr), false);
        assertEq(flow.targetOutflowRate(), 1_000);

        vm.prank(owner);
        vm.expectRevert(bytes("remove-refresh-failed"));
        flow.refreshTargetOutflowRate();
    }

    function test_removeRecipient_tailOutflowRefreshRevert_isBestEffort_withNonZeroUnits() public {
        bytes32 recipientId = bytes32(uint256(502));
        address recipientAddr = address(0x502);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        _addRecipient(recipientId, recipientAddr);

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        assertGt(flow.distributionPool().getUnits(recipientAddr), 0);

        _mockDistributionRefreshFailure(900, bytes("remove-refresh-failed"));

        vm.prank(manager);
        flow.removeRecipient(recipientId);

        FlowTypes.FlowRecipient memory r = flow.getRecipientById(recipientId);
        assertEq(r.isRemoved, true);
        assertEq(flow.recipientExists(recipientAddr), false);
        assertEq(flow.distributionPool().getUnits(recipientAddr), 0);
        assertEq(flow.targetOutflowRate(), 1_000);

        vm.prank(owner);
        vm.expectRevert(bytes("remove-refresh-failed"));
        flow.refreshTargetOutflowRate();
    }

    function test_bulkRemoveRecipients_happyAndReverts() public {
        (bytes32[] memory ids, address[] memory recipients) = _addNRecipients(2);

        vm.prank(manager);
        flow.bulkRemoveRecipients(ids);

        assertEq(flow.recipientExists(recipients[0]), false);
        assertEq(flow.recipientExists(recipients[1]), false);
        assertEq(flow.distributionPool().getUnits(recipients[0]), 0);
        assertEq(flow.distributionPool().getUnits(recipients[1]), 0);

        bytes32[] memory emptyIds = new bytes32[](0);
        vm.prank(manager);
        vm.expectRevert(IFlow.TOO_FEW_RECIPIENTS.selector);
        flow.bulkRemoveRecipients(emptyIds);
    }

    function test_bulkRemoveRecipients_tailOutflowRefreshRevert_isBestEffort() public {
        (bytes32[] memory ids, address[] memory recipients) = _addNRecipients(2);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);
        _mockDistributionRefreshFailure(900, bytes("bulk-remove-refresh-failed"));

        vm.prank(manager);
        flow.bulkRemoveRecipients(ids);

        assertEq(flow.recipientExists(recipients[0]), false);
        assertEq(flow.recipientExists(recipients[1]), false);
        assertEq(flow.targetOutflowRate(), 1_000);

        vm.prank(owner);
        vm.expectRevert(bytes("bulk-remove-refresh-failed"));
        flow.refreshTargetOutflowRate();
    }

    function test_bulkRemoveRecipients_tailOutflowRefreshRevert_isBestEffort_withNonZeroUnits() public {
        (bytes32[] memory ids, address[] memory recipients) = _addNRecipients(2);
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        vm.prank(allocator);
        flow.allocate(ids, scaled);
        assertGt(flow.distributionPool().getUnits(recipients[0]), 0);
        assertGt(flow.distributionPool().getUnits(recipients[1]), 0);

        _mockDistributionRefreshFailure(900, bytes("bulk-remove-refresh-failed"));

        vm.prank(manager);
        flow.bulkRemoveRecipients(ids);

        assertEq(flow.recipientExists(recipients[0]), false);
        assertEq(flow.recipientExists(recipients[1]), false);
        assertEq(flow.distributionPool().getUnits(recipients[0]), 0);
        assertEq(flow.distributionPool().getUnits(recipients[1]), 0);
        assertEq(flow.targetOutflowRate(), 1_000);

        vm.prank(owner);
        vm.expectRevert(bytes("bulk-remove-refresh-failed"));
        flow.refreshTargetOutflowRate();
    }

    function test_bulkRemoveRecipients_midBatchInvalidId_revertsAtomically() public {
        (bytes32[] memory ids, address[] memory recipients) = _addNRecipients(2);
        bytes32[] memory removeIds = new bytes32[](2);
        removeIds[0] = ids[0];
        removeIds[1] = bytes32(uint256(9999));

        vm.prank(manager);
        vm.expectRevert(IFlow.INVALID_RECIPIENT_ID.selector);
        flow.bulkRemoveRecipients(removeIds);

        assertTrue(flow.recipientExists(recipients[0]));
        assertTrue(flow.recipientExists(recipients[1]));
        assertEq(flow.distributionPool().getUnits(recipients[0]), 0);
        assertEq(flow.distributionPool().getUnits(recipients[1]), 0);
    }

    function test_bulkRemoveRecipients_withChildFlow_clearsTracking() public {
        bytes32 childId = bytes32(uint256(100));
        bytes32 eoaId = bytes32(uint256(101));
        _addRecipient(eoaId, address(0x111));

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) =
            flow.addFlowRecipient(childId, recipientMetadata, manager, manager, manager, managerRewardPool, strategies);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = childId;
        ids[1] = eoaId;

        vm.prank(manager);
        flow.bulkRemoveRecipients(ids);

        assertFalse(_isChildFlow(childAddr));
        assertEq(flow.distributionPool().getUnits(childAddr), 0);
    }

    function test_addFlowRecipient_happyPath() public {
        bytes32 rid = bytes32(uint256(11));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) =
            flow.addFlowRecipient(rid, recipientMetadata, manager, manager, manager, managerRewardPool, strategies);

        FlowTypes.FlowRecipient memory r = flow.getRecipientById(rid);
        assertEq(r.recipient, childAddr);
        assertEq(r.isRemoved, false);
        assertEq(uint8(r.recipientType), uint8(FlowTypes.RecipientType.FlowContract));
        assertTrue(flow.recipientExists(childAddr));

        address[] memory children = flow.getChildFlows();
        assertEq(children.length, 1);
        assertEq(children[0], childAddr);

        CustomFlow child = CustomFlow(childAddr);
        assertEq(child.parent(), address(flow));
        assertEq(child.recipientAdmin(), manager);
        assertEq(address(child.superToken()), address(superToken));
        assertEq(child.flowImplementation(), address(flowImplementation));
        assertEq(child.managerRewardPool(), managerRewardPool);
        assertEq(child.managerRewardPoolFlowRatePpm(), flow.managerRewardPoolFlowRatePpm());
        assertEq(child.allocationPipeline(), address(0));

        assertEq(flow.distributionPool().getUnits(childAddr), 0);
    }

    function test_addFlowRecipient_emitsRecipientCreatedBeforeFlowRecipientCreated() public {
        bytes32 rid = bytes32(uint256(211));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.recordLogs();
        vm.prank(manager);
        flow.addFlowRecipient(rid, recipientMetadata, manager, manager, manager, managerRewardPool, strategies);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 missing = type(uint256).max;
        address childFlowAddress = address(0);
        uint256 childFlowDeployedLogIndex = missing;
        uint256 childFlowInitializedLogIndex = missing;
        uint256 recipientCreatedLogIndex = missing;
        uint256 flowRecipientCreatedLogIndex = missing;

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(flow)) {
                if (logs[i].topics.length < 2 || logs[i].topics[1] != rid) continue;
                if (logs[i].topics[0] == CHILD_FLOW_DEPLOYED_SIG && childFlowDeployedLogIndex == missing) {
                    childFlowDeployedLogIndex = i;
                    childFlowAddress = address(uint160(uint256(logs[i].topics[2])));
                    continue;
                }
                if (logs[i].topics[0] == RECIPIENT_CREATED_SIG && recipientCreatedLogIndex == missing) {
                    recipientCreatedLogIndex = i;
                    continue;
                }
                if (logs[i].topics[0] == FLOW_RECIPIENT_CREATED_SIG && flowRecipientCreatedLogIndex == missing) {
                    flowRecipientCreatedLogIndex = i;
                }
                continue;
            }

            if (
                childFlowAddress != address(0)
                    && logs[i].emitter == childFlowAddress
                    && logs[i].topics.length != 0
                    && logs[i].topics[0] == FLOW_INITIALIZED_SIG
                    && childFlowInitializedLogIndex == missing
            ) {
                childFlowInitializedLogIndex = i;
            }
        }

        assertTrue(childFlowDeployedLogIndex != missing);
        assertTrue(childFlowInitializedLogIndex != missing);
        assertTrue(recipientCreatedLogIndex != missing);
        assertTrue(flowRecipientCreatedLogIndex != missing);
        assertLt(childFlowDeployedLogIndex, childFlowInitializedLogIndex);
        assertLt(childFlowDeployedLogIndex, recipientCreatedLogIndex);
        assertLt(recipientCreatedLogIndex, flowRecipientCreatedLogIndex);
    }

    function test_addFlowRecipient_emitsChildFlowDeployed_withExpectedPayload() public {
        bytes32 rid = bytes32(uint256(212));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        address childRecipientAdmin = makeAddr("childRecipientAdminPayload");
        address childFlowOperator = makeAddr("childFlowOperatorPayload");
        address childSweeper = makeAddr("childSweeperPayload");

        vm.recordLogs();
        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            rid,
            recipientMetadata,
            childRecipientAdmin,
            childFlowOperator,
            childSweeper,
            managerRewardPool,
            strategies
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(flow)) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != CHILD_FLOW_DEPLOYED_SIG) continue;
            if (logs[i].topics[1] != rid) continue;

            seen++;

            address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
            address emittedStrategy = address(uint160(uint256(logs[i].topics[3])));
            (
                address emittedRecipientAdmin,
                address emittedFlowOperator,
                address emittedSweeper,
                address emittedManagerRewardPool
            ) = abi.decode(logs[i].data, (address, address, address, address));

            assertEq(emittedRecipient, childAddr);
            assertEq(emittedStrategy, address(strategy));
            assertEq(emittedRecipientAdmin, childRecipientAdmin);
            assertEq(emittedFlowOperator, childFlowOperator);
            assertEq(emittedSweeper, childSweeper);
            assertEq(emittedManagerRewardPool, managerRewardPool);
        }

        assertEq(seen, 1);
    }

    function test_addFlowRecipient_forwardsDistinctChildAuthoritiesAndEnforcesAccess() public {
        bytes32 rid = bytes32(uint256(111));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        address childRecipientAdmin = makeAddr("childRecipientAdmin");
        address childFlowOperator = makeAddr("childFlowOperator");
        address childSweeper = makeAddr("childSweeper");

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            rid,
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
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        child.setDescription("forbidden");

        vm.prank(childRecipientAdmin);
        child.setDescription("allowed");

        vm.prank(childRecipientAdmin);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        child.setTargetOutflowRate(0);

        vm.prank(childFlowOperator);
        child.setTargetOutflowRate(0);

        uint256 sweepAmount = 77;
        vm.prank(owner);
        superToken.transfer(childAddr, sweepAmount);

        vm.prank(childFlowOperator);
        vm.expectRevert(IFlow.NOT_SWEEPER.selector);
        child.sweepSuperToken(other, sweepAmount);

        uint256 before = superToken.balanceOf(other);
        vm.prank(childSweeper);
        uint256 swept = child.sweepSuperToken(other, type(uint256).max);
        assertEq(swept, sweepAmount);
        assertEq(superToken.balanceOf(other) - before, sweepAmount);
    }

    function test_addFlowRecipient_withParentPipeline_childPipelineRemainsUnset() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(0));
        CustomFlow parentWithPipeline =
            _deployFlowWithConfig(owner, manager, managerRewardPool, address(pipeline), address(0), strategies);
        assertEq(parentWithPipeline.allocationPipeline(), address(pipeline));

        vm.prank(owner);
        superToken.transfer(address(parentWithPipeline), 1_000e18);

        vm.prank(manager);
        (, address childAddr) = parentWithPipeline.addFlowRecipient(
            bytes32(uint256(12)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        CustomFlow child = CustomFlow(childAddr);
        assertEq(child.parent(), address(parentWithPipeline));
        assertEq(child.allocationPipeline(), address(0));
    }

    function test_addFlowRecipient_revertsForNestedChildren() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            bytes32(uint256(13)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        CustomFlow child = CustomFlow(childAddr);
        vm.prank(manager);
        vm.expectRevert(IFlow.NESTED_FLOW_RECIPIENTS_DISABLED.selector);
        child.addFlowRecipient(
            bytes32(uint256(14)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
    }

    function test_addFlowRecipient_deploysEip1167Clone() public {
        bytes32 rid = bytes32(uint256(12));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) =
            flow.addFlowRecipient(rid, recipientMetadata, manager, manager, manager, managerRewardPool, strategies);

        bytes memory expectedRuntime = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            bytes20(address(flowImplementation)),
            hex"5af43d82803e903d91602b57fd5bf3"
        );

        assertEq(childAddr.code, expectedRuntime);
    }

    function test_addFlowRecipient_revertsWhenFlowImplementationHasNoCode() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        address flowImplWithoutCode = makeAddr("flowImplWithoutCode");
        address flowProxy = address(new ERC1967Proxy(address(flowImplementation), ""));

        vm.prank(owner);
        ICustomFlow(flowProxy).initialize(
            address(superToken),
            flowImplWithoutCode,
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            flowParams,
            flowMetadata,
            strategies
        );
        CustomFlow flowWithMissingImplCode = CustomFlow(flowProxy);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFlow.NOT_A_CONTRACT.selector, flowImplWithoutCode));
        flowWithMissingImplCode.addFlowRecipient(
            bytes32(uint256(5001)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
    }

    function test_addFlowRecipient_revertCases() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(other);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.addFlowRecipient(
            bytes32(uint256(1)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        FlowTypes.RecipientMetadata memory bad = recipientMetadata;
        bad.image = "";

        vm.prank(manager);
        vm.expectRevert(IFlow.INVALID_METADATA.selector);
        flow.addFlowRecipient(bytes32(uint256(2)), bad, manager, manager, manager, managerRewardPool, strategies);

        vm.prank(manager);
        vm.expectRevert(IFlow.ADDRESS_ZERO.selector);
        flow.addFlowRecipient(
            bytes32(uint256(3)),
            recipientMetadata,
            address(0),
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        vm.prank(manager);
        vm.expectRevert(IFlow.ADDRESS_ZERO.selector);
        flow.addFlowRecipient(
            bytes32(uint256(33)),
            recipientMetadata,
            manager,
            address(0),
            manager,
            managerRewardPool,
            strategies
        );

        vm.prank(manager);
        vm.expectRevert(IFlow.ADDRESS_ZERO.selector);
        flow.addFlowRecipient(
            bytes32(uint256(34)),
            recipientMetadata,
            manager,
            manager,
            address(0),
            managerRewardPool,
            strategies
        );

        vm.prank(manager);
        vm.expectRevert(IFlow.ADDRESS_ZERO.selector);
        flow.addFlowRecipient(
            bytes32(uint256(35)),
            recipientMetadata,
            manager,
            manager,
            manager,
            address(0),
            strategies
        );

        IAllocationStrategy[] memory emptyStrategies = new IAllocationStrategy[](0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFlow.FLOW_REQUIRES_SINGLE_STRATEGY.selector, 0));
        flow.addFlowRecipient(
            bytes32(uint256(31)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            emptyStrategies
        );

        IAllocationStrategy[] memory twoStrategies = new IAllocationStrategy[](2);
        twoStrategies[0] = IAllocationStrategy(address(strategy));
        twoStrategies[1] = IAllocationStrategy(address(0xBEEF));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFlow.FLOW_REQUIRES_SINGLE_STRATEGY.selector, 2));
        flow.addFlowRecipient(
            bytes32(uint256(32)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            twoStrategies
        );

        vm.prank(manager);
        flow.addFlowRecipient(bytes32(uint256(4)), recipientMetadata, manager, manager, manager, managerRewardPool, strategies);

        vm.prank(manager);
        vm.expectRevert(IFlow.RECIPIENT_ALREADY_EXISTS.selector);
        flow.addFlowRecipient(bytes32(uint256(4)), recipientMetadata, manager, manager, manager, managerRewardPool, strategies);
    }

    function test_addFlowRecipient_succeedsPastLegacyMaxChildFlowCount() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        uint256 legacyCap = 170;
        bytes memory childCode = address(new MockChildFlow()).code;
        for (uint256 i = 0; i < legacyCap; ++i) {
            address child = vm.addr(i + 10_000);
            vm.etch(child, childCode);
            _harnessFlow().addChildForTest(child);
        }

        vm.prank(manager);
        (bytes32 rid, address childAddr) = flow.addFlowRecipient(
            bytes32(uint256(1701)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        assertEq(rid, bytes32(uint256(1701)));
        assertEq(flow.getChildFlows().length, legacyCap + 1);
        assertTrue(flow.recipientExists(childAddr));
    }

    function test_addFlowRecipient_succeedsAtLegacyMaxMinusOneAndReachesLegacyMax() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        uint256 legacyCap = 170;
        bytes memory childCode = address(new MockChildFlow()).code;
        for (uint256 i = 0; i < legacyCap - 1; ++i) {
            address child = vm.addr(i + 20_000);
            vm.etch(child, childCode);
            _harnessFlow().addChildForTest(child);
        }

        vm.prank(manager);
        (bytes32 rid, address childAddr) =
            flow.addFlowRecipient(
                bytes32(uint256(1702)),
                recipientMetadata,
                manager,
                manager,
                manager,
                managerRewardPool,
                strategies
            );

        assertEq(rid, bytes32(uint256(1702)));
        assertEq(flow.getChildFlows().length, legacyCap);
        assertTrue(flow.recipientExists(childAddr));
    }

    function test_removeRecipient_childFlow_clearsTracking() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) =
            flow.addFlowRecipient(
                bytes32(uint256(1)),
                recipientMetadata,
                manager,
                manager,
                manager,
                managerRewardPool,
                strategies
            );

        vm.prank(manager);
        flow.removeRecipient(bytes32(uint256(1)));

        assertFalse(_isChildFlow(childAddr));
        assertFalse(flow.recipientExists(childAddr));
        assertEq(flow.distributionPool().getUnits(childAddr), 0);
    }

    function test_getRecipientById_notFound() public {
        vm.expectRevert(IFlow.RECIPIENT_NOT_FOUND.selector);
        flow.getRecipientById(bytes32(uint256(12345)));
    }

    function _mockDistributionRefreshFailure(int96 distributionFlowRate, bytes memory reason) internal {
        bytes memory distributeCallData = abi.encodeWithSelector(
            sf.gda.distributeFlow.selector,
            ISuperToken(address(superToken)),
            address(flow),
            flow.distributionPool(),
            distributionFlowRate,
            new bytes(0)
        );
        bytes memory hostCallData =
            abi.encodeWithSelector(sf.host.callAgreement.selector, sf.gda, distributeCallData, new bytes(0));
        vm.mockCallRevert(address(sf.host), hostCallData, reason);
    }
}
