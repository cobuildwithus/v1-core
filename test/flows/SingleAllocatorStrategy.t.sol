// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { SingleAllocatorStrategy } from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";

contract SingleAllocatorStrategyTest is Test {
    address internal owner = address(0xA11CE);
    address internal allocator = address(0xB0B);
    address internal attacker = address(0xBAD);
    address internal newAllocator = address(0xCAFE);

    SingleAllocatorStrategy internal strategy;

    function setUp() public {
        strategy = new SingleAllocatorStrategy(owner, allocator);
    }

    function test_constructor_setsState() public view {
        assertEq(strategy.allocator(), allocator);
        assertEq(strategy.owner(), owner);
    }

    function test_constructor_revertZeroAllocator() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new SingleAllocatorStrategy(owner, address(0));
    }

    function test_constructor_revertZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SingleAllocatorStrategy(address(0), allocator);
    }

    function test_allocationKey_alwaysZero() public view {
        assertEq(strategy.allocationKey(address(0x1), ""), 0);
        assertEq(strategy.allocationKey(address(0x2), abi.encode(uint256(123))), 0);
    }

    function test_currentWeight_virtualWeight() public view {
        assertEq(strategy.currentWeight(0), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.currentWeight(type(uint256).max), strategy.VIRTUAL_WEIGHT());
    }

    function test_canAllocate_and_canAccountAllocate() public view {
        assertTrue(strategy.canAllocate(0, allocator));
        assertFalse(strategy.canAllocate(0, attacker));
        assertTrue(strategy.canAccountAllocate(allocator));
        assertFalse(strategy.canAccountAllocate(attacker));
    }

    function test_accountAllocationWeight() public view {
        assertEq(strategy.accountAllocationWeight(allocator), strategy.VIRTUAL_WEIGHT());
        assertEq(strategy.accountAllocationWeight(attacker), 0);
    }

    function test_strategyKey() public view {
        assertEq(strategy.strategyKey(), "SingleAllocator");
    }

    function test_setAllocator_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        strategy.setAllocator(newAllocator);

        vm.prank(owner);
        strategy.setAllocator(newAllocator);

        assertEq(strategy.allocator(), newAllocator);
        assertFalse(strategy.canAllocate(0, allocator));
        assertTrue(strategy.canAllocate(0, newAllocator));
        assertFalse(strategy.canAccountAllocate(allocator));
        assertTrue(strategy.canAccountAllocate(newAllocator));
        assertEq(strategy.accountAllocationWeight(allocator), 0);
        assertEq(strategy.accountAllocationWeight(newAllocator), strategy.VIRTUAL_WEIGHT());
    }

    function test_setAllocator_revertZero() public {
        vm.prank(owner);
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        strategy.setAllocator(address(0));
    }
}
