// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IManagedFlow } from "./IManagedFlow.sol";
import { IAllocationStrategy } from "./IAllocationStrategy.sol";

/**
 * @title IFlowEvents
 * @dev This interface defines the events for the Flow contract.
 */
interface IFlowEvents {
    /// @notice Emitted when an allocation commitment is updated for a strategy/key
    event AllocationCommitted(
        address indexed strategy,
        uint256 indexed allocationKey,
        bytes32 commit,
        uint256 weight,
        uint8 snapshotVersion,
        bytes packedSnapshot
    );

    /// @notice Emitted by a parent flow after child clone and before child initialize.
    event ChildFlowDeployed(
        bytes32 indexed recipientId,
        address indexed recipient,
        address indexed strategy,
        address recipientAdmin,
        address flowOperator,
        address sweeper,
        address managerRewardPool
    );

    /// @notice Emitted when a new child flow recipient is created
    event FlowRecipientCreated(
        bytes32 indexed recipientId,
        address indexed recipient,
        address distributionPool,
        uint32 managerRewardPoolFlowRatePpm
    );

    /// @notice Emitted when the metadata is set
    event MetadataSet(FlowTypes.RecipientMetadata metadata);

    /// @notice Emitted when the flow is initialized.
    event FlowInitialized(
        address indexed recipientAdmin,
        address indexed superToken,
        address indexed flowImplementation,
        address flowOperator,
        address sweeper,
        address connectPoolAdmin,
        address managerRewardPool,
        address allocationPipeline,
        address parent,
        address distributionPool,
        uint32 managerRewardPoolFlowRatePpm,
        IAllocationStrategy strategy
    );

    /// @notice Emitted when a new recipient is set
    event RecipientCreated(bytes32 indexed recipientId, FlowTypes.FlowRecipient recipient, address indexed approvedBy);

    /// @notice Emitted when a recipient is removed
    event RecipientRemoved(address indexed recipient, bytes32 indexed recipientId);

    /// @notice Emitted when the cached target outflow rate changes.
    event TargetOutflowRateUpdated(address indexed caller, int96 oldRate, int96 newRate);

    /// @notice Emitted when held SuperToken is transferred out of the flow contract.
    event SuperTokenSwept(address indexed caller, address indexed to, uint256 amount);

    /// @notice Emitted when unit-bootstrap-triggered outflow refresh fails and the write is skipped.
    event TargetOutflowRefreshFailed(int96 targetOutflowRate, bytes reason);
}

/**
 * @title IFlow
 * @dev This interface defines the methods for the Flow contract.
 */
interface IFlow is IFlowEvents, IManagedFlow {
    ///                                                          ///
    ///                           ERRORS                         ///
    ///                                                          ///

    /// @dev Reverts if the lengths of the provided arrays do not match.
    error ARRAY_LENGTH_MISMATCH();

    /// @dev Reverts if unit updates fail
    error UNITS_UPDATE_FAILED();

    /// @dev Reverts if the recipient is not found
    error RECIPIENT_NOT_FOUND();

    /// @dev Reverts if the recipient already exists
    error RECIPIENT_ALREADY_EXISTS();

    /// @dev Reverts if a flow-rate share scaled in PPM is invalid
    error INVALID_RATE_PPM();

    /// @dev Reverts if the flow rate is negative
    error FLOW_RATE_NEGATIVE();

    /// @dev Reverts if the flow rate is too high
    error FLOW_RATE_TOO_HIGH();

    /// @dev Reverts if the recipient is not approved.
    error NOT_APPROVED_RECIPIENT();

    /// @dev Reverts if the caller is not the flow operator or the parent.
    error NOT_FLOW_OPERATOR_OR_PARENT();

    /// @dev Reverts if the caller is not the configured sweep authority.
    error NOT_SWEEPER();

    /// @dev Reverts if the caller cannot connect a pool
    error NOT_ALLOWED_TO_CONNECT_POOL();

    /// @dev Reverts if attempting to register this flow contract as one of its own recipients.
    error SELF_RECIPIENT_NOT_ALLOWED();

    /// @dev Reverts if invalid recipientId is passed
    error INVALID_RECIPIENT_ID();

    /// @dev Reverts if the function caller is not the recipient admin.
    error NOT_RECIPIENT_ADMIN();

    /// @dev Reverts if allocation math will overflow
    error OVERFLOW();

    /// @dev Reverts when flow initialization is attempted without exactly one strategy.
    error FLOW_REQUIRES_SINGLE_STRATEGY(uint256 strategyCount);

    /// @dev Reverts if address 0 is passed but not allowed
    error ADDRESS_ZERO();

