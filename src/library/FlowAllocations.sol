// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow, IFlowEvents } from "../interfaces/IFlow.sol";
import { FlowPools } from "./FlowPools.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { AllocationCommitment } from "./AllocationCommitment.sol";
import { AllocationSnapshot } from "./AllocationSnapshot.sol";
import { FlowUnitMath } from "./FlowUnitMath.sol";

library FlowAllocations {
    uint8 internal constant SNAPSHOT_VERSION_V1 = 1;

    /**
     * @notice Checks that the recipients and allocationsPpm are valid
     * @param recipientIds The recipientIds targeted by this allocation update.
     * @param allocationsPpm Allocation split in 1e6-scale (`1_000_000 == 100%`).
     */
    function validateAllocations(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        bytes32[] calldata recipientIds,
        uint32[] calldata allocationsPpm
    ) public view {
        _assertSortedUnique(recipientIds);

        // recipientIds & allocationsPpm must be equal length
        if (recipientIds.length != allocationsPpm.length) {
            revert IFlow.RECIPIENTS_ALLOCATIONS_MISMATCH(recipientIds.length, allocationsPpm.length);
        }

        uint256 sum = 0;

        // ensure recipients exist and allocations are > 0
        for (uint256 i = 0; i < recipientIds.length; i++) {
            bytes32 recipientId = recipientIds[i];
            if (recipients.recipients[recipientId].recipient == address(0)) revert IFlow.INVALID_RECIPIENT_ID();
            if (recipients.recipients[recipientId].isRemoved) revert IFlow.NOT_APPROVED_RECIPIENT();
            if (allocationsPpm[i] == 0) revert IFlow.ALLOCATION_MUST_BE_POSITIVE();
            sum += allocationsPpm[i];
        }

        if (sum != cfg.ppmScale) revert IFlow.INVALID_SCALED_SUM();
    }

    /**
     * @dev Unchecked apply path for memory arrays.
     * Caller must enforce recipient activity and allocation-sum invariants for new allocations.
     * This function validates previous-state commitment continuity only.
     */
    function applyAllocationWithPreviousStateMemoryUnchecked(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        address strategy,
        uint256 allocationKey,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationScaled,
        uint256 prevWeight,
        bytes32[] memory newRecipientIds,
        uint32[] memory newAllocationScaled
    ) public {
        uint256 allocationScale = cfg.ppmScale;
        uint256 newWeight = IAllocationStrategy(strategy).currentWeight(allocationKey);

        // New inputs must be strictly sorted and unique for canonical hashing and linear merge
        _assertSortedUniqueMemoryNonEmpty(newRecipientIds);

        // --- determine prior state ---
        bytes32 oldCommit = alloc.allocCommit[strategy][allocationKey];
        uint256 oldWeightPlusOne = alloc.allocWeightPlusOne[strategy][allocationKey];
        bool isBrandNewKey = oldCommit == bytes32(0);

        if (isBrandNewKey) {
            if (prevRecipientIds.length != 0 || prevAllocationScaled.length != 0 || prevWeight != 0) {
                revert IFlow.INVALID_PREV_ALLOCATION();
            }
        } else {
            if (AllocationCommitment.hashMemory(prevRecipientIds, prevAllocationScaled) != oldCommit) {
                revert IFlow.INVALID_PREV_ALLOCATION();
            }
            if (oldWeightPlusOne == 0) revert IFlow.INVALID_PREV_ALLOCATION();
        }

        // --- assemble old & new unit pairs ---
        _PairUnits[] memory oldPairs;
        if (oldCommit != bytes32(0)) {
            oldPairs = _pairsUnitsFromComputed(prevRecipientIds, prevAllocationScaled, prevWeight, allocationScale);
        } else {
            oldPairs = new _PairUnits[](0);
        }
        _PairUnits[] memory newPairs = _pairsUnitsFromComputed(
            newRecipientIds,
            newAllocationScaled,
            newWeight,
            allocationScale
        );
        bytes32 newCommit = AllocationCommitment.hashMemory(newRecipientIds, newAllocationScaled);
        bytes memory packedSnapshot = new bytes(0);
        if (newCommit != oldCommit) {
            packedSnapshot = AllocationSnapshot.encodeMemory(recipients, newRecipientIds, newAllocationScaled);
            alloc.allocSnapshotPacked[strategy][allocationKey] = packedSnapshot;
        }

        _applyAllocationPairs(
            cfg,
            recipients,
            alloc,
            strategy,
            allocationKey,
            newWeight,
            oldCommit,
            oldPairs,
            newPairs,
            newCommit
        );
        emit IFlowEvents.AllocationCommitted(strategy, allocationKey, newCommit, newWeight);
        if (newCommit != oldCommit) {
            emit IFlowEvents.AllocationSnapshotUpdated(
                strategy,
                allocationKey,
                newCommit,
                newWeight,
                SNAPSHOT_VERSION_V1,
                packedSnapshot
            );
        }
    }

    // ============ Internal helpers ============
    struct _PairUnits {
        bytes32 id;
        uint128 units;
    }

    struct _MergePairCursor {
        bytes32 recipientIdCurrent;
        uint128 oldUnits;
        uint128 newUnits;
    }

    // slither-disable-next-line too-many-lines
    function _applyAllocationPairs(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        address strategy,
        uint256 allocationKey,
        uint256 newWeight,
        bytes32 oldCommit,
        _PairUnits[] memory oldPairs,
        _PairUnits[] memory newPairs,
        bytes32 commit
    ) internal {
        uint256 oldIndex = 0;
        uint256 newIndex = 0;
        while (oldIndex < oldPairs.length || newIndex < newPairs.length) {
            _MergePairCursor memory cursor;

            if (
                newIndex >= newPairs.length ||
                (oldIndex < oldPairs.length && oldPairs[oldIndex].id < newPairs[newIndex].id)
            ) {
                cursor.recipientIdCurrent = oldPairs[oldIndex].id;
                cursor.oldUnits = oldPairs[oldIndex].units;
                cursor.newUnits = 0;
                unchecked {
                    ++oldIndex;
                }
            } else if (
                oldIndex >= oldPairs.length ||
                (newIndex < newPairs.length && newPairs[newIndex].id < oldPairs[oldIndex].id)
            ) {
                cursor.recipientIdCurrent = newPairs[newIndex].id;
                cursor.oldUnits = 0;
                cursor.newUnits = newPairs[newIndex].units;
                unchecked {
                    ++newIndex;
                }
            } else {
                cursor.recipientIdCurrent = oldPairs[oldIndex].id;
                cursor.oldUnits = oldPairs[oldIndex].units;
                cursor.newUnits = newPairs[newIndex].units;
                unchecked {
                    ++oldIndex;
                    ++newIndex;
                }
            }

            FlowTypes.FlowRecipient storage recipient = recipients.recipients[cursor.recipientIdCurrent];
            address recipientAddress = recipient.recipient;
            if (recipientAddress == address(0) || recipient.isRemoved) {
                continue;
            }

            int256 delta = int256(uint256(cursor.newUnits)) - int256(uint256(cursor.oldUnits));
            if (delta == 0) continue;

            uint128 current = cfg.distributionPool.getUnits(recipientAddress);
            uint128 target;
            if (delta < 0) {
                uint256 dec = uint256(-delta);
                target = dec >= current ? 0 : current - uint128(dec);
            } else {
                uint256 sum = uint256(current) + uint256(delta);
                if (sum > type(uint128).max) revert IFlow.OVERFLOW();
                target = uint128(sum);
            }

            if (target != current) {
                FlowPools.updateDistributionMemberUnits(cfg, recipientAddress, target);
            }
        }

        if (commit != oldCommit) {
            alloc.allocCommit[strategy][allocationKey] = commit;
        }
        uint256 newWeightPlusOne = _weightToPlusOne(newWeight);
        uint256 oldWeightPlusOne = alloc.allocWeightPlusOne[strategy][allocationKey];
        if (newWeightPlusOne != oldWeightPlusOne) {
            alloc.allocWeightPlusOne[strategy][allocationKey] = newWeightPlusOne;
        }
    }

    function _assertSortedUnique(bytes32[] calldata ids) internal pure {
        if (ids.length == 0) revert IFlow.TOO_FEW_RECIPIENTS();
        bytes32 prev = ids[0];
        for (uint256 i = 1; i < ids.length; ++i) {
            bytes32 cur = ids[i];
            if (cur <= prev) revert IFlow.NOT_SORTED_OR_DUPLICATE();
            prev = cur;
        }
    }

    function _assertSortedUniqueMemoryNonEmpty(bytes32[] memory ids) internal pure {
        if (ids.length == 0) revert IFlow.TOO_FEW_RECIPIENTS();
        bytes32 prev = ids[0];
        for (uint256 i = 1; i < ids.length; ++i) {
            bytes32 cur = ids[i];
            if (cur <= prev) revert IFlow.NOT_SORTED_OR_DUPLICATE();
            prev = cur;
        }
    }

    function _pairsUnitsFromComputed(
        bytes32[] memory ids,
        uint32[] memory allocationScaled,
        uint256 weight,
        uint256 allocationScale
    ) internal pure returns (_PairUnits[] memory pairs) {
        if (ids.length != allocationScaled.length) revert IFlow.ARRAY_LENGTH_MISMATCH();
        pairs = new _PairUnits[](ids.length);
        for (uint256 i; i < ids.length; ) {
            pairs[i] = _PairUnits({ id: ids[i], units: _computedUnits(weight, allocationScaled[i], allocationScale) });
            unchecked {
                ++i;
            }
        }
    }

    function _computedUnits(
        uint256 weight,
        uint32 allocationScaled,
        uint256 allocationScale
    ) internal pure returns (uint128) {
        uint256 units = FlowUnitMath.poolUnitsFromScaledAllocation(weight, allocationScaled, allocationScale);
        if (units > type(uint128).max) revert IFlow.OVERFLOW();
        return uint128(units);
    }

    function _weightToPlusOne(uint256 weight) private pure returns (uint256) {
        if (weight == type(uint256).max) revert IFlow.OVERFLOW();
        unchecked {
            return weight + 1;
        }
    }
}
