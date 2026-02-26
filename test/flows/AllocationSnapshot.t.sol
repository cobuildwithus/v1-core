// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { IFlow } from "src/interfaces/IFlow.sol";
import { AllocationSnapshot } from "src/library/AllocationSnapshot.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

contract AllocationSnapshotTest is Test {
    AllocationSnapshotHarness internal harness;

    bytes32 internal constant ID1 = bytes32(uint256(1));
    bytes32 internal constant ID2 = bytes32(uint256(2));

    function setUp() public {
        harness = new AllocationSnapshotHarness();
        harness.setRecipient(ID1, 0);
        harness.setRecipient(ID2, 1);
    }

    function test_encodeMemory_matchesPackedFormat_andRoundTrips() public view {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID1;
        ids[1] = ID2;

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 0x00010203;
        scaled[1] = 0x04050607;

        bytes memory fromMemory = harness.encodeMemory(ids, scaled);
        assertEq(fromMemory, hex"000200000000000102030000000104050607");

        (bytes32[] memory decodedIds, uint32[] memory decodedScaled) = harness.decodeMemory(fromMemory);
        assertEq(decodedIds.length, 2);
        assertEq(decodedIds[0], ID1);
        assertEq(decodedIds[1], ID2);
        assertEq(decodedScaled[0], scaled[0]);
        assertEq(decodedScaled[1], scaled[1]);
    }

    function test_encodeMemory_revertsOnLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID1;
        ids[1] = ID2;

        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.expectRevert(IFlow.ARRAY_LENGTH_MISMATCH.selector);
        harness.encodeMemory(ids, scaled);
    }

    function test_encodeMemory_revertsOnInvalidRecipientId() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID1;
        ids[1] = bytes32(uint256(999));

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        vm.expectRevert(IFlow.INVALID_RECIPIENT_ID.selector);
        harness.encodeMemory(ids, scaled);
    }

    function test_encodeMemory_revertsOnOverflowCount() public {
        uint256 count = uint256(type(uint16).max) + 1;
        bytes32[] memory ids = new bytes32[](count);
        uint32[] memory scaled = new uint32[](count);

        vm.expectRevert(IFlow.OVERFLOW.selector);
        harness.encodeMemory(ids, scaled);
    }
}

contract AllocationSnapshotHarness {
    FlowTypes.RecipientsState private _recipients;

    function setRecipient(bytes32 id, uint32 recipientIndex) external {
        _recipients.recipients[id].recipient = address(uint160(uint256(recipientIndex) + 1));
        _recipients.recipients[id].recipientIndexPlusOne = recipientIndex + 1;

        while (_recipients.recipientIdByIndex.length <= recipientIndex) {
            _recipients.recipientIdByIndex.push(bytes32(0));
        }
        _recipients.recipientIdByIndex[recipientIndex] = id;
    }

    function encodeMemory(bytes32[] memory ids, uint32[] memory scaled) external view returns (bytes memory) {
        return AllocationSnapshot.encodeMemory(_recipients, ids, scaled);
    }

    function decodeMemory(bytes memory packed) external view returns (bytes32[] memory ids, uint32[] memory scaled) {
        return AllocationSnapshot.decodeMemory(_recipients, packed);
    }
}
