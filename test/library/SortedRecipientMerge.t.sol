// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { SortedRecipientMerge } from "src/library/SortedRecipientMerge.sol";

contract SortedRecipientMergeTest is Test {
    uint256 internal constant _POOL_SIZE = 12;
    uint16 internal constant _POOL_MASK = uint16((uint256(1) << _POOL_SIZE) - 1);

    SortedRecipientMergeHarness internal harness;

    function setUp() public {
        harness = new SortedRecipientMergeHarness();
    }

    function test_traverse_requireSorted_emptyArrays() public view {
        bytes32[] memory empty = new bytes32[](0);
        (bool valid, bytes32[] memory merged, uint8[] memory membership) =
            harness.traverse(empty, empty, SortedRecipientMerge.Precondition.RequireSorted);
        assertTrue(valid);
        assertEq(merged.length, 0);
        assertEq(membership.length, 0);
    }

    function test_traverse_assumeSorted_doesNotValidateOrderOrDuplicates() public view {
        bytes32[] memory oldIds = new bytes32[](2);
        oldIds[0] = bytes32(uint256(2));
        oldIds[1] = bytes32(uint256(1)); // intentionally unsorted

        bytes32[] memory newIds = new bytes32[](2);
        newIds[0] = bytes32(uint256(3));
        newIds[1] = bytes32(uint256(3)); // intentionally duplicate

        (bool valid,,) = harness.traverse(oldIds, newIds, SortedRecipientMerge.Precondition.AssumeSorted);
        assertTrue(valid);
    }

    function testFuzz_traverse_requireSorted_hitsUnionExactlyOnce(
        uint16 oldMaskSeed,
        uint16 newMaskSeed
    ) public view {
        uint16 oldMask = oldMaskSeed & _POOL_MASK;
        uint16 newMask = newMaskSeed & _POOL_MASK;

        bytes32[] memory oldIds = _selectSortedIds(oldMask);
        bytes32[] memory newIds = _selectSortedIds(newMask);

        (bool valid, bytes32[] memory merged, uint8[] memory membership) =
            harness.traverse(oldIds, newIds, SortedRecipientMerge.Precondition.RequireSorted);
        assertTrue(valid);

        uint16 unionMask = oldMask | newMask;
        uint256 expectedCount = _countBits(unionMask);
        assertEq(merged.length, expectedCount);
        assertEq(membership.length, expectedCount);

        uint256 cursor;
        for (uint256 i = 0; i < _POOL_SIZE; ) {
            uint16 bit = uint16(1) << i;
            bool inOld = (oldMask & bit) != 0;
            bool inNew = (newMask & bit) != 0;
            if (inOld || inNew) {
                assertEq(merged[cursor], _poolId(i));
                uint8 expectedMembership;
                if (inOld) expectedMembership |= 1;
                if (inNew) expectedMembership |= 2;
                assertEq(membership[cursor], expectedMembership);
                unchecked {
                    ++cursor;
                }
            }
            unchecked {
                ++i;
            }
        }

        for (uint256 i = 1; i < merged.length; ) {
            assertGt(uint256(merged[i]), uint256(merged[i - 1]));
            unchecked {
                ++i;
            }
        }
    }

    function testFuzz_init_requireSorted_rejectsUnsortedInputs(
        uint16 oldMaskSeed,
        uint16 newMaskSeed
    ) public view {
        uint16 oldMask = oldMaskSeed & _POOL_MASK;
        uint16 newMask = newMaskSeed & _POOL_MASK;

        bytes32[] memory sortedOld = _selectSortedIds(oldMask);
        bytes32[] memory sortedNew = _selectSortedIds(newMask);

        if (sortedOld.length > 1) {
            bytes32[] memory unsortedOld = _swapFirstTwo(sortedOld);
            assertFalse(harness.initRequireSorted(unsortedOld, sortedNew));
        }

        if (sortedNew.length > 1) {
            bytes32[] memory unsortedNew = _swapFirstTwo(sortedNew);
            assertFalse(harness.initRequireSorted(sortedOld, unsortedNew));
        }
    }

    function testFuzz_init_requireSorted_rejectsDuplicates(
        uint16 oldMaskSeed,
        uint16 newMaskSeed
    ) public view {
        uint16 oldMask = oldMaskSeed & _POOL_MASK;
        uint16 newMask = newMaskSeed & _POOL_MASK;

        bytes32[] memory sortedOld = _selectSortedIds(oldMask);
        bytes32[] memory sortedNew = _selectSortedIds(newMask);

        bytes32[] memory duplicateOld = _appendDuplicate(sortedOld);
        assertFalse(harness.initRequireSorted(duplicateOld, sortedNew));

        bytes32[] memory duplicateNew = _appendDuplicate(sortedNew);
        assertFalse(harness.initRequireSorted(sortedOld, duplicateNew));
    }

    function _selectSortedIds(uint16 mask) internal pure returns (bytes32[] memory selected) {
        uint256 count = _countBits(mask);
        selected = new bytes32[](count);
        uint256 cursor;
        for (uint256 i = 0; i < _POOL_SIZE; ) {
            if ((mask & (uint16(1) << i)) != 0) {
                selected[cursor] = _poolId(i);
                unchecked {
                    ++cursor;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _swapFirstTwo(bytes32[] memory ids) internal pure returns (bytes32[] memory swapped) {
        swapped = new bytes32[](ids.length);
        for (uint256 i = 0; i < ids.length; ) {
            swapped[i] = ids[i];
            unchecked {
                ++i;
            }
        }
        bytes32 first = swapped[0];
        swapped[0] = swapped[1];
        swapped[1] = first;
    }

    function _appendDuplicate(bytes32[] memory ids) internal pure returns (bytes32[] memory duplicate) {
        if (ids.length == 0) {
            duplicate = new bytes32[](2);
            duplicate[0] = bytes32(uint256(1));
            duplicate[1] = bytes32(uint256(1));
            return duplicate;
        }

        duplicate = new bytes32[](ids.length + 1);
        for (uint256 i = 0; i < ids.length; ) {
            duplicate[i] = ids[i];
            unchecked {
                ++i;
            }
        }
        duplicate[ids.length] = ids[ids.length - 1];
    }

    function _countBits(uint16 x) internal pure returns (uint256 count) {
        while (x != 0) {
            x &= x - 1;
            unchecked {
                ++count;
            }
        }
    }

    function _poolId(uint256 index) internal pure returns (bytes32) {
        return bytes32(index + 1);
    }
}

contract SortedRecipientMergeHarness {
    function initRequireSorted(bytes32[] calldata oldIds, bytes32[] calldata newIds) external pure returns (bool valid) {
        (, valid) = SortedRecipientMerge.init(oldIds, newIds, SortedRecipientMerge.Precondition.RequireSorted);
    }

    function traverse(
        bytes32[] calldata oldIds,
        bytes32[] calldata newIds,
        SortedRecipientMerge.Precondition precondition
    ) external pure returns (bool valid, bytes32[] memory merged, uint8[] memory membership) {
        (SortedRecipientMerge.Cursor memory cursor, bool initValid) = SortedRecipientMerge.init(oldIds, newIds, precondition);
        if (!initValid) return (false, new bytes32[](0), new uint8[](0));

        uint256 oldLen = oldIds.length;
        uint256 newLen = newIds.length;
        uint256 maxLen = oldLen + newLen;
        bytes32[] memory mergedTmp = new bytes32[](maxLen);
        uint8[] memory membershipTmp = new uint8[](maxLen);
        uint256 count;

        while (SortedRecipientMerge.hasNext(cursor, oldLen, newLen)) {
            (SortedRecipientMerge.Step memory step, SortedRecipientMerge.Cursor memory nextCursor) =
                SortedRecipientMerge.next(oldIds, newIds, cursor);
            cursor = nextCursor;

            mergedTmp[count] = step.recipientId;
            uint8 stepMembership;
            if (step.hasOld) stepMembership |= 1;
            if (step.hasNew) stepMembership |= 2;
            membershipTmp[count] = stepMembership;
            unchecked {
                ++count;
            }
        }

        merged = new bytes32[](count);
        membership = new uint8[](count);
        for (uint256 i = 0; i < count; ) {
            merged[i] = mergedTmp[i];
            membership[i] = membershipTmp[i];
            unchecked {
                ++i;
            }
        }
        return (true, merged, membership);
    }
}
