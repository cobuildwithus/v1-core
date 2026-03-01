// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";

import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";

contract FlowUpgradesTest is FlowTestBase {
    function _addChild(bytes32 id) internal returns (address childAddr) {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, childAddr) =
            flow.addFlowRecipient(id, recipientMetadata, manager, manager, manager, managerRewardPool, 0,
            strategies);
    }

    function test_upgrade_entrypoint_selector_notExposedOnParentFlow() public {
        _assertCallFails(
            address(flow), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xBEEF), bytes(""))
        );
        _assertCallFails(address(flow), abi.encodeWithSignature("upgradeAllChildFlows()"));
    }

    function test_upgrade_entrypoint_selector_notExposedOnChildFlow() public {
        address child = _addChild(bytes32(uint256(1)));
        _assertCallFails(child, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xBEEF), bytes("")));
    }

    function test_setFlowImpl_selector_notExposedOnRootFlow() public {
        _assertCallFails(address(flow), abi.encodeWithSignature("setFlowImpl(address)", address(0xCAFE)));
        assertEq(flow.flowImplementation(), address(flowImplementation));
    }

    function test_setFlowImpl_selector_notExposedOnChildFlow() public {
        address child = _addChild(bytes32(uint256(2)));
        _assertCallFails(child, abi.encodeWithSignature("setFlowImpl(address)", address(0xD00D)));
        assertEq(CustomFlow(child).flowImplementation(), address(flowImplementation));
    }
}
