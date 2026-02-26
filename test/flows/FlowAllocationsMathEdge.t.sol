// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {Vm} from "forge-std/Vm.sol";

contract FlowAllocationsMathEdgeTest is FlowAllocationsBase {
    bytes32 internal constant MEMBER_UNITS_UPDATED_SIG =
        keccak256("MemberUnitsUpdated(address,address,uint128,uint128)");
    bytes32 internal constant REMOVED_ALLOCATION_SET_SIG =
        keccak256("AllocationSet(bytes32,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ALLOCATION_COMMITTED_SIG = keccak256("AllocationCommitted(address,uint256,bytes32,uint256)");
    bytes32 internal constant ALLOCATION_SNAPSHOT_UPDATED_SIG =
        keccak256("AllocationSnapshotUpdated(address,uint256,bytes32,uint256,uint8,bytes)");
    uint8 internal constant SNAPSHOT_VERSION_V1 = 1;

    function test_allocate_overflowReverts() public {
        bytes32 id1 = bytes32(uint256(1));
        _addRecipient(id1, address(0x111));

        uint256 huge = type(uint256).max;
        uint256 allocatorKey = _allocatorKey();
        strategy.setWeight(allocatorKey, huge);
        strategy.setCanAllocate(allocatorKey, allocator, true);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(allocator);
        vm.expectRevert(IFlow.OVERFLOW.selector);
        flow.allocate(ids, scaled);
    }

    function test_allocate_initialCommit_emitsSinglePackedSnapshotAndNoLegacyAllocationSet() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 400_000;
        scaled[1] = 600_000;

        vm.recordLogs();
        vm.prank(allocator);
        flow.allocate(ids, scaled);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 1);
        assertEq(_countFlowEvents(logs, REMOVED_ALLOCATION_SET_SIG), 0);

        (bytes32 commit, uint256 weight, bytes memory packedSnapshot) = _getSnapshotUpdatedCommitWeightAndPacked(logs);
        assertEq(commit, keccak256(abi.encode(ids, scaled)));
        assertEq(weight, DEFAULT_WEIGHT);
        assertEq(packedSnapshot.length, 18);
        assertEq(_packedSnapshotCount(packedSnapshot), 2);
    }

    function test_allocate_noopReapply_emitsCommitOnlyWithoutSnapshot() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(allocator);
        flow.allocate(ids, scaled);

        vm.recordLogs();
        vm.prank(allocator);
        flow.allocate(ids, scaled);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.distributionPool().getUnits(recipient), _units(DEFAULT_WEIGHT, scaled[0]));
        assertEq(_countPoolMemberUnitsUpdated(logs), 0);
        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 0);

        (bytes32 commit, uint256 weight) = _getCommittedCommitAndWeight(logs);
        assertEq(commit, keccak256(abi.encode(ids, scaled)));
        assertEq(weight, DEFAULT_WEIGHT);
    }

    function test_allocate_deltaDecreaseWithLowCurrentClampsToZero() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        _allocateSingleKey(5, ids, scaled);

        _harnessFlow().setDistributionUnits(recipient, 0);
        strategy.setWeight(5, 0);

        bytes[][] memory allocData = _defaultAllocationDataForKey(5);
        vm.recordLogs();
        _allocateWithPrevStateForStrategy(address(uint160(5)), allocData, address(strategy), address(flow), ids, scaled);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.distributionPool().getUnits(recipient), 0);
        assertEq(_countPoolMemberUnitsUpdated(logs), 0);
        assertEq(_countFlowEvents(logs, REMOVED_ALLOCATION_SET_SIG), 0);
        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 0);
    }

    function test_allocate_deltaDecreaseWithMixedCurrent_skipsOnlyNoopPoolWrite() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address recipient1 = address(0x111);
        address recipient2 = address(0x222);
        _addRecipient(id1, recipient1);
        _addRecipient(id2, recipient2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        _allocateSingleKey(5, ids, scaled);

        _harnessFlow().setDistributionUnits(recipient1, 0);
        strategy.setWeight(5, 0);

        bytes[][] memory allocData = _defaultAllocationDataForKey(5);
        vm.recordLogs();
        _allocateWithPrevStateForStrategy(address(uint160(5)), allocData, address(strategy), address(flow), ids, scaled);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.distributionPool().getUnits(recipient1), 0);
        assertEq(flow.distributionPool().getUnits(recipient2), uint128(0));
        assertEq(_countPoolMemberUnitsUpdated(logs), 1);
        assertEq(_countFlowEvents(logs, REMOVED_ALLOCATION_SET_SIG), 0);
        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 0);
    }

    function test_allocate_removedRecipientWithStaleCurrent_skipsNoopPoolWrite() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address recipient1 = address(0x111);
        address recipient2 = address(0x222);
        _addRecipient(id1, recipient1);
        _addRecipient(id2, recipient2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;
        _allocateSingleKey(5, ids, scaled);

        _harnessFlow().setDistributionUnits(recipient1, 0);

        bytes32[] memory nextIds = new bytes32[](1);
        nextIds[0] = id2;
        uint32[] memory nextScaled = new uint32[](1);
        nextScaled[0] = 1_000_000;

        bytes[][] memory allocData = _defaultAllocationDataForKey(5);
        vm.recordLogs();
        _allocateWithPrevStateForStrategy(
            address(uint160(5)), allocData, address(strategy), address(flow), nextIds, nextScaled
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.distributionPool().getUnits(recipient1), 0);
        assertEq(flow.distributionPool().getUnits(recipient2), _units(DEFAULT_WEIGHT, 1_000_000));
        assertEq(_countPoolMemberUnitsUpdated(logs), 1);
        assertEq(_countFlowEvents(logs, REMOVED_ALLOCATION_SET_SIG), 0);
        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 1);
        (bytes32 commit, uint256 weight, bytes memory packedSnapshot) =
            _getSnapshotUpdatedCommitWeightAndPacked(logs);
        assertEq(commit, keccak256(abi.encode(nextIds, nextScaled)));
        assertEq(weight, DEFAULT_WEIGHT);
        assertEq(packedSnapshot.length, 10);
        assertEq(_packedSnapshotCount(packedSnapshot), 1);
    }

    function test_syncAllocation_noopApply_emitsCommitOnlyWithoutSnapshot() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 key = 6;
        _allocateSingleKey(key, ids, scaled);

        vm.recordLogs();
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.distributionPool().getUnits(recipient), _units(DEFAULT_WEIGHT, scaled[0]));
        assertEq(_countPoolMemberUnitsUpdated(logs), 0);
        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 0);

        (bytes32 commit, uint256 weight) = _getCommittedCommitAndWeight(logs);
        assertEq(commit, keccak256(abi.encode(ids, scaled)));
        assertEq(weight, DEFAULT_WEIGHT);
    }

    function test_clearStaleAllocation_zeroWeight_emitsCommitOnlyWithoutSnapshot() public {
        bytes32 id1 = bytes32(uint256(1));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id1;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 key = 7;
        _allocateSingleKey(key, ids, scaled);
        strategy.setWeight(key, 0);

        vm.recordLogs();
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.distributionPool().getUnits(recipient), 0);
        assertEq(_countPoolMemberUnitsUpdated(logs), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_COMMITTED_SIG), 1);
        assertEq(_countFlowEvents(logs, ALLOCATION_SNAPSHOT_UPDATED_SIG), 0);

        (bytes32 commit, uint256 weight) = _getCommittedCommitAndWeight(logs);
        assertEq(commit, keccak256(abi.encode(ids, scaled)));
        assertEq(weight, 0);
    }

    function test_setDistributionUnits_allowsClearingFlowUnits() public {
        _harnessFlow().setDistributionUnits(address(flow), 0);
        assertEq(flow.distributionPool().getUnits(address(flow)), 0);
    }

    function _countPoolMemberUnitsUpdated(Vm.Log[] memory logs) internal view returns (uint256 count) {
        address pool = address(flow.distributionPool());
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != pool) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != MEMBER_UNITS_UPDATED_SIG) continue;
            unchecked {
                ++count;
            }
        }
    }

    function _countFlowEvents(Vm.Log[] memory logs, bytes32 eventSig) internal view returns (uint256 count) {
        address flowAddress = address(flow);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != flowAddress) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSig) continue;
            unchecked {
                ++count;
            }
        }
    }

    function _getSnapshotUpdatedCommitWeightAndPacked(Vm.Log[] memory logs)
        internal
        view
        returns (bytes32 commit, uint256 weight, bytes memory packedSnapshot)
    {
        address flowAddress = address(flow);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != flowAddress) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != ALLOCATION_SNAPSHOT_UPDATED_SIG) continue;
            uint8 snapshotVersion;
            (commit, weight, snapshotVersion, packedSnapshot) = abi.decode(logs[i].data, (bytes32, uint256, uint8, bytes));
            assertEq(snapshotVersion, SNAPSHOT_VERSION_V1);
            return (commit, weight, packedSnapshot);
        }
        revert("SNAPSHOT_EVENT_NOT_FOUND");
    }

    function _getCommittedCommitAndWeight(Vm.Log[] memory logs)
        internal
        view
        returns (bytes32 commit, uint256 weight)
    {
        address flowAddress = address(flow);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != flowAddress) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != ALLOCATION_COMMITTED_SIG) continue;
            (commit, weight) = abi.decode(logs[i].data, (bytes32, uint256));
            return (commit, weight);
        }
        revert("COMMIT_EVENT_NOT_FOUND");
    }

    function _packedSnapshotCount(bytes memory packedSnapshot) internal pure returns (uint16) {
        if (packedSnapshot.length < 2) return 0;
        return (uint16(uint8(packedSnapshot[0])) << 8) | uint16(uint8(packedSnapshot[1]));
    }
}
