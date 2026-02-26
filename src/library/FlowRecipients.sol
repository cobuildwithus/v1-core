// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "../storage/FlowStorage.sol";
import { IFlow, IFlowEvents } from "../interfaces/IFlow.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { FlowPools } from "./FlowPools.sol";

library FlowRecipients {
    using EnumerableSet for EnumerableSet.AddressSet;
    error MANAGER_REWARD_POOL_RECIPIENT_NOT_ALLOWED();

    /**
     * @notice Marks a recipient as removed in recipient-state storage
     * @param recipientsState The recipient-state storage of the Flow contract
     * @param _childFlows The set of child flows
     * @param recipientId The ID of the recipient to mark removed
     * @dev Caller authorization is enforced by the parent flow (`onlyRecipientAdmin`).
     * @dev This function updates recipient-state bookkeeping only.
     * @return address The address of the recipient marked removed
     */
    function markRecipientRemoved(
        FlowTypes.RecipientsState storage recipientsState,
        EnumerableSet.AddressSet storage _childFlows,
        bytes32 recipientId
    ) public returns (address) {
        FlowTypes.FlowRecipient storage recipientState = recipientsState.recipients[recipientId];
        if (recipientState.recipient == address(0)) revert IFlow.INVALID_RECIPIENT_ID();
        if (recipientState.isRemoved) revert IFlow.RECIPIENT_ALREADY_REMOVED();

        address recipientAddress = recipientState.recipient;
        FlowTypes.RecipientType recipientType = recipientState.recipientType;
        recipientsState.recipientExists[recipientAddress] = false;

        recipientState.isRemoved = true;

        if (recipientType == FlowTypes.RecipientType.FlowContract) {
            _childFlows.remove(recipientAddress);
        }

        return recipientAddress;
    }

    /**
     * @notice Adds an address to the list of approved recipients
     * @param recipientsState The recipient-state storage of the Flow contract
     * @param recipientId The ID of the recipient to be approved
     * @param recipient The address to be added as an approved recipient
     * @param metadata The metadata of the recipient
     * @return address The address of the newly created recipient
     */
    function addRecipient(
        FlowTypes.RecipientsState storage recipientsState,
        bytes32 recipientId,
        address recipient,
        FlowTypes.RecipientMetadata memory metadata
    ) public returns (address) {
        validateMetadata(metadata);

        if (recipient == address(0)) revert IFlow.ADDRESS_ZERO();
        if (recipient == address(this)) revert IFlow.SELF_RECIPIENT_NOT_ALLOWED();
        if (recipient == IFlow(address(this)).managerRewardPool()) revert MANAGER_REWARD_POOL_RECIPIENT_NOT_ALLOWED();
        if (recipientsState.recipientExists[recipient]) revert IFlow.RECIPIENT_ALREADY_EXISTS();
        if (recipientsState.recipients[recipientId].recipient != address(0)) revert IFlow.RECIPIENT_ALREADY_EXISTS();

        uint32 recipientIndexPlusOne = _appendRecipientIndex(recipientsState, recipientId);
        recipientsState.recipientExists[recipient] = true;

        recipientsState.recipients[recipientId] = FlowTypes.FlowRecipient({
            recipientType: FlowTypes.RecipientType.ExternalAccount,
            isRemoved: false,
            recipient: recipient,
            recipientIndexPlusOne: recipientIndexPlusOne,
            metadata: metadata
        });

        return recipient;
    }

    /**
     * @notice Adds an Flow address to the list of approved recipients
     * @param recipientsState The recipient-state storage of the Flow contract
     * @param recipientId The ID of the recipient to be approved
     * @param recipient The address to be added as an approved recipient
     * @param metadata The metadata of the recipient
     */
    function addFlowRecipient(
        FlowTypes.RecipientsState storage recipientsState,
        bytes32 recipientId,
        address recipient,
        FlowTypes.RecipientMetadata memory metadata
    ) public {
        if (recipient == address(this)) revert IFlow.SELF_RECIPIENT_NOT_ALLOWED();
        if (recipientsState.recipientExists[recipient]) revert IFlow.RECIPIENT_ALREADY_EXISTS();
        if (recipientsState.recipients[recipientId].recipient != address(0)) revert IFlow.RECIPIENT_ALREADY_EXISTS();

        uint32 recipientIndexPlusOne = _appendRecipientIndex(recipientsState, recipientId);
        recipientsState.recipients[recipientId] = FlowTypes.FlowRecipient({
            recipientType: FlowTypes.RecipientType.FlowContract,
            isRemoved: false,
            recipient: recipient,
            recipientIndexPlusOne: recipientIndexPlusOne,
            metadata: metadata
        });

        recipientsState.recipientExists[recipient] = true;
    }

    /**
     * @notice Modifier to validate the metadata for a recipient
     * @param metadata The metadata to validate
     */
    function validateMetadata(FlowTypes.RecipientMetadata memory metadata) public pure {
        if (bytes(metadata.title).length == 0) revert IFlow.INVALID_METADATA();
        if (bytes(metadata.description).length == 0) revert IFlow.INVALID_METADATA();
        if (bytes(metadata.image).length == 0) revert IFlow.INVALID_METADATA();
    }

    /**
     * @notice Validates metadata and role addresses for a child-flow recipient.
     * @param metadata The metadata to validate.
     * @param recipientAdmin The recipient-admin authority.
     * @param flowOperator The flow-rate operations authority.
     * @param sweeper The sweep authority.
     */
    function validateFlowRecipient(
        FlowTypes.RecipientMetadata memory metadata,
        address recipientAdmin,
        address flowOperator,
        address sweeper
    ) public pure {
        validateMetadata(metadata);
        if (recipientAdmin == address(0)) revert IFlow.ADDRESS_ZERO();
        if (flowOperator == address(0)) revert IFlow.ADDRESS_ZERO();
        if (sweeper == address(0)) revert IFlow.ADDRESS_ZERO();
    }

    /**
     * @notice Gets the total amount received by a member from the distribution pool
     * @param cfg The config storage of the Flow contract
     * @param memberAddr The address of the member to check
     * @return uint256 The total amount received by the member
     */
    function getTotalAmountReceivedByMember(
        FlowTypes.Config storage cfg,
        address memberAddr
    ) external view returns (uint256) {
        return cfg.distributionPool.getTotalAmountReceivedByMember(memberAddr);
    }

    /**
     * @notice Removes many recipients in one transaction
     * @dev Emits RecipientRemoved for each, snapshots before zeroing units
     * @param cfg Config storage
     * @param recipientsState Recipient storage
     * @param _childFlows Set of child flows
     * @param recipientIds Ids to remove
     */
    function bulkRemoveRecipients(
        FlowTypes.Config storage cfg,
        FlowTypes.RecipientsState storage recipientsState,
        EnumerableSet.AddressSet storage _childFlows,
        bytes32[] calldata recipientIds
    ) public {
        uint256 n = recipientIds.length;
        if (n == 0) revert IFlow.TOO_FEW_RECIPIENTS();

        address[] memory removedAddrs = new address[](n);

        // Phase 1 — mark removed (no units changed yet)
        for (uint256 i = 0; i < n; ) {
            address recipientAddr = markRecipientRemoved(recipientsState, _childFlows, recipientIds[i]);
            removedAddrs[i] = recipientAddr;

            unchecked {
                ++i;
            }
        }

        // Phase 2 — zero units and emit events
        for (uint256 i = 0; i < n; ) {
            emit IFlowEvents.RecipientRemoved(removedAddrs[i], recipientIds[i]);
            FlowPools.removeFromPools(cfg, removedAddrs[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _appendRecipientIndex(
        FlowTypes.RecipientsState storage recipientsState,
        bytes32 recipientId
    ) private returns (uint32 indexPlusOne) {
        uint256 count = recipientsState.recipientIdByIndex.length;
        if (count >= type(uint32).max) revert IFlow.OVERFLOW();
        recipientsState.recipientIdByIndex.push(recipientId);
        unchecked {
            indexPlusOne = uint32(count + 1);
        }
    }
}
