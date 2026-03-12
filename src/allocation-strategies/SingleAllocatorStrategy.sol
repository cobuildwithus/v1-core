// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";
import { IGoalScopedAllocationStrategy } from "../interfaces/IGoalScopedAllocationStrategy.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";

/// @notice Goal-scoped strategy that admits one controller-contract allocator with a virtual managed weight.
contract SingleAllocatorStrategy is AddressKeyAllocationStrategy, IGoalScopedAllocationStrategy, Initializable {
    error NOT_A_CONTRACT(address account);

    address public override goalTreasury;
    address public allocator;

    uint256 public constant VIRTUAL_WEIGHT = 1e24;
    string public constant STRATEGY_KEY = "SingleAllocator";

    event AllocatorInitialized(address indexed allocator);

    constructor(address goalTreasury_, address allocator_) {
        if (goalTreasury_ == address(0) && allocator_ == address(0)) {
            _disableInitializers();
            return;
        }

        _initialize(goalTreasury_, allocator_);
        _disableInitializers();
    }

    function initialize(address goalTreasury_, address allocator_) external initializer {
        _initialize(goalTreasury_, allocator_);
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

    function _initialize(address goalTreasury_, address allocator_) private {
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (goalTreasury_.code.length == 0) revert NOT_A_CONTRACT(goalTreasury_);
        if (allocator_ == address(0)) revert ADDRESS_ZERO();
        if (allocator_.code.length == 0) revert NOT_A_CONTRACT(allocator_);

        goalTreasury = goalTreasury_;
        allocator = allocator_;

        emit AllocatorInitialized(allocator_);
    }

    function _usesAllocatorKey(address flow, uint256 key) internal view returns (bool) {
        return key == _allocationKeyForAllocator() && flow == IGoalTreasury(goalTreasury).flow();
    }

    function _allocationKeyForAllocator() internal view returns (uint256) {
        return uint256(uint160(allocator));
    }
}
