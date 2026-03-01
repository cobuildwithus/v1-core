// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {Vm} from "forge-std/Vm.sol";

contract FlowAllocationsLifecycleTest is FlowAllocationsBase {
    bytes32 internal constant FLOW_DISTRIBUTION_UPDATED_SIG =
        keccak256("FlowDistributionUpdated(address,address,address,address,int96,int96,int96,address,int96,bytes)");
    bytes internal constant STALE_SINGLE_RECIPIENT_SNAPSHOT = hex"000100000000000f4240";

    function test_syncAllocation_removedFlowRecipientInCommit_skipsChildFlowSyncLoop() public {
        bytes32 childId = bytes32(uint256(5001));
        IAllocationStrategy[] memory childStrategies = new IAllocationStrategy[](1);
        childStrategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            childId, recipientMetadata, manager, manager, manager, managerRewardPool, 0,
            childStrategies
        );

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = childId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        uint256 key = 5001;

        _allocateSingleKey(key, ids, scaled);

        vm.prank(manager);
        flow.removeRecipient(childId);

        uint256 reducedWeight = DEFAULT_WEIGHT / 2;
        strategy.setWeight(key, reducedWeight);

        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        assertEq(flow.getChildFlows().length, 0);
        assertEq(flow.distributionPool().getUnits(childAddr), 0);
        assertEq(_allocWeightPlusOne(key), reducedWeight + 1);
    }

    function test_allocate_removedRecipientIdCannotBeReactivated() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);

        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        uint256 key = 77;
        _allocateSingleKey(key, ids, scaled);

        bytes32 expectedCommit = keccak256(abi.encode(ids, scaled));
        assertEq(flow.getAllocationCommitment(address(strategy), key), expectedCommit);

        vm.prank(manager);
        flow.removeRecipient(id2);
        assertEq(flow.distributionPool().getUnits(r2), 0);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);
        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            address(strategy),
            address(flow),
            ids,
            scaled,
            abi.encodeWithSelector(IFlow.NOT_APPROVED_RECIPIENT.selector)
        );

        assertEq(flow.distributionPool().getUnits(r2), 0);
        assertEq(flow.distributionPool().getUnits(r1), _units(DEFAULT_WEIGHT, 500_000));
        assertEq(flow.getAllocationCommitment(address(strategy), key), expectedCommit);
    }

    function test_allocate_skipsRemovedRecipientsDuringMerge() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);

        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        _allocateSingleKey(99, ids, scaled);

        vm.prank(manager);
        flow.removeRecipient(id2);

        bytes32[] memory nextIds = new bytes32[](1);
        nextIds[0] = id1;
        uint32[] memory nextBps = new uint32[](1);
        nextBps[0] = 1_000_000;

        _allocateSingleKey(99, nextIds, nextBps);

        assertEq(flow.distributionPool().getUnits(r2), 0);
        assertEq(flow.distributionPool().getUnits(r1), _units(DEFAULT_WEIGHT, 1_000_000));
        bytes32 commit = keccak256(abi.encode(nextIds, nextBps));
        assertEq(flow.getAllocationCommitment(address(strategy), 99), commit);
    }

    function test_removeRecipient_thenReallocate_sameKey_doesNotUnderflowAndRestoresWeight() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);
        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 600_000;
        scaled[1] = 400_000;
        _allocateSingleKey(123, ids, scaled);

        vm.prank(manager);
        flow.removeRecipient(id1);

        bytes32[] memory nextIds = new bytes32[](1);
        nextIds[0] = id2;
        uint32[] memory nextBps = new uint32[](1);
        nextBps[0] = 1_000_000;
        _allocateSingleKey(123, nextIds, nextBps);

        assertEq(flow.distributionPool().getUnits(r1), 0);
        assertEq(flow.distributionPool().getUnits(r2), _units(DEFAULT_WEIGHT, 1_000_000));
    }

    function test_removeRecipient_updatesDistributionUnits() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);
        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 600_000;
        scaled[1] = 400_000;

        _allocateSingleKey(7, ids, scaled);
        vm.prank(manager);
        flow.removeRecipient(id1);

        assertEq(flow.distributionPool().getUnits(r1), 0);
        assertEq(flow.distributionPool().getUnits(r2), _units(DEFAULT_WEIGHT, scaled[1]));
    }

    function test_syncAllocation_afterRecipientRemoval_updatesRemainingRecipient() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);
        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        uint256 key = 88;
        _allocateSingleKey(key, ids, scaled);

        vm.prank(manager);
        flow.removeRecipient(id1);

        uint256 reducedWeight = DEFAULT_WEIGHT / 4;
        strategy.setWeight(key, reducedWeight);

        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        assertEq(flow.distributionPool().getUnits(r1), 0);
        assertEq(flow.distributionPool().getUnits(r2), _units(reducedWeight, scaled[1]));
        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
    }

    function test_syncAllocation_readsCurrentWeightOnce_whenRequireZeroWeightFalse() public {
        uint256 key = 94;
        (bytes32[] memory ids, uint32[] memory scaled, address recipient) = _setupSingleRecipientAllocation(key);

        uint256 reducedWeight = DEFAULT_WEIGHT / 5;
        strategy.setWeight(key, reducedWeight);

        vm.expectCall(
            address(strategy), abi.encodeWithSelector(IAllocationStrategy.currentWeight.selector, key), uint64(1)
        );
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        assertEq(_allocWeightPlusOne(key), reducedWeight + 1);
        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(flow.distributionPool().getUnits(recipient), _units(reducedWeight, scaled[0]));
    }

    function test_syncAllocation_denominatorShift_doesNotRedistributeParentFlow_orAutoSyncChildTargetRate() public {
        bytes32 childId = bytes32(uint256(7001));
        bytes32 recipientId = bytes32(uint256(7002));

        IAllocationStrategy[] memory childStrategies = new IAllocationStrategy[](1);
        childStrategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAddr) = flow.addFlowRecipient(
            childId, recipientMetadata, manager, manager, manager, managerRewardPool, 0,
            childStrategies
        );

        _addRecipient(recipientId, address(0xBEEF7));

        vm.prank(owner);
        flow.setTargetOutflowRate(10_000);

        uint256 key = _allocatorKey();
        strategy.setCanAllocate(key, allocator, true);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);

        strategy.setWeight(key, 1_000e15);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(flow), ids, scaled);

        int96 parentTargetBefore = flow.targetOutflowRate();
        int96 childTargetBefore = IFlow(childAddr).targetOutflowRate();

        strategy.setWeight(key, 2_000e15);

        vm.recordLogs();
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.targetOutflowRate(), parentTargetBefore);
        assertEq(_countParentDistributionFlowUpdates(logs), 0);

        int96 desiredChildRate = flow.getMemberFlowRate(childAddr);
        assertEq(int256(IFlow(childAddr).targetOutflowRate()), int256(childTargetBefore));
        assertEq(int256(desiredChildRate), int256(childTargetBefore));
    }

    function test_syncAllocation_denominatorShift_updatesDesiredRates_withoutAutoSyncingChildTargets() public {
        bytes32 childAId = bytes32(uint256(7101));
        bytes32 childBId = bytes32(uint256(7102));
        bytes32 recipientId = bytes32(uint256(7103));

        IAllocationStrategy[] memory childStrategies = new IAllocationStrategy[](1);
        childStrategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(manager);
        (, address childAAddr) = flow.addFlowRecipient(
            childAId, recipientMetadata, manager, manager, manager, managerRewardPool, 0,
            childStrategies
        );
        vm.prank(manager);
        (, address childBAddr) = flow.addFlowRecipient(
            childBId, recipientMetadata, manager, manager, manager, managerRewardPool, 0,
            childStrategies
        );

        _addRecipient(recipientId, address(0xBEEF8));

        vm.prank(owner);
        flow.setTargetOutflowRate(10_000);
        int96 parentTarget = flow.targetOutflowRate();

        uint256 key = _allocatorKey();
        strategy.setCanAllocate(key, allocator, true);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);

        int96 childATargetBefore = IFlow(childAAddr).targetOutflowRate();
        int96 childBTargetBefore = IFlow(childBAddr).targetOutflowRate();

        strategy.setWeight(key, 1_000e15);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(flow), ids, scaled);

        int96 desiredA1 = flow.getMemberFlowRate(childAAddr);
        int96 desiredB1 = flow.getMemberFlowRate(childBAddr);
        assertEq(int256(IFlow(childAAddr).targetOutflowRate()), int256(childATargetBefore));
        assertEq(int256(IFlow(childBAddr).targetOutflowRate()), int256(childBTargetBefore));

        strategy.setWeight(key, 2_000e15);
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        int96 desiredA2 = flow.getMemberFlowRate(childAAddr);
        int96 desiredB2 = flow.getMemberFlowRate(childBAddr);
        assertEq(desiredA2, desiredA1);
        assertEq(desiredB2, desiredB1);
        assertEq(int256(IFlow(childAAddr).targetOutflowRate()), int256(childATargetBefore));
        assertEq(int256(IFlow(childBAddr).targetOutflowRate()), int256(childBTargetBefore));
        assertEq(flow.targetOutflowRate(), parentTarget);

        strategy.setWeight(key, 500e15);
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        int96 desiredA3 = flow.getMemberFlowRate(childAAddr);
        int96 desiredB3 = flow.getMemberFlowRate(childBAddr);
        assertEq(desiredA3, desiredA2);
        assertEq(desiredB3, desiredB2);
        assertEq(int256(IFlow(childAAddr).targetOutflowRate()), int256(childATargetBefore));
        assertEq(int256(IFlow(childBAddr).targetOutflowRate()), int256(childBTargetBefore));
        assertEq(flow.targetOutflowRate(), parentTarget);
    }

    function test_syncAllocationForAccount_updatesUnitsForDerivedAllocationKey() public {
        uint256 key = _allocatorKey();
        (bytes32[] memory ids, uint32[] memory scaled, address recipient) = _setupSingleRecipientAllocation(key);

        uint256 reducedWeight = DEFAULT_WEIGHT / 5;
        strategy.setWeight(key, reducedWeight);

        vm.prank(other);
        flow.syncAllocationForAccount(allocator);

        assertEq(_allocWeightPlusOne(key), reducedWeight + 1);
        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(flow.distributionPool().getUnits(recipient), _units(reducedWeight, scaled[0]));
    }

    function test_syncAllocationForAccount_revertsWhenNoCommitmentExistsForDerivedKey() public {
        vm.expectRevert(CustomFlow.STALE_CLEAR_NO_COMMITMENT.selector);
        vm.prank(other);
        flow.syncAllocationForAccount(allocator);
    }

    function test_syncAllocation_noCommit_withStoredSnapshot_revertsStaleClearNoCommitment() public {
        uint256 key = 95;
        _addRecipient(bytes32(uint256(1)), address(0x111));
        _harnessFlow().setAllocSnapshotPackedForTest(address(strategy), key, STALE_SINGLE_RECIPIENT_SNAPSHOT);

        assertEq(flow.getAllocationCommitment(address(strategy), key), bytes32(0));

        vm.expectRevert(CustomFlow.STALE_CLEAR_NO_COMMITMENT.selector);
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);
    }

    function test_clearStaleAllocation_noCommit_withStoredSnapshot_revertsStaleClearNoCommitment() public {
        uint256 key = 96;
        _addRecipient(bytes32(uint256(1)), address(0x111));
        _harnessFlow().setAllocSnapshotPackedForTest(address(strategy), key, STALE_SINGLE_RECIPIENT_SNAPSHOT);

        assertEq(flow.getAllocationCommitment(address(strategy), key), bytes32(0));

        vm.expectRevert(CustomFlow.STALE_CLEAR_NO_COMMITMENT.selector);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), key);
    }

    function test_syncAllocation_revertsWhenStrategyNotDefault() public {
        uint256 key = 92;
        (bytes32[] memory ids, uint32[] memory scaled, address recipient) = _setupSingleRecipientAllocation(key);

        vm.expectRevert(abi.encodeWithSelector(IFlow.ONLY_DEFAULT_STRATEGY_ALLOWED.selector, address(0xBEEF)));
        vm.prank(other);
        flow.syncAllocation(address(0xBEEF), key);

        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(flow.distributionPool().getUnits(recipient), _units(DEFAULT_WEIGHT, scaled[0]));
    }

    function test_clearStaleAllocation_afterRecipientRemoval_clearsRemainingRecipientUnits() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);
        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        uint256 key = 89;
        _allocateSingleKey(key, ids, scaled);

        vm.prank(manager);
        flow.removeRecipient(id1);

        strategy.setWeight(key, 0);

        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), key);

        assertEq(flow.distributionPool().getUnits(r1), 0);
        assertEq(flow.distributionPool().getUnits(r2), uint128(0));
        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
    }

    function test_clearStaleAllocation_revertsWhenStrategyNotDefault() public {
        uint256 key = 93;
        (bytes32[] memory ids, uint32[] memory scaled, address recipient) = _setupSingleRecipientAllocation(key);

        vm.expectRevert(abi.encodeWithSelector(IFlow.ONLY_DEFAULT_STRATEGY_ALLOWED.selector, address(0xBEEF)));
        vm.prank(other);
        flow.clearStaleAllocation(address(0xBEEF), key);

        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(flow.distributionPool().getUnits(recipient), _units(DEFAULT_WEIGHT, scaled[0]));
    }

    function test_syncAllocation_existingCommit_withoutCachedWeight_reverts() public {
        uint256 key = 90;
        (bytes32[] memory ids, uint32[] memory scaled, address recipient) = _setupSingleRecipientAllocation(key);

        uint256 reducedWeight = DEFAULT_WEIGHT / 3;
        assertEq(_allocWeightPlusOne(key), DEFAULT_WEIGHT + 1);
        _clearAllocWeightCache(key);
        assertEq(_allocWeightPlusOne(key), 0);

        strategy.setWeight(key, reducedWeight);

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        vm.prank(other);
        flow.syncAllocation(address(strategy), key);

        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(_allocWeightPlusOne(key), 0);
        assertEq(flow.distributionPool().getUnits(recipient), _units(DEFAULT_WEIGHT, scaled[0]));
    }

    function test_clearStaleAllocation_existingCommit_withoutCachedWeight_reverts() public {
        uint256 key = 91;
        (bytes32[] memory ids, uint32[] memory scaled, address recipient) = _setupSingleRecipientAllocation(key);

        assertEq(_allocWeightPlusOne(key), DEFAULT_WEIGHT + 1);
        _clearAllocWeightCache(key);
        assertEq(_allocWeightPlusOne(key), 0);

        strategy.setWeight(key, 0);

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), key);

        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, scaled)));
        assertEq(_allocWeightPlusOne(key), 0);
        assertEq(flow.distributionPool().getUnits(recipient), _units(DEFAULT_WEIGHT, scaled[0]));
    }

    function test_previewChildSyncRequirements_revertsWhenStrategyNotDefault() public {
        bytes32 id = bytes32(uint256(1));
        _addRecipient(id, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.expectRevert(abi.encodeWithSelector(IFlow.ONLY_DEFAULT_STRATEGY_ALLOWED.selector, address(0xBEEF)));
        flow.previewChildSyncRequirements(address(0xBEEF), 0, ids, scaled);
    }

    function _setupSingleRecipientAllocation(uint256 key)
        internal
        returns (bytes32[] memory ids, uint32[] memory scaled, address recipient)
    {
        bytes32 id = bytes32(uint256(1));
        recipient = address(0x111);
        _addRecipient(id, recipient);

        ids = new bytes32[](1);
        ids[0] = id;

        scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        _allocateSingleKey(key, ids, scaled);
    }

    function _allocWeightPlusOne(uint256 key) internal view returns (uint256) {
        return _harnessFlow().getAllocWeightPlusOneForTest(address(strategy), key);
    }

    function _clearAllocWeightCache(uint256 key) internal {
        _harnessFlow().clearAllocWeightPlusOneForTest(address(strategy), key);
    }

    function _countParentDistributionFlowUpdates(Vm.Log[] memory logs) internal view returns (uint256 count) {
        address poolAdminGda = address(sf.gda);
        bytes32 poolTopic = bytes32(uint256(uint160(address(flow.distributionPool()))));
        bytes32 distributorTopic = bytes32(uint256(uint160(address(flow))));

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != poolAdminGda) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != FLOW_DISTRIBUTION_UPDATED_SIG) continue;
            if (logs[i].topics[2] != poolTopic) continue;
            if (logs[i].topics[3] != distributorTopic) continue;
            unchecked {
                ++count;
            }
        }
    }
}
