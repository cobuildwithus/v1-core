// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowInitializationAndAccessBase} from "test/flows/FlowInitializationAndAccess.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";

contract FlowInitializationAndAccessParentTest is FlowInitializationAndAccessBase {
    function test_parent_canCall_ownerOrParentSetters() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();
        address parentAddr = address(0xABCD);
        CustomFlow child = _deployFlowWith(
            owner,
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            parentAddr,
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        vm.prank(owner);
        superToken.transfer(address(child), 1_000e18);

        vm.prank(parentAddr);
        child.setTargetOutflowRate(1_000);
        assertEq(child.targetOutflowRate(), 1_000);
    }
}
