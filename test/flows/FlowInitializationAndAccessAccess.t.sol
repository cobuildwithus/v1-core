// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowInitializationAndAccessBase} from "test/flows/FlowInitializationAndAccess.t.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";

contract FlowInitializationAndAccessAccessTest is FlowInitializationAndAccessBase {
    function test_onlyRecipientAdmin_functions_revertForUnauthorized() public {
        bytes32 id = bytes32(uint256(1));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;

        vm.startPrank(other);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.addRecipient(id, other, recipientMetadata);

        IAllocationStrategy[] memory strategies = _oneStrategy();
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.addFlowRecipient(
            bytes32(uint256(2)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );

        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.removeRecipient(id);

        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.bulkRemoveRecipients(ids);
        vm.stopPrank();

        vm.startPrank(allocator);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.addRecipient(bytes32(uint256(99)), allocator, recipientMetadata);
        vm.stopPrank();
    }

    function test_removedBulkAddRecipients_selector_notExposed_forAnyCaller() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(8001));
        address[] memory addrs = new address[](1);
        addrs[0] = other;
        FlowTypes.RecipientMetadata[] memory metas = new FlowTypes.RecipientMetadata[](1);
        metas[0] = recipientMetadata;

        bytes memory legacyCallData = abi.encodeWithSignature(
            "bulkAddRecipients(bytes32[],address[],(string,string,string,string,string)[])",
            ids,
            addrs,
            metas
        );

        vm.prank(other);
        _assertCallFails(address(flow), legacyCallData);

        vm.prank(manager);
        _assertCallFails(address(flow), legacyCallData);
    }

    function test_initCaller_notRecipientAdmin_cannotCall_recipientAdminOnly_functions() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();
        address distinctManager = address(0xBEEF);
        CustomFlow ownerSeparatedFlow = _deployFlowWith(
            owner,
            address(superToken),
            address(flowImplementation),
            distinctManager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        vm.prank(owner);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        ownerSeparatedFlow.addRecipient(bytes32(uint256(100)), owner, recipientMetadata);
    }

    function test_recipientAdminOnly_setters_revertForUnauthorized() public {
        vm.startPrank(other);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.setMetadata(recipientMetadata);

        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.setDescription("x");
        vm.stopPrank();
    }

    function test_removedChildSyncModeSetter_selector_notExposed() public {
        _assertCallFails(
            address(flow),
            abi.encodeWithSignature("setChildFlowSyncMode(address,uint8)", address(0x1234), uint8(0))
        );
    }

    function test_removedSyncChildFlows_selector_notExposed() public {
        bytes memory callData = abi.encodeWithSignature("syncChildFlows(uint256)", uint256(1));

        _assertCallFails(address(flow), callData);

        vm.prank(manager);
        _assertCallFails(address(flow), callData);
    }

    function test_addRecipient_revertsWhenRecipientIsSelf() public {
        bytes32 id = bytes32(uint256(404));
        vm.prank(manager);
        vm.expectRevert(IFlow.SELF_RECIPIENT_NOT_ALLOWED.selector);
        flow.addRecipient(id, address(flow), recipientMetadata);
    }

    function test_onlyFlowOperatorOrParent_functions_accessControl() public {
        vm.startPrank(other);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        flow.setTargetOutflowRate(1);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        flow.refreshTargetOutflowRate();
        vm.stopPrank();

        vm.startPrank(manager);
        flow.setTargetOutflowRate(1);
        flow.refreshTargetOutflowRate();
        vm.stopPrank();
    }

    function test_roleSeparatedInit_flowRateOps_requireFlowOperatorOrParent() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();
        address parentFlow = makeAddr("parentFlow");
        address operator = makeAddr("operator");
        address sweeper = makeAddr("sweeper");
        CustomFlow roleSeparatedFlow = _deployFlowWithConfigAndRoles(
            owner,
            manager,
            operator,
            sweeper,
            managerRewardPool,
            address(0),
            parentFlow,
            strategies
        );

        vm.prank(manager);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        roleSeparatedFlow.setTargetOutflowRate(0);

        vm.prank(other);
        vm.expectRevert(IFlow.NOT_FLOW_OPERATOR_OR_PARENT.selector);
        roleSeparatedFlow.refreshTargetOutflowRate();

        vm.startPrank(operator);
        roleSeparatedFlow.setTargetOutflowRate(0);
        roleSeparatedFlow.refreshTargetOutflowRate();
        vm.stopPrank();

        vm.startPrank(parentFlow);
        roleSeparatedFlow.setTargetOutflowRate(0);
        roleSeparatedFlow.refreshTargetOutflowRate();
        vm.stopPrank();
    }

    function test_removedFlowRateMutationSelectors_notExposed_evenForOperatorOrParent() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();
        address parentFlow = makeAddr("parentFlow");
        address operator = makeAddr("operator");
        address sweeper = makeAddr("sweeper");
        CustomFlow roleSeparatedFlow = _deployFlowWithConfigAndRoles(
            owner,
            manager,
            operator,
            sweeper,
            managerRewardPool,
            address(0),
            parentFlow,
            strategies
        );

        bytes memory legacyIncreaseCallData = abi.encodeWithSignature("increaseFlowRate(int96)", int96(1));
        bytes memory legacyCapCallData = abi.encodeWithSignature("capFlowRateToMaxSafe()");

        vm.prank(other);
        _assertCallFails(address(roleSeparatedFlow), legacyIncreaseCallData);
        vm.prank(other);
        _assertCallFails(address(roleSeparatedFlow), legacyCapCallData);

        vm.prank(operator);
        _assertCallFails(address(roleSeparatedFlow), legacyIncreaseCallData);
        vm.prank(operator);
        _assertCallFails(address(roleSeparatedFlow), legacyCapCallData);

        vm.prank(parentFlow);
        _assertCallFails(address(roleSeparatedFlow), legacyIncreaseCallData);
        vm.prank(parentFlow);
        _assertCallFails(address(roleSeparatedFlow), legacyCapCallData);
    }

    function test_sweep_requiresConfiguredSweeper_evenWhenParentIsSet() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();
        address parentFlow = makeAddr("parentFlow");
        address operator = makeAddr("operator");
        address sweeper = makeAddr("sweeper");
        CustomFlow roleSeparatedFlow = _deployFlowWithConfigAndRoles(
            owner,
            manager,
            operator,
            sweeper,
            managerRewardPool,
            address(0),
            parentFlow,
            strategies
        );

        vm.prank(parentFlow);
        vm.expectRevert(IFlow.NOT_SWEEPER.selector);
        roleSeparatedFlow.sweepSuperToken(address(0xCAFE), 1);
    }

    function test_sweep_onlyConfiguredSweeper_canTransferBalance() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();
        address operator = makeAddr("operator");
        address sweeper = makeAddr("sweeper");
        CustomFlow roleSeparatedFlow = _deployFlowWithConfigAndRoles(
            owner,
            manager,
            operator,
            sweeper,
            managerRewardPool,
            address(0),
            address(0),
            strategies
        );

        uint256 amount = 1234;
        vm.prank(owner);
        superToken.transfer(address(roleSeparatedFlow), amount);

        vm.prank(manager);
        vm.expectRevert(IFlow.NOT_SWEEPER.selector);
        roleSeparatedFlow.sweepSuperToken(other, amount);

        vm.prank(operator);
        vm.expectRevert(IFlow.NOT_SWEEPER.selector);
        roleSeparatedFlow.sweepSuperToken(other, amount);

        uint256 before = superToken.balanceOf(other);
        vm.prank(sweeper);
        uint256 swept = roleSeparatedFlow.sweepSuperToken(other, type(uint256).max);

        assertEq(swept, amount);
        assertEq(superToken.balanceOf(other) - before, amount);
        assertEq(superToken.balanceOf(address(roleSeparatedFlow)), 0);
    }

    function test_removed_config_setter_selectors_are_not_exposed() public {
        vm.startPrank(other);
        _assertRemovedConfigSettersNotExposed(address(flow));
        vm.stopPrank();

        vm.startPrank(manager);
        _assertRemovedConfigSettersNotExposed(address(flow));
        vm.stopPrank();
    }
}
