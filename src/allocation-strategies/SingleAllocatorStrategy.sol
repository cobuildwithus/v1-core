// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";

contract SingleAllocatorStrategy is IAllocationStrategy, Ownable {
    address public allocator;

    // Fixed virtual weight for the single allocator account.
    uint256 public constant VIRTUAL_WEIGHT = FlowProtocolConstants.SINGLE_ALLOCATOR_VIRTUAL_WEIGHT;

    // Strategy JSON key exposed to front-end helpers (unquoted).
    string public constant STRATEGY_KEY = "SingleAllocator";

    event AllocatorChanged(address indexed oldAllocator, address indexed newAllocator);

    constructor(address _initialOwner, address _allocator) Ownable(_initialOwner) {
        if (_allocator == address(0)) revert ADDRESS_ZERO();
        allocator = _allocator;
        emit AllocatorChanged(address(0), _allocator);
    }

    function allocationKey(address, bytes calldata) external pure override returns (uint256) {
        return 0; // one fixed allocation key for all allocations
    }

    function currentWeight(uint256) external view override returns (uint256) {
        return VIRTUAL_WEIGHT;
    }

    function canAllocate(uint256, address caller) external view override returns (bool) {
        return caller == allocator;
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        return account == allocator;
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        return account == allocator ? VIRTUAL_WEIGHT : 0;
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    /// Optional: owner can hand the baton to a new allocator.
    function setAllocator(address newAllocator) external onlyOwner {
        if (newAllocator == address(0)) revert ADDRESS_ZERO();
        address oldAllocator = allocator;
        allocator = newAllocator;
        emit AllocatorChanged(oldAllocator, newAllocator);
    }
}
