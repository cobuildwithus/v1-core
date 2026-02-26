// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface IAllocationKeyAccountResolver {
    function accountForAllocationKey(uint256 allocationKey) external view returns (address);
}
