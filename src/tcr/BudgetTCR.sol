// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { BudgetTCRStorageV1 } from "./storage/BudgetTCRStorageV1.sol";
import { BudgetTCRInitValidation } from "./library/BudgetTCRInitValidation.sol";
import { BudgetTCRValidationLib } from "./library/BudgetTCRValidationLib.sol";
import { BudgetTCRStackActions } from "./library/BudgetTCRStackActions.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { BudgetTerminalActions } from "src/goals/library/BudgetTerminalActions.sol";
import { BudgetTopologyRegistryLib } from "src/goals/library/BudgetTopologyRegistryLib.sol";
import { BudgetGateSync } from "src/goals/policies/library/BudgetGateSync.sol";
import { BudgetControllerSyncLib } from "src/library/BudgetControllerSyncLib.sol";

contract BudgetTCR is GeneralizedTCR, IBudgetTCR, BudgetTCRStorageV1 {
    bytes32 private constant _SYNC_SKIP_NO_BUDGET_TREASURY = "NO_BUDGET_TREASURY";
    bytes32 private constant _SYNC_SKIP_STACK_INACTIVE = "STACK_INACTIVE";

    constructor() {
        _disableInitializers();
    }

    function initialize(
        InitConfig calldata initConfig,
        DeploymentConfig calldata deploymentConfig
    ) external initializer {
        address budgetGatePolicy_ = BudgetTCRInitValidation.validateInitialization(initConfig, deploymentConfig);
        BudgetTCRInitValidation.validateStackModuleCompatibility(deploymentConfig);

        IBudgetTCR.BudgetValidationBounds calldata budgetBounds = deploymentConfig.budgetValidationBounds;
        IBudgetTCR.OracleValidationBounds calldata oracleBounds = deploymentConfig.oracleValidationBounds;

        goalFlow = deploymentConfig.goalFlow;
        goalTreasury = deploymentConfig.goalTreasury;

        goalToken = deploymentConfig.goalToken;
        cobuildToken = deploymentConfig.cobuildToken;

        goalRulesets = deploymentConfig.goalRulesets;
        goalRevnetId = deploymentConfig.goalRevnetId;
        paymentTokenDecimals = deploymentConfig.paymentTokenDecimals;

        stackDeployer = deploymentConfig.stackDeployer;
        premiumEscrowImplementation = deploymentConfig.riskModuleRouting.premiumEscrowImplementation;
        _budgetGatePolicy = budgetGatePolicy_;
        underwriterSlasherRouter = deploymentConfig.riskModuleRouting.underwriterSlasherRouter;
        budgetPremiumPpm = deploymentConfig.budgetPremiumPpm;
        budgetSlashPpm = deploymentConfig.budgetSlashPpm;
        budgetSuccessResolver = deploymentConfig.budgetSuccessResolver;
        _budgetSpendPolicy = deploymentConfig.budgetSpendPolicy;
        allocationMechanismAdmin = initConfig.allocationMechanismAdmin;
        budgetValidationBounds = budgetBounds;
        oracleValidationBounds = oracleBounds;

        __GeneralizedTCR_init(initConfig.tcrConfig);
    }

    function _verifyItemData(bytes calldata item) internal view override returns (bool valid) {
        return BudgetTCRValidationLib.verifyItemData(item, budgetValidationBounds, goalTreasury.deadline());
    }

    function _assertCanAddItem(bytes32 itemID, bytes calldata) internal view override {
        if (goalTreasury.resolved()) revert GOAL_TERMINAL();
        if (_pendingRemovalFinalizations[itemID]) revert REMOVAL_FINALIZATION_PENDING();
        if (items[itemID].status == Status.Absent && _budgetDeployments[itemID].budgetTreasury != address(0)) {
            revert ITEM_RELIST_NOT_ALLOWED(itemID);
        }
    }

    function isRegistrationPending(bytes32 itemId) external view override returns (bool pending) {
        pending = _pendingRegistrationActivations[itemId];
    }

    function isRemovalPending(bytes32 itemId) external view override returns (bool pending) {
        pending = _pendingRemovalFinalizations[itemId];
    }

    function budgetStackTopology(
        bytes32 itemID
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = BudgetTopologyRegistryLib.topologyFromDeployment(deployment);
        active = deployment.active;
    }

    function budgetStackTopologyForBudgetTreasury(
        address budgetTreasury
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = BudgetTopologyRegistryLib.validatedItemIdForBudgetTreasury(
            _budgetDeployments,
            _itemIdByBudgetTreasury,
            budgetTreasury
        );
        if (itemID == bytes32(0)) return (topology, false);

        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = BudgetTopologyRegistryLib.topologyFromDeployment(deployment);
        active = deployment.active;
    }

    function budgetStackTopologyForChildFlow(
        address childFlow
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = BudgetTopologyRegistryLib.validatedItemIdForChildFlow(
            _budgetDeployments,
            _itemIdByChildFlow,
            childFlow
        );
        if (itemID == bytes32(0)) return (topology, false);

        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = BudgetTopologyRegistryLib.topologyFromDeployment(deployment);
        active = deployment.active;
    }

    function itemIdForBudgetTreasury(address budgetTreasury) external view override returns (bytes32 itemID) {
        itemID = BudgetTopologyRegistryLib.validatedItemIdForBudgetTreasury(
            _budgetDeployments,
            _itemIdByBudgetTreasury,
            budgetTreasury
        );
    }

    function itemIdForChildFlow(address childFlow) external view override returns (bytes32 itemID) {
        itemID = BudgetTopologyRegistryLib.validatedItemIdForChildFlow(
            _budgetDeployments,
            _itemIdByChildFlow,
            childFlow
        );
    }

    function budgetSpendPolicy() public view override(IBudgetTCR, BudgetTCRStorageV1) returns (address policy) {
        policy = super.budgetSpendPolicy();
    }

    function budgetGatePolicy() public view override(IBudgetTCR, BudgetTCRStorageV1) returns (address policy) {
        policy = super.budgetGatePolicy();
    }

    // slither-disable-next-line reentrancy-no-eth
    function activateRegisteredBudget(bytes32 itemID) external override nonReentrant returns (bool activated) {
        if (!_pendingRegistrationActivations[itemID]) revert REGISTRATION_NOT_PENDING();
        if (goalTreasury.resolved()) revert GOAL_TERMINAL();
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert ITEM_NOT_REGISTERED();
        if (!_budgetDeployments[itemID].active) {
            BudgetTCRStackActions.deployBudgetStack(
                _budgetDeployments,
                _itemIdByBudgetTreasury,
                _itemIdByChildFlow,
                itemID,
                item.data
            );
        }

        _pendingRegistrationActivations[itemID] = false;
        activated = true;
    }

    // slither-disable-next-line reentrancy-no-eth
    function finalizeRemovedBudget(bytes32 itemID) external override nonReentrant returns (bool terminallyResolved) {
        if (!_pendingRemovalFinalizations[itemID]) revert REMOVAL_NOT_PENDING();

        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        address childFlow = deployment.childFlow;
        address budgetTreasury = deployment.budgetTreasury;
        if (!deployment.active) {
            terminallyResolved = budgetTreasury == address(0) || IBudgetTreasury(budgetTreasury).resolved();
            if (terminallyResolved) {
                _pendingRemovalFinalizations[itemID] = false;
            }
            emit BudgetStackRemovalHandled(itemID, childFlow, budgetTreasury, false, terminallyResolved);
            return terminallyResolved;
        }

        IBudgetStakeLedger(_budgetStakeLedger()).removeBudget(itemID);
        bool removedFromParent = BudgetTerminalActions.removeRecipientFromGoalFlowIfPresent(
            goalFlow,
            itemID,
            childFlow
        );

        terminallyResolved = true;
        if (budgetTreasury != address(0)) {
            IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
            if (treasury.activatedAt() != 0) {
                // Removal must stop budget spend immediately, but activated removals do not auto-force failure.
                treasury.forceFlowRateToZero();
                terminallyResolved = treasury.resolved();
            } else {
                treasury.disableSuccessResolution();
                if (!BudgetTerminalActions.resolveBudgetTerminalStateStrict(treasury)) {
                    revert TERMINAL_RESOLUTION_FAILED();
                }
            }
        }

        deployment.active = false;
        _pendingRemovalFinalizations[itemID] = !terminallyResolved;
        emit BudgetStackRemovalHandled(itemID, childFlow, budgetTreasury, removedFromParent, terminallyResolved);
    }

    // slither-disable-next-line reentrancy-no-eth
    function _onItemRegistered(bytes32 itemID, bytes memory) internal override {
        _pendingRemovalFinalizations[itemID] = false;
        _pendingRegistrationActivations[itemID] = true;
        emit BudgetStackActivationQueued(itemID);
    }

    // slither-disable-next-line reentrancy-no-eth
    function _onItemRemoved(bytes32 itemID) internal override {
        _pendingRegistrationActivations[itemID] = false;

        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (!deployment.active) {
            _pendingRemovalFinalizations[itemID] = false;
            return;
        }

        address budgetTreasury = deployment.budgetTreasury;
        if (budgetTreasury != address(0)) {
            IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
            if (treasury.activatedAt() == 0) {
                // Pre-activation removals are immediate fail-closed and cannot later become success-eligible.
                treasury.disableSuccessResolution();
            }
        }

        _pendingRemovalFinalizations[itemID] = true;
        emit BudgetStackRemovalQueued(itemID);
    }

    function retryRemovedBudgetResolution(
        bytes32 itemID
    ) external override nonReentrant returns (bool terminallyResolved) {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        address budgetTreasury = deployment.budgetTreasury;
        if (budgetTreasury == address(0)) revert ITEM_NOT_DEPLOYED();
        if (deployment.active) revert STACK_STILL_ACTIVE();

        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
        if (!treasury.successResolutionDisabled()) {
            treasury.forceFlowRateToZero();
            if (!treasury.resolved()) {
                try treasury.sync() {} catch (bytes memory reason) {
                    emit BudgetTreasuryCallFailed(itemID, budgetTreasury, IBudgetTreasury.sync.selector, reason);
                }
            }
            terminallyResolved = treasury.resolved();
        } else {
            terminallyResolved = BudgetTerminalActions.resolveBudgetTerminalStateBestEffort(itemID, treasury);
        }
        if (terminallyResolved) {
            _pendingRemovalFinalizations[itemID] = false;
        }
        emit BudgetStackTerminalizationRetried(itemID, budgetTreasury, terminallyResolved);
    }

    function pruneTerminalBudget(
        address budgetTreasury
    ) external override nonReentrant returns (bool removedFromParent, bool goalSynced) {
        bytes32 itemID = _itemIdByBudgetTreasury[budgetTreasury];
        if (itemID == bytes32(0)) revert ITEM_NOT_DEPLOYED();

        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury != budgetTreasury) revert ITEM_NOT_DEPLOYED();

        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
        if (!treasury.resolved()) revert ITEM_NOT_TERMINAL();

        address childFlow = deployment.childFlow;
        (removedFromParent, goalSynced) = _pruneTerminalBudgetLocal(itemID, deployment, budgetTreasury);

        emit BudgetTerminalRecipientPruned(itemID, childFlow, budgetTreasury, removedFromParent, goalSynced);
    }

    function syncBudgetTreasuries(
        bytes32[] calldata itemIDs
    ) external override nonReentrant returns (uint256 attempted, uint256 succeeded) {
        address budgetStakeLedger = _budgetStakeLedger();
        uint32 slashPpm = budgetSlashPpm;
        IFlow goalFlow_ = goalFlow;
        IBudgetGatePolicy gatePolicy = IBudgetGatePolicy(_budgetGatePolicy);

        uint256 count = itemIDs.length;
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = itemIDs[i];
            BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetDeployments[itemID];
            address budgetTreasury = deployment.budgetTreasury;

            if (budgetTreasury == address(0)) {
                emit BudgetTreasuryBatchSyncSkipped(itemID, address(0), _SYNC_SKIP_NO_BUDGET_TREASURY);
                continue;
            }

            if (!deployment.active) {
                emit BudgetTreasuryBatchSyncSkipped(itemID, budgetTreasury, _SYNC_SKIP_STACK_INACTIVE);
                continue;
            }

            attempted += 1;
            if (address(gatePolicy) != address(0)) {
                BudgetGateSync.applyBudgetGate(
                    itemID,
                    budgetTreasury,
                    deployment.childFlow,
                    budgetStakeLedger,
                    slashPpm,
                    goalFlow_,
                    gatePolicy
                );
            }

            BudgetControllerSyncLib.SyncAttempt memory attempt = BudgetControllerSyncLib.trySyncBudgetTreasury(
                itemID,
                budgetTreasury
            );
            if (attempt.success) {
                succeeded += 1;
                if (attempt.terminal && goalFlow_.recipientExists(deployment.childFlow)) {
                    (bool removedFromParent, bool goalSynced) = _pruneTerminalBudgetLocal(
                        itemID,
                        deployment,
                        budgetTreasury
                    );
                    emit BudgetTerminalRecipientPruned(
                        itemID,
                        deployment.childFlow,
                        budgetTreasury,
                        removedFromParent,
                        goalSynced
                    );
                }
            }
            emit BudgetTreasuryBatchSyncAttempted(itemID, budgetTreasury, attempt.success);
        }
    }

    function _budgetStakeLedger() internal view returns (address ledger) {
        ledger = goalTreasury.budgetStakeLedger();
        if (ledger == address(0)) revert BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
    }

    function _pruneTerminalBudgetLocal(
        bytes32 itemID,
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment,
        address budgetTreasury
    ) internal returns (bool removedFromParent, bool goalSynced) {
        (removedFromParent, goalSynced) = BudgetControllerSyncLib.pruneTerminalRecipientAndSyncGoal(
            goalFlow,
            goalTreasury,
            itemID,
            deployment.childFlow,
            budgetTreasury,
            true
        );
        if (!deployment.active && _pendingRemovalFinalizations[itemID]) {
            _pendingRemovalFinalizations[itemID] = false;
        }
    }
}
