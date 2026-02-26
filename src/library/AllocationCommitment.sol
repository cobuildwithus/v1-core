// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IFlow } from "../interfaces/IFlow.sol";

library AllocationCommitment {
    function hashMemory(
        bytes32[] memory recipientIds,
        uint32[] memory allocationScaled
    ) internal pure returns (bytes32) {
        if (recipientIds.length != allocationScaled.length) revert IFlow.ARRAY_LENGTH_MISMATCH();
        return keccak256(abi.encode(recipientIds, allocationScaled));
    }
}
