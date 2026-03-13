// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { BudgetStackTypes } from "src/interfaces/BudgetStackTypes.sol";
import { IBudgetStackControllerReader } from "src/interfaces/IBudgetStackControllerReader.sol";
import { IBudgetStackRuntimeDeployer } from "src/interfaces/IBudgetStackRuntimeDeployer.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { BudgetStackInstantiationLib } from "src/goals/library/BudgetStackInstantiationLib.sol";
import { BudgetTerminalActions } from "src/goals/library/BudgetTerminalActions.sol";
import { BudgetTopologyRegistryLib } from "src/goals/library/BudgetTopologyRegistryLib.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { BudgetGateSync } from "src/goals/policies/library/BudgetGateSync.sol";
import { BudgetControllerSyncLib } from "src/library/BudgetControllerSyncLib.sol";
import { BudgetTopologyReaderBase } from "src/library/BudgetTopologyReaderBase.sol";
import { SpendPolicyValidationLib } from "src/library/SpendPolicyValidationLib.sol";
import { SuccessResolverValidationLib } from "src/library/SuccessResolverValidationLib.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract ManagedBudgetController is IManagedBudgetController, ReentrancyGuardUpgradeable, BudgetTopologyReaderBase {
    bytes32 private constant _SYNC_SKIP_NO_BUDGET_TREASURY = "NO_BUDGET_TREASURY";
    bytes32 private constant _SYNC_SKIP_STACK_INACTIVE = "STACK_INACTIVE";

    event BudgetTerminalRecipientPruned(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        bool removedFromParent,
        bool goalSynced
    );
    event BudgetTreasuryBatchSyncAttempted(bytes32 indexed itemID, address indexed budgetTreasury, bool success);
    event BudgetTreasuryBatchSyncSkipped(bytes32 indexed itemID, address indexed budgetTreasury, bytes32 reason);

    address public override authority;
    address public override pendingAuthority;
    address public override goalTreasury;
    address public override goalFlow;
    address public override stackDeployer;
    address public override budgetGatePolicy;
    address public override budgetSuccessResolver;
    address public override budgetSpendPolicy;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;

    mapping(bytes32 => BudgetTopologyRegistryLib.BudgetDeployment) private _budgetDeployments;
    mapping(address => bytes32) private _itemIdByBudgetTreasury;
    mapping(address => bytes32) private _itemIdByChildFlow;
    bytes32[] private _activeBudgetIds;
    mapping(bytes32 => uint256) private _activeBudgetIndexPlusOne;

    constructor() {
        _disableInitializers();
    }

    modifier onlyAuthority() {
        if (msg.sender != authority) revert ONLY_AUTHORITY();
        _;
    }

    function initialize(InitConfig calldata initConfig) external initializer {
        __ReentrancyGuard_init();

        if (initConfig.authority == address(0)) revert ADDRESS_ZERO();
        _requireContract(initConfig.goalTreasury);
        _requireContract(initConfig.goalFlow);
        _requireContract(initConfig.stackDeployer);
        if (IBudgetStackControllerReader(initConfig.stackDeployer).controller() != address(this)) {
            revert INVALID_STACK_DEPLOYER(initConfig.stackDeployer);
        }
        if (!_matchesManagedPresetTraits(IBudgetStackRuntimeDeployer(initConfig.stackDeployer).stackModuleConfig())) {
            revert INVALID_STACK_DEPLOYER(initConfig.stackDeployer);
        }
        if (initConfig.budgetGatePolicy != address(0)) {
            _requireContract(initConfig.budgetGatePolicy);
            if (
                !BudgetGatePolicyHook.supportsZeroCoverageBudgetGatePolicy(
                    IBudgetGatePolicy(initConfig.budgetGatePolicy)
                )
            ) {
                revert INVALID_BUDGET_GATE_POLICY(initConfig.budgetGatePolicy);
            }
        }
        _requireContract(initConfig.budgetSuccessResolver);
        _requireValidSuccessResolver(initConfig.budgetSuccessResolver);
        _requireContract(initConfig.budgetSpendPolicy);
        _requireValidBudgetSpendPolicy(initConfig.budgetSpendPolicy);
        if (initConfig.successAssertionLiveness == 0) revert INVALID_SUCCESS_ASSERTION_LIVENESS();

        authority = initConfig.authority;
        goalTreasury = initConfig.goalTreasury;
        goalFlow = initConfig.goalFlow;
        stackDeployer = initConfig.stackDeployer;
        budgetGatePolicy = initConfig.budgetGatePolicy;
        budgetSuccessResolver = initConfig.budgetSuccessResolver;
        budgetSpendPolicy = initConfig.budgetSpendPolicy;
        successAssertionLiveness = initConfig.successAssertionLiveness;
        successAssertionBond = initConfig.successAssertionBond;
    }

    function activeBudgetCount() external view override returns (uint256 count) {
        count = _activeBudgetIds.length;
    }

    function activeBudgetIdAt(uint256 index) external view override returns (bytes32 itemID) {
        itemID = _activeBudgetIds[index];
    }

    function createBudget(
        bytes32 itemID,
        BudgetConfig calldata config
    ) external override onlyAuthority nonReentrant returns (address childFlow_, address budgetTreasury_) {
        if (itemID == bytes32(0)) revert INVALID_ITEM_ID();
        if (IGoalTreasury(goalTreasury).resolved()) revert GOAL_TERMINAL();
        if (_budgetDeployments[itemID].budgetTreasury != address(0)) revert ITEM_ALREADY_EXISTS(itemID);

        IGoalTreasury goalTreasury_ = IGoalTreasury(goalTreasury);
        address budgetStakeLedger = goalTreasury_.budgetStakeLedger();
        IBudgetStackRuntimeDeployer deployer = IBudgetStackRuntimeDeployer(stackDeployer);
        BudgetStackTypes.PreparationResult memory prepared = deployer.prepareBudgetStack(budgetStakeLedger, goalFlow);

        _requirePreparedStack(prepared);

        BudgetStackInstantiationLib.InstantiatedBudgetStack memory deployed = BudgetStackInstantiationLib
            .instantiatePreparedBudgetStackWithoutRiskModule(
                BudgetStackInstantiationLib.buildPreparedBudgetStackContext(
                    BudgetStackInstantiationLib.PreparedBudgetStackContextInput({
                        itemID: itemID,
                        metadata: config.metadata,
                        goalFlow: ICustomFlow(goalFlow),
                        deployer: deployer,
                        prepared: prepared,
                        fundingDeadline: config.fundingDeadline,
                        executionDuration: config.executionDuration,
                        activationThreshold: config.activationThreshold,
                        runwayCap: config.runwayCap,
                        successOracleSpecHash: config.successOracleSpecHash,
                        successAssertionPolicyHash: config.successAssertionPolicyHash,
                        successResolver: budgetSuccessResolver,
                        successAssertionLiveness: successAssertionLiveness,
                        successAssertionBond: successAssertionBond,
                        spendPolicy: budgetSpendPolicy,
                        premiumPpm: 0
                    })
                )
            );

        childFlow_ = deployed.childFlow;
        budgetTreasury_ = deployed.budgetTreasury;
        _recordBudgetStackTopology(itemID, deployed);
        _setItemActive(itemID, true);

        emit ManagedBudgetCreated(itemID, childFlow_, budgetTreasury_, deployed.premiumEscrow, deployed.strategy);
    }

    function removeBudget(
        bytes32 itemID
    ) external override onlyAuthority nonReentrant returns (bool removedFromParent, bool terminallyResolved) {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury == address(0)) revert ITEM_NOT_DEPLOYED();
        if (!_isItemActive(itemID)) revert ITEM_NOT_ACTIVE();

        address childFlow_ = deployment.childFlow;
        address budgetTreasury_ = deployment.budgetTreasury;

        removedFromParent = BudgetTerminalActions.removeRecipientFromGoalFlowIfPresent(
            IFlow(goalFlow),
            itemID,
            childFlow_
        );

        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury_);
        treasury.failRemovedBudget();
        _pruneTerminalBudgetLocal(itemID, deployment, budgetTreasury_, false);
        terminallyResolved = true;
        emit ManagedBudgetRemoved(itemID, childFlow_, budgetTreasury_, removedFromParent, terminallyResolved);
    }

    function setBudgetWeights(
        bytes32[] calldata itemIDs,
        uint32[] calldata ppm
    ) external override onlyAuthority nonReentrant {
        if (itemIDs.length != ppm.length) revert ARRAY_LENGTH_MISMATCH();
        if (itemIDs.length == 0) {
            if (_activeBudgetIds.length != 0) revert ITEM_NOT_ACTIVE();
            emit ManagedBudgetWeightsSet(itemIDs, ppm);
            return;
        }

        uint256 count = itemIDs.length;
        for (uint256 i = 0; i < count; ) {
            if (!_isItemActive(itemIDs[i])) revert ITEM_NOT_ACTIVE();
            unchecked {
                ++i;
            }
        }

        ICustomFlow(goalFlow).allocate(itemIDs, ppm);
        emit ManagedBudgetWeightsSet(itemIDs, ppm);
    }

    function setBudgetFlowWeights(
        bytes32 budgetItemID,
        bytes32[] calldata itemIDs,
        uint32[] calldata ppm
    ) external override onlyAuthority nonReentrant {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);

        ICustomFlow(deployment.childFlow).allocate(itemIDs, ppm);
        emit ManagedBudgetFlowWeightsSet(budgetItemID, itemIDs, ppm);
    }

    function addBudgetFlowRecipient(
        bytes32 budgetItemID,
        bytes32 recipientId,
        address recipient,
        FlowTypes.RecipientMetadata calldata metadata
    ) external override onlyAuthority nonReentrant returns (bytes32 createdRecipientId, address recipientAddress) {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);
        return ICustomFlow(deployment.childFlow).addRecipient(recipientId, recipient, metadata);
    }

    function removeBudgetFlowRecipient(
        bytes32 budgetItemID,
        bytes32 recipientId
    ) external override onlyAuthority nonReentrant {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);
        ICustomFlow(deployment.childFlow).removeRecipient(recipientId);
    }

    function setBudgetFlowRecipientEnabled(
        bytes32 budgetItemID,
        bytes32 recipientId,
        bool enabled
    ) external override onlyAuthority nonReentrant {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);
        IFlow(deployment.childFlow).setRecipientEnabled(recipientId, enabled);
    }

    function transferAuthority(address newAuthority) external override onlyAuthority {
        if (newAuthority == address(0)) revert ADDRESS_ZERO();
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    function acceptAuthority() external override {
        address nextAuthority = pendingAuthority;
        if (msg.sender != nextAuthority) revert ONLY_PENDING_AUTHORITY();

        address previousAuthority = authority;
        authority = nextAuthority;
        pendingAuthority = address(0);
        emit AuthorityTransferred(previousAuthority, nextAuthority);
    }

    function pruneTerminalBudget(
        address budgetTreasury_
    ) external override nonReentrant returns (bool removedFromParent, bool goalSynced) {
        bytes32 itemID = _itemIdByBudgetTreasury[budgetTreasury_];
        if (itemID == bytes32(0)) revert ITEM_NOT_DEPLOYED();

        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury != budgetTreasury_) revert ITEM_NOT_DEPLOYED();

        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury_);
        if (!treasury.resolved()) revert ITEM_NOT_TERMINAL();

        (removedFromParent, goalSynced) = _pruneTerminalBudgetLocal(itemID, deployment, budgetTreasury_, true);

        emit BudgetTerminalRecipientPruned(
            itemID,
            deployment.childFlow,
            budgetTreasury_,
            removedFromParent,
            goalSynced
        );
    }

    function syncBudgetTreasuries(
        bytes32[] calldata itemIDs
    ) external override nonReentrant returns (uint256 attempted, uint256 succeeded) {
        uint256 count = itemIDs.length;
        for (uint256 i = 0; i < count; ) {
            bytes32 itemID = itemIDs[i];
            BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
            address budgetTreasury_ = deployment.budgetTreasury;

            if (budgetTreasury_ == address(0)) {
                emit BudgetTreasuryBatchSyncSkipped(itemID, address(0), _SYNC_SKIP_NO_BUDGET_TREASURY);
                unchecked {
                    ++i;
                }
                continue;
            }

            if (!_isItemActive(itemID)) {
                emit BudgetTreasuryBatchSyncSkipped(itemID, budgetTreasury_, _SYNC_SKIP_STACK_INACTIVE);
                unchecked {
                    ++i;
                }
                continue;
            }

            attempted += 1;
            _applyBudgetGatePolicy(itemID, deployment);

            BudgetControllerSyncLib.SyncAttempt memory attempt = BudgetControllerSyncLib.trySyncBudgetTreasury(
                itemID,
                budgetTreasury_
            );
            if (attempt.success) {
                succeeded += 1;
                if (attempt.terminal) {
                    (bool removedFromParent, bool goalSynced) = _pruneTerminalBudgetLocal(
                        itemID,
                        deployment,
                        budgetTreasury_,
                        true
                    );
                    emit BudgetTerminalRecipientPruned(
                        itemID,
                        deployment.childFlow,
                        budgetTreasury_,
                        removedFromParent,
                        goalSynced
                    );
                }
            }
            emit BudgetTreasuryBatchSyncAttempted(itemID, budgetTreasury_, attempt.success);

            unchecked {
                ++i;
            }
        }
    }

    function _applyBudgetGatePolicy(
        bytes32 itemID,
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment
    ) private {
        address gatePolicy = budgetGatePolicy;
        if (gatePolicy == address(0)) return;

        BudgetGateSync.applyBudgetGate(
            itemID,
            deployment.budgetTreasury,
            deployment.childFlow,
            address(0),
            0,
            IFlow(goalFlow),
            IBudgetGatePolicy(gatePolicy)
        );
    }

    function _recordBudgetStackTopology(
        bytes32 itemID,
        BudgetStackInstantiationLib.InstantiatedBudgetStack memory deployed
    ) private {
        BudgetTopologyRegistryLib.recordBudgetStackTopology(
            _budgetDeployments,
            _itemIdByBudgetTreasury,
            _itemIdByChildFlow,
            itemID,
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: deployed.childFlow,
                budgetTreasury: deployed.budgetTreasury,
                premiumEscrow: deployed.premiumEscrow,
                strategy: deployed.strategy,
                allocationMechanism: address(0),
                allocationMechanismArbitrator: address(0)
            })
        );
    }

    function _pruneTerminalBudgetLocal(
        bytes32 itemID,
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment,
        address budgetTreasury_,
        bool detachParentRecipient
    ) private returns (bool removedFromParent, bool goalSynced) {
        (removedFromParent, goalSynced) = BudgetControllerSyncLib.pruneTerminalRecipientAndSyncGoal(
            IFlow(goalFlow),
            IGoalTreasury(goalTreasury),
            itemID,
            deployment.childFlow,
            budgetTreasury_,
            detachParentRecipient
        );
        _setItemActive(itemID, false);
    }

    function _requireActiveBudgetDeployment(
        bytes32 itemID
    ) private view returns (BudgetTopologyRegistryLib.BudgetDeployment storage deployment) {
        deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury == address(0)) revert ITEM_NOT_DEPLOYED();
        if (!_isItemActive(itemID)) revert ITEM_NOT_ACTIVE();
    }

    function _setItemActive(bytes32 itemID, bool active) private {
        uint256 indexPlusOne = _activeBudgetIndexPlusOne[itemID];
        if (active) {
            if (indexPlusOne != 0) return;
            _activeBudgetIds.push(itemID);
            _activeBudgetIndexPlusOne[itemID] = _activeBudgetIds.length;
            return;
        }

        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _activeBudgetIds.length - 1;
        if (index != lastIndex) {
            bytes32 lastItemID = _activeBudgetIds[lastIndex];
            _activeBudgetIds[index] = lastItemID;
            _activeBudgetIndexPlusOne[lastItemID] = index + 1;
        }

        _activeBudgetIds.pop();
        delete _activeBudgetIndexPlusOne[itemID];
    }

    function _isItemActive(bytes32 itemID) private view returns (bool) {
        return _activeBudgetIndexPlusOne[itemID] != 0;
    }

    function _budgetTopologyDeployment(
        bytes32 itemID
    ) internal view override returns (BudgetTopologyRegistryLib.BudgetDeployment storage deployment) {
        deployment = _budgetDeployments[itemID];
    }

    function _budgetTopologyItemIdForBudgetTreasury(
        address budgetTreasury_
    ) internal view override returns (bytes32 itemID) {
        itemID = BudgetTopologyRegistryLib.validatedItemIdForBudgetTreasury(
            _budgetDeployments,
            _itemIdByBudgetTreasury,
            budgetTreasury_
        );
    }

    function _budgetTopologyItemIdForChildFlow(address childFlow_) internal view override returns (bytes32 itemID) {
        itemID = BudgetTopologyRegistryLib.validatedItemIdForChildFlow(
            _budgetDeployments,
            _itemIdByChildFlow,
            childFlow_
        );
    }

    function _budgetTopologyIsActive(
        bytes32 itemID,
        BudgetTopologyRegistryLib.BudgetDeployment storage
    ) internal view override returns (bool active) {
        active = _isItemActive(itemID);
    }

    function _requirePreparedStack(BudgetStackTypes.PreparationResult memory prepared) private view {
        if (prepared.strategy == address(0)) revert INVALID_PREPARED_STRATEGY(address(0));
        if (prepared.budgetTreasury == address(0)) revert INVALID_PREPARED_BUDGET_TREASURY(address(0));
        if (prepared.allocationMechanism != address(0)) {
            revert INVALID_ALLOCATION_MECHANISM(prepared.allocationMechanism);
        }
        if (prepared.childFlowRecipientAdmin != address(this)) {
            revert INVALID_CHILD_FLOW_RECIPIENT_ADMIN(prepared.childFlowRecipientAdmin);
        }
        if (prepared.premiumEscrow != address(0)) {
            revert INVALID_PREMIUM_ESCROW(prepared.premiumEscrow);
        }
    }

    function _matchesManagedPresetTraits(BudgetStackTypes.StackModuleConfig memory actual) private view returns (bool) {
        return
            actual.childFlowStrategyMode == BudgetStackTypes.ChildFlowStrategyMode.Factory &&
            actual.childFlowStrategyTarget != address(0) &&
            actual.childFlowStrategyTarget.code.length != 0 &&
            actual.mechanismLayerMode == BudgetStackTypes.MechanismLayerMode.None &&
            actual.childFlowRecipientAdmin == address(this) &&
            actual.premiumEscrowImplementation == address(0);
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert ADDRESS_ZERO();
        if (account.code.length == 0) revert NOT_A_CONTRACT(account);
    }

    function _requireValidSuccessResolver(address resolver) private view {
        if (!SuccessResolverValidationLib.passesValidationProbe(resolver)) {
            revert INVALID_SUCCESS_RESOLVER(resolver);
        }
    }

    function _requireValidBudgetSpendPolicy(address policy) private view {
        if (!SpendPolicyValidationLib.passesValidationProbe(policy)) {
            revert INVALID_BUDGET_SPEND_POLICY(policy);
        }
    }
}
