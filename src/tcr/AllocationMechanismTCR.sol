// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IGeneralizedTCRConfig } from "./interfaces/IGeneralizedTCRConfig.sol";
import { IAllocationMechanismFactory } from "./interfaces/IAllocationMechanismFactory.sol";

import { MechanismFundingEscrow } from "src/escrow/MechanismFundingEscrow.sol";

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IManagedFlow } from "src/interfaces/IManagedFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

/**
 * @title AllocationMechanismTCR
 * @notice A budget-scoped registry for allocation mechanisms.
 *
 *         Each curated item contains:
 *         - recipient metadata for budget flow,
 *         - optional timing/funding policy,
 *         - a mechanism factory + opaque mechanism config payload.
 *
 *         Operationally:
 *         - When an item becomes Registered, activation is queued.
 *         - Anyone can call `activateMechanism(itemID)` to deploy the mechanism stack via the
 *           allowlisted mechanism factory declared in the listing payload.
 *         - On activation, this contract deploys a `MechanismFundingEscrow` and adds it as the
 *           budget-flow recipient. Escrowed funds can be:
 *             - Released into the mechanism payout recipient once min-funding is met, or
 *             - Refunded back to budget flow if the listing expires underfunded.
 *         - When an item becomes Absent (removed), removal is queued.
 *         - Anyone can call `finalizeRemovedMechanism(itemID)` to remove recipient + refund escrow.
 */
