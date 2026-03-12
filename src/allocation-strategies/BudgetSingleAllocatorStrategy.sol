// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

/// @notice Budget-flow strategy that grants one allocator authority over a specific budget treasury flow.
contract BudgetSingleAllocatorStrategy is AddressKeyAllocationStrategy {
    error NOT_A_CONTRACT(address account);

    address public immutable budgetTreasury;
    address public immutable allocator;

    uint256 public constant VIRTUAL_WEIGHT = 1e24;
    string public constant STRATEGY_KEY = "BudgetSingleAllocator";

    event AllocatorChanged(address indexed oldAllocator, address indexed newAllocator);

    constructor(address budgetTreasury_, address allocator_) {
        if (budgetTreasury_ == address(0)) revert IAllocationStrategy.ADDRESS_ZERO();
        if (budgetTreasury_.code.length == 0) revert NOT_A_CONTRACT(budgetTreasury_);
        if (allocator_ == address(0)) revert IAllocationStrategy.ADDRESS_ZERO();

        budgetTreasury = budgetTreasury_;
        allocator = allocator_;

        emit AllocatorChanged(address(0), allocator_);
    }

    function currentWeight(address flow, uint256 key) external view override returns (uint256) {
        if (!_usesAllocatorKey(flow, key)) return 0;
        return VIRTUAL_WEIGHT;
    }

    function canAllocate(address flow, uint256 key, address caller) external view override returns (bool) {
        return caller == allocator && _usesAllocatorKey(flow, key);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _usesAllocatorKey(address flow, uint256 key) internal view returns (bool) {
        return key == uint256(uint160(allocator)) && flow == IBudgetTreasury(budgetTreasury).flow();
    }
}
