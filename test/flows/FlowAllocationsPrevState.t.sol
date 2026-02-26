// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {TestableCustomFlow} from "test/harness/TestableCustomFlow.sol";

contract FlowAllocationsPrevStateTest is FlowAllocationsBase {
    bytes32 internal constant FLOW_ALLOC_STORAGE_LOCATION =
        0xec99f0a88c8217d873dc1f006d43648a9c64971b5d0403486aac00b6b2bec900;
    uint256 internal constant ALLOC_SNAPSHOT_PACKED_OFFSET = 3;

    function test_allocate_firstCommit_succeedsWithoutPrevStatePayload() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(allocator);
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), _allocatorKey()), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_existingCommit_weightChange_usesCurrentWeight() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 key = _allocatorKey();
        uint256 weightA = 41e24;
        uint256 weightB = 52e24;
        strategy.setWeight(key, weightA);
        strategy.setCanAllocate(key, allocator, true);

        bytes[][] memory allocData = _defaultAllocationDataForKey(key);
        bytes[][] memory emptyPrevStates = _buildEmptyPrevStates(allocData);

        vm.prank(allocator);
        flow.allocate(ids, scaled);
        _assertCommitAndCacheWeight(key, weightA, ids, scaled);

        strategy.setWeight(key, weightB);
        bytes32 commitBefore = flow.getAllocationCommitment(address(strategy), key);

        bytes[][] memory prevStates = new bytes[][](1);
        prevStates[0] = new bytes[](1);
        prevStates[0][0] = abi.encode(ids, scaled);

        vm.prank(allocator);
        flow.allocate(ids, scaled);

        _assertCommitAndCacheWeight(key, weightB, ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), key), commitBefore);
        assertEq(flow.distributionPool().getUnits(recipient), _units(weightB, scaled[0]));
    }

    function test_allocate_existingCommit_updatesWithoutPrevStatePayload() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        _allocateSingleKey(6, ids, scaled);

        vm.prank(address(uint160(6)));
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), 6), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_unsortedLegacyPrevStatePayloadNoLongerApplies() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        _allocateSingleKey(3, ids, scaled);

        vm.prank(address(uint160(3)));
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), 3), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_existingCommit_ignoresLegacyPrevStateContentConcept() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 700_000;
        scaled[1] = 300_000;

        _allocateSingleKey(72, ids, scaled);

        vm.prank(address(uint160(72)));
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), 72), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_legacyPrevStateLengthMismatchConceptNoLongerApplies() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        _allocateSingleKey(77, ids, scaled);

        vm.prank(address(uint160(77)));
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), 77), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_legacyDuplicatePrevStateConceptNoLongerApplies() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;
        _allocateSingleKey(88, ids, scaled);

        vm.prank(address(uint160(88)));
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), 88), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_legacyMalformedPrevStateConceptNoLongerApplies() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        _allocateSingleKey(123, ids, scaled);

        bytes32 commitBefore = flow.getAllocationCommitment(address(strategy), 123);
        uint128 unitsBefore = flow.distributionPool().getUnits(recipient);

        vm.prank(address(uint160(123)));
        flow.allocate(ids, scaled);

        assertEq(flow.getAllocationCommitment(address(strategy), 123), commitBefore);
        assertEq(flow.distributionPool().getUnits(recipient), unitsBefore);
    }

    function test_allocate_noCommit_withStoredSnapshot_revertsInvalidPrevAllocation() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        // count=1, index=0, scaled=1_000_000
        bytes memory packedSnapshot = hex"000100000000000f4240";
        TestableCustomFlow(address(flow)).setAllocSnapshotPackedForTest(address(strategy), _allocatorKey(), packedSnapshot);

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        vm.prank(allocator);
        flow.allocate(ids, scaled);
    }

    function test_syncAllocation_existingCommit_withEmptyStoredSnapshot_revertsInvalidPrevAllocation() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 key = 3201;
        _allocateSingleKey(key, ids, scaled);

        TestableCustomFlow(address(flow)).setAllocSnapshotPackedForTest(address(strategy), key, "");

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);
    }

    function test_syncAllocation_existingCommit_doesNotRewriteSnapshotWhenCommitUnchanged() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 600_000;
        scaled[1] = 400_000;

        uint256 key = 3203;
        _allocateSingleKey(key, ids, scaled);

        bytes32 snapshotSlot = _allocSnapshotPackedSlot(address(strategy), key);
        bytes32 snapshotWordBefore = vm.load(address(flow), snapshotSlot);

        strategy.setWeight(key, DEFAULT_WEIGHT + 1e23);

        vm.record();
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);
        (, bytes32[] memory writes) = vm.accesses(address(flow));

        assertEq(vm.load(address(flow), snapshotSlot), snapshotWordBefore);
        assertFalse(_containsSlot(writes, snapshotSlot));
    }

    function test_allocate_existingCommit_changedCommit_rewritesSnapshot() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaledA = new uint32[](2);
        scaledA[0] = 600_000;
        scaledA[1] = 400_000;

        uint256 key = 3205;
        _allocateSingleKey(key, ids, scaledA);

        bytes32 snapshotSlot = _allocSnapshotPackedSlot(address(strategy), key);
        bytes32 snapshotWordBefore = vm.load(address(flow), snapshotSlot);

        uint32[] memory scaledB = new uint32[](2);
        scaledB[0] = 250_000;
        scaledB[1] = 750_000;

        vm.record();
        vm.prank(address(uint160(key)));
        flow.allocate(ids, scaledB);
        (, bytes32[] memory writes) = vm.accesses(address(flow));

        assertTrue(_containsSlot(writes, snapshotSlot));
        assertTrue(vm.load(address(flow), snapshotSlot) != snapshotWordBefore);
        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaledB)));
    }

    function test_applyAllocation_existingCommit_missingSnapshot_doesNotAutoRestoreSnapshot() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 600_000;
        scaled[1] = 400_000;

        uint256 key = 3204;
        _allocateSingleKey(key, ids, scaled);

        TestableCustomFlow harness = TestableCustomFlow(address(flow));
        harness.setAllocSnapshotPackedForTest(address(strategy), key, "");
        assertEq(harness.getAllocSnapshotPackedForTest(address(strategy), key).length, 0);

        uint256 prevWeight = harness.getAllocWeightPlusOneForTest(address(strategy), key) - 1;
        harness.syncAllocationWithPrevStateBypassForTest(address(strategy), key, prevWeight, ids, scaled);

        bytes memory restored = harness.getAllocSnapshotPackedForTest(address(strategy), key);
        assertEq(restored.length, 0);
    }

    function test_clearStaleAllocation_existingCommit_withMalformedStoredSnapshot_revertsInvalidPrevAllocation() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 key = 3202;
        _allocateSingleKey(key, ids, scaled);

        TestableCustomFlow(address(flow)).setAllocSnapshotPackedForTest(address(strategy), key, hex"00");

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), key);
    }

    function test_allocate_existingCommit_withoutCachedWeight_reverts() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 key = _allocatorKey();
        uint256 weightA = 19e24;
        uint256 weightB = 23e24;
        strategy.setWeight(key, weightA);
        strategy.setCanAllocate(key, allocator, true);

        bytes[][] memory allocData = _defaultAllocationDataForKey(key);
        bytes[][] memory emptyPrevStates = _buildEmptyPrevStates(allocData);

        vm.prank(allocator);
        flow.allocate(ids, scaled);
        _assertCommitAndCacheWeight(key, weightA, ids, scaled);

        TestableCustomFlow(address(flow)).clearAllocWeightPlusOneForTest(address(strategy), key);
        assertEq(_allocWeightPlusOne(key), 0);

        strategy.setWeight(key, weightB);
        bytes[][] memory prevStates = new bytes[][](1);
        prevStates[0] = new bytes[](1);
        prevStates[0][0] = abi.encode(ids, scaled);

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        vm.prank(allocator);
        flow.allocate(ids, scaled);

        assertEq(_allocWeightPlusOne(key), 0);
        assertEq(flow.distributionPool().getUnits(recipient), _units(weightA, scaled[0]));
    }

    function _assertCommitAndCacheWeight(uint256 key, uint256 expectedWeight, bytes32[] memory ids, uint32[] memory scaled)
        internal
        view
    {
        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(_allocWeightPlusOne(key), expectedWeight + 1);
    }

    function _allocWeightPlusOne(uint256 key) internal view returns (uint256) {
        return TestableCustomFlow(address(flow)).getAllocWeightPlusOneForTest(address(strategy), key);
    }

    function _allocSnapshotPackedSlot(address strategyAddress, uint256 allocationKey) internal pure returns (bytes32 slot) {
        uint256 snapshotBaseSlot = uint256(FLOW_ALLOC_STORAGE_LOCATION) + ALLOC_SNAPSHOT_PACKED_OFFSET;
        bytes32 strategySlot = keccak256(abi.encode(strategyAddress, snapshotBaseSlot));
        slot = keccak256(abi.encode(allocationKey, strategySlot));
    }

    function _containsSlot(bytes32[] memory slots, bytes32 target) internal pure returns (bool found) {
        for (uint256 i = 0; i < slots.length; ++i) {
            if (slots[i] == target) return true;
        }
    }
}
