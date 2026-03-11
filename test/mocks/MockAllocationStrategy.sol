// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";

contract MockAllocationStrategy is IAllocationStrategy {
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => mapping(address => bool)) public keyCanAllocate;
    mapping(address => bool) public accountCanAllocate;

    bool public useAuxAsKey = true;
    address public requiredFlow;
    address public stakeVault;
    string public constant KEY = "MockStrategy";

    function setUseAuxAsKey(bool v) external {
        useAuxAsKey = v;
    }

    function setWeight(uint256 key, uint256 weight) external {
        weights[key] = weight;
    }

    function setCanAllocate(uint256 key, address caller, bool allowed) external {
        keyCanAllocate[key][caller] = allowed;
    }

    function setCanAccountAllocate(address caller, bool allowed) external {
        accountCanAllocate[caller] = allowed;
    }

    function setStakeVault(address stakeVault_) external {
        stakeVault = stakeVault_;
    }

    function setRequiredFlow(address requiredFlow_) external {
        requiredFlow = requiredFlow_;
    }

    function allocationKey(address caller, bytes calldata aux) external view returns (uint256) {
        if (useAuxAsKey) {
            if (aux.length == 0) return uint256(uint160(caller));
            return abi.decode(aux, (uint256));
        }
        return uint256(keccak256(abi.encode(caller, aux)));
    }

    function accountForAllocationKey(uint256 key) external pure returns (address) {
        return address(uint160(key));
    }

    function currentWeight(address flow, uint256 key) external view returns (uint256) {
        if (requiredFlow != address(0) && flow != requiredFlow) return 0;
        return weights[key];
    }

    function canAllocate(address flow, uint256 key, address caller) external view returns (bool) {
        if (requiredFlow != address(0) && flow != requiredFlow) return false;
        return keyCanAllocate[key][caller] || accountCanAllocate[caller];
    }

    function strategyKey() external pure returns (string memory) {
        return KEY;
    }
}
