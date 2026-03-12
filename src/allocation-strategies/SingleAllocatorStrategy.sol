// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ScopedSingleAllocatorStrategyBase } from "./ScopedSingleAllocatorStrategyBase.sol";
import { IGoalScopedAllocationStrategy } from "../interfaces/IGoalScopedAllocationStrategy.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";

/// @notice Goal-scoped strategy that admits one controller-contract allocator with a virtual managed weight.
contract SingleAllocatorStrategy is ScopedSingleAllocatorStrategyBase, IGoalScopedAllocationStrategy {
    IGoalTreasury private _goalTreasury;

    string public constant STRATEGY_KEY = "SingleAllocator";

    constructor(address goalTreasury_, address allocator_) {
        if (_isImplementationConstructorSentinel(goalTreasury_, allocator_)) return;
        _initializeSingleAllocator(goalTreasury_, allocator_);
    }

    function initialize(address goalTreasury_, address allocator_) external initializer {
        _initializeSingleAllocator(goalTreasury_, allocator_);
    }

    function goalTreasury() public view override returns (address) {
        return address(_goalTreasury);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _initializeSingleAllocator(address goalTreasury_, address allocator_) private {
        _requireContract(goalTreasury_);
        _goalTreasury = IGoalTreasury(goalTreasury_);
        _initializeAllocator(allocator_);
    }

    function _scopedFlow() internal view override returns (address) {
        return _goalTreasury.flow();
    }
}
