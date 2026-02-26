// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow } from "../interfaces/IFlow.sol";

/// @notice Compact onchain allocation snapshot packing utilities.
library AllocationSnapshot {
    function encodeMemory(
        FlowTypes.RecipientsState storage recipients,
        bytes32[] memory ids,
        uint32[] memory allocationScaled
    ) internal view returns (bytes memory packed) {
        if (ids.length != allocationScaled.length) revert IFlow.ARRAY_LENGTH_MISMATCH();

        uint256 count = ids.length;
        if (count > type(uint16).max) revert IFlow.OVERFLOW();

        packed = new bytes(2 + (count * 8));
        _writeUint16(packed, 0, uint16(count));

        uint256 cursor = 2;
        for (uint256 i = 0; i < count; ) {
            uint32 indexPlusOne = recipients.recipients[ids[i]].recipientIndexPlusOne;
            if (indexPlusOne == 0) revert IFlow.INVALID_RECIPIENT_ID();

            _writeUint32(packed, cursor, indexPlusOne - 1);
            _writeUint32(packed, cursor + 4, allocationScaled[i]);
            cursor += 8;

            unchecked {
                ++i;
            }
        }
    }

    function decodeStorage(
        FlowTypes.RecipientsState storage recipients,
        bytes storage packed
    ) internal view returns (bytes32[] memory ids, uint32[] memory allocationScaled) {
        bytes memory copied = packed;
        return decodeMemory(recipients, copied);
    }

    function decodeMemory(
        FlowTypes.RecipientsState storage recipients,
        bytes memory packed
    ) internal view returns (bytes32[] memory ids, uint32[] memory allocationScaled) {
        if (packed.length == 0) {
            return (new bytes32[](0), new uint32[](0));
        }
        if (packed.length < 2) revert IFlow.INVALID_PREV_ALLOCATION();

        uint256 count = _readUint16(packed, 0);
        uint256 expectedLength = 2 + (count * 8);
        if (packed.length != expectedLength) revert IFlow.INVALID_PREV_ALLOCATION();

        ids = new bytes32[](count);
        allocationScaled = new uint32[](count);

        uint256 indexTableLength = recipients.recipientIdByIndex.length;
        uint256 cursor = 2;
        bytes32 prev;

        for (uint256 i = 0; i < count; ) {
            uint32 recipientIndex = _readUint32(packed, cursor);
            uint32 scaled = _readUint32(packed, cursor + 4);
            if (scaled == 0) revert IFlow.INVALID_PREV_ALLOCATION();
            if (recipientIndex >= indexTableLength) revert IFlow.INVALID_PREV_ALLOCATION();

            bytes32 recipientId = recipients.recipientIdByIndex[recipientIndex];
            if (i != 0 && recipientId <= prev) revert IFlow.NOT_SORTED_OR_DUPLICATE();
            prev = recipientId;

            ids[i] = recipientId;
            allocationScaled[i] = scaled;
            cursor += 8;

            unchecked {
                ++i;
            }
        }
    }

    function _writeUint16(bytes memory out, uint256 offset, uint16 value) private pure {
        out[offset] = bytes1(uint8(value >> 8));
        out[offset + 1] = bytes1(uint8(value));
    }

    function _writeUint32(bytes memory out, uint256 offset, uint32 value) private pure {
        out[offset] = bytes1(uint8(value >> 24));
        out[offset + 1] = bytes1(uint8(value >> 16));
        out[offset + 2] = bytes1(uint8(value >> 8));
        out[offset + 3] = bytes1(uint8(value));
    }

    function _readUint16(bytes memory in_, uint256 offset) private pure returns (uint16 value) {
        value = (uint16(uint8(in_[offset])) << 8) | uint16(uint8(in_[offset + 1]));
    }

    function _readUint32(bytes memory in_, uint256 offset) private pure returns (uint32 value) {
        value =
            (uint32(uint8(in_[offset])) << 24) |
            (uint32(uint8(in_[offset + 1])) << 16) |
            (uint32(uint8(in_[offset + 2])) << 8) |
            uint32(uint8(in_[offset + 3]));
    }
}
