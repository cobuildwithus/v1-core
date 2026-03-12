// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IGeneralizedTCR } from "./IGeneralizedTCR.sol";
import { IGeneralizedTCRConfig } from "./IGeneralizedTCRConfig.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { IBudgetController } from "src/interfaces/IBudgetController.sol";

interface IBudgetTCR is IGeneralizedTCR, IBudgetController {
    struct BudgetValidationBounds {
        uint64 minFundingLeadTime;
        uint64 maxFundingHorizon;
        uint64 minExecutionDuration;
        uint64 maxExecutionDuration;
        uint256 minActivationThreshold;
        uint256 maxActivationThreshold;
        uint256 maxRunwayCap;
    }

    struct OracleValidationBounds {
        uint64 liveness;
        uint256 bondAmount;
    }

    struct OracleConfig {
        bytes32 oracleSpecHash;
        bytes32 assertionPolicyHash;
    }

    struct BudgetListing {
        FlowTypes.RecipientMetadata metadata;
        uint64 fundingDeadline;
        uint64 executionDuration;
        uint256 activationThreshold;
        uint256 runwayCap;
        OracleConfig oracleConfig;
    }

    struct InitConfig {
        address allocationMechanismAdmin;
        IGeneralizedTCRConfig.RegistryConfig tcrConfig;
    }

    struct RiskModuleRouting {
        address budgetGatePolicy;
        address premiumEscrowImplementation;
        address underwriterSlasherRouter;
        bool requireZeroPremiumAndSlashRates;
    }

    struct DeploymentConfig {
        address stackDeployer;
        address budgetSuccessResolver;
        address budgetSpendPolicy;
        RiskModuleRouting riskModuleRouting;
        IFlow goalFlow;
        IGoalTreasury goalTreasury;
        IERC20 goalToken;
        IERC20 cobuildToken;
        IJBRulesets goalRulesets;
        uint256 goalRevnetId;
        uint8 paymentTokenDecimals;
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
        BudgetValidationBounds budgetValidationBounds;
        OracleValidationBounds oracleValidationBounds;
    }

    event BudgetStackDeployed(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        address strategy
    );
    event BudgetAllocationMechanismDeployed(
        bytes32 indexed itemID,
        address indexed allocationMechanism,
        address indexed allocationMechanismArbitrator,
        address roundFactory
    );
    event BudgetStackActivationQueued(bytes32 indexed itemID);
    event BudgetStackRemovalQueued(bytes32 indexed itemID);

    event BudgetStackRemovalHandled(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        bool removedFromParent,
        bool terminallyResolved
    );

    event BudgetStackTerminalizationRetried(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bool terminallyResolved
    );
    event BudgetTerminalRecipientPruned(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        bool removedFromParent,
        bool goalSynced
    );
    event BudgetTerminalizationStepFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bytes4 indexed selector,
        bytes reason
    );

    event BudgetTreasuryBatchSyncAttempted(bytes32 indexed itemID, address indexed budgetTreasury, bool success);
    event BudgetTreasuryBatchSyncSkipped(bytes32 indexed itemID, address indexed budgetTreasury, bytes32 reason);
    event BudgetTreasuryCallFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bytes4 indexed selector,
        bytes reason
    );
    event BudgetCreditCapEnforcementFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        address callTarget,
        bytes4 indexed selector,
        bytes reason
    );

    error INVALID_BOUNDS();
    error ITEM_NOT_DEPLOYED();
    error ITEM_NOT_REGISTERED();
    error REMOVAL_FINALIZATION_PENDING();
    error ITEM_RELIST_NOT_ALLOWED(bytes32 itemID);
    error REGISTRATION_NOT_PENDING();
    error REMOVAL_NOT_PENDING();
    error STACK_ALREADY_ACTIVE();
    error STACK_STILL_ACTIVE();
    error ITEM_NOT_TERMINAL();
    error TERMINAL_RESOLUTION_FAILED();
    error BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
    error INVALID_PPM(uint32 ppmValue);
    error NOT_A_CONTRACT(address account);
    error INVALID_BUDGET_SPEND_POLICY(address policy);
    error INVALID_BUDGET_GATE_POLICY(address policy);
    error INVALID_PREMIUM_ESCROW_IMPLEMENTATION(address implementation);
    error PREMIUM_MODULE_CONFIG_MISMATCH();
    error PREMIUM_MODULE_ABSENCE_REQUIRES_ZERO_RATES();
    error UNDERWRITER_SLASHER_NOT_CONFIGURED();
    error MANAGER_REWARD_DISTRIBUTION_POOL_NOT_CONFIGURED();
    error GOAL_TERMINAL();

    function initialize(InitConfig calldata initConfig, DeploymentConfig calldata deploymentConfig) external;
    function activateRegisteredBudget(bytes32 itemID) external returns (bool activated);
    function finalizeRemovedBudget(bytes32 itemID) external returns (bool terminallyResolved);
    function isRegistrationPending(bytes32 itemId) external view returns (bool pending);
    function isRemovalPending(bytes32 itemId) external view returns (bool pending);
    function retryRemovedBudgetResolution(bytes32 itemID) external returns (bool terminallyResolved);
    function budgetSpendPolicy() external view returns (address);
    function budgetGatePolicy() external view returns (address);
}
