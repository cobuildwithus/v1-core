// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {CustomFlow} from "src/flows/CustomFlow.sol";
import {FlowAllocations} from "src/library/FlowAllocations.sol";
import {FlowPools} from "src/library/FlowPools.sol";
import {CustomFlowAllocationEngine} from "src/library/CustomFlowAllocationEngine.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract TestableCustomFlow is CustomFlow {
    using EnumerableSet for EnumerableSet.AddressSet;

    function setDistributionUnits(address member, uint128 units) external {
        FlowPools.updateDistributionMemberUnits(_cfgStorage(), member, units);
    }

    function addChildForTest(address child) external {
        _childFlowsSet().add(child);
    }

    function getAllocWeightPlusOneForTest(address strategy, uint256 allocationKey) external view returns (uint256) {
        return _allocStorage().allocWeightPlusOne[strategy][allocationKey];
    }

    function clearAllocWeightPlusOneForTest(address strategy, uint256 allocationKey) external {
        _allocStorage().allocWeightPlusOne[strategy][allocationKey] = 0;
    }

    function setAllocSnapshotPackedForTest(address strategy, uint256 allocationKey, bytes calldata packed) external {
        _allocStorage().allocSnapshotPacked[strategy][allocationKey] = packed;
    }

    function getAllocSnapshotPackedForTest(address strategy, uint256 allocationKey) external view returns (bytes memory) {
        return _allocStorage().allocSnapshotPacked[strategy][allocationKey];
    }

    function syncAllocationWithPrevStateBypassForTest(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevIds,
        uint32[] calldata prevAllocationScaled
    ) external {
        bytes32[] memory ids = prevIds;
        uint32[] memory scaled = prevAllocationScaled;
        CustomFlowAllocationEngine.applyAllocationWithPipeline(
            _cfgStorage(),
            _recipientsStorage(),
            _allocStorage(),
            _pipelineStorage(),
            strategy,
            allocationKey,
            prevWeight,
            ids,
            scaled,
            ids,
            scaled
        );
    }

    function allocateWithoutRefreshForTest(bytes32[] calldata recipientIds, uint32[] calldata allocationsPpm)
        external
        nonReentrant
    {
        FlowAllocations.validateAllocations(_cfgStorage(), _recipientsStorage(), recipientIds, allocationsPpm);

        bytes32[] memory ids = recipientIds;
        uint32[] memory scaled = allocationsPpm;
        CustomFlowAllocationEngine.processAllocationForCaller(
            _cfgStorage(),
            _recipientsStorage(),
            _allocStorage(),
            _pipelineStorage(),
            _defaultStrategyOrRevert(),
            msg.sender,
            ids,
            scaled
        );
    }
}
