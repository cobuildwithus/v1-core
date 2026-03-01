// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IAllocationStrategy } from "./IAllocationStrategy.sol";
import { ISuperfluidPool, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

interface IManagedFlow {
    /**
     * @notice Adds an address to the list of approved recipients
     * @param newRecipientId The ID of the recipient
     * @param recipient The address to be added as an approved recipient
     * @param metadata The metadata of the recipient
     * @return recipientId The ID of the recipient
     * @return recipientAddress The address of the Flow recipient
     */
    function addRecipient(
        bytes32 newRecipientId,
        address recipient,
        FlowTypes.RecipientMetadata memory metadata
    ) external returns (bytes32 recipientId, address recipientAddress);

    /**
     * @notice Adds a new Flow contract as a recipient
     * @dev Only supported for root flows (`parent() == address(0)`).
     * @param newRecipientId The ID of the recipient
     * @param metadata The metadata of the recipient
     * @param recipientAdmin The recipient-admin authority for the new contract
     * @param flowOperator The flow-rate operations authority for the new contract
     * @param sweeper The sweep authority for the new contract
     * @param managerRewardPool The address of the manager reward pool for the new contract
     * @param managerRewardPoolFlowRatePpm The manager reward flow-rate share for the new contract in ppm
     * @param strategies The strategies for the new contract
     * @return recipientId The ID of the recipient
     * @return recipientAddress The address of the newly created flow contract
     */
    function addFlowRecipient(
        bytes32 newRecipientId,
        FlowTypes.RecipientMetadata memory metadata,
        address recipientAdmin,
        address flowOperator,
        address sweeper,
        address managerRewardPool,
        uint32 managerRewardPoolFlowRatePpm,
        IAllocationStrategy[] calldata strategies
    ) external returns (bytes32 recipientId, address recipientAddress);

    /**
     * @notice Removes a recipient for receiving funds
     * @param recipientId The ID of the recipient to be removed
     */
    function removeRecipient(bytes32 recipientId) external;

    /**
     * @notice Transfers held SuperToken balance out of the flow.
     * @param to Recipient address.
     * @param amount Amount to transfer. Use max uint256 to sweep all available balance.
     * @return swept Actual amount transferred.
     */
    function sweepSuperToken(address to, uint256 amount) external returns (uint256 swept);

    /// @notice Returns the SuperToken configured for this flow.
    function superToken() external view returns (ISuperToken);

    /**
     * @notice Returns the flow manager reward pool address
     * @return The address of the flow manager reward pool
     */
    function managerRewardPool() external view returns (address);

    /**
     * @notice Returns the recipient administration authority address.
     * @return The recipient admin address.
     */
    function recipientAdmin() external view returns (address);

    /**
     * @notice Returns the flow operator authority address.
     * @return The flow operator address.
     */
    function flowOperator() external view returns (address);

    /**
     * @notice Returns the sweep authority address.
     * @return The sweeper address.
     */
    function sweeper() external view returns (address);

    /**
     * @notice Returns the optional allocation pipeline address.
     */
    function allocationPipeline() external view returns (address);

    /**
     * @notice Returns the flow parent address
     * @return The address of the flow parent
     */
    function parent() external view returns (address);

    /**
     * @notice Returns the flow strategies
     * @return The flow strategies
     */
    function strategies() external view returns (IAllocationStrategy[] memory);

    /**
     * @notice Returns the flow manager reward pool flow rate in ppm scale
     * @return The flow rate share of the flow manager reward pool in ppm
     */
    function managerRewardPoolFlowRatePpm() external view returns (uint32);

    /**
     * @notice Returns the flow distribution pool address
     * @return The address of the flow distribution pool
     */
    function distributionPool() external view returns (ISuperfluidPool);

    /**
     * @notice Checks if a recipient exists in the Flow contract
     * @param recipient The address of the recipient to check
     * @return exists True if the recipient exists, false otherwise
     */
    function recipientExists(address recipient) external view returns (bool exists);
}
