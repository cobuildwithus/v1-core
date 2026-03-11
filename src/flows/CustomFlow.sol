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
        IAllocationStrategy _strategy
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
        __Flow_initWithRoles(initConfig, _flowOperator, _sweeper, _strategy);
        if (_allocationPipeline != address(0)) {
            IAllocationPipeline(_allocationPipeline).validateForFlow(address(this));
        }
    }

    // slither-disable-next-line reentrancy-no-eth
    function allocate(bytes32[] calldata recipientIds, uint32[] calldata allocationsPpm) external nonReentrant {
        FlowAllocations.validateAllocations(_recipientsStorage(), recipientIds, allocationsPpm);

        _allocateAndSync(
            _defaultStrategyOrRevert(),
            CustomFlowRuntimeHelpers.copyBytes32Calldata(recipientIds),
            CustomFlowRuntimeHelpers.copyUint32Calldata(allocationsPpm)
        );
    }

    function syncAllocation(uint256 allocationKey) external nonReentrant {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        _loadAndSyncStoredAllocation(address(configuredStrategy), allocationKey, false);
    }

    function syncAllocationForAccount(address account) external nonReentrant {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        uint256 allocationKey = _allocationKeyOf(configuredStrategy, account);
        _loadAndSyncStoredAllocation(address(configuredStrategy), allocationKey, false);
    }

    function allocationKeyOf(address account) external view returns (uint256 allocationKey) {
        allocationKey = _allocationKeyOf(_defaultStrategyOrRevert(), account);
    }

    function currentWeight(uint256 allocationKey) external view returns (uint256 weight) {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        weight = configuredStrategy.currentWeight(address(this), allocationKey);
    }

    function canAllocate(uint256 allocationKey, address caller) external view returns (bool allowed) {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        allowed = configuredStrategy.canAllocate(address(this), allocationKey, caller);
    }

    function canAccountAllocate(address account) external view returns (bool allowed) {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        uint256 allocationKey = _allocationKeyOf(configuredStrategy, account);
        allowed = configuredStrategy.canAllocate(address(this), allocationKey, account);
    }

    function accountAllocationWeight(address account) external view returns (uint256 weight) {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        uint256 allocationKey = _allocationKeyOf(configuredStrategy, account);
        weight = configuredStrategy.currentWeight(address(this), allocationKey);
    }

    function _loadAndSyncStoredAllocation(
        address strategyAddress,
        uint256 allocationKey,
        bool requireZeroWeight
    ) internal {
        if (_allocStorage().allocCommit[strategyAddress][allocationKey] == bytes32(0))
            revert STALE_CLEAR_NO_COMMITMENT();
        (
            bytes32[] memory prevRecipientIds,
            uint32[] memory prevAllocationPpm,
            uint256 prevWeight
        ) = CustomFlowPreviousState.loadAndResolvePreviousState(
                _recipientsStorage(),
                _allocStorage(),
                strategyAddress,
                allocationKey
            );
        _syncStoredAllocationWithPrevState(
            strategyAddress,
            allocationKey,
            prevWeight,
            prevRecipientIds,
            prevAllocationPpm,
            requireZeroWeight
        );
    }

    // slither-disable-next-line reentrancy-no-eth
    function _allocateAndSync(
        IAllocationStrategy allocationStrategy,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) internal {
        uint128 totalUnitsBefore = _cfgStorage().distributionPool.getTotalUnits();

        CustomFlowAllocationEngine.processAllocationForCaller(
            _cfgStorage(),
            _recipientsStorage(),
            _allocStorage(),
            _pipelineStorage(),
            address(this),
            allocationStrategy,
            msg.sender,
            FlowAllocations.AllocationVector({ recipientIds: recipientIds, allocationsPpm: allocationsPpm })
        );

        _bestEffortRefreshOutflowAfterUnitsCrossing(_cfgStorage(), totalUnitsBefore);
    }

    function clearStaleAllocation(uint256 allocationKey) external nonReentrant {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        _loadAndSyncStoredAllocation(address(configuredStrategy), allocationKey, true);
    }

    function previewChildSyncRequirements(
        uint256 allocationKey,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external view returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        IAllocationStrategy configuredStrategy = _defaultStrategyOrRevert();
        return
            CustomFlowPreview.previewChildSyncRequirements(
                _recipientsStorage(),
                _allocStorage(),
                _pipelineStorage(),
                address(this),
                address(configuredStrategy),
                allocationKey,
                newRecipientIds,
                newAllocationPpm
            );
    }

    // slither-disable-next-line reentrancy-no-eth
    function _syncStoredAllocationWithPrevState(
        address strategyAddress,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationPpm,
        bool requireZeroWeight
    ) internal {
        uint256 currentWeight = IAllocationStrategy(strategyAddress).currentWeight(address(this), allocationKey);
        if (requireZeroWeight) {
            if (currentWeight != 0) revert STALE_CLEAR_WEIGHT_NOT_ZERO(currentWeight);
        } else if (currentWeight == prevWeight) {
            return;
        }

        uint128 totalUnitsBefore = _cfgStorage().distributionPool.getTotalUnits();

        CustomFlowAllocationEngine.applyMaintenanceWithPipeline(
            _cfgStorage(),
            _recipientsStorage(),
            _allocStorage(),
            _pipelineStorage(),
            FlowAllocations.MaintenanceApplyRequest({
                strategy: strategyAddress,
                allocationKey: allocationKey,
                storedAllocation: FlowAllocations.PreviousAllocationData({
                    allocation: FlowAllocations.AllocationVector({
                        recipientIds: prevRecipientIds,
                        allocationsPpm: prevAllocationPpm
                    }),
                    weight: prevWeight
                }),
                newWeight: currentWeight
            })
        );

        _bestEffortRefreshOutflowAfterUnitsCrossing(_cfgStorage(), totalUnitsBefore);
    }

    function _defaultStrategyOrRevert() internal view returns (IAllocationStrategy configuredStrategy) {
        configuredStrategy = CustomFlowRuntimeHelpers.defaultStrategyOrRevert(_allocStorage());
    }

    function _allocationKeyOf(
        IAllocationStrategy configuredStrategy,
        address account
    ) private view returns (uint256 allocationKey) {
        allocationKey = configuredStrategy.allocationKey(account, bytes(""));
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
     * @param configuredStrategy The allocation strategy to use.
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
        IAllocationStrategy configuredStrategy
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
            configuredStrategy
        );
    }
}
