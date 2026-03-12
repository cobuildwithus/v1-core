// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface ISuccessAssertionDocumentRegistry {
    error HASH_ZERO();
    error DOCUMENT_EMPTY();
    error HASH_MISMATCH(bytes32 expected, bytes32 actual);

    event DocumentRegistered(bytes32 indexed hash, address indexed submitter, uint256 length);

    function register(bytes32 expectedHash, string calldata text) external returns (bool newlyRegistered);
    function hasDocument(bytes32 hash) external view returns (bool);
    function getDocument(bytes32 hash) external view returns (string memory);
}
