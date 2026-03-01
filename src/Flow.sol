// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowStorageV1 } from "./storage/FlowStorage.sol";
import { IFlow } from "./interfaces/IFlow.sol";
import { IAllocationStrategy } from "./interfaces/IAllocationStrategy.sol";
import { FlowRecipients } from "./library/FlowRecipients.sol";
import { FlowPools } from "./library/FlowPools.sol";
import { FlowRates } from "./library/FlowRates.sol";
import { FlowInitialization } from "./library/FlowInitialization.sol";
import { FlowSets } from "./library/FlowSets.sol";

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { ISuperToken, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

abstract contract Flow is IFlow, ReentrancyGuardUpgradeable, FlowStorageV1 {
    error ONLY_SELF_OUTFLOW_REFRESH();

    /**
     * @notice Initializes the Flow contract with split operational authorities.
     * @param initConfig The flow initialization config.
     * @param flowOperator_ Flow-rate operations authority.
     * @param sweeper_ Sweep authority.
     * @param _strategies Allocation strategies.
     */
    function __Flow_initWithRoles(
        IFlow.FlowInitConfig memory initConfig,
        address flowOperator_,
        address sweeper_,
        IAllocationStrategy[] calldata _strategies
    ) internal onlyInitializing {
        Config storage cfg = _cfgStorage();
        FlowInitialization.checkAndSetInitializationParams(
            cfg,
            _allocStorage(),
            _pipelineStorage(),
            initConfig,
            _strategies
        );
        if (flowOperator_ == address(0) || sweeper_ == address(0)) revert ADDRESS_ZERO();
        cfg.flowOperator = flowOperator_;
        cfg.sweeper = sweeper_;

        __ReentrancyGuard_init();

        emit FlowInitialized(
            initConfig.recipientAdmin,
            initConfig.superToken,
            initConfig.flowImplementation,
            flowOperator_,
            sweeper_,
            initConfig.managerRewardPool,
            initConfig.allocationPipeline,
            initConfig.parent,
            address(cfg.distributionPool),
            cfg.managerRewardPoolFlowRatePpm,
            _strategies[0]
        );
        emit MetadataSet(cfg.metadata);
    }

    /// @notice Restricts recipient lifecycle authority to the configured recipient admin.
    modifier onlyRecipientAdmin() {
        if (msg.sender != _cfgStorage().recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        _;
    }

    /// @notice Restricts access to the flow operator or parent flow.
    modifier onlyFlowOperatorOrParent() {
        if (msg.sender != _cfgStorage().flowOperator && msg.sender != _cfgStorage().parent) {
            revert NOT_FLOW_OPERATOR_OR_PARENT();
        }
        _;
    }

    /// @notice Restricts access to the configured sweep authority.
    modifier onlySweeper() {
        if (msg.sender != _cfgStorage().sweeper) revert NOT_SWEEPER();
        _;
    }

    /**
     * @notice Adds an address to the list of approved recipients
     * @param _recipientId The ID of the recipient. Must be unique and not already in use.
     * @param _recipient The address to be added as an approved recipient
     * @param _metadata The metadata of the recipient
     * @return bytes32 The recipientId of the newly created recipient
     * @return address The address of the newly created recipient
     */
    // slither-disable-next-line unused-return
    function addRecipient(
        bytes32 _recipientId,
        address _recipient,
        RecipientMetadata memory _metadata
    ) external onlyRecipientAdmin nonReentrant returns (bytes32, address) {
        RecipientsState storage recipientsState = _recipientsStorage();
        address recipientAddress = FlowRecipients.addRecipient(recipientsState, _recipientId, _recipient, _metadata);

        emit RecipientCreated(_recipientId, recipientsState.recipients[_recipientId], msg.sender);

        return (_recipientId, recipientAddress);
    }

    /**
     * @notice Adds a new Flow contract as a recipient
     * @dev This function creates a new Flow contract and adds it as a recipient
     * @param _recipientId The ID of the recipient. Must be unique and not already in use.
     * @param _metadata The metadata of the recipient
     * @param _recipientAdmin The recipient-admin authority for the new contract
     * @param _flowOperator The flow-rate operations authority for the new contract
     * @param _sweeper The sweep authority for the new contract
     * @param _managerRewardPool The address of the manager reward pool for the new contract
     * @param _managerRewardPoolFlowRatePpm The manager reward flow-rate share for the new contract in ppm
     * @param _strategies The allocation strategies to use.
     * @return bytes32 The recipientId of the newly created Flow contract
     * @return address The address of the newly created Flow contract
     * @dev Only callable by the recipient admin of the contract
     * @dev Emits a RecipientCreated event if the recipient is successfully added
     */
    // slither-disable-next-line unused-return
    function addFlowRecipient(
        bytes32 _recipientId,
        RecipientMetadata calldata _metadata,
        address _recipientAdmin,
        address _flowOperator,
        address _sweeper,
        address _managerRewardPool,
        uint32 _managerRewardPoolFlowRatePpm,
        IAllocationStrategy[] calldata _strategies
    ) external onlyRecipientAdmin nonReentrant returns (bytes32, address) {
        Config storage cfg = _cfgStorage();
        RecipientsState storage recipientsState = _recipientsStorage();
        if (cfg.parent != address(0)) revert NESTED_FLOW_RECIPIENTS_DISABLED();

        FlowRecipients.validateFlowRecipient(_metadata, _recipientAdmin, _flowOperator, _sweeper);

        address recipient = _deployFlowRecipient(
            _recipientId,
            _metadata,
            _recipientAdmin,
            _flowOperator,
            _sweeper,
            _managerRewardPool,
            _managerRewardPoolFlowRatePpm,
            _strategies
        );

        FlowRecipients.addFlowRecipient(recipientsState, _recipientId, recipient, _metadata);
        FlowSets.add(_childFlowsSet(), recipient);

        emit RecipientCreated(_recipientId, recipientsState.recipients[_recipientId], msg.sender);
        emit FlowRecipientCreated(
            _recipientId,
            recipient,
            address(IFlow(recipient).distributionPool()),
            IFlow(recipient).managerRewardPoolFlowRatePpm()
        );

        // Connect the child flow to this flow's distribution pool.
        FlowPools.connectAndInitializeFlowRecipient(cfg, recipient, 0);

        return (_recipientId, recipient);
    }

    /**
     * @notice Deploys a new Flow contract as a recipient
     * @dev This function is virtual to allow for different deployment strategies in derived contracts
     * @param _recipientId The ID of the recipient. Must be unique and not already in use.
     * @param _metadata The metadata of the recipient
     * @param _recipientAdmin The recipient-admin authority for the new contract
     * @param _flowOperator The flow-rate operations authority for the new contract
     * @param _sweeper The sweep authority for the new contract
     * @param _managerRewardPool The address of the manager reward pool for the new contract
     * @param _managerRewardPoolFlowRatePpm The manager reward flow-rate share for the new contract in ppm
     * @param _strategies The allocation strategies to use.
     * @return address The address of the newly created Flow contract
     */
    function _deployFlowRecipient(
        bytes32 _recipientId,
        RecipientMetadata calldata _metadata,
        address _recipientAdmin,
        address _flowOperator,
        address _sweeper,
        address _managerRewardPool,
        uint32 _managerRewardPoolFlowRatePpm,
        IAllocationStrategy[] calldata _strategies
    ) internal virtual returns (address);

    /**
     * @notice Removes a recipient for receiving funds
     * @param recipientId The ID of the recipient to be approved
     * @dev Only callable by the recipient admin of the contract
     * @dev Emits a RecipientRemoved event if the recipient is successfully removed
     */
    // slither-disable-next-line reentrancy-no-eth
    function removeRecipient(bytes32 recipientId) external onlyRecipientAdmin nonReentrant {
        address recipientAddress = FlowRecipients.markRecipientRemoved(
            _recipientsStorage(),
            _childFlowsSet(),
            recipientId
        );

        // Recipient lifecycle consumers should treat RecipientRemoved as canonical.
        // Pool unit updates are telemetry and should not be used as delete signals.
        emit RecipientRemoved(recipientAddress, recipientId);

        FlowPools.removeFromPools(_cfgStorage(), recipientAddress);
        _bestEffortRefreshOutflowFromCachedTarget(targetOutflowRate());
    }

    /**
     * @notice Removes many recipients in one transaction
     * @param recipientIds The IDs of the recipients to remove
     */
    // slither-disable-next-line reentrancy-no-eth
    function bulkRemoveRecipients(bytes32[] calldata recipientIds) external onlyRecipientAdmin nonReentrant {
        FlowRecipients.bulkRemoveRecipients(_cfgStorage(), _recipientsStorage(), _childFlowsSet(), recipientIds);
        _bestEffortRefreshOutflowFromCachedTarget(targetOutflowRate());
    }

    /**
     * @notice Connects this contract to a Superfluid pool
     * @param poolAddress The address of the Superfluid pool to connect to
     * @dev Only callable by recipient admin or parent authority.
     * @dev Emits a PoolConnected event upon successful connection
     */
    function connectPool(ISuperfluidPool poolAddress) external nonReentrant {
        if (address(poolAddress) == address(0)) revert ADDRESS_ZERO();
        if (msg.sender != _cfgStorage().recipientAdmin && msg.sender != _cfgStorage().parent) {
            revert NOT_ALLOWED_TO_CONNECT_POOL();
        }

        bool success = FlowPools.connectPool(_cfgStorage(), poolAddress);
        if (!success) revert POOL_CONNECTION_FAILED();
    }

    /**
     * @notice Sets this contract's total outflow rate
     * @param newTargetOutflowRate The new total outflow rate
     * @dev Only callable by the flow operator or parent flow.
     */
    function setTargetOutflowRate(int96 newTargetOutflowRate) external onlyFlowOperatorOrParent nonReentrant {
        if (_ratesStorage().cachedFlowRate == newTargetOutflowRate) return;
        _setFlowRate(newTargetOutflowRate);
    }

    /**
     * @notice Reapplies this contract's cached target outflow rate.
     * @dev Only callable by the flow operator or parent flow.
     */
    function refreshTargetOutflowRate() external onlyFlowOperatorOrParent nonReentrant {
        int96 cachedTargetOutflowRate = _ratesStorage().cachedFlowRate;
        if (cachedTargetOutflowRate <= 0) return;
        _setFlowRate(cachedTargetOutflowRate);
    }

    /**
     * @notice Transfers held SuperToken balance out of the flow.
     * @param to Recipient address.
     * @param amount Amount to transfer. Use max uint256 to sweep all available balance.
     * @return swept Actual amount transferred.
     */
    function sweepSuperToken(address to, uint256 amount) external onlySweeper nonReentrant returns (uint256 swept) {
        if (to == address(0)) revert ADDRESS_ZERO();

        uint256 available = _cfgStorage().superToken.balanceOf(address(this));
        if (available == 0) return 0;

        swept = amount > available ? available : amount;
        if (swept == 0) return 0;

        bool success = _cfgStorage().superToken.transfer(to, swept);
        if (!success) revert TRANSFER_FAILED();

        emit SuperTokenSwept(msg.sender, to, swept);
    }

    /**
     * @notice Sets the flow to the manager reward pool
     * @param _newManagerRewardFlowRate The new flow rate to the manager reward pool
     */
    function _setFlowToManagerRewardPool(int96 _newManagerRewardFlowRate) internal {
        // some flows initially don't have a manager reward pool, so we don't need to set a flow to it
        if (_cfgStorage().managerRewardPool == address(0)) return;

        FlowPools.setFlowToManagerRewardPool(_cfgStorage(), getManagerRewardPoolFlowRate(), _newManagerRewardFlowRate);
    }

    /**
     * @notice Internal function to set the flow rate for the distribution pool and manager reward pool
     * @param _flowRate The new flow rate to be set
     */
    // slither-disable-next-line reentrancy-no-eth
    function _setFlowRate(int96 _flowRate) internal {
        if (_flowRate < 0) revert FLOW_RATE_NEGATIVE();
        int96 oldRate = _ratesStorage().cachedFlowRate;
        if (oldRate != _flowRate) {
            emit TargetOutflowRateUpdated(msg.sender, oldRate, _flowRate);
        }
        _ratesStorage().cachedFlowRate = _flowRate;

        (int96 distributionFlowRate, int96 managerRewardFlowRate) = FlowRates.calculateFlowRates(
            _cfgStorage(),
            _flowRate
        );

        _setFlowToManagerRewardPool(managerRewardFlowRate);

        FlowPools.distributeFlowToDistributionPool(_cfgStorage(), distributionFlowRate);
    }

    /**
     * @notice Internal self-call entrypoint used to best-effort refresh distribution flow after units changes.
     * @dev Restricted to `address(this)` to avoid exposing an unauthenticated outflow mutation surface.
     */
    function _refreshOutflowFromCachedTarget(int96 expectedTargetOutflowRate) external {
        if (msg.sender != address(this)) revert ONLY_SELF_OUTFLOW_REFRESH();
        if (_ratesStorage().cachedFlowRate != expectedTargetOutflowRate) return;
        _setFlowRate(expectedTargetOutflowRate);
    }

    function _bestEffortRefreshOutflowFromCachedTarget(int96 expectedTargetOutflowRate) internal {
        try this._refreshOutflowFromCachedTarget(expectedTargetOutflowRate) {} catch {}
    }

    function _bestEffortRefreshOutflowAfterUnitsCrossing(Config storage cfg, uint128 totalUnitsBefore) internal {
        int96 cachedTargetOutflowRate = _ratesStorage().cachedFlowRate;
        if (cachedTargetOutflowRate <= 0) return;

        uint128 totalUnitsAfter = cfg.distributionPool.getTotalUnits();
        bool unitsCrossedZeroBoundary = (totalUnitsBefore == 0) != (totalUnitsAfter == 0);
        if (!unitsCrossedZeroBoundary) return;

        try this._refreshOutflowFromCachedTarget(cachedTargetOutflowRate) {} catch (bytes memory reason) {
            emit TargetOutflowRefreshFailed(cachedTargetOutflowRate, reason);
        }
    }

    /**
     * @notice Lets the recipient admin set metadata for the flow.
     * @param metadata The metadata of the flow
     */
    function setMetadata(RecipientMetadata memory metadata) external onlyRecipientAdmin {
        FlowRecipients.validateMetadata(metadata);
        _cfgStorage().metadata = metadata;
        emit MetadataSet(metadata);
    }

    /**
     * @notice Sets the description for the flow
     * @param description The new description for the flow
     */
    function setDescription(string calldata description) external onlyRecipientAdmin {
        Config storage cfg = _cfgStorage();
        RecipientMetadata memory metadata = cfg.metadata;
        metadata.description = description;
        FlowRecipients.validateMetadata(metadata);

        cfg.metadata.description = description;
        emit MetadataSet(cfg.metadata);
    }

    /**
     * @notice Retrieves the flow rate for a specific member in the pool
     * @param memberAddr The address of the member
     * @return flowRate The flow rate for the member
     */
    function getMemberFlowRate(address memberAddr) public view returns (int96) {
        return FlowRates.getMemberFlowRate(_cfgStorage(), memberAddr);
    }

    /**
     * @notice Retrieves the member units for a specific member in the distribution pool
     * @param memberAddr The address of the member
     * @return totalUnits The total units for the member
     */
    function getMemberUnits(address memberAddr) public view returns (uint256) {
        return FlowRates.getMemberUnits(_cfgStorage(), memberAddr);
    }

    /**
     * @notice Retrieves all child flow addresses
     * @return addresses An array of addresses representing all child flows
     */
    function getChildFlows() external view returns (address[] memory) {
        return FlowSets.values(_childFlowsSet());
    }

    /**
     * @notice Retrieves the total amount received by a specific member in the pool
     * @param memberAddr The address of the member
     * @return totalAmountReceived The total amount received by the member
     */
    function getTotalReceivedByMember(address memberAddr) external view returns (uint256) {
        return FlowRecipients.getTotalAmountReceivedByMember(_cfgStorage(), memberAddr);
    }

    /**
     * @return totalFlowRate The total flow rate of the distribution pool and the manager reward pool
     */
    function targetOutflowRate() public view returns (int96) {
        return _ratesStorage().cachedFlowRate;
    }

    /**
     * @notice Retrieves the actual flow rate for the contract
     * @return int96 The actual flow rate
     */
    function getActualFlowRate() public view returns (int96) {
        return FlowRates.getActualFlowRate(_cfgStorage(), address(this));
    }

    /**
     * @notice Gets the net flow rate for the contract
     * @dev This function is used to get the net flow rate for the contract
     * @return The net flow rate
     */
    function getNetFlowRate() public view returns (int96) {
        return FlowRates.getNetFlowRate(_cfgStorage(), address(this));
    }

    /**
     * @notice Read-only commitment (hash) for an allocation key
     * @dev commit = keccak256(abi.encode(canonical(recipientIds, percentAllocations)))
     * Canonicalized by recipientId asc.
     */
    function getAllocationCommitment(address strategy, uint256 allocationKey) external view returns (bytes32) {
        return _allocStorage().allocCommit[strategy][allocationKey];
    }

    /**
     * @notice Retrieves a recipient by their ID
     * @param recipientId The ID of the recipient to retrieve
     * @return recipient The FlowRecipient struct containing the recipient's information
     */
    function getRecipientById(bytes32 recipientId) external view returns (FlowRecipient memory recipient) {
        recipient = _recipientsStorage().recipients[recipientId];
        if (recipient.recipient == address(0)) revert RECIPIENT_NOT_FOUND();
        return recipient;
    }

    /**
     * @notice Checks if a recipient exists
     * @param recipient The address of the recipient to check
     * @return exists True if the recipient exists, false otherwise
     */
    function recipientExists(address recipient) public view returns (bool) {
        return _recipientsStorage().recipientExists[recipient];
    }

    /**
     * @notice Retrieves the metadata for this Flow contract
     * @return RecipientMetadata The metadata struct containing title, description, image, tagline, and url
     */
    function flowMetadata() external view returns (RecipientMetadata memory) {
        return _cfgStorage().metadata;
    }

    /**
     * @notice Retrieves the distribution pool
     * @return ISuperfluidPool The distribution pool
     */
    function distributionPool() external view returns (ISuperfluidPool) {
        return _cfgStorage().distributionPool;
    }

    /**
     * @notice Retrieves the SuperToken used for the flow
     * @return ISuperToken The SuperToken instance
     */
    function superToken() external view returns (ISuperToken) {
        return _cfgStorage().superToken;
    }

    /**
     * @notice Retrieves the flow implementation contract address
     * @return address The address of the flow implementation contract
     */
    function flowImplementation() external view returns (address) {
        return _cfgStorage().flowImplementation;
    }

    /**
     * @notice Retrieves the parent contract address
     * @return address The address of the parent contract
     */
    function parent() external view returns (address) {
        return _cfgStorage().parent;
    }

    /**
     * @notice Retrieves the recipient admin address.
     * @return address The recipient admin.
     */
    function recipientAdmin() external view returns (address) {
        return _cfgStorage().recipientAdmin;
    }

    /**
     * @notice Retrieves the flow operator address.
     * @return address The flow operator.
     */
    function flowOperator() external view returns (address) {
        return _cfgStorage().flowOperator;
    }

    /**
     * @notice Retrieves the sweep authority address.
     * @return address The sweep authority.
     */
    function sweeper() external view returns (address) {
        return _cfgStorage().sweeper;
    }

    /**
     * @notice Retrieves the manager reward pool address
     * @return address The address of the manager reward pool
     */
    function managerRewardPool() external view returns (address) {
        return _cfgStorage().managerRewardPool;
    }

    /**
     * @notice Retrieves the allocation pipeline address.
     * @return address The configured pipeline (or zero if unset).
     */
    function allocationPipeline() external view returns (address) {
        return _pipelineStorage().allocationPipeline;
    }

    /**
     * @notice Retrieves the current flow rate to the manager reward pool
     * @return flowRate The current flow rate to the manager reward pool
     */
    function getManagerRewardPoolFlowRate() public view returns (int96) {
        return FlowRates.getManagerRewardPoolFlowRate(_cfgStorage(), address(this));
    }

    /**
     * @notice Retrieves the rewards pool flow rate percentage
     * @return uint256 The rewards pool flow rate percentage
     */
    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        return _cfgStorage().managerRewardPoolFlowRatePpm;
    }

    /**
     * @notice Retrieves the claimable balance from the distribution pool for a member address
     * @param member The address of the member to check the claimable balance for
     * @return claimable The claimable balance from the distribution pool
     */
    function getClaimableBalance(address member) external view returns (uint256) {
        return FlowRates.getClaimableBalance(_cfgStorage(), member);
    }

    /**
     * @notice Retrieves the allocation strategies
     * @return IAllocationStrategy[] The allocation strategies
     */
    function strategies() external view returns (IAllocationStrategy[] memory) {
        return _allocStorage().strategies;
    }
}
