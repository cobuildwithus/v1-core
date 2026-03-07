// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow, IFlowEvents } from "../interfaces/IFlow.sol";
import { FlowPools } from "./FlowPools.sol";
import { AllocationCommitment } from "./AllocationCommitment.sol";
import { AllocationSnapshot } from "./AllocationSnapshot.sol";
import { FlowProtocolConstants } from "./FlowProtocolConstants.sol";
import { FlowUnitMath } from "./FlowUnitMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library FlowAllocations {
    uint8 internal constant SNAPSHOT_VERSION_V1 = 1;

    struct AllocationVector {
        bytes32[] recipientIds;
        uint32[] allocationsPpm;
    }

    struct PreviousAllocationData {
        AllocationVector allocation;
        uint256 weight;
    }

    struct AllocationEditRequest {
        address strategy;
        uint256 allocationKey;
        PreviousAllocationData previousAllocation;
        AllocationVector newAllocation;
        uint256 newWeight;
    }

    struct MaintenanceApplyRequest {
        address strategy;
        uint256 allocationKey;
        PreviousAllocationData storedAllocation;
        uint256 newWeight;
    }

    /**
     * @notice Checks that the recipients and allocationsPpm are valid
     * @param recipientIds The recipientIds targeted by this allocation update.
     * @param allocationsPpm Allocation split in 1e6-scale (`1_000_000 == 100%`).
     */
    function validateAllocations(
        FlowTypes.RecipientsState storage recipients,
        bytes32[] calldata recipientIds,
        uint32[] calldata allocationsPpm
    ) internal view {
        _validateAllocationVectorStructureCalldata(recipientIds, allocationsPpm);
        _assertRecipientsActiveCalldata(recipients, recipientIds);
    }

    /**
     * @dev Applies a validated allocation edit with caller-supplied previous state and new weight.
     * New recipients must be active and the allocation vector must be structurally canonical.
     */
    function applyAllocationEdit(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        AllocationEditRequest memory request
    ) internal {
        _validateAllocationVectorStructureMemory(
            request.previousAllocation.allocation.recipientIds,
            request.previousAllocation.allocation.allocationsPpm,
            true
        );
        _validateAllocationVectorStructureMemory(
            request.newAllocation.recipientIds,
            request.newAllocation.allocationsPpm,
            false
        );
        _assertRecipientsActiveMemory(recipients, request.newAllocation.recipientIds);

        _applyAllocation(
            cfg,
            recipients,
            alloc,
            request.strategy,
            request.allocationKey,
            request.previousAllocation,
            request.newAllocation,
            request.newWeight
        );
    }

    /**
     * @dev Reapplies a stored allocation composition during maintenance sync with a fresh weight.
     * Removed recipients are tolerated, but the stored allocation vector must still be structurally valid.
     */
    function applyStoredAllocationMaintenance(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        MaintenanceApplyRequest memory request
    ) internal {
        _validateAllocationVectorStructureMemory(
            request.storedAllocation.allocation.recipientIds,
            request.storedAllocation.allocation.allocationsPpm,
            false
        );

        _applyAllocation(
            cfg,
            recipients,
            alloc,
            request.strategy,
            request.allocationKey,
            request.storedAllocation,
            request.storedAllocation.allocation,
            request.newWeight
        );
    }

    function _applyAllocation(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipients,
        FlowTypes.AllocationState storage alloc,
        address strategy,
        uint256 allocationKey,
        PreviousAllocationData memory previousAllocation,
        AllocationVector memory newAllocation,
        uint256 newWeight
    ) private {
        bytes32[] memory prevRecipientIds = previousAllocation.allocation.recipientIds;
        uint32[] memory prevAllocationPpm = previousAllocation.allocation.allocationsPpm;
        bytes32[] memory newRecipientIds = newAllocation.recipientIds;
        uint32[] memory newAllocationPpm = newAllocation.allocationsPpm;
        uint256 prevWeight = previousAllocation.weight;

        bytes32 oldCommit = alloc.allocCommit[strategy][allocationKey];
        uint256 oldWeightPlusOne = alloc.allocWeightPlusOne[strategy][allocationKey];
        bool isBrandNewKey = oldCommit == bytes32(0);

        if (isBrandNewKey) {
            if (prevRecipientIds.length != 0 || prevAllocationPpm.length != 0 || prevWeight != 0) {
                revert IFlow.INVALID_PREV_ALLOCATION();
            }
        } else {
            if (oldWeightPlusOne == 0) revert IFlow.INVALID_PREV_ALLOCATION();
            unchecked {
                if (prevWeight != oldWeightPlusOne - 1) revert IFlow.INVALID_PREV_ALLOCATION();
            }
            if (AllocationCommitment.hashMemory(prevRecipientIds, prevAllocationPpm) != oldCommit) {
                revert IFlow.INVALID_PREV_ALLOCATION();
            }
        }

        // --- assemble old & new unit pairs ---
        _PairUnits[] memory oldPairs;
        if (oldCommit != bytes32(0)) {
            oldPairs = _pairsUnitsFromComputed(prevRecipientIds, prevAllocationPpm, prevWeight);
        } else {
            oldPairs = new _PairUnits[](0);
        }
        _PairUnits[] memory newPairs = _pairsUnitsFromComputed(newRecipientIds, newAllocationPpm, newWeight);
        bytes32 newCommit = AllocationCommitment.hashMemory(newRecipientIds, newAllocationPpm);
        bytes memory packedSnapshot = new bytes(0);
        if (newCommit != oldCommit) {
            packedSnapshot = AllocationSnapshot.encodeMemory(recipients, newRecipientIds, newAllocationPpm);
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

            bool isDisabled = recipients.isRecipientDisabled[recipientAddress];
            uint128 current = isDisabled
                ? recipients.savedUnitsWhenDisabled[recipientAddress]
                : cfg.distributionPool.getUnits(recipientAddress);
            uint128 target;
            if (delta < 0) {
                uint256 dec = SafeCast.toUint256(-delta);
                target = dec >= current ? 0 : current - SafeCast.toUint128(dec);
            } else {
                uint256 sum = uint256(current) + SafeCast.toUint256(delta);
                if (sum > type(uint128).max) revert IFlow.OVERFLOW();
                target = SafeCast.toUint128(sum);
            }

            if (target != current) {
                if (isDisabled) {
                    // Preserve allocator intent while recipient is gated. Actual pool units remain at zero.
                    recipients.savedUnitsWhenDisabled[recipientAddress] = target;
                } else {
                    FlowPools.updateDistributionMemberUnits(cfg, recipientAddress, target);
                }
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

    function _validateAllocationVectorStructureCalldata(
        bytes32[] calldata recipientIds,
        uint32[] calldata allocationsPpm
    ) private pure {
        _assertSortedUnique(recipientIds);

        if (recipientIds.length != allocationsPpm.length) {
            revert IFlow.RECIPIENTS_ALLOCATIONS_MISMATCH(recipientIds.length, allocationsPpm.length);
        }

        uint256 sum;
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            if (allocationsPpm[i] == 0) revert IFlow.ALLOCATION_MUST_BE_POSITIVE();
            sum += allocationsPpm[i];
        }

        if (sum != FlowProtocolConstants.PPM_SCALE) revert IFlow.INVALID_SCALED_SUM();
    }

    function _validateAllocationVectorStructureMemory(
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        bool allowEmpty
    ) private pure {
        if (recipientIds.length != allocationsPpm.length) revert IFlow.ARRAY_LENGTH_MISMATCH();
        if (recipientIds.length == 0) {
            if (allowEmpty) return;
            revert IFlow.TOO_FEW_RECIPIENTS();
        }

        _assertSortedUniqueMemoryNonEmpty(recipientIds);

        uint256 sum;
        for (uint256 i = 0; i < allocationsPpm.length; ++i) {
            if (allocationsPpm[i] == 0) revert IFlow.ALLOCATION_MUST_BE_POSITIVE();
            sum += allocationsPpm[i];
        }

        if (sum != FlowProtocolConstants.PPM_SCALE) revert IFlow.INVALID_SCALED_SUM();
    }

    function _assertRecipientsActiveCalldata(
        FlowTypes.RecipientsState storage recipients,
        bytes32[] calldata recipientIds
    ) private view {
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            _assertRecipientActive(recipients, recipientIds[i]);
        }
    }

    function _assertRecipientsActiveMemory(
        FlowTypes.RecipientsState storage recipients,
        bytes32[] memory recipientIds
    ) private view {
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            _assertRecipientActive(recipients, recipientIds[i]);
        }
    }

    function _assertRecipientActive(FlowTypes.RecipientsState storage recipients, bytes32 recipientId) private view {
        FlowTypes.FlowRecipient storage recipient = recipients.recipients[recipientId];
        if (recipient.recipient == address(0)) revert IFlow.INVALID_RECIPIENT_ID();
        if (recipient.isRemoved) revert IFlow.NOT_APPROVED_RECIPIENT();
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
        uint32[] memory allocationPpm,
        uint256 weight
    ) internal pure returns (_PairUnits[] memory pairs) {
        if (ids.length != allocationPpm.length) revert IFlow.ARRAY_LENGTH_MISMATCH();
        pairs = new _PairUnits[](ids.length);
        for (uint256 i; i < ids.length; ) {
            pairs[i] = _PairUnits({ id: ids[i], units: _computedUnits(weight, allocationPpm[i]) });
            unchecked {
                ++i;
            }
        }
    }

    function _computedUnits(uint256 weight, uint32 allocationPpm) internal pure returns (uint128) {
        uint256 units = FlowUnitMath.poolUnitsFromScaledAllocation(
            weight,
            allocationPpm,
            FlowProtocolConstants.PPM_SCALE_UINT256
        );
        if (units > type(uint128).max) revert IFlow.OVERFLOW();
        return SafeCast.toUint128(units);
    }

    function _weightToPlusOne(uint256 weight) private pure returns (uint256) {
        if (weight == type(uint256).max) revert IFlow.OVERFLOW();
        unchecked {
            return weight + 1;
        }
    }
}
