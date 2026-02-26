// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";

import {IFlow, ICustomFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract FlowInitializationAndAccessBase is FlowTestBase {
    function _expectInitRevertWithRoles(
        bytes memory revertData,
        address superToken_,
        address flowImpl_,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address managerRewardPool_,
        address parent_,
        IFlow.FlowParams memory params,
        FlowTypes.RecipientMetadata memory metadata,
        IAllocationStrategy[] memory strategies
    ) internal {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));
        if (revertData.length > 0) vm.expectRevert(revertData);
        ICustomFlow(proxy).initialize(
            superToken_,
            flowImpl_,
            recipientAdmin_,
            flowOperator_,
            sweeper_,
            managerRewardPool_,
            address(0),
            parent_,
            params,
            metadata,
            strategies
        );
    }

    function _expectInitRevert(
        bytes memory revertData,
        address superToken_,
        address flowImpl_,
        address manager_,
        address managerRewardPool_,
        address parent_,
        IFlow.FlowParams memory params,
        FlowTypes.RecipientMetadata memory metadata,
        IAllocationStrategy[] memory strategies
    ) internal {
        _expectInitRevertWithRoles(
            revertData,
            superToken_,
            flowImpl_,
            manager_,
            manager_,
            manager_,
            managerRewardPool_,
            parent_,
            params,
            metadata,
            strategies
        );
    }

    function _deployFlowWith(
        address initCaller,
        address superToken_,
        address flowImpl_,
        address manager_,
        address managerRewardPool_,
        address parent_,
        IFlow.FlowParams memory params,
        FlowTypes.RecipientMetadata memory metadata,
        IAllocationStrategy[] memory strategies
    ) internal returns (CustomFlow deployed) {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));
        vm.prank(initCaller);
        ICustomFlow(proxy).initialize(
            superToken_,
            flowImpl_,
            manager_,
            manager_,
            manager_,
            managerRewardPool_,
            address(0),
            parent_,
            params,
            metadata,
            strategies
        );
        deployed = CustomFlow(proxy);
    }

    function _oneStrategy() internal view returns (IAllocationStrategy[] memory arr) {
        arr = new IAllocationStrategy[](1);
        arr[0] = IAllocationStrategy(address(strategy));
    }
}

contract FlowInitializationAndAccessInitSurfaceAuditTest is FlowInitializationAndAccessBase {
    function test_initialize_revertsWhenFlowOperatorIsZero_butOtherRolesAreSet() public {
        _expectInitRevertWithRoles(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            address(0),
            manager,
            managerRewardPool,
            address(0),
            flowParams,
            flowMetadata,
            _oneStrategy()
        );
    }

    function test_initialize_revertsWhenSweeperIsZero_butOtherRolesAreSet() public {
        _expectInitRevertWithRoles(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            address(0),
            managerRewardPool,
            address(0),
            flowParams,
            flowMetadata,
            _oneStrategy()
        );
    }

    function test_initializeWithRoles_selectorNotExposed() public {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));

        bytes memory legacyCallData = abi.encodeWithSignature(
            "initializeWithRoles(address,address,address,address,address,address,address,address,address,(uint32),(string,string,string,string,string),address[])",
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            flowParams,
            flowMetadata,
            _oneStrategy()
        );

        _assertCallFails(proxy, legacyCallData);
        assertEq(ICustomFlow(proxy).recipientAdmin(), address(0));
    }

    function test_initialize_legacySelectorWithConnectPoolAdmin_notExposed() public {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));

        bytes memory legacyCallData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address,address,(uint32),(string,string,string,string,string),address[])",
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            address(0xD00D),
            flowParams,
            flowMetadata,
            _oneStrategy()
        );

        _assertCallFails(proxy, legacyCallData);
        assertEq(ICustomFlow(proxy).recipientAdmin(), address(0));
    }

    function test_connectPoolAdmin_getterSelectorNotExposed() public {
        _assertCallFails(address(flow), abi.encodeWithSignature("connectPoolAdmin()"));
        assertEq(flow.recipientAdmin(), manager);
    }
}
