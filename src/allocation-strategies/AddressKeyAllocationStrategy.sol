// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IAllocationKeyAccountResolver } from "../interfaces/IAllocationKeyAccountResolver.sol";

abstract contract AddressKeyAllocationStrategy is IAllocationStrategy, IAllocationKeyAccountResolver {
    function allocationKey(address caller, bytes calldata) external pure virtual override returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256 key) external pure virtual override returns (address) {
        return _accountForKey(key);
    }

    function _accountForKey(uint256 key) internal pure returns (address) {
        return address(uint160(key));
    }
}
