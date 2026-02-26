// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowInitializationAndAccessBase} from "test/flows/FlowInitializationAndAccess.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {ISuperfluidPool, ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperTokenV1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

contract FlowInitializationAndAccessConnectTest is FlowInitializationAndAccessBase {
    using SuperTokenV1Library for ISuperToken;

    function test_connectPool_permissions_and_zeroAddress() public {
        vm.expectRevert(IFlow.ADDRESS_ZERO.selector);
        flow.connectPool(ISuperfluidPool(address(0)));

        ISuperfluidPool distribution = flow.distributionPool();
        ISuperToken token = ISuperToken(address(superToken));

        assertFalse(token.isMemberConnected(address(distribution), address(flow)));

        vm.prank(owner);
        flow.connectPool(distribution);
        assertTrue(token.isMemberConnected(address(distribution), address(flow)));

        IAllocationStrategy[] memory strategies = _oneStrategy();
        address parentAddr = address(0x1234);
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

        assertFalse(token.isMemberConnected(address(child.distributionPool()), address(child)));
        assertFalse(token.isMemberConnected(address(distribution), address(child)));
        vm.prank(parentAddr);
        child.connectPool(distribution);
        assertTrue(token.isMemberConnected(address(distribution), address(child)));

        _expectConnectPoolDenied(flow, distribution);
        _expectConnectPoolDenied(child, distribution);

        vm.prank(connectPoolAdmin);
        flow.connectPool(distribution);

        vm.prank(manager);
        flow.connectPool(distribution);
    }

    function _expectConnectPoolDenied(CustomFlow flow_, ISuperfluidPool pool) internal {
        vm.prank(other);
        vm.expectRevert(IFlow.NOT_ALLOWED_TO_CONNECT_POOL.selector);
        flow_.connectPool(pool);
    }
}
