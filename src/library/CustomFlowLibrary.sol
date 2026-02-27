// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow, ICustomFlow, IFlowEvents } from "../interfaces/IFlow.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";

library CustomFlowLibrary {
    /**
     * @notice Deploys a new Flow contract as a recipient
     * @dev This function overrides the base _deployFlowRecipient to use CustomFlow-specific initialization
     * @param recipientId The ID of the recipient. Must be unique and not already in use.
     * @param metadata The recipient's metadata like title, description, etc.
     * @param recipientAdmin The recipient-admin authority for the new contract
     * @param flowOperator The flow-rate operations authority for the new contract
     * @param sweeper The sweep authority for the new contract
     * @param managerRewardPool The address of the manager reward pool for the new contract
     * @param managerRewardPoolFlowRatePpm The manager reward flow share for the child in 1e6-scale.
     * @param strategies The allocation strategies to use.
     * @return address The address of the newly created Flow contract
     */
    function deployFlowRecipient(
        FlowTypes.Config storage cfg,
        bytes32 recipientId,
        FlowTypes.RecipientMetadata calldata metadata,
        address recipientAdmin,
        address flowOperator,
        address sweeper,
        address managerRewardPool,
        uint32 managerRewardPoolFlowRatePpm,
        IAllocationStrategy[] calldata strategies
    ) public returns (address) {
        address flowImplementation = cfg.flowImplementation;
        if (flowImplementation.code.length == 0) revert IFlow.NOT_A_CONTRACT(flowImplementation);

        address recipient = Clones.clone(flowImplementation);
        address strategy = strategies.length == 0 ? address(0) : address(strategies[0]);
        emit IFlowEvents.ChildFlowDeployed(
            recipientId,
            recipient,
            strategy,
            recipientAdmin,
            flowOperator,
            sweeper,
            managerRewardPool
        );

        ICustomFlow(recipient).initialize({
            superToken: address(cfg.superToken),
            flowImplementation: flowImplementation,
            recipientAdmin: recipientAdmin,
            flowOperator: flowOperator,
            sweeper: sweeper,
            managerRewardPool: managerRewardPool,
            allocationPipeline: address(0),
            parent: address(this),
            flowParams: IFlow.FlowParams({ managerRewardPoolFlowRatePpm: managerRewardPoolFlowRatePpm }),
            metadata: metadata,
            strategies: strategies
        });

        return recipient;
    }
}
