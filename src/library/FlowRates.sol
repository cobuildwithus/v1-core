// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { FlowProtocolConstants } from "./FlowProtocolConstants.sol";

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library FlowRates {
    using SuperTokenV1Library for ISuperToken;

    /**
     * @notice Calculates the distribution-pool and manager-reward flow-rate split
     * @param _flowRate The desired flow rate for the flow contract
     * @return distributionFlowRate The distribution pool flow rate
     * @return managerRewardFlowRate The manager reward pool flow rate
     */
    function calculateFlowRates(
        FlowTypes.Config storage cfg,
        int96 _flowRate
    ) external view returns (int96 distributionFlowRate, int96 managerRewardFlowRate) {
        if (_flowRate < 0) revert IFlow.FLOW_RATE_NEGATIVE();
        uint32 managerRewardPpm = cfg.managerRewardPool == address(0) ? 0 : cfg.managerRewardPoolFlowRatePpm;
        int256 managerRewardFlowRateShare = SafeCast.toInt256(
            _scaleAmountByPpm(SafeCast.toUint256(_flowRate), managerRewardPpm)
        );

        if (managerRewardFlowRateShare > type(int96).max) revert IFlow.FLOW_RATE_TOO_HIGH();

        managerRewardFlowRate = int96(managerRewardFlowRateShare);
        distributionFlowRate = _flowRate - managerRewardFlowRate;
    }

    /**
     * @notice Retrieves the actual flow rate for the Flow contract
     * @param flowAddress The address of the flow contract
     * @return actualFlowRate The actual flow rate for the Flow contract
     */
    function getActualFlowRate(FlowTypes.Config storage cfg, address flowAddress) public view returns (int96) {
        int96 managerRewardFlowRate = cfg.managerRewardPool == address(0)
            ? int96(0)
            : cfg.superToken.getFlowRate(flowAddress, cfg.managerRewardPool);
        return managerRewardFlowRate + cfg.superToken.getFlowDistributionFlowRate(flowAddress, cfg.distributionPool);
    }

    /**
     * @notice Retrieves the current flow rate to the manager reward pool
     * @param flowAddress The address of the flow contract
     * @return flowRate The current flow rate to the manager reward pool
     */
    function getManagerRewardPoolFlowRate(
        FlowTypes.Config storage cfg,
        address flowAddress
    ) external view returns (int96 flowRate) {
        if (cfg.managerRewardPool == address(0)) return 0;
        flowRate = cfg.superToken.getFlowRate(flowAddress, cfg.managerRewardPool);
    }

    /**
     * @notice Retrieves the flow rate for a specific member in the pool
     * @param memberAddr The address of the member
     * @return flowRate The flow rate for the member
     */
    function getMemberFlowRate(FlowTypes.Config storage cfg, address memberAddr) public view returns (int96 flowRate) {
        flowRate = cfg.distributionPool.getMemberFlowRate(memberAddr);
    }

    /**
     * @notice Retrieves the claimable balance from the distribution pool for a member address
     * @param member The address of the member to check the claimable balance for
     * @return claimable The claimable balance from the distribution pool
     */
    // slither-disable-next-line unused-return
    function getClaimableBalance(FlowTypes.Config storage cfg, address member) external view returns (uint256) {
        (int256 distributionClaimable, ) = cfg.distributionPool.getClaimableNow(member);
        if (distributionClaimable <= 0) return 0;
        return uint256(distributionClaimable);
    }

    /**
     * @notice Retrieves the total member units for a specific member in the distribution pool
     * @param memberAddr The address of the member
     * @return totalUnits The total units for the member
     */
    function getMemberUnits(
        FlowTypes.Config storage cfg,
        address memberAddr
    ) external view returns (uint256 totalUnits) {
        totalUnits = cfg.distributionPool.getUnits(memberAddr);
    }

    /**
     * @notice Gets the net flow rate for the contract
     * @dev This function is used to get the net flow rate for the contract
     * @return The net flow rate
     */
    function getNetFlowRate(FlowTypes.Config storage cfg, address flowAddress) public view returns (int96) {
        return cfg.superToken.getNetFlowRate(flowAddress);
    }

    /**
     * @notice Multiplies an amount by a PPM-scaled share.
     * @param amount Amount to scale by `scaledPpm`.
     * @param scaledPpm Share scaled by the protocol PPM scale (`1_000_000 == 100%`).
     * @return scaledAmount Scaled share of `amount`.
     */
    function _scaleAmountByPpm(uint256 amount, uint256 scaledPpm) public pure returns (uint256) {
        return Math.mulDiv(amount, scaledPpm, FlowProtocolConstants.PPM_SCALE);
    }
}
