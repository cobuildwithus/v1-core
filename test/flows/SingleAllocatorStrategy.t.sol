// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Test} from "forge-std/Test.sol";

import {SingleAllocatorStrategy} from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {AddressKeyAllocation} from "src/library/AddressKeyAllocation.sol";

contract SingleAllocatorStrategyTest is Test {
    address internal constant FLOW = address(0xF10);

    SingleAllocatorStrategyTestAllocator internal controller;
    SingleAllocatorStrategyTestAllocator internal newController;

    SingleAllocatorStrategy internal strategy;
    SingleAllocatorStrategyTestGoalTreasury internal goalTreasury;

    function setUp() public {
        controller = new SingleAllocatorStrategyTestAllocator();
        newController = new SingleAllocatorStrategyTestAllocator();
        goalTreasury = new SingleAllocatorStrategyTestGoalTreasury(FLOW);
        strategy = new SingleAllocatorStrategy(address(goalTreasury), address(controller));
    }

    function test_constructor_setsGoalScopeAndAllocator() public view {
        assertEq(strategy.goalTreasury(), address(goalTreasury));
        assertEq(strategy.allocator(), address(controller));
    }

    function test_constructor_revertsOnZeroGoalTreasury() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new SingleAllocatorStrategy(address(0), address(controller));
    }

    function test_constructor_revertsOnNonContractGoalTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(SingleAllocatorStrategy.NOT_A_CONTRACT.selector, address(0xBEEF)));
        new SingleAllocatorStrategy(address(0xBEEF), address(controller));
    }

    function test_constructor_revertsOnZeroAllocator() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new SingleAllocatorStrategy(address(goalTreasury), address(0));
    }

    function test_constructor_revertsOnNonContractAllocator() public {
        address eoaController = makeAddr("eoa-controller");
        vm.expectRevert(abi.encodeWithSelector(SingleAllocatorStrategy.NOT_A_CONTRACT.selector, eoaController));
        new SingleAllocatorStrategy(address(goalTreasury), eoaController);
    }

    function test_allocationKey_roundTripsThroughControllerAddress() public {
        uint256 key = strategy.allocationKey(address(controller), bytes(""));
        assertEq(key, AddressKeyAllocation.keyFor(address(controller)));
        assertEq(strategy.accountForAllocationKey(key), address(controller));

        address outsider = makeAddr("outsider");
        uint256 outsiderKey = strategy.allocationKey(outsider, abi.encode(uint256(123)));
        assertEq(outsiderKey, AddressKeyAllocation.keyFor(outsider));
        assertEq(strategy.accountForAllocationKey(outsiderKey), outsider);
    }

    function test_currentWeightAndCanAllocate_areScopedToGoalFlowAndAllocatorKey() public {
        uint256 controllerKey = strategy.allocationKey(address(controller), bytes(""));
        address outsider = makeAddr("outsider");
        uint256 outsiderKey = strategy.allocationKey(outsider, bytes(""));

        assertEq(strategy.currentWeight(FLOW, controllerKey), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(address(0xBEEF), controllerKey), 0);
        assertEq(strategy.currentWeight(FLOW, outsiderKey), 0);

        assertTrue(strategy.canAllocate(FLOW, controllerKey, address(controller)));
        assertFalse(strategy.canAllocate(FLOW, controllerKey, outsider));
        assertFalse(strategy.canAllocate(FLOW, outsiderKey, address(controller)));
        assertFalse(strategy.canAllocate(address(0xBEEF), controllerKey, address(controller)));
    }

    function test_legacyOwnableSurface_isAbsent() public {
        _assertSelectorAbsent(address(strategy), abi.encodeWithSignature("changeAllocator(address)", newController));
        _assertSelectorAbsent(address(strategy), abi.encodeWithSignature("owner()"));
        assertEq(strategy.allocator(), address(controller));
    }

    function test_clone_initialize_setsGoalScopeAndAllocator() public {
        SingleAllocatorStrategy clone = _cloneStrategy();

        clone.initialize(address(goalTreasury), address(controller));

        assertEq(clone.goalTreasury(), address(goalTreasury));
        assertEq(clone.allocator(), address(controller));
    }

    function test_clone_initialize_revertsOnReinitialize() public {
        SingleAllocatorStrategy clone = _cloneStrategy();

        clone.initialize(address(goalTreasury), address(controller));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(goalTreasury), address(newController));
    }

    function test_clone_initialize_revertsOnNonContractAllocator() public {
        SingleAllocatorStrategy clone = _cloneStrategy();
        address eoaController = makeAddr("eoa-controller");

        vm.expectRevert(abi.encodeWithSelector(SingleAllocatorStrategy.NOT_A_CONTRACT.selector, eoaController));
        clone.initialize(address(goalTreasury), eoaController);
    }

    function test_directDeployment_rejectsInitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        strategy.initialize(address(goalTreasury), address(newController));
    }

    function _assertSelectorAbsent(address target, bytes memory callData) internal {
        (bool success, bytes memory returnData) = target.call(callData);
        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function _cloneStrategy() internal returns (SingleAllocatorStrategy clone) {
        SingleAllocatorStrategy implementation = new SingleAllocatorStrategy(address(0), address(0));
        clone = SingleAllocatorStrategy(Clones.clone(address(implementation)));
    }
}

contract SingleAllocatorStrategyTestGoalTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract SingleAllocatorStrategyTestAllocator {}
