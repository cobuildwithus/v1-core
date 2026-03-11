// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {AddressKeyAllocation} from "src/library/AddressKeyAllocation.sol";

contract BudgetSingleAllocatorStrategyTest is Test {
    address internal constant FLOW = address(0xF10);

    event AllocatorChanged(address indexed oldAllocator, address indexed newAllocator);

    address internal owner = makeAddr("owner");
    address internal allocator = makeAddr("allocator");
    address internal newAllocator = makeAddr("new-allocator");
    address internal outsider = makeAddr("outsider");

    BudgetSingleAllocatorStrategy internal strategy;
    BudgetSingleAllocatorStrategyTestBudgetTreasury internal budgetTreasury;

    function setUp() public {
        budgetTreasury = new BudgetSingleAllocatorStrategyTestBudgetTreasury(FLOW);
        strategy = new BudgetSingleAllocatorStrategy(owner, address(budgetTreasury), allocator);
    }

    function test_constructor_setsBudgetScopeOwnerAndAllocator() public view {
        assertEq(strategy.owner(), owner);
        assertEq(strategy.budgetTreasury(), address(budgetTreasury));
        assertEq(strategy.allocator(), allocator);
    }

    function test_constructor_revertsOnZeroBudgetTreasury() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new BudgetSingleAllocatorStrategy(owner, address(0), allocator);
    }

    function test_constructor_revertsOnNonContractBudgetTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(BudgetSingleAllocatorStrategy.NOT_A_CONTRACT.selector, address(0xBEEF)));
        new BudgetSingleAllocatorStrategy(owner, address(0xBEEF), allocator);
    }

    function test_constructor_revertsOnZeroAllocator() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new BudgetSingleAllocatorStrategy(owner, address(budgetTreasury), address(0));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BudgetSingleAllocatorStrategy(address(0), address(budgetTreasury), allocator);
    }

    function test_allocationKey_roundTripsThroughAllocatorAddress() public view {
        uint256 key = strategy.allocationKey(allocator, bytes(""));
        assertEq(key, AddressKeyAllocation.keyFor(allocator));
        assertEq(strategy.accountForAllocationKey(key), allocator);
    }

    function test_currentWeightAndCanAllocate_areScopedToBudgetFlowAndAllocatorKey() public view {
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));
        uint256 outsiderKey = strategy.allocationKey(outsider, bytes(""));

        assertEq(strategy.currentWeight(FLOW, allocatorKey), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(address(0xBEEF), allocatorKey), 0);
        assertEq(strategy.currentWeight(FLOW, outsiderKey), 0);

        assertTrue(strategy.canAllocate(FLOW, allocatorKey, allocator));
        assertFalse(strategy.canAllocate(FLOW, allocatorKey, outsider));
        assertFalse(strategy.canAllocate(FLOW, outsiderKey, allocator));
        assertFalse(strategy.canAllocate(address(0xBEEF), allocatorKey, allocator));
    }

    function test_changeAllocator_emitsOldAndNewAllocatorAndUpdatesScope() public {
        uint256 oldKey = strategy.allocationKey(allocator, bytes(""));
        uint256 newKey = strategy.allocationKey(newAllocator, bytes(""));

        vm.expectEmit(address(strategy));
        emit AllocatorChanged(allocator, newAllocator);

        vm.prank(owner);
        strategy.changeAllocator(newAllocator);

        assertEq(strategy.allocator(), newAllocator);
        assertEq(strategy.currentWeight(FLOW, oldKey), 0);
        assertEq(strategy.currentWeight(FLOW, newKey), strategy.VIRTUAL_WEIGHT());
        assertFalse(strategy.canAllocate(FLOW, oldKey, allocator));
        assertTrue(strategy.canAllocate(FLOW, newKey, newAllocator));
    }

    function test_changeAllocator_onlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        strategy.changeAllocator(newAllocator);
    }

    function test_changeAllocator_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        strategy.changeAllocator(address(0));
    }

    function test_transferOwnership_doesNotChangeAllocatorIdentity() public {
        vm.prank(owner);
        strategy.transferOwnership(outsider);

        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));
        uint256 outsiderKey = strategy.allocationKey(outsider, bytes(""));

        assertEq(strategy.owner(), outsider);
        assertEq(strategy.allocator(), allocator);
        assertTrue(strategy.canAllocate(FLOW, allocatorKey, allocator));
        assertFalse(strategy.canAllocate(FLOW, outsiderKey, outsider));
        assertEq(strategy.currentWeight(FLOW, allocatorKey), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(FLOW, outsiderKey), 0);
    }
}

contract BudgetSingleAllocatorStrategyTestBudgetTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}
