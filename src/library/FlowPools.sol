// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { Flow } from "../Flow.sol";

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

library FlowPools {
    using SuperTokenV1Library for ISuperToken;

    /**
     * @notice Connects the flow contract to a Superfluid pool.
     * @param cfg The config storage of the Flow contract.
     * @param poolAddress The pool to connect.
     * @return success True when membership is connected.
     */
    function connectPool(FlowTypes.Config storage cfg, ISuperfluidPool poolAddress) external returns (bool success) {
        return cfg.superToken.connectPool(poolAddress);
    }

    /**
     * @notice Connects a new Flow contract to the distribution pool and initializes its member units
     * @param cfg The config storage of the Flow contract
     * @param recipient The address of the new Flow contract
     * @param defaultDistributionMemberUnits The number of units to assign in the distribution pool
     */
    function connectAndInitializeFlowRecipient(
        FlowTypes.Config storage cfg,
        address recipient,
        uint128 defaultDistributionMemberUnits
    ) public {
        // Connect the new child contract to the distribution pool
        Flow(recipient).connectPool(cfg.distributionPool);

        // Initialize member units
        if (defaultDistributionMemberUnits == 0) return;
        updateDistributionMemberUnits(cfg, recipient, defaultDistributionMemberUnits);
    }

    /**
     * @notice Sets the flow to the manager reward pool
     * @param cfg The config storage of the Flow contract
     * @param _currentManagerRewardFlowRate The current flow rate to the manager reward pool
     * @param _newManagerRewardFlowRate The new flow rate to the manager reward pool
     */
    // slither-disable-next-line unused-return
    function setFlowToManagerRewardPool(
        FlowTypes.Config storage cfg,
        int96 _currentManagerRewardFlowRate,
        int96 _newManagerRewardFlowRate
    ) public {
        if (_newManagerRewardFlowRate == _currentManagerRewardFlowRate) return;

        if (_newManagerRewardFlowRate > 0) {
            // if flow to reward pool is 0, create a flow, otherwise update the flow
            if (_currentManagerRewardFlowRate == 0) {
                // Transitioning from zero to positive requires creating the stream.
                cfg.superToken.createFlow(cfg.managerRewardPool, _newManagerRewardFlowRate);
            } else {
                cfg.superToken.updateFlow(cfg.managerRewardPool, _newManagerRewardFlowRate);
            }
        } else if (_currentManagerRewardFlowRate > 0 && _newManagerRewardFlowRate == 0) {
            // only delete if the flow rate is going to 0 and reward pool flow rate is currently > 0
            cfg.superToken.deleteFlow(address(this), cfg.managerRewardPool);
        }
    }

    /**
     * @notice Resets the flow distribution after removing a recipient
     * @dev This function should be called after removing a recipient to ensure proper flow rate distribution
     * @param cfg The config storage of the Flow contract
     * @param recipientAddress The address of the removed recipient
     */
    function removeFromPools(FlowTypes.Config storage cfg, address recipientAddress) public {
        updateDistributionMemberUnits(cfg, recipientAddress, 0);
    }

    /**
     * @notice Updates the member units in the Superfluid pool
     * @param cfg The config storage of the Flow contract
     * @param member The address of the member whose units are being updated
     * @param units The new number of units to be assigned to the member
     * @dev Reverts with UNITS_UPDATE_FAILED if the update fails
     */
    function updateDistributionMemberUnits(FlowTypes.Config storage cfg, address member, uint128 units) public {
        if (units == 0 && cfg.distributionPool.getUnits(member) == 0) return;
        bool success = cfg.distributionPool.updateMemberUnits(member, units);

        if (!success) revert IFlow.UNITS_UPDATE_FAILED();
    }

    /**
     * @notice Distributes flow rate to the distribution pool
     * @param cfg The config storage of the Flow contract
     * @param distributionFlowRate The flow rate for the distribution pool
     */
    // slither-disable-next-line unused-return
    function distributeFlowToDistributionPool(FlowTypes.Config storage cfg, int96 distributionFlowRate) public {
        cfg.superToken.distributeFlow(address(this), cfg.distributionPool, distributionFlowRate);
    }
}
