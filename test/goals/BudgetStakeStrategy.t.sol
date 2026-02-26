// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeStrategy } from "src/allocation-strategies/BudgetStakeStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";

contract BudgetStakeStrategyTest is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    bytes32 internal recipientId = bytes32(uint256(42));

    BudgetStakeMockLedger internal ledger;
    BudgetStakeMockTreasury internal treasury;
    BudgetStakeStrategy internal strategy;

    function setUp() public {
        ledger = new BudgetStakeMockLedger();
        treasury = new BudgetStakeMockTreasury();
        ledger.setBudget(recipientId, address(treasury));
        strategy = new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), recipientId);
    }

    function test_constructor_revertsOnZeroLedger() public {
        vm.expectRevert(IAllocationStrategy.ADDRESS_ZERO.selector);
        new BudgetStakeStrategy(IBudgetStakeLedger(address(0)), recipientId);
    }

    function test_allocationKey_usesCallerAddress() public view {
        assertEq(strategy.allocationKey(alice, ""), uint256(uint160(alice)));
        assertEq(strategy.allocationKey(bob, abi.encode(uint256(7))), uint256(uint160(bob)));
    }

    function test_strategyKey_constant() public view {
        assertEq(strategy.strategyKey(), "BudgetStake");
    }

    function test_weightQueries_followLedgerStake() public {
        ledger.setAllocatedStake(alice, address(treasury), 25e18);
        ledger.setAllocatedStake(bob, address(treasury), 5e18);

        uint256 aliceKey = uint256(uint160(alice));
        uint256 bobKey = uint256(uint160(bob));

        assertEq(strategy.currentWeight(aliceKey), 25e18);
        assertEq(strategy.currentWeight(bobKey), 5e18);
        assertEq(strategy.accountAllocationWeight(alice), 25e18);
        assertEq(strategy.accountAllocationWeight(bob), 5e18);
        assertTrue(strategy.canAccountAllocate(alice));
        assertTrue(strategy.canAccountAllocate(bob));
        assertFalse(strategy.canAccountAllocate(address(0xCAFE)));
    }

    function test_canAllocate_requiresMatchingCallerAndWeight() public {
        uint256 aliceKey = uint256(uint160(alice));
        uint256 bobKey = uint256(uint160(bob));
        ledger.setAllocatedStake(alice, address(treasury), 1e18);

        assertTrue(strategy.canAllocate(aliceKey, alice));
        assertFalse(strategy.canAllocate(aliceKey, bob));
        assertFalse(strategy.canAllocate(bobKey, bob));
    }

    function test_whenBudgetResolved_allocationDisabledAndWeightZero() public {
        uint256 aliceKey = uint256(uint160(alice));
        ledger.setAllocatedStake(alice, address(treasury), 7e18);

        assertTrue(strategy.canAllocate(aliceKey, alice));
        assertTrue(strategy.canAccountAllocate(alice));
        assertEq(strategy.currentWeight(aliceKey), 7e18);

        treasury.setResolved(true);

        assertFalse(strategy.canAllocate(aliceKey, alice));
        assertFalse(strategy.canAccountAllocate(alice));
        assertEq(strategy.currentWeight(aliceKey), 0);
        assertEq(strategy.accountAllocationWeight(alice), 0);
    }

    function test_whenRecipientHasNoBudget_strategyFailsClosed() public {
        bytes32 unregisteredRecipient = bytes32(uint256(99));
        BudgetStakeStrategy unregisteredStrategy =
            new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), unregisteredRecipient);

        uint256 aliceKey = uint256(uint160(alice));
        ledger.setAllocatedStake(alice, address(treasury), 3e18);

        assertEq(unregisteredStrategy.currentWeight(aliceKey), 0);
        assertEq(unregisteredStrategy.accountAllocationWeight(alice), 0);
        assertFalse(unregisteredStrategy.canAllocate(aliceKey, alice));
        assertFalse(unregisteredStrategy.canAccountAllocate(alice));
    }

    function test_whenMappedBudgetHasNoCode_strategyFailsClosed() public {
        address undeployedTreasury = address(0xBEEF);
        ledger.setBudget(recipientId, undeployedTreasury);
        ledger.setAllocatedStake(alice, undeployedTreasury, 3e18);

        uint256 aliceKey = uint256(uint160(alice));
        assertEq(strategy.currentWeight(aliceKey), 0);
        assertEq(strategy.accountAllocationWeight(alice), 0);
        assertFalse(strategy.canAllocate(aliceKey, alice));
        assertFalse(strategy.canAccountAllocate(alice));
    }

    function test_whenMappedBudgetResolvedCallReverts_strategyFailsClosed() public {
        BudgetStakeMockTreasuryReverting revertingTreasury = new BudgetStakeMockTreasuryReverting();
        ledger.setBudget(recipientId, address(revertingTreasury));
        ledger.setAllocatedStake(alice, address(revertingTreasury), 3e18);

        uint256 aliceKey = uint256(uint160(alice));
        assertEq(strategy.currentWeight(aliceKey), 0);
        assertEq(strategy.accountAllocationWeight(alice), 0);
        assertFalse(strategy.canAllocate(aliceKey, alice));
        assertFalse(strategy.canAccountAllocate(alice));
    }
}

contract BudgetStakeMockLedger {
    mapping(bytes32 => address) internal _budgetByRecipient;
    mapping(address => mapping(address => uint256)) internal _allocatedStake;

    function setBudget(bytes32 recipientId, address budget) external {
        _budgetByRecipient[recipientId] = budget;
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetByRecipient[recipientId];
    }

    function setAllocatedStake(address account, address budget, uint256 amount) external {
        _allocatedStake[account][budget] = amount;
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256) {
        return _allocatedStake[account][budget];
    }
}

contract BudgetStakeMockTreasury {
    bool public resolved;

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}

contract BudgetStakeMockTreasuryReverting {
    error RESOLVED_REVERT();

    function resolved() external pure returns (bool) {
        revert RESOLVED_REVERT();
    }
}
