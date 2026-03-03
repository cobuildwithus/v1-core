// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { ISubmissionDepositStrategy } from "./interfaces/ISubmissionDepositStrategy.sol";
import { IAllocationRoundFactory } from "./interfaces/IAllocationRoundFactory.sol";

import { MechanismFundingEscrow } from "src/escrow/MechanismFundingEscrow.sol";

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IManagedFlow } from "src/interfaces/IManagedFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

/**
 * @title AllocationMechanismTCR
 * @notice A budget-scoped TCR that curates allocation mechanisms (initially, rounds).
 *
 *         Operationally:
 *         - Items represent "round mechanisms" (metadata + timing + optional funding policy).
 *         - When an item becomes Registered, activation is queued.
 *         - Anyone can call `activateRound(itemID)` to deploy the round stack via the allowlisted
 *           mechanism factory declared in that listing payload.
 *         - On activation, this contract deploys a MechanismFundingEscrow and adds the escrow as the
 *           budget-flow recipient. Budget-flow funds are therefore escrowed and can be:
 *             - Released into the RoundPrizeVault for payouts (once min-funding is met), or
 *             - Refunded back to the budget flow if the round expires underfunded.
 *         - When an item becomes Absent (removed), removal is queued.
 *         - Anyone can call `finalizeRemovedRound(itemID)` to remove the recipient from the budget flow.
 *
 *         Funding lifecycle enforcement:
 *         - This contract can permissionlessly stop funding when:
 *             - the round reaches its maxBudgetFunding cap,
 *             - the round passes endAt (contest window ended), or
 *             - the round passes fundingDeadline without meeting minBudgetFunding (expired underfunded).
 *         - Underfunded expiry refunds escrowed funds back to the budget flow address.
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

    struct RoundDeploymentConfig {
        /// @notice Allowlisted factory that deploys this mechanism.
        address mechanismFactory;
        // RoundSubmissionTCR config
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        address submissionTcrGovernor;
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

    /// @dev Round listing stored as item data and fixed at curation time.
    /// @notice Funding policy applies only to budget-flow contributions (escrow receipts).
    struct RoundMechanismListing {
        FlowTypes.RecipientMetadata metadata;
        /// @notice Submission window start timestamp (0 means no gating).
        uint64 startAt;
        /// @notice Submission window end timestamp (0 means no gating).
        uint64 endAt;
        /// @notice If non-zero and `minBudgetFunding` is not met by this timestamp,
        ///         the round expires underfunded and escrowed funds are refunded.
        uint64 fundingDeadline;
        /// @notice Minimum budget-flow funding required for the round to be eligible to use escrowed funds.
        uint256 minBudgetFunding;
        /// @notice Maximum budget-flow funding the round may receive. When reached, funding is stopped.
        uint256 maxBudgetFunding;
        /// @notice Immutable deployment config consumed at activation.
        RoundDeploymentConfig deployment;
    }

    struct RoundDeployment {
        address prizeVault;
        address submissionTCR;
        address arbitrator;
        address depositStrategy;
        /// @notice Escrow that receives budget-flow funding for this round.
        address fundingEscrow;
        /// @notice Whether this round is currently an active budget-flow recipient.
        bool active;
    }

    enum FundingStopReason {
        None,
        Ended,
        Capped,
        ExpiredUnderfunded
    }

    // ---------------------------
    // Errors
    // ---------------------------

    error ONLY_GOVERNOR();
    error INVALID_ROUND_CONFIG();
    error INVALID_TIME_WINDOW(uint64 startAt, uint64 endAt);
    error INVALID_FUNDING_POLICY(uint64 fundingDeadline, uint256 minBudgetFunding, uint256 maxBudgetFunding);
    error ROUND_ALREADY_ENDED(uint64 endAt);
    error NOT_REGISTERED();
    error NOT_QUEUED();
    error ALREADY_DEPLOYED();
    error BUDGET_FLOW_MISMATCH();
    error NOT_DEPLOYED();
    error REMOVAL_FINALIZATION_PENDING();
    error ROUND_BELOW_MIN_FUNDING(uint256 minRequired, uint256 totalReceived);
    error ROUND_EXPIRED_UNDERFUNDED(uint64 fundingDeadline, uint256 minRequired, uint256 totalReceived);
    error FACTORY_NOT_ALLOWED(address factory);
    error INVALID_FACTORY(address factory);

    // ---------------------------
    // Events
    // ---------------------------

    event RoundActivationQueued(bytes32 indexed itemID);
    event RoundRemovalQueued(bytes32 indexed itemID);
    event RoundActivated(
        bytes32 indexed itemID,
        address indexed prizeVault,
        address indexed fundingEscrow,
        address submissionTCR,
        address arbitrator,
        address depositStrategy
    );
    event RoundRemoved(bytes32 indexed itemID);
    event MechanismFactoryAllowedSet(address indexed factory, bool allowed);

    event RoundFundingStopped(bytes32 indexed itemID, FundingStopReason indexed reason, uint256 totalReceived);
    event RoundFundingRefunded(bytes32 indexed itemID, uint256 amount);
    event RoundFundingReleased(bytes32 indexed itemID, uint256 amount);

    // ---------------------------
    // Storage
    // ---------------------------

    mapping(address => bool) public mechanismFactoryAllowed;
    address public budgetTreasury;
    IManagedFlow public budgetFlow;

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
        address initialMechanismFactory_,
        RegistryConfig calldata registryConfig
    ) external initializer {
        if (budgetTreasury_ == address(0) || initialMechanismFactory_ == address(0)) revert ADDRESS_ZERO();
        if (initialMechanismFactory_.code.length == 0) revert INVALID_FACTORY(initialMechanismFactory_);

        budgetTreasury = budgetTreasury_;
        mechanismFactoryAllowed[initialMechanismFactory_] = true;
        address budgetFlowAddress = IBudgetTreasury(budgetTreasury_).flow();
        if (budgetFlowAddress == address(0) || budgetFlowAddress.code.length == 0) revert BUDGET_FLOW_MISMATCH();
        budgetFlow = IManagedFlow(budgetFlowAddress);

        // Basic sanity check: we must be recipient admin of the budget flow we intend to manage.
        if (budgetFlow.recipientAdmin() != address(this)) revert BUDGET_FLOW_MISMATCH();

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

    function activateRound(bytes32 itemID) external nonReentrant returns (IAllocationRoundFactory.DeployedRound memory deployed) {
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert NOT_REGISTERED();
        if (!activationQueued[itemID]) revert NOT_QUEUED();
        if (_roundDeployment[itemID].prizeVault != address(0)) revert ALREADY_DEPLOYED();

        RoundMechanismListing memory listing = _decodeListing(item.data);
        _validateListing(listing);

        // Avoid deploying rounds that are already past their intended lifecycle windows.
        if (listing.endAt != 0 && block.timestamp > listing.endAt) revert ROUND_ALREADY_ENDED(listing.endAt);
        if (_isExpiredUnderfunded(listing, 0)) {
            revert ROUND_EXPIRED_UNDERFUNDED(listing.fundingDeadline, listing.minBudgetFunding, 0);
        }

        RoundDeploymentConfig memory deploymentConfig = listing.deployment;
        address factory = deploymentConfig.mechanismFactory;
        if (!mechanismFactoryAllowed[factory]) revert FACTORY_NOT_ALLOWED(factory);
        if (factory.code.length == 0) revert INVALID_FACTORY(factory);

        deployed = IAllocationRoundFactory(factory).createRoundForBudget(
            itemID,
            budgetTreasury,
            IAllocationRoundFactory.RoundTiming({ startAt: listing.startAt, endAt: listing.endAt }),
            deploymentConfig.roundOperator,
            IAllocationRoundFactory.SubmissionTcrConfig({
                arbitratorExtraData: deploymentConfig.arbitratorExtraData,
                registrationMetaEvidence: deploymentConfig.registrationMetaEvidence,
                clearingMetaEvidence: deploymentConfig.clearingMetaEvidence,
                governor: deploymentConfig.submissionTcrGovernor,
                submissionBaseDeposit: deploymentConfig.submissionBaseDeposit,
                removalBaseDeposit: deploymentConfig.removalBaseDeposit,
                submissionChallengeBaseDeposit: deploymentConfig.submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit: deploymentConfig.removalChallengeBaseDeposit,
                challengePeriodDuration: deploymentConfig.challengePeriodDuration
            }),
            IAllocationRoundFactory.ArbitratorConfig({
                votingPeriod: deploymentConfig.votingPeriod,
                votingDelay: deploymentConfig.votingDelay,
                revealPeriod: deploymentConfig.revealPeriod,
                arbitrationCost: deploymentConfig.arbitrationCost,
                wrongOrMissedSlashBps: deploymentConfig.wrongOrMissedSlashBps,
                slashCallerBountyBps: deploymentConfig.slashCallerBountyBps
            })
        );

        ISuperfluidPool distributionPool = budgetFlow.distributionPool();
        if (address(distributionPool) == address(0)) revert BUDGET_FLOW_MISMATCH();

        // Deploy an escrow that will receive all budget-flow funding for this round.
        address escrow = address(
            new MechanismFundingEscrow(
                budgetFlow.superToken(), distributionPool, address(this), address(budgetFlow), deployed.prizeVault
            )
        );

        activationQueued[itemID] = false;

        _roundDeployment[itemID] = RoundDeployment({
            prizeVault: deployed.prizeVault,
            submissionTCR: deployed.submissionTCR,
            arbitrator: deployed.arbitrator,
            depositStrategy: deployed.depositStrategy,
            fundingEscrow: escrow,
            active: true
        });

        // Add the escrow as a budget-flow recipient.
        budgetFlow.addRecipient(itemID, escrow, listing.metadata);

        emit RoundActivated(
            itemID,
            deployed.prizeVault,
            escrow,
            deployed.submissionTCR,
            deployed.arbitrator,
            deployed.depositStrategy
        );
    }

    /// @notice Removes the round recipient from the budget flow when the item is removed from the TCR.
    /// @dev Also refunds any remaining escrowed budget-flow funds back to the budget flow address.
    function finalizeRemovedRound(bytes32 itemID) external nonReentrant {
        if (!removalQueued[itemID]) revert NOT_QUEUED();

        RoundDeployment storage dep = _roundDeployment[itemID];
        if (dep.prizeVault == address(0) || dep.fundingEscrow == address(0)) revert NOT_DEPLOYED();

        if (dep.active) {
            // Stop future funding only when still active; Flow.removeRecipient reverts if already removed.
            dep.active = false;
            budgetFlow.removeRecipient(itemID);
        }
        removalQueued[itemID] = false;

        // Refund remaining escrow balance back to the budget flow.
        _refundEscrow(itemID, dep.fundingEscrow);

        emit RoundRemoved(itemID);
    }

    function roundDeployment(bytes32 itemID) external view returns (RoundDeployment memory dep) {
        dep = _roundDeployment[itemID];
    }

    // ---------------------------
    // Funding lifecycle
    // ---------------------------

    /// @notice Permissionlessly enforces per-round funding policy.
    /// @dev Stops budget-flow funding when cap is reached or round ends.
    ///      Refunds escrowed funds on underfunded expiry.
    function syncRoundFunding(bytes32 itemID) external nonReentrant {
        _syncRoundFunding(itemID);
    }

    /// @notice Releases escrowed budget-flow funds into the prize vault.
    /// @dev Guarded by minBudgetFunding and underfunded-expiry rules.
    function releaseRoundFunds(bytes32 itemID, uint256 amount) external nonReentrant returns (uint256 released) {
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert NOT_REGISTERED();
        if (removalQueued[itemID]) revert REMOVAL_FINALIZATION_PENDING();
        RoundDeployment memory dep = _roundDeployment[itemID];
        if (dep.prizeVault == address(0) || dep.fundingEscrow == address(0)) revert NOT_DEPLOYED();

        RoundMechanismListing memory listing = _decodeListing(item.data);
        _validateListing(listing);

        uint256 totalReceived = _totalEscrowReceived(dep.fundingEscrow);

        // If the round would be considered expired-underfunded, do not allow release.
        if (_isExpiredUnderfunded(listing, totalReceived)) {
            revert ROUND_EXPIRED_UNDERFUNDED(listing.fundingDeadline, listing.minBudgetFunding, totalReceived);
        }

        if (listing.minBudgetFunding != 0 && totalReceived < listing.minBudgetFunding) {
            revert ROUND_BELOW_MIN_FUNDING(listing.minBudgetFunding, totalReceived);
        }

        uint256 toRelease = amount == 0 ? type(uint256).max : amount;
        released = MechanismFundingEscrow(dep.fundingEscrow).release(toRelease);
        if (released != 0) emit RoundFundingReleased(itemID, released);
    }

    // ---------------------------
    // Governance
    // ---------------------------

    function setMechanismFactoryAllowed(address factory, bool allowed) external onlyGovernor {
        if (factory == address(0)) revert ADDRESS_ZERO();
        if (allowed && factory.code.length == 0) revert INVALID_FACTORY(factory);
        mechanismFactoryAllowed[factory] = allowed;
        emit MechanismFactoryAllowedSet(factory, allowed);
    }

    // ---------------------------
    // TCR hooks
    // ---------------------------

    function _verifyItemData(bytes calldata itemData) internal view override returns (bool valid) {
        // Ensure the listing decodes, and validate required metadata fields.
        try this.decodeListing(itemData) returns (RoundMechanismListing memory decoded) {
            if (_hasInvalidTimeWindow(decoded)) return false;
            if (!_isValidFundingPolicy(decoded)) return false;
            if (!_isValidRoundDeploymentConfig(decoded.deployment)) return false;
            if (!mechanismFactoryAllowed[decoded.deployment.mechanismFactory]) return false;

            FlowTypes.RecipientMetadata memory metadata = decoded.metadata;
            // Flow enforces these, but failing early is cheaper.
            if (bytes(metadata.title).length == 0) return false;
            if (bytes(metadata.description).length == 0) return false;
            if (bytes(metadata.image).length == 0) return false;
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

        // Queue removal/finalization for any deployed round to guarantee escrow cleanup.
        if (_roundDeployment[itemID].prizeVault != address(0)) {
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

    function _validateListing(RoundMechanismListing memory listing) internal pure {
        if (_hasInvalidTimeWindow(listing)) {
            revert INVALID_TIME_WINDOW(listing.startAt, listing.endAt);
        }
        if (!_isValidFundingPolicy(listing)) {
            revert INVALID_FUNDING_POLICY(listing.fundingDeadline, listing.minBudgetFunding, listing.maxBudgetFunding);
        }
        if (!_isValidRoundDeploymentConfig(listing.deployment)) {
            revert INVALID_ROUND_CONFIG();
        }
    }

    function _hasInvalidTimeWindow(RoundMechanismListing memory listing) internal pure returns (bool) {
        return listing.endAt != 0 && listing.startAt != 0 && listing.endAt < listing.startAt;
    }

    function _isValidFundingPolicy(RoundMechanismListing memory listing) internal pure returns (bool) {
        // Funding policy sanity:
        // - max must be >= min when both are set.
        // - min and underfunded-expiry require a funding deadline.
        // - if endAt is set, fundingDeadline (when set) must not exceed it.
        if (listing.maxBudgetFunding != 0 && listing.minBudgetFunding != 0 && listing.maxBudgetFunding < listing.minBudgetFunding) {
            return false;
        }
        if (listing.fundingDeadline != 0 && listing.minBudgetFunding == 0) return false;
        if (listing.minBudgetFunding != 0 && listing.fundingDeadline == 0) return false;
        if (listing.endAt != 0 && listing.fundingDeadline != 0 && listing.fundingDeadline > listing.endAt) return false;

        return true;
    }

    function _isValidRoundDeploymentConfig(RoundDeploymentConfig memory config) internal pure returns (bool) {
        if (config.mechanismFactory == address(0)) return false;
        if (config.submissionTcrGovernor == address(0)) return false;
        if (config.roundOperator == address(0)) return false;
        if (bytes(config.registrationMetaEvidence).length == 0) return false;
        if (bytes(config.clearingMetaEvidence).length == 0) return false;
        return true;
    }

    function _totalEscrowReceived(address fundingEscrow) internal view returns (uint256) {
        return budgetFlow.distributionPool().getTotalAmountReceivedByMember(fundingEscrow);
    }

    function _stopFunding(
        bytes32 itemID,
        RoundDeployment storage dep,
        FundingStopReason reason,
        uint256 totalReceived
    ) internal {
        if (!dep.active) return;
        dep.active = false;
        budgetFlow.removeRecipient(itemID);
        emit RoundFundingStopped(itemID, reason, totalReceived);
    }

    function _isExpiredUnderfunded(
        RoundMechanismListing memory listing,
        uint256 totalReceived
    ) internal view returns (bool) {
        return
            listing.fundingDeadline != 0 &&
            listing.minBudgetFunding != 0 &&
            block.timestamp > listing.fundingDeadline &&
            totalReceived < listing.minBudgetFunding;
    }

    function _refundEscrow(bytes32 itemID, address fundingEscrow) internal {
        uint256 refunded = MechanismFundingEscrow(fundingEscrow).refund(type(uint256).max);
        if (refunded != 0) emit RoundFundingRefunded(itemID, refunded);
    }

    function _syncRoundFunding(bytes32 itemID) internal {
        RoundDeployment storage dep = _roundDeployment[itemID];
        if (dep.prizeVault == address(0) || dep.fundingEscrow == address(0)) revert NOT_DEPLOYED();
        if (removalQueued[itemID]) return;
        if (!dep.active) return;

        RoundMechanismListing memory listing = _decodeListing(items[itemID].data);
        _validateListing(listing);

        uint256 totalReceived = _totalEscrowReceived(dep.fundingEscrow);

        // Underfunded expiry has priority over other stop conditions, so funds are refunded
        // even if `endAt` has already passed.
        if (_isExpiredUnderfunded(listing, totalReceived)) {
            _stopFunding(itemID, dep, FundingStopReason.ExpiredUnderfunded, totalReceived);
            _refundEscrow(itemID, dep.fundingEscrow);
            return;
        }

        if (listing.maxBudgetFunding != 0 && totalReceived >= listing.maxBudgetFunding) {
            _stopFunding(itemID, dep, FundingStopReason.Capped, totalReceived);
            return;
        }

        if (listing.endAt != 0 && block.timestamp > listing.endAt) {
            _stopFunding(itemID, dep, FundingStopReason.Ended, totalReceived);
        }
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert ONLY_GOVERNOR();
        _;
    }
}
