// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Budget-flow strategy that grants one allocator authority over a specific budget treasury flow.
contract BudgetSingleAllocatorStrategy is AddressKeyAllocationStrategy, Initializable {
    error NOT_A_CONTRACT(address account);

    address public budgetTreasury;
    address public allocator;

    uint256 public constant VIRTUAL_WEIGHT = 1e24;
    string public constant STRATEGY_KEY = "BudgetSingleAllocator";

    event AllocatorInitialized(address indexed allocator);

    constructor(address budgetTreasury_, address allocator_) {
        _disableInitializers();

        if (budgetTreasury_ == address(0) && allocator_ == address(0)) return;
        _initialize(budgetTreasury_, allocator_);
    }

    function initialize(address budgetTreasury_, address allocator_) external initializer {
        _initialize(budgetTreasury_, allocator_);
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
        return key == _allocationKeyForAllocator() && flow == IBudgetTreasury(budgetTreasury).flow();
    }

    function _allocationKeyForAllocator() internal view returns (uint256) {
        return uint256(uint160(allocator));
    }

    function _initialize(address budgetTreasury_, address allocator_) internal {
        if (budgetTreasury_ == address(0)) revert IAllocationStrategy.ADDRESS_ZERO();
        if (budgetTreasury_.code.length == 0) revert NOT_A_CONTRACT(budgetTreasury_);
        if (allocator_ == address(0)) revert IAllocationStrategy.ADDRESS_ZERO();
        if (allocator_.code.length == 0) revert NOT_A_CONTRACT(allocator_);

        budgetTreasury = budgetTreasury_;
        allocator = allocator_;

        emit AllocatorInitialized(allocator_);
    }
}
