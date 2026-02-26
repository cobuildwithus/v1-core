// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTestBase } from "test/flows/helpers/FlowTestBase.t.sol";
import { FlowUnitMath } from "src/library/FlowUnitMath.sol";

contract FlowAllocationsFuzzTest is FlowTestBase {
    function _units(uint256 weight, uint32 scaled) internal pure returns (uint128) {
        return uint128(FlowUnitMath.poolUnitsFromScaledAllocation(weight, scaled, 1e6));
    }

    function testFuzz_allocate_singleKey_matchesReferenceModel(
        uint32 bpsA,
        uint32 bpsB,
        uint128 weightA,
        uint128 weightB
    ) public {
        bpsA = uint32(bound(bpsA, 1, 999_999));
        bpsB = uint32(bound(bpsB, 1, 999_999));

        uint32 bpsA2 = 1_000_000 - bpsA;
        uint32 bpsB2 = 1_000_000 - bpsB;

        weightA = uint128(bound(weightA, 1e15, 1e27));
        weightB = uint128(bound(weightB, 1e15, 1e27));

        bytes32 id1 = bytes32(uint256(1));
        bytes32 id2 = bytes32(uint256(2));
        address r1 = address(0x111);
        address r2 = address(0x222);

        _addRecipient(id1, r1);
        _addRecipient(id2, r2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;

        uint32[] memory splitA = new uint32[](2);
        splitA[0] = bpsA;
        splitA[1] = bpsA2;

        uint32[] memory splitB = new uint32[](2);
        splitB[0] = bpsB;
        splitB[1] = bpsB2;

        uint256 allocatorKey = _allocatorKey();
        strategy.setWeight(allocatorKey, weightA);
        strategy.setCanAllocate(allocatorKey, allocator, true);
        bytes[][] memory allocData = _defaultAllocationDataForKey(allocatorKey);

        _allocateWithPrevStateForStrategy(allocator, allocData, address(strategy), address(flow), ids, splitA);

        uint128 modelR1A = _units(weightA, bpsA);
        uint128 modelR2A = _units(weightA, bpsA2);
        assertEq(flow.distributionPool().getUnits(r1), modelR1A);
        assertEq(flow.distributionPool().getUnits(r2), modelR2A);

        strategy.setWeight(allocatorKey, weightB);
        _allocateWithPrevStateForStrategy(allocator, allocData, address(strategy), address(flow), ids, splitB);

        uint128 modelR1B = _units(weightB, bpsB);
        uint128 modelR2B = _units(weightB, bpsB2);

        assertEq(flow.distributionPool().getUnits(r1), modelR1B);
        assertEq(flow.distributionPool().getUnits(r2), modelR2B);
    }
}
