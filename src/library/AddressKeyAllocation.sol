// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library AddressKeyAllocation {
    error INVALID_ALLOCATION_KEY(uint256 key);

    function keyFor(address account) internal pure returns (uint256) {
        return uint256(uint160(account));
    }

    function accountForKey(uint256 key) internal pure returns (address) {
        if (key > type(uint160).max) revert INVALID_ALLOCATION_KEY(key);
        return address(SafeCast.toUint160(key));
    }
}
