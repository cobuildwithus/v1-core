// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Flow } from "../Flow.sol";
import { ICustomFlow, IFlow } from "../interfaces/IFlow.sol";
import { FlowAllocations } from "../library/FlowAllocations.sol";
import { CustomFlowPreview } from "../library/CustomFlowPreview.sol";
import { CustomFlowLibrary } from "../library/CustomFlowLibrary.sol";
import { CustomFlowPreviousState } from "../library/CustomFlowPreviousState.sol";
import { CustomFlowAllocationEngine } from "../library/CustomFlowAllocationEngine.sol";
import { CustomFlowRuntimeHelpers } from "../library/CustomFlowRuntimeHelpers.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IAllocationPipeline } from "../interfaces/IAllocationPipeline.sol";

contract CustomFlow is ICustomFlow, Flow {
    error STALE_CLEAR_NO_COMMITMENT();
    error STALE_CLEAR_WEIGHT_NOT_ZERO(uint256 currentWeight);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _superToken,
        address _flowImplementation,
        address _recipientAdmin,
        address _flowOperator,
        address _sweeper,
        address _managerRewardPool,
        address _allocationPipeline,
        address _parent,
        FlowParams memory _flowParams,
        RecipientMetadata memory _metadata,
        IAllocationStrategy[] calldata _strategies
    ) external initializer {
        IFlow.FlowInitConfig memory initConfig = IFlow.FlowInitConfig({
            superToken: _superToken,
            flowImplementation: _flowImplementation,
            recipientAdmin: _recipientAdmin,
            managerRewardPool: _managerRewardPool,
            allocationPipeline: _allocationPipeline,
            parent: _parent,
            flowParams: _flowParams,
            metadata: _metadata
        });
        __Flow_initWithRoles(initConfig, _flowOperator, _sweeper, _strategies);
        if (_allocationPipeline != address(0)) {
            IAllocationPipeline(_allocationPipeline).validateForFlow(address(this));
        }
    }

    // slither-disable-next-line reentrancy-no-eth
    function allocate(bytes32[] calldata recipientIds, uint32[] calldata allocationsPpm) external nonReentrant {
        FlowAllocations.validateAllocations(_cfgStorage(), _recipientsStorage(), recipientIds, allocationsPpm);

        _allocateAndSync(
            _defaultStrategyOrRevert(),
            CustomFlowRuntimeHelpers.copyBytes32Calldata(recipientIds),
            CustomFlowRuntimeHelpers.copyUint32Calldata(allocationsPpm)
        );
    }

    function syncAllocation(address strategy, uint256 allocationKey) external nonReentrant {
        _requireDefaultStrategy(strategy);
        _loadAndSyncStoredAllocation(strategy, allocationKey, false);
    }

    function syncAllocationForAccount(address account) external nonReentrant {
        IAllocationStrategy defaultStrategy = _defaultStrategyOrRevert();
        uint256 allocationKey = defaultStrategy.allocationKey(account, bytes(""));
        _loadAndSyncStoredAllocation(address(defaultStrategy), allocationKey, false);
    }

    function _loadAndSyncStoredAllocation(address strategy, uint256 allocationKey, bool requireZeroWeight) internal {
        if (_allocStorage().allocCommit[strategy][allocationKey] == bytes32(0)) revert STALE_CLEAR_NO_COMMITMENT();
        (
            bytes32[] memory prevRecipientIds,
            uint32[] memory prevAllocationScaled,
            uint256 prevWeight
        ) = CustomFlowPreviousState.loadAndResolvePreviousState(
                _recipientsStorage(),
                _allocStorage(),
                strategy,
                allocationKey
            );
        _syncStoredAllocationWithPrevState(
            strategy,
            allocationKey,
            prevWeight,
            prevRecipientIds,
            prevAllocationScaled,
            requireZeroWeight
        );
    }

    // slither-disable-next-line reentrancy-no-eth
    function _allocateAndSync(
        IAllocationStrategy strategy,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) internal {
        uint128 totalUnitsBefore = _cfgStorage().distributionPool.getTotalUnits();

        CustomFlowAllocationEngine.processAllocationForCaller(
            _cfgStorage(),
            _recipientsStorage(),
            _allocStorage(),
            _pipelineStorage(),
            strategy,
            msg.sender,
            recipientIds,
            allocationsPpm
        );

        _bestEffortRefreshOutflowAfterUnitsCrossing(_cfgStorage(), totalUnitsBefore);
    }

    function clearStaleAllocation(address strategy, uint256 allocationKey) external nonReentrant {
        _requireDefaultStrategy(strategy);
        _loadAndSyncStoredAllocation(strategy, allocationKey, true);
    }

    function previewChildSyncRequirements(
        address strategy,
        uint256 allocationKey,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationScaled
    ) external view returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        _requireDefaultStrategy(strategy);
        return
            CustomFlowPreview.previewChildSyncRequirements(
                _cfgStorage(),
                _recipientsStorage(),
                _allocStorage(),
                _pipelineStorage(),
                strategy,
                allocationKey,
                newRecipientIds,
                newAllocationScaled
            );
    }

    // slither-disable-next-line reentrancy-no-eth
    function _syncStoredAllocationWithPrevState(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationScaled,
        bool requireZeroWeight
    ) internal {
        if (requireZeroWeight) {
            uint256 currentWeight = IAllocationStrategy(strategy).currentWeight(allocationKey);
            if (currentWeight != 0) revert STALE_CLEAR_WEIGHT_NOT_ZERO(currentWeight);
        }

        uint128 totalUnitsBefore = _cfgStorage().distributionPool.getTotalUnits();

        CustomFlowAllocationEngine.applyAllocationWithPipeline(
            _cfgStorage(),
            _recipientsStorage(),
            _allocStorage(),
            _pipelineStorage(),
            strategy,
            allocationKey,
            prevWeight,
            prevRecipientIds,
            prevAllocationScaled,
            prevRecipientIds,
            prevAllocationScaled
        );

        _bestEffortRefreshOutflowAfterUnitsCrossing(_cfgStorage(), totalUnitsBefore);
    }

    function _defaultStrategyOrRevert() internal view returns (IAllocationStrategy strategy) {
        strategy = CustomFlowRuntimeHelpers.defaultStrategyOrRevert(_allocStorage());
    }

    function _requireDefaultStrategy(address strategy) internal view {
        if (strategy != address(_defaultStrategyOrRevert())) {
            revert IFlow.ONLY_DEFAULT_STRATEGY_ALLOWED(strategy);
        }
    }

    /**
     * @notice Deploys a new Flow contract as a recipient
     * @dev This function is virtual to allow for different deployment strategies in derived contracts
     * @param recipientId The ID of the recipient. Must be unique and not already in use.
     * @param metadata The recipient's metadata like title, description, etc.
     * @param recipientAdmin The recipient-admin authority for the new contract
     * @param flowOperator The flow-rate operations authority for the new contract
     * @param sweeper The sweep authority for the new contract
     * @param managerRewardPool The address of the manager reward pool for the new contract
     * @param managerRewardPoolFlowRatePpm The manager reward flow-rate share for the new contract in ppm
     * @param strategies The allocation strategies to use.
     * @return recipient address The address of the newly created Flow contract
     */
    function _deployFlowRecipient(
        bytes32 recipientId,
        RecipientMetadata calldata metadata,
        address recipientAdmin,
        address flowOperator,
        address sweeper,
        address managerRewardPool,
        uint32 managerRewardPoolFlowRatePpm,
        IAllocationStrategy[] calldata strategies
    ) internal override returns (address recipient) {
        recipient = CustomFlowLibrary.deployFlowRecipient(
            _cfgStorage(),
            recipientId,
            metadata,
            recipientAdmin,
            flowOperator,
            sweeper,
            managerRewardPool,
            managerRewardPoolFlowRatePpm,
            strategies
        );
    }
}