    /// @dev Reverts if an expected contract address has no deployed code.
    error NOT_A_CONTRACT(address account);

    /// @dev Reverts if allocation scaled does not sum to the full allocation scale (1_000_000)
    error INVALID_SCALED_SUM();

    /// @dev Reverts if metadata is invalid
    error INVALID_METADATA();

    /// @dev Reverts if recipient is already approved
    error RECIPIENT_ALREADY_REMOVED();

    /// @dev Reverts if msg.sender is not able to allocate with the strategy
    error NOT_ABLE_TO_ALLOCATE();

    /// @dev Reverts when a call requires the flow's single default strategy but receives a different strategy.
    error ONLY_DEFAULT_STRATEGY_ALLOWED(address strategy);

    /// @dev Array lengths of recipients & allocationsPpm don't match (`recipientsLength` != `allocationsLength`)
    /// @param recipientsLength Length of recipients array
    /// @param allocationsLength Length of allocationsPpm array
    error RECIPIENTS_ALLOCATIONS_MISMATCH(uint256 recipientsLength, uint256 allocationsLength);

    /// @dev Reverts if no recipients are specified
    error TOO_FEW_RECIPIENTS();

    /// @dev Reverts if an allocation value is not positive
    error ALLOCATION_MUST_BE_POSITIVE();

    /// @dev Reverts if recipientIds array is not strictly ascending or has duplicates
    error NOT_SORTED_OR_DUPLICATE();

    /// @dev Reverts if pool connection fails
    error POOL_CONNECTION_FAILED();

    /// @dev Reverts when token transferFrom returns false
    error TRANSFER_FROM_FAILED();

    /// @dev Reverts when token transfer returns false
    error TRANSFER_FAILED();

    /// @dev Reverts when attempting to add a flow recipient from a non-root flow.
    error NESTED_FLOW_RECIPIENTS_DISABLED();

    /// @dev Reverts when attempting to add the manager reward pool as a normal recipient.
    error MANAGER_REWARD_POOL_RECIPIENT_NOT_ALLOWED();

    /// @dev Reverts if stored previous allocation state is invalid or inconsistent with the stored commitment
    error INVALID_PREV_ALLOCATION();

    /// @dev Reverts if a configured allocation ledger is not a deployed contract or does not expose required interface.
    error INVALID_ALLOCATION_LEDGER(address allocationLedger);

    /// @dev Reverts if a configured allocation ledger points to an invalid goal treasury.
    error INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(address allocationLedger, address goalTreasury);

    /// @dev Reverts if a configured ledger goal treasury is not wired to this flow.
    error INVALID_ALLOCATION_LEDGER_FLOW(address expectedFlow, address configuredFlow);

    /// @dev Reverts if a configured ledger goal treasury has an invalid stake vault.
    error INVALID_ALLOCATION_LEDGER_STAKE_VAULT(address goalTreasury, address stakeVault);

    /// @dev Reverts if a configured allocation pipeline is not a deployed contract.
    error INVALID_ALLOCATION_PIPELINE(address allocationPipeline);

    /// @dev Reverts when enabling allocation-ledger checkpointing with anything other than exactly one strategy.
    error ALLOCATION_LEDGER_REQUIRES_SINGLE_STRATEGY(uint256 strategyCount);

    ///                                                          ///
    ///                         STRUCTS                          ///
    ///                                                          ///

    /**
     * @notice Structure to hold the parameters for initializing a Flow contract.
     * @param managerRewardPoolFlowRatePpm Manager reward flow share in 1e6-scale
     * (`ppmScale`, where `1_000_000 == 100%`).
     */
    struct FlowParams {
        uint32 managerRewardPoolFlowRatePpm;
    }

    /**
     * @notice Structure used to initialize base Flow configuration.
     */
    struct FlowInitConfig {
        address superToken;
        address flowImplementation;
        address recipientAdmin;
        address managerRewardPool;
        address allocationPipeline;
        address parent;
        address connectPoolAdmin;
        FlowParams flowParams;
        FlowTypes.RecipientMetadata metadata;
    }

    /**
     * @notice Sets this contract's total outflow rate
     * @param targetOutflowRate The new total outflow rate
     * @dev Only callable by the flow operator or parent flow.
     */
    function setTargetOutflowRate(int96 targetOutflowRate) external;

    /**
     * @notice Reapplies this contract's cached target outflow rate.
     * @dev Only callable by the flow operator or parent flow.
     */
    function refreshTargetOutflowRate() external;

    /**
     * @notice Gets this contract's cached total outflow rate
     * @return The total outflow rate split between distribution and manager reward paths
     */
    function targetOutflowRate() external view returns (int96);

