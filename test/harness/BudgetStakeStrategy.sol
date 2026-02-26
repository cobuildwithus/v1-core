// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { AddressKeyAllocationStrategy } from "src/allocation-strategies/AddressKeyAllocationStrategy.sol";

contract BudgetStakeStrategy is AddressKeyAllocationStrategy {
    IBudgetStakeLedger public immutable budgetStakeLedger;
    bytes32 public immutable recipientId;

    string public constant STRATEGY_KEY = "BudgetStake";

    constructor(IBudgetStakeLedger budgetStakeLedger_, bytes32 recipientId_) {
        if (address(budgetStakeLedger_) == address(0)) revert ADDRESS_ZERO();
        budgetStakeLedger = budgetStakeLedger_;
        recipientId = recipientId_;
    }

    function currentWeight(uint256 key) external view override returns (uint256) {
        (address effectiveBudgetTreasury, bool closed) = _effectiveTreasuryAndClosed();
        if (closed) return 0;
        return budgetStakeLedger.userAllocatedStakeOnBudget(_accountForKey(key), effectiveBudgetTreasury);
    }

    function canAllocate(uint256 key, address caller) external view override returns (bool) {
        (address effectiveBudgetTreasury, bool closed) = _effectiveTreasuryAndClosed();
        if (closed) return false;
        address allocator = _accountForKey(key);
        if (caller != allocator) return false;
        return budgetStakeLedger.userAllocatedStakeOnBudget(allocator, effectiveBudgetTreasury) > 0;
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        (address effectiveBudgetTreasury, bool closed) = _effectiveTreasuryAndClosed();
        if (closed) return false;
        return budgetStakeLedger.userAllocatedStakeOnBudget(account, effectiveBudgetTreasury) > 0;
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        (address effectiveBudgetTreasury, bool closed) = _effectiveTreasuryAndClosed();
        if (closed) return 0;
        return budgetStakeLedger.userAllocatedStakeOnBudget(account, effectiveBudgetTreasury);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _effectiveTreasuryAndClosed() internal view returns (address effectiveBudgetTreasury, bool closed) {
        effectiveBudgetTreasury = budgetStakeLedger.budgetForRecipient(recipientId);
        if (effectiveBudgetTreasury == address(0)) return (effectiveBudgetTreasury, true);
        if (effectiveBudgetTreasury.code.length == 0) return (effectiveBudgetTreasury, true);

        try IBudgetTreasury(effectiveBudgetTreasury).resolved() returns (bool resolved_) {
            return (effectiveBudgetTreasury, resolved_);
        } catch {
            return (effectiveBudgetTreasury, true);
        }
    }
}
