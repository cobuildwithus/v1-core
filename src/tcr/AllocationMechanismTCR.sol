// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { ISubmissionDepositStrategy } from "./interfaces/ISubmissionDepositStrategy.sol";

import { RoundFactory } from "src/rounds/RoundFactory.sol";

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IManagedFlow } from "src/interfaces/IManagedFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title AllocationMechanismTCR
 * @notice A budget-scoped TCR that curates allocation mechanisms (initially, rounds).
 *
 *         Operationally:
 *         - Items represent "round mechanisms" (metadata + timing).
 *         - When an item becomes Registered, activation is queued.
 *         - Anyone can call `activateRound(itemID)` to deploy the round stack via a shared
 *           RoundFactory and add the resulting RoundPrizeVault as a recipient to the budget flow.
 *         - When an item becomes Absent (removed), removal is queued.
 *         - Anyone can call `finalizeRemovedRound(itemID)` to remove the recipient from the budget flow.
 *
 *         This contract is intended to be set as `recipientAdmin` of the budget flow it manages.
 */
contract AllocationMechanismTCR is GeneralizedTCR {
    // ---------------------------
    // Types
    // ---------------------------

    struct RegistryConfig {
        IArbitrator arbitrator;
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        address governor;
        IVotes votingToken;
        uint256 submissionBaseDeposit;
        ISubmissionDepositStrategy submissionDepositStrategy;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
    }

    /// @dev Round listing stored as item data.
    struct RoundMechanismListing {
        FlowTypes.RecipientMetadata metadata;
        uint64 startAt;
        uint64 endAt;
    }

    /// @dev Default config applied to new rounds deployed via this registry.
    struct RoundDefaults {
        // RoundSubmissionTCR config
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        address governor;
        uint256 submissionBaseDeposit;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
        // Arbitrator config
        uint256 votingPeriod;
        uint256 votingDelay;
        uint256 revealPeriod;
        uint256 arbitrationCost;
        uint256 wrongOrMissedSlashBps;
        uint256 slashCallerBountyBps;
        // Prize vault operator
        address roundOperator;
    }

    struct RoundDeployment {
        address prizeVault;
        address submissionTCR;
        address arbitrator;
        address depositStrategy;
        bool active;
    }

    // ---------------------------
    // Errors
    // ---------------------------

    error ONLY_GOVERNOR();
    error INVALID_ROUND_DEFAULTS();
    error INVALID_TIME_WINDOW(uint64 startAt, uint64 endAt);
    error NOT_REGISTERED();
    error NOT_QUEUED();
    error ALREADY_DEPLOYED();
    error BUDGET_FLOW_MISMATCH();
    error NOT_ACTIVE();
    error REMOVAL_FINALIZATION_PENDING();

    // ---------------------------
    // Events
    // ---------------------------

    event RoundActivationQueued(bytes32 indexed itemID);
    event RoundRemovalQueued(bytes32 indexed itemID);
    event RoundActivated(
        bytes32 indexed itemID,
        address indexed prizeVault,
        address submissionTCR,
        address arbitrator,
        address depositStrategy
    );
    event RoundRemoved(bytes32 indexed itemID);
    event RoundDefaultsUpdated();

    // ---------------------------
    // Storage
    // ---------------------------

    RoundFactory public roundFactory;
    address public budgetTreasury;
    IManagedFlow public budgetFlow;

    RoundDefaults public roundDefaults;

    mapping(bytes32 => bool) public activationQueued;
    mapping(bytes32 => bool) public removalQueued;
    mapping(bytes32 => RoundDeployment) internal _roundDeployment;

    constructor() {
        _disableInitializers();
    }

    // ---------------------------
    // Init
    // ---------------------------

    function initialize(
        address budgetTreasury_,
        address roundFactory_,
        RoundDefaults calldata roundDefaults_,
        RegistryConfig calldata registryConfig
    ) external initializer {
        if (budgetTreasury_ == address(0) || roundFactory_ == address(0)) revert ADDRESS_ZERO();
        if (roundDefaults_.roundOperator == address(0)) revert ADDRESS_ZERO();
        _validateRoundDefaults(roundDefaults_);

        budgetTreasury = budgetTreasury_;
        roundFactory = RoundFactory(roundFactory_);
        address budgetFlowAddress = IBudgetTreasury(budgetTreasury_).flow();
        if (budgetFlowAddress == address(0) || budgetFlowAddress.code.length == 0) revert BUDGET_FLOW_MISMATCH();
        budgetFlow = IManagedFlow(budgetFlowAddress);

        // Basic sanity check: we must be recipient admin of the budget flow we intend to manage.
        if (budgetFlow.recipientAdmin() != address(this)) revert BUDGET_FLOW_MISMATCH();

        roundDefaults = roundDefaults_;

        __GeneralizedTCR_init(
            registryConfig.arbitrator,
            registryConfig.arbitratorExtraData,
            registryConfig.registrationMetaEvidence,
            registryConfig.clearingMetaEvidence,
            registryConfig.governor,
            registryConfig.votingToken,
            registryConfig.submissionBaseDeposit,
            registryConfig.removalBaseDeposit,
            registryConfig.submissionChallengeBaseDeposit,
            registryConfig.removalChallengeBaseDeposit,
            registryConfig.challengePeriodDuration,
            registryConfig.submissionDepositStrategy
        );
    }

    // ---------------------------
    // Round lifecycle
    // ---------------------------

    function activateRound(bytes32 itemID) external nonReentrant returns (RoundFactory.DeployedRound memory deployed) {
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert NOT_REGISTERED();
        if (!activationQueued[itemID]) revert NOT_QUEUED();
        if (_roundDeployment[itemID].prizeVault != address(0)) revert ALREADY_DEPLOYED();

        RoundMechanismListing memory listing = _decodeListing(item.data);
        if (listing.endAt != 0 && listing.startAt != 0 && listing.endAt < listing.startAt) {
            revert INVALID_TIME_WINDOW(listing.startAt, listing.endAt);
        }

        deployed = roundFactory.createRoundForBudget(
            itemID,
            budgetTreasury,
            RoundFactory.RoundTiming({ startAt: listing.startAt, endAt: listing.endAt }),
            roundDefaults.roundOperator,
            RoundFactory.SubmissionTcrConfig({
                arbitratorExtraData: roundDefaults.arbitratorExtraData,
                registrationMetaEvidence: roundDefaults.registrationMetaEvidence,
                clearingMetaEvidence: roundDefaults.clearingMetaEvidence,
                governor: roundDefaults.governor,
                submissionBaseDeposit: roundDefaults.submissionBaseDeposit,
                removalBaseDeposit: roundDefaults.removalBaseDeposit,
                submissionChallengeBaseDeposit: roundDefaults.submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit: roundDefaults.removalChallengeBaseDeposit,
                challengePeriodDuration: roundDefaults.challengePeriodDuration
            }),
            RoundFactory.ArbitratorConfig({
                votingPeriod: roundDefaults.votingPeriod,
                votingDelay: roundDefaults.votingDelay,
                revealPeriod: roundDefaults.revealPeriod,
                arbitrationCost: roundDefaults.arbitrationCost,
                wrongOrMissedSlashBps: roundDefaults.wrongOrMissedSlashBps,
                slashCallerBountyBps: roundDefaults.slashCallerBountyBps
            })
        );

        // Add the deployed prize vault as a budget-flow recipient.
        budgetFlow.addRecipient(itemID, deployed.prizeVault, listing.metadata);

        activationQueued[itemID] = false;

        _roundDeployment[itemID] = RoundDeployment({
            prizeVault: deployed.prizeVault,
            submissionTCR: deployed.submissionTCR,
            arbitrator: deployed.arbitrator,
            depositStrategy: deployed.depositStrategy,
            active: true
        });

        emit RoundActivated(itemID, deployed.prizeVault, deployed.submissionTCR, deployed.arbitrator, deployed.depositStrategy);
    }

    function finalizeRemovedRound(bytes32 itemID) external nonReentrant {
        if (!removalQueued[itemID]) revert NOT_QUEUED();

        RoundDeployment storage dep = _roundDeployment[itemID];
        if (!dep.active) revert NOT_ACTIVE();

        budgetFlow.removeRecipient(itemID);
        dep.active = false;
        removalQueued[itemID] = false;

        emit RoundRemoved(itemID);
    }

    function roundDeployment(bytes32 itemID) external view returns (RoundDeployment memory dep) {
        dep = _roundDeployment[itemID];
    }

    // ---------------------------
    // Governance
    // ---------------------------

    function setRoundDefaults(RoundDefaults calldata next) external onlyGovernor {
        if (next.roundOperator == address(0)) revert ADDRESS_ZERO();
        _validateRoundDefaults(next);
        roundDefaults = next;
        emit RoundDefaultsUpdated();
    }

    // ---------------------------
    // TCR hooks
    // ---------------------------

    function _verifyItemData(bytes calldata itemData) internal view override returns (bool valid) {
        // Ensure the listing decodes, and validate required metadata fields.
        try this.decodeListing(itemData) returns (RoundMechanismListing memory decoded) {
            if (decoded.endAt != 0 && decoded.startAt != 0 && decoded.endAt < decoded.startAt) return false;

            // Flow enforces these, but failing early is cheaper.
            if (bytes(decoded.metadata.title).length == 0) return false;
            if (bytes(decoded.metadata.description).length == 0) return false;
            if (bytes(decoded.metadata.image).length == 0) return false;
            return true;
        } catch {
            return false;
        }
    }

    function _assertCanAddItem(bytes32 itemID, bytes calldata) internal view override {
        if (removalQueued[itemID]) revert REMOVAL_FINALIZATION_PENDING();
        if (_roundDeployment[itemID].prizeVault != address(0)) revert ALREADY_DEPLOYED();
    }

    function _onItemRegistered(bytes32 itemID, bytes memory) internal override {
        activationQueued[itemID] = true;
        removalQueued[itemID] = false;
        emit RoundActivationQueued(itemID);
    }

    function _onItemRemoved(bytes32 itemID) internal override {
        activationQueued[itemID] = false;

        // If the recipient was activated, queue removal from the budget flow.
        if (_roundDeployment[itemID].active) {
            removalQueued[itemID] = true;
            emit RoundRemovalQueued(itemID);
        }
    }

    // ---------------------------
    // Internal
    // ---------------------------

    function _decodeListing(bytes memory itemData) internal pure returns (RoundMechanismListing memory listing) {
        listing = abi.decode(itemData, (RoundMechanismListing));
    }

    /// @notice Public decode helper used for safe try/catch validation in `_verifyItemData`.
    function decodeListing(bytes calldata itemData) external pure returns (RoundMechanismListing memory listing) {
        listing = _decodeListing(itemData);
    }

    function _validateRoundDefaults(RoundDefaults calldata defaults) internal pure {
        if (defaults.governor == address(0)) revert INVALID_ROUND_DEFAULTS();
        if (bytes(defaults.registrationMetaEvidence).length == 0) revert INVALID_ROUND_DEFAULTS();
        if (bytes(defaults.clearingMetaEvidence).length == 0) revert INVALID_ROUND_DEFAULTS();
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert ONLY_GOVERNOR();
        _;
    }
}
