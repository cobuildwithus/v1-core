// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";

/// @notice Runtime helper methods extracted from CustomFlow to reduce concrete flow bytecode size.
library CustomFlowRuntimeHelpers {
    function defaultStrategyOrRevert(
        FlowTypes.AllocationState storage alloc
    ) external view returns (IAllocationStrategy strategy) {
        strategy = alloc.strategy;
        if (address(strategy) == address(0)) revert IFlow.ADDRESS_ZERO();
    }

    function allocationKeyWithEmptyAux(
        IAllocationStrategy strategy,
        address account
    ) external view returns (uint256 allocationKey) {
        allocationKey = _allocationKeyWithEmptyAux(strategy, account);
    }

    function defaultStrategyAllocationContextForAccount(
        FlowTypes.AllocationState storage alloc,
        address account
    ) external view returns (IAllocationStrategy strategy, uint256 allocationKey) {
        strategy = alloc.strategy;
        if (address(strategy) == address(0)) revert IFlow.ADDRESS_ZERO();
        allocationKey = _allocationKeyWithEmptyAux(strategy, account);
    }

    function _allocationKeyWithEmptyAux(
        IAllocationStrategy strategy,
        address account
    ) private view returns (uint256 allocationKey) {
        allocationKey = strategy.allocationKey(account, bytes(""));
    }

    function copyBytes32Calldata(bytes32[] calldata source) external pure returns (bytes32[] memory copied) {
        uint256 length = source.length;
        copied = new bytes32[](length);
        for (uint256 i = 0; i < length; ) {
            copied[i] = source[i];
            unchecked {
                ++i;
            }
        }
    }

    function copyUint32Calldata(uint32[] calldata source) external pure returns (uint32[] memory copied) {
        uint256 length = source.length;
        copied = new uint32[](length);
        for (uint256 i = 0; i < length; ) {
            copied[i] = source[i];
            unchecked {
                ++i;
            }
        }
    }
}
