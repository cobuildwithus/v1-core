// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { SingleAllocatorStrategy } from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { AddressKeyAllocation } from "src/library/AddressKeyAllocation.sol";

contract SingleAllocatorStrategyTest is Test {
    address internal constant FLOW = address(0xF10);

    event AllocatorChanged(address indexed oldAllocator, address indexed newAllocator);

    address internal owner = makeAddr("owner");
    address internal controller = makeAddr("controller");
    address internal safe = makeAddr("safe");
    address internal newSafe = makeAddr("new-safe");
    address internal newController = makeAddr("new-controller");
    address internal outsider = makeAddr("outsider");

    SingleAllocatorStrategy internal strategy;
    SingleAllocatorStrategyTestGoalTreasury internal goalTreasury;

    function setUp() public {
        goalTreasury = new SingleAllocatorStrategyTestGoalTreasury(FLOW);
        strategy = new SingleAllocatorStrategy(owner, address(goalTreasury), controller);
    }

    function test_constructor_setsGoalScopeOwnerAndAllocator() public view {
        assertEq(strategy.owner(), owner);
        assertEq(strategy.goalTreasury(), address(goalTreasury));
        assertEq(strategy.allocator(), controller);
    }

    function test_constructor_revertsOnZeroGoalTreasury() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new SingleAllocatorStrategy(owner, address(0), controller);
    }

    function test_constructor_revertsOnNonContractGoalTreasury() public {
        vm.expectRevert(
            abi.encodeWithSelector(SingleAllocatorStrategy.NOT_A_CONTRACT.selector, address(0xBEEF))
        );
        new SingleAllocatorStrategy(owner, address(0xBEEF), controller);
    }

    function test_constructor_revertsOnZeroAllocator() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new SingleAllocatorStrategy(owner, address(goalTreasury), address(0));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SingleAllocatorStrategy(address(0), address(goalTreasury), controller);
    }

    function test_allocationKey_roundTripsThroughControllerAddress() public view {
        uint256 key = strategy.allocationKey(controller, bytes(""));
        assertEq(key, AddressKeyAllocation.keyFor(controller));
        assertEq(strategy.accountForAllocationKey(key), controller);

        uint256 outsiderKey = strategy.allocationKey(outsider, abi.encode(uint256(123)));
        assertEq(outsiderKey, AddressKeyAllocation.keyFor(outsider));
        assertEq(strategy.accountForAllocationKey(outsiderKey), outsider);
    }

    function test_currentWeightAndCanAllocate_areScopedToGoalFlowAndAllocatorKey() public view {
        uint256 controllerKey = strategy.allocationKey(controller, bytes(""));
        uint256 outsiderKey = strategy.allocationKey(outsider, bytes(""));

        assertEq(strategy.currentWeight(FLOW, controllerKey), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(address(0xBEEF), controllerKey), 0);
        assertEq(strategy.currentWeight(FLOW, outsiderKey), 0);

        assertTrue(strategy.canAllocate(FLOW, controllerKey, controller));
        assertFalse(strategy.canAllocate(FLOW, controllerKey, safe));
        assertFalse(strategy.canAllocate(FLOW, outsiderKey, controller));
        assertFalse(strategy.canAllocate(address(0xBEEF), controllerKey, controller));
    }

    function test_changeAllocator_emitsOldAndNewAllocator() public {
        vm.expectEmit(address(strategy));
        emit AllocatorChanged(controller, newController);

        vm.prank(owner);
        strategy.changeAllocator(newController);

        assertEq(strategy.allocator(), newController);
    }

    function test_changeAllocator_onlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        strategy.changeAllocator(newController);
    }

    function test_changeAllocator_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        strategy.changeAllocator(address(0));
    }

    function test_transferOwnership_doesNotChangeAllocatorIdentity() public {
        vm.prank(owner);
        strategy.transferOwnership(newSafe);

        uint256 controllerKey = strategy.allocationKey(controller, bytes(""));
        uint256 safeKey = strategy.allocationKey(newSafe, bytes(""));

        assertEq(strategy.owner(), newSafe);
        assertEq(strategy.allocator(), controller);
        assertTrue(strategy.canAllocate(FLOW, controllerKey, controller));
        assertFalse(strategy.canAllocate(FLOW, safeKey, newSafe));
        assertEq(strategy.currentWeight(FLOW, controllerKey), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(FLOW, safeKey), 0);
    }
}

contract SingleAllocatorStrategyTestGoalTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}
