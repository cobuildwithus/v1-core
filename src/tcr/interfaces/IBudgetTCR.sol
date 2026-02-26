// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IGeneralizedTCR } from "./IGeneralizedTCR.sol";
import { IArbitrator } from "./IArbitrator.sol";
import { ISubmissionDepositStrategy } from "./ISubmissionDepositStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

interface IBudgetTCR is IGeneralizedTCR {
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
        uint8 maxOracleType;
        uint64 liveness;
        uint256 bondAmount;
    }

    struct OracleConfig {
        uint8 oracleType;
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

    struct RegistryConfig {
        address governor;
        IArbitrator arbitrator;
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        IVotes votingToken;
        uint256 submissionBaseDeposit;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
        ISubmissionDepositStrategy submissionDepositStrategy;
    }

    struct DeploymentConfig {
        address stackDeployer;
        address itemValidator;
        address budgetSuccessResolver;
        IFlow goalFlow;
        IGoalTreasury goalTreasury;
        IERC20 goalToken;
        IERC20 cobuildToken;
        IJBRulesets goalRulesets;
        uint256 goalRevnetId;
        uint8 paymentTokenDecimals;
        address managerRewardPool;
        BudgetValidationBounds budgetValidationBounds;
        OracleValidationBounds oracleValidationBounds;
    }

    event BudgetStackDeployed(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        address stakeVault,
        address strategy
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

    error INVALID_BOUNDS();
    error ITEM_NOT_DEPLOYED();
    error ITEM_NOT_REGISTERED();
    error ITEM_NOT_REMOVED();
    error REMOVAL_FINALIZATION_PENDING();
    error REGISTRATION_NOT_PENDING();
    error REMOVAL_NOT_PENDING();
    error STACK_ALREADY_ACTIVE();
    error STACK_STILL_ACTIVE();
    error TERMINAL_RESOLUTION_FAILED();
    error REWARD_ESCROW_NOT_CONFIGURED();
    error BUDGET_STAKE_LEDGER_NOT_CONFIGURED();

    function initialize(RegistryConfig calldata registryConfig, DeploymentConfig calldata deploymentConfig) external;
    function activateRegisteredBudget(bytes32 itemID) external returns (bool activated);
    function finalizeRemovedBudget(bytes32 itemID) external returns (bool terminallyResolved);
    function isRegistrationPending(bytes32 itemId) external view returns (bool pending);
    function isRemovalPending(bytes32 itemId) external view returns (bool pending);
    function retryRemovedBudgetResolution(bytes32 itemID) external returns (bool terminallyResolved);
    function syncBudgetTreasuries(bytes32[] calldata itemIDs) external returns (uint256 attempted, uint256 succeeded);
}
