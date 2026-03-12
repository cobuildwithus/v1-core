// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetController } from "./IBudgetController.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

interface IManagedBudgetController is IBudgetController {
    struct InitConfig {
        address authority;
        address goalTreasury;
        address goalFlow;
        address stackDeployer;
        address budgetGatePolicy;
        address budgetSuccessResolver;
        address budgetSpendPolicy;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
    }

    struct BudgetConfig {
        FlowTypes.RecipientMetadata metadata;
        uint64 fundingDeadline;
        uint64 executionDuration;
        uint256 activationThreshold;
        uint256 runwayCap;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
    }

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error ONLY_AUTHORITY();
    error ONLY_PENDING_AUTHORITY();
    error ARRAY_LENGTH_MISMATCH();
    error INVALID_ITEM_ID();
    error ITEM_ALREADY_EXISTS(bytes32 itemID);
    error ITEM_NOT_DEPLOYED();
    error ITEM_NOT_ACTIVE();
    error ITEM_NOT_TERMINAL();
    error GOAL_TERMINAL();

    event AuthorityTransferStarted(address indexed authority, address indexed pendingAuthority);
    event AuthorityTransferred(address indexed previousAuthority, address indexed nextAuthority);
    event ManagedBudgetCreated(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        address premiumEscrow,
        address strategy
    );
    event ManagedBudgetRemoved(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        bool removedFromParent,
        bool terminallyResolved
    );
    event ManagedBudgetWeightsSet(bytes32[] itemIDs, uint32[] ppm);
    event ManagedBudgetFlowWeightsSet(bytes32 indexed budgetItemID, bytes32[] itemIDs, uint32[] ppm);

    function initialize(InitConfig calldata initConfig) external;

    function authority() external view returns (address);
    function pendingAuthority() external view returns (address);
    function goalTreasury() external view returns (address);
    function goalFlow() external view returns (address);
    function stackDeployer() external view returns (address);
    function budgetGatePolicy() external view returns (address);
    function budgetSuccessResolver() external view returns (address);
    function budgetSpendPolicy() external view returns (address);
    function successAssertionLiveness() external view returns (uint64);
    function successAssertionBond() external view returns (uint256);

    function activeBudgetCount() external view returns (uint256 count);
    function activeBudgetIdAt(uint256 index) external view returns (bytes32 itemID);

    function createBudget(
        bytes32 itemID,
        BudgetConfig calldata config
    ) external returns (address childFlow, address budgetTreasury);

    function removeBudget(bytes32 itemID) external returns (bool removedFromParent, bool terminallyResolved);

    function setBudgetWeights(bytes32[] calldata itemIDs, uint32[] calldata ppm) external;
    function setBudgetFlowWeights(bytes32 budgetItemID, bytes32[] calldata itemIDs, uint32[] calldata ppm) external;
    function addBudgetFlowRecipient(
        bytes32 budgetItemID,
        bytes32 recipientId,
        address recipient,
        FlowTypes.RecipientMetadata calldata metadata
    ) external returns (bytes32 createdRecipientId, address recipientAddress);
    function removeBudgetFlowRecipient(bytes32 budgetItemID, bytes32 recipientId) external;
    function setBudgetFlowRecipientEnabled(bytes32 budgetItemID, bytes32 recipientId, bool enabled) external;

    function transferAuthority(address newAuthority) external;
    function acceptAuthority() external;
}
