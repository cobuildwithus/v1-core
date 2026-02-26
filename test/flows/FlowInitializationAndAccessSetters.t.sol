// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowInitializationAndAccessBase} from "test/flows/FlowInitializationAndAccess.t.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";

contract FlowInitializationAndAccessSettersTest is FlowInitializationAndAccessBase {
    function test_setFlowRate_revertsOnNegative() public {
        vm.prank(owner);
        vm.expectRevert(IFlow.FLOW_RATE_NEGATIVE.selector);
        flow.setTargetOutflowRate(-1);
    }

    function test_removedConfigSetterSelectors_failAndPreserveValues() public {
        address originalFlowImpl = address(flowImplementation);
        uint32 originalRewardPpm = flowParams.managerRewardPoolFlowRatePpm;

        vm.startPrank(manager);
        _assertRemovedConfigSettersNotExposed(address(flow));
        vm.stopPrank();

        assertEq(flow.flowImplementation(), originalFlowImpl);
        assertEq(flow.managerRewardPoolFlowRatePpm(), originalRewardPpm);

        IAllocationStrategy[] memory strategies = _oneStrategy();
        vm.prank(manager);
        flow.addFlowRecipient(
            bytes32(uint256(3001)),
            recipientMetadata,
            manager,
            manager,
            manager,
            managerRewardPool,
            strategies
        );
    }

    function test_roleSeparatedInit_setsAuthorities_andRemovedChildSyncModeSelectorNotExposed() public {
        address operator = address(0x222);
        address sweeper = address(0x333);
        IAllocationStrategy[] memory strategies = _oneStrategy();
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

        assertEq(roleSeparatedFlow.recipientAdmin(), manager);
        assertEq(roleSeparatedFlow.flowOperator(), operator);
        assertEq(roleSeparatedFlow.sweeper(), sweeper);
        _assertCallFails(address(roleSeparatedFlow), abi.encodeWithSignature("setRecipientAdmin(address)", address(0x1234)));

        vm.startPrank(manager);
        (, address childFlow) =
            roleSeparatedFlow.addFlowRecipient(
                bytes32(uint256(2001)),
                recipientMetadata,
                manager,
                manager,
                manager,
                managerRewardPool,
                strategies
            );
        childFlow;
        _assertCallFails(
            address(roleSeparatedFlow),
            abi.encodeWithSignature("setChildFlowSyncMode(address,uint8)", address(0x777), uint8(0))
        );
        vm.stopPrank();
    }

    function test_metadataSetters_validation() public {
        FlowTypes.RecipientMetadata memory bad = recipientMetadata;
        bad.title = "";

        vm.startPrank(manager);
        vm.expectRevert(IFlow.INVALID_METADATA.selector);
        flow.setMetadata(bad);

        vm.expectRevert(IFlow.INVALID_METADATA.selector);
        flow.setDescription("");

        flow.setDescription("new description");
        vm.stopPrank();

        FlowTypes.RecipientMetadata memory m = flow.flowMetadata();
        assertEq(m.description, "new description");
    }
}
