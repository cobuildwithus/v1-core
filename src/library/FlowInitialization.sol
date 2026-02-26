// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { FlowProtocolConstants } from "./FlowProtocolConstants.sol";

import { PoolConfig, SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

library FlowInitialization {
    using SuperTokenV1Library for ISuperToken;
    uint32 public constant ppmScale = FlowProtocolConstants.PPM_SCALE;

    /**
     * @notice Checks the initialization parameters for the Flow contract
     * @param cfg The config storage of the Flow contract
     * @param alloc The allocation storage of the Flow contract
     * @param pipeline The pipeline storage of the Flow contract
     * @param initConfig The flow initialization config
     * @param _strategies The allocation strategies to use.
     */
    function checkAndSetInitializationParams(
        FlowTypes.Config storage cfg,
        FlowTypes.AllocationState storage alloc,
        FlowTypes.PipelineState storage pipeline,
        IFlow.FlowInitConfig memory initConfig,
        IAllocationStrategy[] calldata _strategies
    ) public {
        if (initConfig.flowImplementation == address(0)) revert IFlow.ADDRESS_ZERO();
        if (initConfig.recipientAdmin == address(0)) revert IFlow.ADDRESS_ZERO();
        if (initConfig.superToken == address(0)) revert IFlow.ADDRESS_ZERO();
        if (bytes(initConfig.metadata.title).length == 0) revert IFlow.INVALID_METADATA();
        if (bytes(initConfig.metadata.description).length == 0) revert IFlow.INVALID_METADATA();
        if (bytes(initConfig.metadata.image).length == 0) revert IFlow.INVALID_METADATA();
        if (initConfig.flowParams.managerRewardPoolFlowRatePpm > ppmScale) revert IFlow.INVALID_RATE_PPM();
        if (initConfig.managerRewardPool == address(0) && initConfig.flowParams.managerRewardPoolFlowRatePpm > 0) {
            revert IFlow.ADDRESS_ZERO();
        }
        uint256 strategyCount = _strategies.length;
        if (strategyCount != 1) revert IFlow.FLOW_REQUIRES_SINGLE_STRATEGY(strategyCount);
        if (address(_strategies[0]) == address(0)) revert IFlow.ADDRESS_ZERO();
        // Set the flow configuration
        cfg.managerRewardPoolFlowRatePpm = initConfig.flowParams.managerRewardPoolFlowRatePpm;
        cfg.flowImplementation = initConfig.flowImplementation;
        cfg.recipientAdmin = initConfig.recipientAdmin;
        cfg.parent = initConfig.parent;
        cfg.managerRewardPool = initConfig.managerRewardPool;
        alloc.strategies = _strategies;

        PoolConfig memory poolConfig = PoolConfig({
            transferabilityForUnitsOwner: false,
            distributionFromAnyAddress: false
        });

        cfg.superToken = ISuperToken(initConfig.superToken);
        cfg.distributionPool = cfg.superToken.createPool(address(this), poolConfig);

        cfg.ppmScale = ppmScale;
        cfg.connectPoolAdmin = initConfig.connectPoolAdmin;
        address allocationPipeline = initConfig.allocationPipeline;
        if (allocationPipeline != address(0)) {
            if (allocationPipeline.code.length == 0) revert IFlow.INVALID_ALLOCATION_PIPELINE(allocationPipeline);
        }
        pipeline.allocationPipeline = allocationPipeline;

        // Set the metadata
        cfg.metadata = initConfig.metadata;
    }
}