    /**
     * @notice Gets this contract's current on-chain outflow rate
     * @return The current aggregate outflow rate
     */
    function getActualFlowRate() external view returns (int96);

    /**
     * @notice Gets this contract's net flow rate (incoming minus outgoing)
     * @return The net flow rate
     */
    function getNetFlowRate() external view returns (int96);

    /**
     * @notice Reads the current allocation commitment for a strategy/allocationKey pair.
     * @param strategy The allocation strategy address.
     * @param allocationKey The allocation key for the strategy.
     * @return commit Hash of canonical previous recipient ids + allocation scaled payload.
     */
    function getAllocationCommitment(address strategy, uint256 allocationKey) external view returns (bytes32 commit);
}

interface ICustomFlow is IFlow {
    /**
     * @notice Preview item describing a required child-sync target.
     * @param budgetTreasury Budget treasury address that identifies the child flow.
     * @param childFlow Resolved child flow address.
     * @param childStrategy Resolved child allocation strategy.
     * @param allocationKey Resolved child allocation key for the parent allocator account.
     * @param expectedCommit Current child allocation commitment expected by the parent sync path.
     */
    struct ChildSyncRequirement {
        address budgetTreasury;
        address childFlow;
        address childStrategy;
        uint256 allocationKey;
        bytes32 expectedCommit;
    }

    /**
     * @notice Initializes a CustomFlow with explicit operational authorities.
     * @dev `recipientAdmin` controls recipient lifecycle; `flowOperator` controls flow-rate ops; `sweeper` controls balance sweep.
     * @param superToken The address of the SuperToken to be used for the pool
     * @param flowImplementation The address of the flow implementation contract
     * @param recipientAdmin The recipient-admin authority
     * @param flowOperator The flow-rate operations authority
     * @param sweeper The sweep authority
     * @param managerRewardPool The address of the manager reward pool
     * @param allocationPipeline The address of the allocation pipeline, or zero for no pipeline.
     * @param parent The address of the parent flow contract (optional)
     * @param connectPoolAdmin The address of the admin that can connect the pool
     * @param flowParams The parameters for the flow contract
     * @param metadata The metadata for the flow contract
     * @param strategies The allocation strategies to use.
     */
    function initialize(
        address superToken,
        address flowImplementation,
        address recipientAdmin,
        address flowOperator,
        address sweeper,
        address managerRewardPool,
        address allocationPipeline,
        address parent,
        address connectPoolAdmin,
        FlowParams memory flowParams,
        FlowTypes.RecipientMetadata memory metadata,
        IAllocationStrategy[] calldata strategies
    ) external;

    /**
     * @notice Applies recipient allocation splits using the flow's single configured default strategy.
     * @dev Allocation key is always derived by the configured strategy from `msg.sender` and empty aux data.
     * @param recipientIds New recipient ids.
     * @param allocationsPpm New recipient allocations in 1e6-scale (`1_000_000 == 100%`).
     */
    function allocate(bytes32[] calldata recipientIds, uint32[] calldata allocationsPpm) external;

    /**
     * @notice Permissionlessly resynchronizes an existing allocation commitment from stored previous-state snapshot.
     * @param strategy The allocation strategy address.
     * @param allocationKey The allocation key.
     */
    function syncAllocation(address strategy, uint256 allocationKey) external;

    /**
     * @notice Permissionlessly resynchronizes the default-strategy allocation derived for an account.
     * @dev Derives `allocationKey(account, "")` on the configured default strategy and reuses canonical sync path.
     * @param account Account whose derived default-strategy allocation should be resynchronized.
     */
    function syncAllocationForAccount(address account) external;

    /**
     * @notice Permissionlessly clears stale units using stored previous-state snapshot.
     * @param strategy The allocation strategy address.
     * @param allocationKey The allocation key.
     */
    function clearStaleAllocation(address strategy, uint256 allocationKey) external;

    /**
     * @notice Previews required child-sync targets for a parent allocation update.
     * @dev Returns only budgets that both changed allocation amount and currently have a child commitment
     *      (`expectedCommit != 0`) under the same target-resolution semantics as parent auto-sync.
     * @param strategy Parent allocation strategy.
     * @param allocationKey Parent allocation key.
     * @param newRecipientIds New recipient ids for the parent allocation update.
     * @param newAllocationScaled New recipient allocations in 1e6-scale for the parent allocation update.
     * @return reqs Required child-sync targets.
     */
    function previewChildSyncRequirements(
        address strategy,
        uint256 allocationKey,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationScaled
    ) external view returns (ChildSyncRequirement[] memory reqs);
}
