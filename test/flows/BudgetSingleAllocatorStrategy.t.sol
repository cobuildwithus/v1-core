// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {ScopedSingleAllocatorStrategyBase} from "src/allocation-strategies/ScopedSingleAllocatorStrategyBase.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {AddressKeyAllocation} from "src/library/AddressKeyAllocation.sol";

contract BudgetSingleAllocatorStrategyTest is Test {
    address internal constant FLOW = address(0xF10);

    address internal allocator = address(new BudgetSingleAllocatorStrategyTestAllocator());
    address internal outsider = makeAddr("outsider");

    BudgetSingleAllocatorStrategy internal strategy;
    BudgetSingleAllocatorStrategyTestBudgetTreasury internal budgetTreasury;

    function setUp() public {
        budgetTreasury = new BudgetSingleAllocatorStrategyTestBudgetTreasury(FLOW);
        strategy = new BudgetSingleAllocatorStrategy(address(budgetTreasury), allocator);
    }

    function test_constructor_setsBudgetScopeAndAllocator() public view {
        assertEq(strategy.budgetTreasury(), address(budgetTreasury));
        assertEq(strategy.allocator(), allocator);
    }

    function test_implementationDeployment_allowsZeroZeroAndCloneInitialization() public {
        BudgetSingleAllocatorStrategy implementation = new BudgetSingleAllocatorStrategy(address(0), address(0));
        BudgetSingleAllocatorStrategy clone = BudgetSingleAllocatorStrategy(Clones.clone(address(implementation)));

        clone.initialize(address(budgetTreasury), allocator);

        assertEq(clone.budgetTreasury(), address(budgetTreasury));
        assertEq(clone.allocator(), allocator);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(budgetTreasury), allocator);
    }

    function test_constructor_revertsOnZeroBudgetTreasury() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new BudgetSingleAllocatorStrategy(address(0), allocator);
    }

    function test_constructor_revertsOnNonContractBudgetTreasury() public {
        vm.expectRevert(
            abi.encodeWithSelector(ScopedSingleAllocatorStrategyBase.NOT_A_CONTRACT.selector, address(0xBEEF))
        );
        new BudgetSingleAllocatorStrategy(address(0xBEEF), allocator);
    }

    function test_constructor_revertsOnZeroAllocator() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new BudgetSingleAllocatorStrategy(address(budgetTreasury), address(0));
    }

    function test_constructor_revertsOnNonContractAllocator() public {
        address eoaAllocator = makeAddr("eoa-allocator");

        vm.expectRevert(
            abi.encodeWithSelector(ScopedSingleAllocatorStrategyBase.NOT_A_CONTRACT.selector, eoaAllocator)
        );
        new BudgetSingleAllocatorStrategy(address(budgetTreasury), eoaAllocator);
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

    function test_legacyOwnableAndAllocatorMutationSurface_isAbsent() public view {
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));
        uint256 outsiderKey = strategy.allocationKey(outsider, bytes(""));

        assertEq(strategy.allocator(), allocator);
        assertTrue(strategy.canAllocate(FLOW, allocatorKey, allocator));
        assertFalse(strategy.canAllocate(FLOW, outsiderKey, outsider));
        assertEq(strategy.currentWeight(FLOW, allocatorKey), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(FLOW, outsiderKey), 0);
        _assertSelectorAbsent(address(strategy), abi.encodeWithSignature("changeAllocator(address)", outsider));
        _assertSelectorAbsent(address(strategy), abi.encodeWithSignature("owner()"));
        _assertSelectorAbsent(address(strategy), abi.encodeWithSignature("transferOwnership(address)", outsider));
    }

    function _assertSelectorAbsent(address target, bytes memory callData) internal view {
        (bool success, bytes memory returnData) = target.staticcall(callData);
        assertFalse(success);
        assertEq(returnData.length, 0);
    }
}

contract BudgetSingleAllocatorStrategyTestBudgetTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract BudgetSingleAllocatorStrategyTestAllocator {}
