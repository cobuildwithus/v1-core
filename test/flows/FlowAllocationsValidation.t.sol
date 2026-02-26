// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {IFlow, ICustomFlow} from "src/interfaces/IFlow.sol";

contract FlowAllocationsValidationTest is FlowAllocationsBase {
    struct LegacyAllocationAction {
        address strategy;
        bytes allocationData;
        bytes prevState;
    }

    function test_allocate_defaultStrategyEntryPoint_succeeds() public {
        bytes32 id = bytes32(uint256(1));
        _addRecipient(id, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(allocator);
        flow.allocate(ids, scaled);
        uint256 allocatorKey = _allocatorKey();
        assertEq(flow.getAllocationCommitment(address(strategy), allocatorKey), keccak256(abi.encode(ids, scaled)));

        bytes memory prevState = abi.encode(ids, scaled);
        vm.prank(allocator);
        flow.allocate(ids, scaled);
        assertEq(flow.getAllocationCommitment(address(strategy), allocatorKey), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_defaultStrategyEntryPoint_ignoresLegacyPrevStateConcept() public {
        bytes32 id = bytes32(uint256(1));
        _addRecipient(id, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(allocator);
        flow.allocate(ids, scaled);

        vm.prank(allocator);
        flow.allocate(ids, scaled);

        uint256 allocatorKey = _allocatorKey();
        assertEq(flow.getAllocationCommitment(address(strategy), allocatorKey), keccak256(abi.encode(ids, scaled)));
    }

    function test_allocate_defaultStrategyEntryPoint_revertsWhenNotAbleToAllocate() public {
        bytes32 id = bytes32(uint256(1));
        _addRecipient(id, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        strategy.setCanAllocate(_allocatorKey(), allocator, false);
        strategy.setCanAccountAllocate(allocator, false);

        vm.expectRevert(IFlow.NOT_ABLE_TO_ALLOCATE.selector);
        vm.prank(allocator);
        flow.allocate(ids, scaled);
    }

    function test_allocate_revertsOnValidationFailures() public {
        _addRecipient(bytes32(uint256(1)), address(0x111));

        bytes[][] memory allocData = _defaultAllocationDataForKey(0);
        bytes[][] memory prevStates = _buildEmptyPrevStates(allocData);

        bytes32[] memory ids = new bytes32[](0);
        uint32[] memory scaled = new uint32[](0);

        vm.prank(allocator);
        vm.expectRevert(IFlow.TOO_FEW_RECIPIENTS.selector);
        flow.allocate(ids, scaled);

        ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        scaled = new uint32[](2);
        scaled[0] = 1_000_000;
        scaled[1] = 0;

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IFlow.RECIPIENTS_ALLOCATIONS_MISMATCH.selector, 1, 2));
        flow.allocate(ids, scaled);

        scaled = new uint32[](1);
        scaled[0] = 0;
        vm.prank(allocator);
        vm.expectRevert(IFlow.ALLOCATION_MUST_BE_POSITIVE.selector);
        flow.allocate(ids, scaled);

        scaled[0] = 999_999;
        vm.prank(allocator);
        vm.expectRevert(IFlow.INVALID_SCALED_SUM.selector);
        flow.allocate(ids, scaled);
    }

    function test_allocate_revertsOnUnsortedOrDuplicateRecipientIds() public {
        _addRecipient(bytes32(uint256(1)), address(0x111));
        _addRecipient(bytes32(uint256(2)), address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(2));
        ids[1] = bytes32(uint256(1));

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        bytes[][] memory allocData = _defaultAllocationDataForKey(0);
        bytes[][] memory prevStates = _buildEmptyPrevStates(allocData);

        vm.prank(allocator);
        vm.expectRevert(IFlow.NOT_SORTED_OR_DUPLICATE.selector);
        flow.allocate(ids, scaled);

        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(1));
        vm.prank(allocator);
        vm.expectRevert(IFlow.NOT_SORTED_OR_DUPLICATE.selector);
        flow.allocate(ids, scaled);
    }

    function test_allocate_revertsOnStrategyAuthorizationCheck() public {
        _addRecipient(bytes32(uint256(1)), address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        bytes[][] memory allocData = _defaultAllocationDataForKey(42);
        bytes[][] memory prevStates = _buildEmptyPrevStates(allocData);

        strategy.setCanAccountAllocate(allocator, false);
        strategy.setCanAllocate(_allocatorKey(), allocator, false);
        vm.prank(allocator);
        vm.expectRevert(IFlow.NOT_ABLE_TO_ALLOCATE.selector);
        flow.allocate(ids, scaled);
    }

    function test_allocate_revertsOnInvalidAndRemovedRecipientIds() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address recipient = address(0x111);
        _addRecipient(id1, recipient);

        bytes[][] memory allocData = _defaultAllocationDataForKey(0);
        bytes[][] memory prevStates = _buildEmptyPrevStates(allocData);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id2;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.prank(allocator);
        vm.expectRevert(IFlow.INVALID_RECIPIENT_ID.selector);
        flow.allocate(ids, scaled);

        _addRecipient(id2, address(0x222));
        vm.prank(manager);
        flow.removeRecipient(id2);

        vm.prank(allocator);
        vm.expectRevert(IFlow.NOT_APPROVED_RECIPIENT.selector);
        flow.allocate(ids, scaled);
    }

    function test_allocate_defaultStrategyEntryPoint_usesCallerDerivedKeyForAuthAndCommit() public {
        bytes32 id = bytes32(uint256(1));
        _addRecipient(id, address(0x111));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        uint256 allocatorKey = _allocatorKey();
        uint256 legacyAuxKey = 42;

        strategy.setCanAccountAllocate(allocator, false);
        strategy.setCanAllocate(allocatorKey, allocator, false);
        strategy.setCanAllocate(legacyAuxKey, allocator, true);
        strategy.setWeight(legacyAuxKey, 9e24);

        vm.expectRevert(IFlow.NOT_ABLE_TO_ALLOCATE.selector);
        vm.prank(allocator);
        flow.allocate(ids, scaled);

        strategy.setCanAllocate(allocatorKey, allocator, true);
        vm.prank(allocator);
        flow.allocate(ids, scaled);

        bytes32 commit = keccak256(abi.encode(ids, scaled));
        assertEq(flow.getAllocationCommitment(address(strategy), allocatorKey), commit);
        assertEq(flow.getAllocationCommitment(address(strategy), legacyAuxKey), bytes32(0));
    }

    function test_allocate_legacyActionSelector_notExposed() public {
        bytes32 id = bytes32(uint256(1));
        _addRecipient(id, address(0x111));

        LegacyAllocationAction[] memory actions = new LegacyAllocationAction[](1);
        actions[0] = LegacyAllocationAction({
            strategy: address(strategy),
            allocationData: abi.encode(uint256(7)),
            prevState: ""
        });

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        (bool success,) = address(flow).call(
            abi.encodeWithSignature(
                "allocate((address,bytes,bytes)[],bytes32[],uint32[],(address,bytes)[])",
                actions,
                ids,
                scaled,
                _emptyChildSyncs()
            )
        );

        assertFalse(success);
    }
}
