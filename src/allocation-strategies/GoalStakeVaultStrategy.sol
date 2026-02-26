// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalStakeVault } from "../interfaces/IGoalStakeVault.sol";
import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";

contract GoalStakeVaultStrategy is AddressKeyAllocationStrategy {
    IGoalStakeVault public immutable stakeVault;

    string public constant STRATEGY_KEY = "GoalStakeVault";

    constructor(IGoalStakeVault stakeVault_) {
        if (address(stakeVault_) == address(0)) revert ADDRESS_ZERO();
        stakeVault = stakeVault_;
    }

    function currentWeight(uint256 key) external view override returns (uint256) {
        if (stakeVault.goalResolved()) return 0;
        return stakeVault.weightOf(_accountForKey(key));
    }

    function canAllocate(uint256 key, address caller) external view override returns (bool) {
        if (stakeVault.goalResolved()) return false;
        address allocator = _accountForKey(key);
        return caller == allocator && stakeVault.weightOf(allocator) > 0;
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        if (stakeVault.goalResolved()) return false;
        return stakeVault.weightOf(account) > 0;
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        if (stakeVault.goalResolved()) return 0;
        return stakeVault.weightOf(account);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }
}
