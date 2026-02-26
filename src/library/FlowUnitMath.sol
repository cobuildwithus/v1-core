// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FlowProtocolConstants } from "./FlowProtocolConstants.sol";

library FlowUnitMath {
    function weightedAllocation(
        uint256 weight,
        uint32 allocationScaled,
        uint256 allocationScale
    ) internal pure returns (uint256) {
        return Math.mulDiv(weight, allocationScaled, allocationScale);
    }

    function poolUnitsFromScaledAllocation(
        uint256 weight,
        uint32 allocationScaled,
        uint256 allocationScale
    ) internal pure returns (uint256) {
        return weightedAllocation(weight, allocationScaled, allocationScale) / FlowProtocolConstants.UNIT_WEIGHT_SCALE;
    }

    function floorToUnitWeightScale(uint256 amount) internal pure returns (uint256) {
        return (amount / FlowProtocolConstants.UNIT_WEIGHT_SCALE) * FlowProtocolConstants.UNIT_WEIGHT_SCALE;
    }

    function effectiveAllocatedStake(
        uint256 weight,
        uint32 allocationScaled,
        uint256 allocationScale
    ) internal pure returns (uint256) {
        return floorToUnitWeightScale(weightedAllocation(weight, allocationScaled, allocationScale));
    }
}
