// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

library SortedRecipientMerge {
    enum Precondition {
        AssumeSorted,
        RequireSorted
    }

    struct Cursor {
        uint256 oldIndex;
        uint256 newIndex;
    }

    struct Step {
        bytes32 recipientId;
        uint256 oldIndex;
        uint256 newIndex;
        bool hasOld;
        bool hasNew;
    }

    function init(
        bytes32[] calldata oldIds,
        bytes32[] calldata newIds,
        Precondition precondition
    ) internal pure returns (Cursor memory cursor, bool valid) {
        if (precondition != Precondition.RequireSorted) return (cursor, true);
        if (!_isStrictlySortedUnique(oldIds) || !_isStrictlySortedUnique(newIds)) return (cursor, false);
        return (cursor, true);
    }

    function hasNext(Cursor memory cursor, uint256 oldLength, uint256 newLength) internal pure returns (bool) {
        return cursor.oldIndex < oldLength || cursor.newIndex < newLength;
    }

    function next(
        bytes32[] calldata oldIds,
        bytes32[] calldata newIds,
        Cursor memory cursor
    ) internal pure returns (Step memory step, Cursor memory nextCursor) {
        uint256 oldIndex = cursor.oldIndex;
        uint256 newIndex = cursor.newIndex;
        uint256 oldLength = oldIds.length;
        uint256 newLength = newIds.length;
        nextCursor = cursor;

        if (newIndex >= newLength || (oldIndex < oldLength && oldIds[oldIndex] < newIds[newIndex])) {
            step.recipientId = oldIds[oldIndex];
            step.oldIndex = oldIndex;
            step.hasOld = true;
            unchecked {
                nextCursor.oldIndex = oldIndex + 1;
            }
            return (step, nextCursor);
        }

        if (oldIndex >= oldLength || newIds[newIndex] < oldIds[oldIndex]) {
            step.recipientId = newIds[newIndex];
            step.newIndex = newIndex;
            step.hasNew = true;
            unchecked {
                nextCursor.newIndex = newIndex + 1;
            }
            return (step, nextCursor);
        }

        step.recipientId = oldIds[oldIndex];
        step.oldIndex = oldIndex;
        step.newIndex = newIndex;
        step.hasOld = true;
        step.hasNew = true;
        unchecked {
            nextCursor.oldIndex = oldIndex + 1;
            nextCursor.newIndex = newIndex + 1;
        }
    }

    function _isStrictlySortedUnique(bytes32[] calldata ids) private pure returns (bool) {
        uint256 length = ids.length;
        if (length < 2) return true;

        bytes32 prev = ids[0];
        for (uint256 i = 1; i < length; ) {
            bytes32 current = ids[i];
            if (current <= prev) return false;
            prev = current;
            unchecked {
                ++i;
            }
        }
        return true;
    }
}
