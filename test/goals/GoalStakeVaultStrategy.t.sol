// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalStakeVaultStrategy } from "src/allocation-strategies/GoalStakeVaultStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IGoalStakeVault } from "src/interfaces/IGoalStakeVault.sol";

contract GoalStakeVaultStrategyTest is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    StrategyMockStakeVault internal vault;
    GoalStakeVaultStrategy internal strategy;

    function setUp() public {
        vault = new StrategyMockStakeVault();
        strategy = new GoalStakeVaultStrategy(IGoalStakeVault(address(vault)));
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new GoalStakeVaultStrategy(IGoalStakeVault(address(0)));
    }

    function test_allocationKey_usesCallerAddress() public view {
        assertEq(strategy.allocationKey(alice, ""), uint256(uint160(alice)));
        assertEq(strategy.allocationKey(bob, abi.encode(uint256(123))), uint256(uint160(bob)));
    }

    function test_strategyKey_constant() public view {
        assertEq(strategy.strategyKey(), "GoalStakeVault");
    }

    function test_weightQueries_followVaultState() public {
        vault.setWeight(alice, 10e18);
        vault.setWeight(bob, 3e18);

        uint256 aliceKey = uint256(uint160(alice));
        uint256 bobKey = uint256(uint160(bob));

        assertEq(strategy.currentWeight(aliceKey), 10e18);
        assertEq(strategy.currentWeight(bobKey), 3e18);
        assertEq(strategy.accountAllocationWeight(alice), 10e18);
        assertEq(strategy.accountAllocationWeight(bob), 3e18);
        assertTrue(strategy.canAccountAllocate(alice));
        assertTrue(strategy.canAccountAllocate(bob));
        assertFalse(strategy.canAccountAllocate(address(0xCAFE)));
    }

    function test_canAllocate_requiresMatchingCallerAndWeight() public {
        uint256 aliceKey = uint256(uint160(alice));
        uint256 bobKey = uint256(uint160(bob));

        vault.setWeight(alice, 1e18);

        assertTrue(strategy.canAllocate(aliceKey, alice));
        assertFalse(strategy.canAllocate(aliceKey, bob));
        assertFalse(strategy.canAllocate(bobKey, bob));
    }

    function test_liveWeightUpdates_areReflected() public {
        uint256 aliceKey = uint256(uint160(alice));

        vault.setWeight(alice, 2e18);
        assertEq(strategy.currentWeight(aliceKey), 2e18);

        vault.setWeight(alice, 9e18);
        assertEq(strategy.currentWeight(aliceKey), 9e18);
        assertEq(strategy.accountAllocationWeight(alice), 9e18);
    }

    function test_whenResolved_allocationDisabledAndWeightZero() public {
        uint256 aliceKey = uint256(uint160(alice));
        vault.setWeight(alice, 7e18);

        assertTrue(strategy.canAllocate(aliceKey, alice));
        assertTrue(strategy.canAccountAllocate(alice));
        assertEq(strategy.currentWeight(aliceKey), 7e18);

        vault.setResolved(true);

        assertFalse(strategy.canAllocate(aliceKey, alice));
        assertFalse(strategy.canAccountAllocate(alice));
        assertEq(strategy.currentWeight(aliceKey), 0);
        assertEq(strategy.accountAllocationWeight(alice), 0);
    }
}

contract StrategyMockStakeVault {
    mapping(address => uint256) private _weightOf;
    bool public goalResolved;

    function setWeight(address account, uint256 weight) external {
        _weightOf[account] = weight;
    }

    function setResolved(bool resolved_) external {
        goalResolved = resolved_;
    }

    function weightOf(address account) external view returns (uint256) {
        return _weightOf[account];
    }
}