contract AllocationMechanismTCR is GeneralizedTCR {
    uint256 public constant MAX_ACTIVE_MECHANISM_RECIPIENTS = 7;
    address public immutable mechanismFundingEscrowImplementation;

    // ---------------------------
    // Types
    // ---------------------------

    struct InitConfig {
        IGeneralizedTCRConfig.RegistryConfig tcrConfig;
        address factoryManager;
    }

    struct MechanismDeploymentConfig {
        /// @notice Allowlisted mechanism factory for this listing.
        address mechanismFactory;
        /// @notice Opaque config blob consumed by `mechanismFactory.deployForBudget(...)`.
        bytes mechanismConfig;
    }

    struct MechanismListing {
        FlowTypes.RecipientMetadata metadata;
        /// @notice Optional lifecycle duration from activation time (0 = no duration stop).
        uint64 duration;
        /// @notice Optional underfunded-expiry deadline for min funding.
        uint64 fundingDeadline;
        /// @notice Minimum funding required before escrow release is permitted.
        uint256 minBudgetFunding;
        /// @notice Maximum funding cap; once reached, recipient is disabled.
        uint256 maxBudgetFunding;
        /// @notice Immutable mechanism deployment config.
        MechanismDeploymentConfig deploymentConfig;
    }

    struct MechanismDeployment {
        address mechanism;
        address payoutRecipient;
        address arbitrator;
        address auxiliary;
        address fundingEscrow;
        uint64 activatedAt;
        uint256 maxEffectiveFundingObserved;
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

    error ONLY_FACTORY_MANAGER();
    error INVALID_MECHANISM_CONFIG();
    error INVALID_FUNDING_POLICY(uint64 fundingDeadline, uint256 minBudgetFunding, uint256 maxBudgetFunding);
    error NOT_REGISTERED();
    error NOT_QUEUED();
    error ALREADY_DEPLOYED();
    error BUDGET_FLOW_MISMATCH();
    error NOT_DEPLOYED();
    error REMOVAL_FINALIZATION_PENDING();
    error MECHANISM_BELOW_MIN_FUNDING(uint256 minRequired, uint256 totalReceived);
    error MECHANISM_EXPIRED_UNDERFUNDED(uint64 fundingDeadline, uint256 minRequired, uint256 totalReceived);
    error FACTORY_NOT_ALLOWED(address factory);
    error INVALID_FACTORY(address factory);
    error ACTIVE_MECHANISM_RECIPIENT_CAP_REACHED(uint256 maxRecipients);
    error ACTIVE_MECHANISM_RECIPIENT_COUNT_UNDERFLOW();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);

    // ---------------------------
    // Events
    // ---------------------------

    event MechanismActivationQueued(bytes32 indexed itemID);
    event MechanismRemovalQueued(bytes32 indexed itemID);
    event MechanismActivated(
        bytes32 indexed itemID,
        address indexed mechanism,
        address indexed fundingEscrow,
        address payoutRecipient,
        address arbitrator,
        address auxiliary
    );
    event MechanismRemoved(bytes32 indexed itemID);
    event MechanismFactoryAllowedSet(address indexed factory, bool allowed);

    event MechanismFundingStopped(bytes32 indexed itemID, FundingStopReason indexed reason, uint256 totalReceived);
    event MechanismFundingRefunded(bytes32 indexed itemID, uint256 amount);
    event MechanismFundingReleased(bytes32 indexed itemID, uint256 amount);

    // ---------------------------
    // Storage
    // ---------------------------

    mapping(address => bool) public mechanismFactoryAllowed;
    address public budgetTreasury;
    address public factoryManager;
    IManagedFlow public budgetFlow;

    mapping(bytes32 => bool) public activationQueued;
    mapping(bytes32 => bool) public removalQueued;
    mapping(bytes32 => MechanismDeployment) internal _mechanismDeployment;
    uint256 public activeMechanismRecipientCount;

    constructor(address mechanismFundingEscrowImplementation_) {
        if (mechanismFundingEscrowImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (mechanismFundingEscrowImplementation_.code.length == 0) {
            revert IMPLEMENTATION_HAS_NO_CODE(mechanismFundingEscrowImplementation_);
        }

        mechanismFundingEscrowImplementation = mechanismFundingEscrowImplementation_;
        _disableInitializers();
    }

    // ---------------------------
    // Init
    // ---------------------------

    function initialize(
        address budgetTreasury_,
        address initialMechanismFactory_,
        InitConfig calldata initConfig
    ) external initializer {
        if (budgetTreasury_ == address(0) || initialMechanismFactory_ == address(0)) revert ADDRESS_ZERO();
        if (initialMechanismFactory_.code.length == 0) revert INVALID_FACTORY(initialMechanismFactory_);

        budgetTreasury = budgetTreasury_;
        mechanismFactoryAllowed[initialMechanismFactory_] = true;
        address budgetFlowAddress = IBudgetTreasury(budgetTreasury_).flow();
        if (budgetFlowAddress == address(0) || budgetFlowAddress.code.length == 0) revert BUDGET_FLOW_MISMATCH();
        budgetFlow = IManagedFlow(budgetFlowAddress);

        if (budgetFlow.recipientAdmin() != address(this)) revert BUDGET_FLOW_MISMATCH();

        __GeneralizedTCR_init(initConfig.tcrConfig);
        if (initConfig.factoryManager == address(0)) revert ADDRESS_ZERO();
        factoryManager = initConfig.factoryManager;
    }

    // ---------------------------
    // Mechanism lifecycle
    // ---------------------------

    function activateMechanism(
        bytes32 itemID
    ) external nonReentrant returns (IAllocationMechanismFactory.DeployedMechanism memory deployed) {
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert NOT_REGISTERED();
        if (!activationQueued[itemID]) revert NOT_QUEUED();
        if (_mechanismDeployment[itemID].mechanism != address(0)) revert ALREADY_DEPLOYED();
        if (activeMechanismRecipientCount >= MAX_ACTIVE_MECHANISM_RECIPIENTS) {
            revert ACTIVE_MECHANISM_RECIPIENT_CAP_REACHED(MAX_ACTIVE_MECHANISM_RECIPIENTS);
        }

        MechanismListing memory listing = _decodeAndValidateListing(item.data);

        if (_isExpiredUnderfunded(listing, 0)) {
            revert MECHANISM_EXPIRED_UNDERFUNDED(listing.fundingDeadline, listing.minBudgetFunding, 0);
        }

        address factory = listing.deploymentConfig.mechanismFactory;
        if (!mechanismFactoryAllowed[factory]) revert FACTORY_NOT_ALLOWED(factory);
        if (factory.code.length == 0) revert INVALID_FACTORY(factory);

        deployed = IAllocationMechanismFactory(factory).deployForBudget(
            itemID,
            budgetTreasury,
            listing.deploymentConfig.mechanismConfig
        );

        ISuperfluidPool distributionPool = budgetFlow.distributionPool();
        if (address(distributionPool) == address(0)) revert BUDGET_FLOW_MISMATCH();
        _validateFactoryDeployment(deployed);

        address escrow = _deployMechanismFundingEscrow(distributionPool, deployed.payoutRecipient);

        activationQueued[itemID] = false;
        _mechanismDeployment[itemID] = MechanismDeployment({
            mechanism: deployed.mechanism,
            payoutRecipient: deployed.payoutRecipient,
            arbitrator: deployed.arbitrator,
            auxiliary: deployed.auxiliary,
            fundingEscrow: escrow,
            activatedAt: uint64(block.timestamp),
            maxEffectiveFundingObserved: 0,
            active: true
        });

        budgetFlow.addRecipient(itemID, escrow, listing.metadata);
        _incrementActiveMechanismRecipientCount();

        emit MechanismActivated(
            itemID,
            deployed.mechanism,
            escrow,
            deployed.payoutRecipient,
            deployed.arbitrator,
            deployed.auxiliary
        );
    }

    function finalizeRemovedMechanism(bytes32 itemID) external nonReentrant {
        if (!removalQueued[itemID]) revert NOT_QUEUED();

        MechanismDeployment storage dep = _mechanismDeployment[itemID];
        if (dep.mechanism == address(0) || dep.fundingEscrow == address(0)) revert NOT_DEPLOYED();

        _deactivateMechanismRecipient(itemID, dep);
        removalQueued[itemID] = false;

        _refundEscrow(itemID, dep.fundingEscrow);

        emit MechanismRemoved(itemID);
    }

    function mechanismDeployment(bytes32 itemID) external view returns (MechanismDeployment memory dep) {
        dep = _mechanismDeployment[itemID];
    }

    // ---------------------------
    // Funding lifecycle
    // ---------------------------

    function syncMechanismFunding(bytes32 itemID) external nonReentrant {
        _syncMechanismFunding(itemID);
    }

    function releaseMechanismFunds(bytes32 itemID, uint256 amount) external nonReentrant returns (uint256 released) {
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert NOT_REGISTERED();
        if (removalQueued[itemID]) revert REMOVAL_FINALIZATION_PENDING();

        _syncMechanismFunding(itemID);
        MechanismDeployment storage dep = _mechanismDeployment[itemID];

        MechanismListing memory listing = _decodeAndValidateListing(item.data);

        uint256 policyFunding = _policyFundingLevel(dep);

        if (_isExpiredUnderfunded(listing, policyFunding)) {
            return 0;
        }

        if (listing.minBudgetFunding != 0 && policyFunding < listing.minBudgetFunding) {
            revert MECHANISM_BELOW_MIN_FUNDING(listing.minBudgetFunding, policyFunding);
        }

        uint256 toRelease = amount == 0 ? type(uint256).max : amount;
        released = MechanismFundingEscrow(dep.fundingEscrow).release(toRelease);
        if (released != 0) emit MechanismFundingReleased(itemID, released);
    }

    // ---------------------------
    // Governance
    // ---------------------------

    function setMechanismFactoryAllowed(address factory, bool allowed) external onlyFactoryManager {
        if (factory == address(0)) revert ADDRESS_ZERO();
        if (allowed && factory.code.length == 0) revert INVALID_FACTORY(factory);
        mechanismFactoryAllowed[factory] = allowed;
        emit MechanismFactoryAllowedSet(factory, allowed);
    }

    // ---------------------------
    // TCR hooks
    // ---------------------------

    function _verifyItemData(bytes calldata itemData) internal view override returns (bool valid) {
        try this.decodeMechanismListing(itemData) returns (MechanismListing memory decoded) {
            if (!_isValidFundingPolicy(decoded)) return false;
            if (!_isValidMechanismDeploymentConfig(decoded.deploymentConfig)) return false;
            if (!mechanismFactoryAllowed[decoded.deploymentConfig.mechanismFactory]) return false;

            FlowTypes.RecipientMetadata memory metadata = decoded.metadata;
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
        if (_mechanismDeployment[itemID].mechanism != address(0)) revert ALREADY_DEPLOYED();
    }

    function _onItemRegistered(bytes32 itemID, bytes memory) internal override {
        activationQueued[itemID] = true;
        removalQueued[itemID] = false;
        emit MechanismActivationQueued(itemID);
    }

    function _onItemRemoved(bytes32 itemID) internal override {
        activationQueued[itemID] = false;

        if (_mechanismDeployment[itemID].mechanism != address(0)) {
            removalQueued[itemID] = true;
            emit MechanismRemovalQueued(itemID);
        }
    }

    // ---------------------------
    // Internal
    // ---------------------------

    function _decodeListing(bytes memory itemData) internal pure returns (MechanismListing memory listing) {
        listing = abi.decode(itemData, (MechanismListing));
    }

    function _deployMechanismFundingEscrow(
        ISuperfluidPool distributionPool,
        address payoutRecipient
    ) internal returns (address escrow) {
        escrow = Clones.clone(mechanismFundingEscrowImplementation);
        MechanismFundingEscrow(escrow).initialize(
            budgetFlow.superToken(),
            distributionPool,
            address(this),
            address(budgetFlow),
            payoutRecipient
        );
    }

    function decodeMechanismListing(bytes calldata itemData) external pure returns (MechanismListing memory listing) {
        listing = _decodeListing(itemData);
    }

    function _decodeAndValidateListing(bytes memory itemData) internal pure returns (MechanismListing memory listing) {
        listing = _decodeListing(itemData);
        _validateListing(listing);
    }

    function _validateListing(MechanismListing memory listing) internal pure {
        if (!_isValidFundingPolicy(listing)) {
            revert INVALID_FUNDING_POLICY(listing.fundingDeadline, listing.minBudgetFunding, listing.maxBudgetFunding);
        }
        if (!_isValidMechanismDeploymentConfig(listing.deploymentConfig)) {
            revert INVALID_MECHANISM_CONFIG();
        }
    }

    function _isValidFundingPolicy(MechanismListing memory listing) internal pure returns (bool) {
        if (
            listing.maxBudgetFunding != 0 &&
            listing.minBudgetFunding != 0 &&
            listing.maxBudgetFunding < listing.minBudgetFunding
        ) {
            return false;
        }
        if (listing.fundingDeadline != 0 && listing.minBudgetFunding == 0) return false;
        if (listing.minBudgetFunding != 0 && listing.fundingDeadline == 0) return false;

        return true;
    }

    function _isValidMechanismDeploymentConfig(MechanismDeploymentConfig memory config) internal pure returns (bool) {
        return config.mechanismFactory != address(0);
    }

    function _validateFactoryDeployment(IAllocationMechanismFactory.DeployedMechanism memory deployed) internal view {
        if (deployed.mechanism == address(0) || deployed.mechanism.code.length == 0) {
            revert INVALID_MECHANISM_CONFIG();
        }
        if (deployed.payoutRecipient == address(0) || deployed.payoutRecipient == address(this)) {
            revert INVALID_MECHANISM_CONFIG();
        }
    }

    function _totalEscrowReceived(address fundingEscrow) internal view returns (uint256) {
        ISuperfluidPool escrowPool = MechanismFundingEscrow(fundingEscrow).distributionPool();
        return escrowPool.getTotalAmountReceivedByMember(fundingEscrow);
    }

    function _effectiveEscrowFunding(address fundingEscrow) internal view returns (uint256) {
        return _totalEscrowReceived(fundingEscrow);
    }

    function _policyFundingLevel(MechanismDeployment storage dep) internal returns (uint256) {
        uint256 effectiveFunding = _effectiveEscrowFunding(dep.fundingEscrow);
        if (effectiveFunding > dep.maxEffectiveFundingObserved) {
            dep.maxEffectiveFundingObserved = effectiveFunding;
        }
        return dep.maxEffectiveFundingObserved;
    }

    function _stopFunding(
        bytes32 itemID,
        MechanismDeployment storage dep,
        FundingStopReason reason,
        uint256 totalReceived
    ) internal {
        if (!_deactivateMechanismRecipient(itemID, dep)) return;
        emit MechanismFundingStopped(itemID, reason, totalReceived);
    }

    function _deactivateMechanismRecipient(bytes32 itemID, MechanismDeployment storage dep) internal returns (bool) {
        if (!dep.active) return false;
        dep.active = false;
        budgetFlow.removeRecipient(itemID);
        _decrementActiveMechanismRecipientCount();
        return true;
    }

    function _incrementActiveMechanismRecipientCount() internal {
        unchecked {
            activeMechanismRecipientCount += 1;
        }
    }

    function _decrementActiveMechanismRecipientCount() internal {
        if (activeMechanismRecipientCount == 0) revert ACTIVE_MECHANISM_RECIPIENT_COUNT_UNDERFLOW();
        unchecked {
            activeMechanismRecipientCount -= 1;
        }
    }

    function _isExpiredUnderfunded(
        MechanismListing memory listing,
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
        if (refunded != 0) emit MechanismFundingRefunded(itemID, refunded);
    }

    function _syncMechanismFunding(bytes32 itemID) internal {
        MechanismDeployment storage dep = _mechanismDeployment[itemID];
        if (dep.mechanism == address(0) || dep.fundingEscrow == address(0)) revert NOT_DEPLOYED();
        if (removalQueued[itemID]) return;

        MechanismListing memory listing = _decodeAndValidateListing(items[itemID].data);

        uint256 policyFunding = _policyFundingLevel(dep);

        if (_isExpiredUnderfunded(listing, policyFunding)) {
            if (dep.active) _stopFunding(itemID, dep, FundingStopReason.ExpiredUnderfunded, policyFunding);
            _refundEscrow(itemID, dep.fundingEscrow);
            return;
        }

        if (!dep.active) return;

        if (listing.maxBudgetFunding != 0 && policyFunding >= listing.maxBudgetFunding) {
            _stopFunding(itemID, dep, FundingStopReason.Capped, policyFunding);
            return;
        }

        if (_isDurationElapsed(listing.duration, dep.activatedAt)) {
            _stopFunding(itemID, dep, FundingStopReason.Ended, policyFunding);
        }
    }

    function _isDurationElapsed(uint64 duration, uint64 activatedAt) internal view returns (bool) {
        return duration != 0 && block.timestamp > uint256(activatedAt) + uint256(duration);
    }

    modifier onlyFactoryManager() {
        if (msg.sender != factoryManager) revert ONLY_FACTORY_MANAGER();
        _;
    }
}
