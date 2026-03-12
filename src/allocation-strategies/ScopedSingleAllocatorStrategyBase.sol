// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";

abstract contract ScopedSingleAllocatorStrategyBase is AddressKeyAllocationStrategy, Initializable {
    error NOT_A_CONTRACT(address account);

    uint256 public constant VIRTUAL_WEIGHT = 1e24;

    address public allocator;

    event AllocatorInitialized(address indexed allocator);

    constructor() {
        _disableInitializers();
    }

    function currentWeight(address flow, uint256 key) external view override returns (uint256) {
        return _usesAllocatorKey(flow, key) ? VIRTUAL_WEIGHT : 0;
    }

    function canAllocate(address flow, uint256 key, address caller) external view override returns (bool) {
        return caller == allocator && _usesAllocatorKey(flow, key);
    }

    function _requireContract(address account) internal view {
        if (account == address(0)) revert ADDRESS_ZERO();
        if (account.code.length == 0) revert NOT_A_CONTRACT(account);
    }

    function _initializeAllocator(address allocator_) internal {
        _requireContract(allocator_);
        allocator = allocator_;
        emit AllocatorInitialized(allocator_);
    }

    function _isImplementationConstructorSentinel(address scoped_, address allocator_) internal pure returns (bool) {
        return scoped_ == address(0) && allocator_ == address(0);
    }

    function _usesAllocatorKey(address flow, uint256 key) internal view returns (bool) {
        return key == uint256(uint160(allocator)) && flow == _scopedFlow();
    }

    function _scopedFlow() internal view virtual returns (address);
}
