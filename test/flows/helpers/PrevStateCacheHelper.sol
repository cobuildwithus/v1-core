// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { ICustomFlow } from "src/interfaces/IFlow.sol";
import { Test } from "forge-std/Test.sol";

abstract contract PrevStateCacheHelper is Test {
    error ALLOCATION_LENGTH_MISMATCH();

    struct LegacyChildSyncRequestCompact {
        address budgetTreasury;
        bytes prevAllocationState;
    }

    struct PrevStateCacheItem {
        bool exists;
        bytes32[] recipientIds;
        uint32[] scaled;
    }

    struct _AllocateRequest {
        address allocator;
        bytes[][] allocationData;
        address strategyAddr;
        address flowAddr;
        bytes32[] recipientIds;
        uint32[] scaled;
    }

    mapping(address => mapping(uint256 => PrevStateCacheItem)) internal _prevAllocationState;

    function _countPrevStateItems(
        bytes[][] memory allocationData,
        bytes[][] memory states
    ) private pure returns (uint256 stateCount) {
        if (allocationData.length != states.length) revert ALLOCATION_LENGTH_MISMATCH();

        for (uint256 i = 0; i < allocationData.length; i++) {
            if (allocationData[i].length != states[i].length) revert ALLOCATION_LENGTH_MISMATCH();
            stateCount += allocationData[i].length;
        }
    }

    function _singlePrevAllocationState(
        bytes[][] memory allocationData,
        bytes[][] memory states
    ) internal pure returns (bytes memory prevState) {
        uint256 stateCount = _countPrevStateItems(allocationData, states);
        if (stateCount != 1) revert ALLOCATION_LENGTH_MISMATCH();
        prevState = states[0][0];
    }

    function _buildEmptyPrevStates(bytes[][] memory allocationData) internal pure returns (bytes[][] memory) {
        bytes[][] memory states = new bytes[][](allocationData.length);
        for (uint256 i = 0; i < allocationData.length; i++) {
            states[i] = new bytes[](allocationData[i].length);
        }
        return states;
    }

    function _encodePrevAllocationState(address strategyAddr, uint256 allocationKey) internal view returns (bytes memory) {
        PrevStateCacheItem storage item = _prevAllocationState[strategyAddr][allocationKey];
        if (!item.exists) return "";
        return abi.encode(item.recipientIds, item.scaled);
    }

    function _sortAllocPairs(bytes32[] memory ids, uint32[] memory scaled) internal pure {
        if (ids.length != scaled.length || ids.length < 2) return;
        _qsortPairs(ids, scaled, int256(0), int256(ids.length - 1));
    }

    function _qsortPairs(bytes32[] memory ids, uint32[] memory scaled, int256 lo, int256 hi) private pure {
        int256 i = lo;
        int256 j = hi;
        bytes32 p = ids[uint256(lo + (hi - lo) / 2)];
        while (i <= j) {
            while (ids[uint256(i)] < p) i++;
            while (ids[uint256(j)] > p) j--;
            if (i <= j) {
                (ids[uint256(i)], ids[uint256(j)]) = (ids[uint256(j)], ids[uint256(i)]);
                (scaled[uint256(i)], scaled[uint256(j)]) = (scaled[uint256(j)], scaled[uint256(i)]);
                i++;
                j--;
            }
        }
        if (lo < j) _qsortPairs(ids, scaled, lo, j);
        if (i < hi) _qsortPairs(ids, scaled, i, hi);
    }

    function _buildPrevStatesForStrategy(
        address allocator,
        bytes[][] memory allocationData,
        address strategyAddr
    ) internal view returns (bytes[][] memory) {
        bytes[][] memory states = new bytes[][](allocationData.length);
        uint256 key = IAllocationStrategy(strategyAddr).allocationKey(allocator, bytes(""));

        for (uint256 i = 0; i < allocationData.length; i++) {
            states[i] = new bytes[](allocationData[i].length);
            for (uint256 j = 0; j < allocationData[i].length; j++) {
                states[i][j] = _encodePrevAllocationState(strategyAddr, key);
            }
        }
        return states;
    }

    function _updatePrevStateCacheForStrategy(
        address allocator,
        bytes[][] memory,
        address strategyAddr,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) internal {
        uint256 key = IAllocationStrategy(strategyAddr).allocationKey(allocator, bytes(""));
        PrevStateCacheItem storage item = _prevAllocationState[strategyAddr][key];
        item.exists = true;
        item.recipientIds = recipientIds;
        item.scaled = allocationsPpm;
    }

    function _allocateWithPrevStateForStrategy(
        address allocator,
        bytes[][] memory allocationData,
        address strategyAddr,
        address flowAddr,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) internal {
        LegacyChildSyncRequestCompact[] memory childSyncs = new LegacyChildSyncRequestCompact[](0);
        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            strategyAddr,
            flowAddr,
            recipientIds,
            allocationsPpm,
            childSyncs
        );
    }

    function _allocateWithPrevStateForStrategy(
        address allocator,
        bytes[][] memory allocationData,
        address strategyAddr,
        address flowAddr,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        LegacyChildSyncRequestCompact[] memory
    ) internal {
        _runAllocate(
            _AllocateRequest({
                allocator: allocator,
                allocationData: allocationData,
                strategyAddr: strategyAddr,
                flowAddr: flowAddr,
                recipientIds: recipientIds,
                scaled: allocationsPpm
            }),
            "",
            true
        );
    }

    function _allocateWithPrevStateForStrategyExpectRevert(
        address allocator,
        bytes[][] memory allocationData,
        address strategyAddr,
        address flowAddr,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        bytes memory expectedRevert
    ) internal {
        LegacyChildSyncRequestCompact[] memory childSyncs = new LegacyChildSyncRequestCompact[](0);
        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            strategyAddr,
            flowAddr,
            recipientIds,
            allocationsPpm,
            childSyncs,
            expectedRevert
        );
    }

    function _allocateWithPrevStateForStrategyExpectRevert(
        address allocator,
        bytes[][] memory allocationData,
        address strategyAddr,
        address flowAddr,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        LegacyChildSyncRequestCompact[] memory,
        bytes memory expectedRevert
    ) internal {
        _runAllocate(
            _AllocateRequest({
                allocator: allocator,
                allocationData: allocationData,
                strategyAddr: strategyAddr,
                flowAddr: flowAddr,
                recipientIds: recipientIds,
                scaled: allocationsPpm
            }),
            expectedRevert,
            false
        );
    }

    function _runAllocate(_AllocateRequest memory req, bytes memory expectedRevert, bool updateCache) private {
        _sortAllocPairs(req.recipientIds, req.scaled);
        if (expectedRevert.length > 0) vm.expectRevert(expectedRevert);
        _prankAllocate(req.allocator, req.flowAddr, req.recipientIds, req.scaled);

        if (updateCache) {
            _updatePrevStateCacheForStrategy(req.allocator, req.allocationData, req.strategyAddr, req.recipientIds, req.scaled);
        }
    }

    function _prankAllocate(
        address allocator,
        address flowAddr,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) private {
        vm.prank(allocator);
        ICustomFlow(flowAddr).allocate(recipientIds, allocationsPpm);
    }
}
