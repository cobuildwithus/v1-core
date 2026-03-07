// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { BudgetTCRStorageV1 } from "./storage/BudgetTCRStorageV1.sol";
import { BudgetTCRValidationLib } from "./library/BudgetTCRValidationLib.sol";
import { BudgetTCRStackActions } from "./library/BudgetTCRStackActions.sol";
import { BudgetTCRCreditCapActions } from "./library/BudgetTCRCreditCapActions.sol";
import { BudgetTCRTerminalActions } from "./library/BudgetTCRTerminalActions.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

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
        if (deploymentConfig.stackDeployer == address(0)) revert ADDRESS_ZERO();
        if (deploymentConfig.budgetSuccessResolver == address(0)) revert ADDRESS_ZERO();
        if (address(deploymentConfig.goalFlow) == address(0)) revert ADDRESS_ZERO();
        if (address(deploymentConfig.goalTreasury) == address(0)) revert ADDRESS_ZERO();
        if (address(deploymentConfig.goalToken) == address(0)) revert ADDRESS_ZERO();
        if (address(deploymentConfig.cobuildToken) == address(0)) revert ADDRESS_ZERO();
        if (address(deploymentConfig.goalRulesets) == address(0)) revert ADDRESS_ZERO();
        if (deploymentConfig.premiumEscrowImplementation == address(0)) {
            revert INVALID_PREMIUM_ESCROW_IMPLEMENTATION(address(0));
        }
        if (deploymentConfig.premiumEscrowImplementation.code.length == 0) {
            revert INVALID_PREMIUM_ESCROW_IMPLEMENTATION(deploymentConfig.premiumEscrowImplementation);
        }
        address underwriterSlasherRouter_ = deploymentConfig.underwriterSlasherRouter;
        if (underwriterSlasherRouter_ == address(0) || underwriterSlasherRouter_.code.length == 0) {
            revert UNDERWRITER_SLASHER_NOT_CONFIGURED();
        }
        if (deploymentConfig.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_PPM(deploymentConfig.budgetPremiumPpm);
        }
        if (deploymentConfig.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE) {
            revert INVALID_PPM(deploymentConfig.budgetSlashPpm);
        }
        if (deploymentConfig.goalTreasury.budgetStakeLedger() == address(0)) {
            revert BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
        }
        if (initConfig.allocationMechanismAdmin == address(0)) revert ADDRESS_ZERO();

        IBudgetTCR.BudgetValidationBounds calldata budgetBounds = deploymentConfig.budgetValidationBounds;
        IBudgetTCR.OracleValidationBounds calldata oracleBounds = deploymentConfig.oracleValidationBounds;

        if (budgetBounds.maxExecutionDuration < budgetBounds.minExecutionDuration) revert INVALID_BOUNDS();
        if (budgetBounds.maxActivationThreshold < budgetBounds.minActivationThreshold) revert INVALID_BOUNDS();
        if (oracleBounds.liveness == 0 || oracleBounds.bondAmount == 0) {
            revert INVALID_BOUNDS();
        }

        goalFlow = deploymentConfig.goalFlow;
        goalTreasury = deploymentConfig.goalTreasury;

        goalToken = deploymentConfig.goalToken;
        cobuildToken = deploymentConfig.cobuildToken;

        goalRulesets = deploymentConfig.goalRulesets;
        goalRevnetId = deploymentConfig.goalRevnetId;
        paymentTokenDecimals = deploymentConfig.paymentTokenDecimals;

        stackDeployer = deploymentConfig.stackDeployer;
        premiumEscrowImplementation = deploymentConfig.premiumEscrowImplementation;
        underwriterSlasherRouter = underwriterSlasherRouter_;
        budgetPremiumPpm = deploymentConfig.budgetPremiumPpm;
        budgetSlashPpm = deploymentConfig.budgetSlashPpm;
        budgetSuccessResolver = deploymentConfig.budgetSuccessResolver;
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
        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = _budgetStackTopologyFromDeployment(deployment);
        active = deployment.active;
    }

    function budgetStackTopologyForBudgetTreasury(
        address budgetTreasury
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = _itemIdByBudgetTreasury[budgetTreasury];
        if (itemID == bytes32(0)) return (topology, false);

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury != budgetTreasury) return (topology, false);

        topology = _budgetStackTopologyFromDeployment(deployment);
        active = deployment.active;
    }

    function budgetStackTopologyForChildFlow(
        address childFlow
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = _itemIdByChildFlow[childFlow];
        if (itemID == bytes32(0)) return (topology, false);

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.childFlow != childFlow) return (topology, false);

        topology = _budgetStackTopologyFromDeployment(deployment);
        active = deployment.active;
    }

    function itemIdForBudgetTreasury(address budgetTreasury) external view override returns (bytes32 itemID) {
        itemID = _itemIdByBudgetTreasury[budgetTreasury];
        if (itemID == bytes32(0)) return bytes32(0);
        if (_budgetDeployments[itemID].budgetTreasury != budgetTreasury) return bytes32(0);
    }

    function itemIdForChildFlow(address childFlow) external view override returns (bytes32 itemID) {
        itemID = _itemIdByChildFlow[childFlow];
        if (itemID == bytes32(0)) return bytes32(0);
        if (_budgetDeployments[itemID].childFlow != childFlow) return bytes32(0);
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

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
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
        bool removedFromParent = BudgetTCRTerminalActions.removeRecipientFromGoalFlowIfPresent(
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
                if (!BudgetTCRTerminalActions.resolveBudgetTerminalStateStrict(treasury)) {
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

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
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
        BudgetDeployment storage deployment = _budgetDeployments[itemID];
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
            terminallyResolved = BudgetTCRTerminalActions.resolveBudgetTerminalStateBestEffort(itemID, treasury);
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

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury != budgetTreasury) revert ITEM_NOT_DEPLOYED();

        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
        if (!treasury.resolved()) revert ITEM_NOT_TERMINAL();

        address childFlow = deployment.childFlow;
        removedFromParent = BudgetTCRTerminalActions.removeRecipientFromGoalFlowIfPresent(goalFlow, itemID, childFlow);
        goalSynced = BudgetTCRTerminalActions.trySyncGoalTreasury(goalTreasury, itemID, budgetTreasury);
        if (!deployment.active && _pendingRemovalFinalizations[itemID]) {
            _pendingRemovalFinalizations[itemID] = false;
        }

        emit BudgetTerminalRecipientPruned(itemID, childFlow, budgetTreasury, removedFromParent, goalSynced);
    }

    function syncBudgetTreasuries(
        bytes32[] calldata itemIDs
    ) external override nonReentrant returns (uint256 attempted, uint256 succeeded) {
        address budgetStakeLedger = _budgetStakeLedger();
        uint32 slashPpm = budgetSlashPpm;

        uint256 count = itemIDs.length;
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = itemIDs[i];
            BudgetDeployment storage deployment = _budgetDeployments[itemID];
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
            BudgetTCRCreditCapActions.bestEffortEnforceBudgetCreditCap(
                goalFlow,
                itemID,
                deployment.childFlow,
                budgetTreasury,
                budgetStakeLedger,
                slashPpm
            );

            bool success;
            try IBudgetTreasury(budgetTreasury).sync() {
                success = true;
                succeeded += 1;
            } catch (bytes memory reason) {
                emit BudgetTreasuryCallFailed(itemID, budgetTreasury, IBudgetTreasury.sync.selector, reason);
            }
            emit BudgetTreasuryBatchSyncAttempted(itemID, budgetTreasury, success);
        }
    }

    function _budgetStakeLedger() internal view returns (address ledger) {
        ledger = goalTreasury.budgetStakeLedger();
        if (ledger == address(0)) revert BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
    }

    function _budgetStackTopologyFromDeployment(
        BudgetDeployment storage deployment
    ) internal view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology) {
        topology = IBudgetStackTopologyReader.BudgetStackTopology({
            childFlow: deployment.childFlow,
            budgetTreasury: deployment.budgetTreasury,
            premiumEscrow: deployment.premiumEscrow,
            strategy: deployment.strategy,
            allocationMechanism: deployment.allocationMechanism,
            allocationMechanismArbitrator: deployment.allocationMechanismArbitrator
        });
    }
}
