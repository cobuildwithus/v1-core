// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {SuccessAssertionDocumentRegistry} from "src/goals/SuccessAssertionDocumentRegistry.sol";
import {ISuccessAssertionDocumentRegistry} from "src/interfaces/ISuccessAssertionDocumentRegistry.sol";

contract SuccessAssertionDocumentRegistryTest is Test {
    SuccessAssertionDocumentRegistry internal registry;

    function setUp() public {
        registry = new SuccessAssertionDocumentRegistry();
    }

    function test_register_storesTextByHash() public {
        string memory text = "goal success spec v1";
        bytes32 hash = keccak256(bytes(text));

        bool newlyRegistered = registry.register(hash, text);

        assertTrue(newlyRegistered);
        assertTrue(registry.hasDocument(hash));
        assertEq(registry.getDocument(hash), text);
    }

    function test_register_isIdempotentForExistingHash() public {
        string memory text = "shared assertion policy";
        bytes32 hash = keccak256(bytes(text));

        assertTrue(registry.register(hash, text));
        assertFalse(registry.register(hash, text));
        assertEq(registry.getDocument(hash), text);
    }

    function test_register_revertsOnZeroHash() public {
        vm.expectRevert(ISuccessAssertionDocumentRegistry.HASH_ZERO.selector);
        registry.register(bytes32(0), "text");
    }

    function test_register_revertsOnEmptyText() public {
        vm.expectRevert(ISuccessAssertionDocumentRegistry.DOCUMENT_EMPTY.selector);
        registry.register(keccak256(bytes("non-empty")), "");
    }

    function test_register_revertsOnHashMismatch() public {
        bytes32 expectedHash = keccak256(bytes("expected"));
        bytes32 actualHash = keccak256(bytes("actual"));

        vm.expectRevert(
            abi.encodeWithSelector(ISuccessAssertionDocumentRegistry.HASH_MISMATCH.selector, expectedHash, actualHash)
        );
        registry.register(expectedHash, "actual");
    }
}
