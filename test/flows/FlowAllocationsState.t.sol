// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FlowAllocationsStateTest is FlowAllocationsBase {
    function test_allocate_firstAllocation_setsCommitAndUnits() public {
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

        _allocateSingleKey(0, ids, scaled);

        uint128 expected1 = _units(DEFAULT_WEIGHT, scaled[0]);
        uint128 expected2 = _units(DEFAULT_WEIGHT, scaled[1]);

        assertEq(flow.distributionPool().getUnits(address(0x111)), expected1);
        assertEq(flow.distributionPool().getUnits(address(0x222)), expected2);

        bytes32 commit = keccak256(abi.encode(ids, scaled));
        assertEq(flow.getAllocationCommitment(address(strategy), 0), commit);
    }

    function test_allocate_secondAllocation_withPrevState_updatesByDelta() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory bpsA = new uint32[](2);
        bpsA[0] = 700_000;
        bpsA[1] = 300_000;

        _allocateSingleKey(0, ids, bpsA);

        uint32[] memory bpsB = new uint32[](2);
        bpsB[0] = 200_000;
        bpsB[1] = 800_000;

        _allocateSingleKey(0, ids, bpsB);

        uint128 expected1 = _units(DEFAULT_WEIGHT, bpsB[0]);
        uint128 expected2 = _units(DEFAULT_WEIGHT, bpsB[1]);

        assertEq(flow.distributionPool().getUnits(address(0x111)), expected1);
        assertEq(flow.distributionPool().getUnits(address(0x222)), expected2);
    }

    function test_allocate_multiKeySingleStrategy_accumulatesUnitsAcrossCalls() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        _addRecipient(id1, address(0x111));
        _addRecipient(id2, address(0x222));

        uint256 keyA = 10;
        uint256 keyB = 11;

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 600_000;
        scaled[1] = 400_000;

        _allocateSingleKey(keyA, ids, scaled);
        _allocateSingleKey(keyB, ids, scaled);

        uint128 expected1 = _units(DEFAULT_WEIGHT, scaled[0]) + _units(DEFAULT_WEIGHT, scaled[0]);
        uint128 expected2 = _units(DEFAULT_WEIGHT, scaled[1]) + _units(DEFAULT_WEIGHT, scaled[1]);
        assertEq(flow.distributionPool().getUnits(address(0x111)), expected1);
        assertEq(flow.distributionPool().getUnits(address(0x222)), expected2);

        bytes32 commit = keccak256(abi.encode(ids, scaled));
        assertEq(flow.getAllocationCommitment(address(strategy), keyA), commit);
        assertEq(flow.getAllocationCommitment(address(strategy), keyB), commit);
    }

    function test_initialize_revertsWhenMultipleStrategiesConfigured() public {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](2);
        strategies[0] = IAllocationStrategy(address(strategy));
        strategies[1] = IAllocationStrategy(address(0xBEEF));

        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));

        vm.expectRevert(abi.encodeWithSelector(IFlow.FLOW_REQUIRES_SINGLE_STRATEGY.selector, 2));
        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            flowParams,
            flowMetadata,
            strategies
        );
    }

    function test_allocate_firstCommitForKey_doesNotApplyLegacySubtraction() public {
        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);

        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        uint256 allocatorKey = _allocatorKey();
        strategy.setWeight(allocatorKey, 623);
        strategy.setCanAllocate(allocatorKey, allocator, true);
        bytes32[] memory seedIds = new bytes32[](1);
        seedIds[0] = id1;
        uint32[] memory seedBps = new uint32[](1);
        seedBps[0] = 1_000_000;
        bytes[][] memory seedAllocationData = _defaultAllocationDataForKey(allocatorKey);
        bytes[][] memory seedPrevStates = _buildEmptyPrevStates(seedAllocationData);
        vm.prank(allocator);
        flow.allocate(seedIds, seedBps);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 500_000;
        scaled[1] = 500_000;

        _allocateSingleKey(55, ids, scaled);

        uint128 expected = _units(DEFAULT_WEIGHT, 500_000);
        assertEq(flow.distributionPool().getUnits(r1), expected);
        assertEq(flow.distributionPool().getUnits(r2), expected);
        assertTrue(flow.getAllocationCommitment(address(strategy), 55) != bytes32(0));
    }
}
