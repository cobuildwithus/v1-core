// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISuccessAssertionDocumentRegistry } from "src/interfaces/ISuccessAssertionDocumentRegistry.sol";

contract SuccessAssertionDocumentRegistry is ISuccessAssertionDocumentRegistry {
    mapping(bytes32 hash => string text) internal _documentText;

    function register(bytes32 expectedHash, string calldata text) external returns (bool newlyRegistered) {
        if (expectedHash == bytes32(0)) revert HASH_ZERO();

        uint256 textLength = bytes(text).length;
        if (textLength == 0) revert DOCUMENT_EMPTY();

        bytes32 actualHash = keccak256(bytes(text));
        if (actualHash != expectedHash) revert HASH_MISMATCH(expectedHash, actualHash);

        if (bytes(_documentText[expectedHash]).length != 0) return false;

        _documentText[expectedHash] = text;
        emit DocumentRegistered(expectedHash, msg.sender, textLength);
        return true;
    }

    function hasDocument(bytes32 hash) external view returns (bool) {
        return bytes(_documentText[hash]).length != 0;
    }

    function getDocument(bytes32 hash) external view returns (string memory) {
        return _documentText[hash];
    }
}
