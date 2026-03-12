// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ScopedSingleAllocatorStrategyBase } from "./ScopedSingleAllocatorStrategyBase.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

/// @notice Budget-flow strategy that grants one allocator authority over a specific budget treasury flow.
contract BudgetSingleAllocatorStrategy is ScopedSingleAllocatorStrategyBase {
    IBudgetTreasury private _budgetTreasury;

    string public constant STRATEGY_KEY = "BudgetSingleAllocator";

    constructor(address budgetTreasury_, address allocator_) {
        if (_isImplementationConstructorSentinel(budgetTreasury_, allocator_)) return;
        _initializeBudgetSingleAllocator(budgetTreasury_, allocator_);
    }

    function initialize(address budgetTreasury_, address allocator_) external initializer {
        _initializeBudgetSingleAllocator(budgetTreasury_, allocator_);
    }

    function budgetTreasury() public view returns (address) {
        return address(_budgetTreasury);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _initializeBudgetSingleAllocator(address budgetTreasury_, address allocator_) private {
        _requireContract(budgetTreasury_);
        _budgetTreasury = IBudgetTreasury(budgetTreasury_);
        _initializeAllocator(allocator_);
    }

    function _scopedFlow() internal view override returns (address) {
        return _budgetTreasury.flow();
    }
}
