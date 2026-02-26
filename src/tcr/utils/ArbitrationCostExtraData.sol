// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Helpers for encoding arbitration cost into extraData.
library ArbitrationCostExtraData {
    bytes4 internal constant PREFIX = bytes4(keccak256("ERC20VotesArbitrator.cost"));
    uint256 internal constant HEADER_LENGTH = 36;

    function encode(uint256 cost, bytes memory baseExtraData) internal pure returns (bytes memory) {
        return bytes.concat(PREFIX, bytes32(cost), baseExtraData);
    }

    function decodeCost(bytes calldata extraData) internal pure returns (bool hasSnapshot, uint256 cost) {
        if (extraData.length < HEADER_LENGTH) return (false, 0);

        if (bytes4(extraData[:4]) != PREFIX) return (false, 0);

        assembly {
            cost := calldataload(add(extraData.offset, 4))
        }
        return (true, cost);
    }
}
