// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { BudgetTCRTerminalActions } from "src/tcr/library/BudgetTCRTerminalActions.sol";
import { BudgetControllerSyncLib } from "src/library/BudgetControllerSyncLib.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract ManagedBudgetController is IManagedBudgetController, ReentrancyGuardUpgradeable {
    bytes32 private constant _SYNC_SKIP_NO_BUDGET_TREASURY = "NO_BUDGET_TREASURY";
    bytes32 private constant _SYNC_SKIP_STACK_INACTIVE = "STACK_INACTIVE";

    struct BudgetDeployment {
        address childFlow;
        address budgetTreasury;
        address premiumEscrow;
        address strategy;
    }

    event BudgetTerminalRecipientPruned(
        bytes32 indexed itemID,
        address indexed childFlow,
        address indexed budgetTreasury,
        bool removedFromParent,
        bool goalSynced
    );
    event BudgetTreasuryBatchSyncAttempted(bytes32 indexed itemID, address indexed budgetTreasury, bool success);
    event BudgetTreasuryBatchSyncSkipped(bytes32 indexed itemID, address indexed budgetTreasury, bytes32 reason);
    event BudgetTreasuryCallFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bytes4 indexed selector,
        bytes reason
    );
    event BudgetGatePolicyCallFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        address callTarget,
        bytes4 indexed selector,
        bytes reason
    );

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

    mapping(bytes32 => BudgetDeployment) private _budgetDeployments;
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
        if (initConfig.budgetSuccessResolver == address(0)) revert ADDRESS_ZERO();
        _requireContract(initConfig.budgetSpendPolicy);

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

    function budgetStackTopology(
        bytes32 itemID
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = _budgetStackTopologyFromDeployment(deployment);
        active = _isItemActive(itemID);
    }

    function budgetStackTopologyForBudgetTreasury(
        address budgetTreasury_
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = _validatedItemIdForBudgetTreasury(budgetTreasury_);
        if (itemID == bytes32(0)) return (topology, false);

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = _budgetStackTopologyFromDeployment(deployment);
        active = _isItemActive(itemID);
    }

    function budgetStackTopologyForChildFlow(
        address childFlow_
    ) external view override returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = _validatedItemIdForChildFlow(childFlow_);
        if (itemID == bytes32(0)) return (topology, false);

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        topology = _budgetStackTopologyFromDeployment(deployment);
        active = _isItemActive(itemID);
    }

    function itemIdForBudgetTreasury(address budgetTreasury_) external view override returns (bytes32 itemID) {
        itemID = _validatedItemIdForBudgetTreasury(budgetTreasury_);
    }

    function itemIdForChildFlow(address childFlow_) external view override returns (bytes32 itemID) {
        itemID = _validatedItemIdForChildFlow(childFlow_);
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
        IBudgetStackDeployer deployer = IBudgetStackDeployer(stackDeployer);
        IBudgetStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            budgetStakeLedger,
            goalFlow
        );

        _requirePreparedStack(prepared);
        if (prepared.childFlowRecipientAdmin != address(this)) {
            revert INVALID_CHILD_FLOW_RECIPIENT_ADMIN(prepared.childFlowRecipientAdmin);
        }
        if (prepared.premiumEscrow != address(0)) {
            revert INVALID_PREMIUM_ESCROW(prepared.premiumEscrow);
        }

        (, childFlow_) = ICustomFlow(goalFlow).addFlowRecipient(
            itemID,
            config.metadata,
            prepared.childFlowRecipientAdmin,
            prepared.budgetTreasury,
            prepared.budgetTreasury,
            prepared.premiumEscrow,
            0,
            IAllocationStrategy(prepared.strategy)
        );

        IBudgetTreasury.BudgetConfig memory budgetTreasuryConfig = IBudgetTreasury.BudgetConfig({
            flow: childFlow_,
            premiumEscrow: prepared.premiumEscrow,
            fundingDeadline: config.fundingDeadline,
            executionDuration: config.executionDuration,
            activationThreshold: config.activationThreshold,
            runwayCap: config.runwayCap,
            successResolver: budgetSuccessResolver,
            successAssertionLiveness: successAssertionLiveness,
            successAssertionBond: successAssertionBond,
            successOracleSpecHash: config.successOracleSpecHash,
            successAssertionPolicyHash: config.successAssertionPolicyHash,
            spendPolicy: budgetSpendPolicy
        });
        budgetTreasury_ = deployer.deployBudgetTreasury(prepared.budgetTreasury, budgetTreasuryConfig);
        if (budgetTreasury_ != prepared.budgetTreasury) revert ITEM_NOT_DEPLOYED();

        _recordBudgetStackTopology(itemID, childFlow_, budgetTreasury_, prepared.premiumEscrow, prepared.strategy);
        _setItemActive(itemID, true);

        emit ManagedBudgetCreated(itemID, childFlow_, budgetTreasury_, prepared.premiumEscrow, prepared.strategy);
    }

    function removeBudget(
        bytes32 itemID
    ) external override onlyAuthority nonReentrant returns (bool removedFromParent, bool terminallyResolved) {
        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury == address(0)) revert ITEM_NOT_DEPLOYED();
        if (!_isItemActive(itemID)) revert ITEM_NOT_ACTIVE();

        address childFlow_ = deployment.childFlow;
        address budgetTreasury_ = deployment.budgetTreasury;

        removedFromParent = BudgetTCRTerminalActions.removeRecipientFromGoalFlowIfPresent(
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
        BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);

        ICustomFlow(deployment.childFlow).allocate(itemIDs, ppm);
        emit ManagedBudgetFlowWeightsSet(budgetItemID, itemIDs, ppm);
    }

    function addBudgetFlowRecipient(
        bytes32 budgetItemID,
        bytes32 recipientId,
        address recipient,
        FlowTypes.RecipientMetadata calldata metadata
    ) external override onlyAuthority nonReentrant returns (bytes32 createdRecipientId, address recipientAddress) {
        BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);
        return ICustomFlow(deployment.childFlow).addRecipient(recipientId, recipient, metadata);
    }

    function removeBudgetFlowRecipient(
        bytes32 budgetItemID,
        bytes32 recipientId
    ) external override onlyAuthority nonReentrant {
        BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);
        ICustomFlow(deployment.childFlow).removeRecipient(recipientId);
    }

    function setBudgetFlowRecipientEnabled(
        bytes32 budgetItemID,
        bytes32 recipientId,
        bool enabled
    ) external override onlyAuthority nonReentrant {
        BudgetDeployment storage deployment = _requireActiveBudgetDeployment(budgetItemID);
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

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
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
            BudgetDeployment storage deployment = _budgetDeployments[itemID];
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

    function _applyBudgetGatePolicy(bytes32 itemID, BudgetDeployment storage deployment) private {
        address gatePolicy = budgetGatePolicy;
        if (gatePolicy == address(0)) return;

        IBudgetGatePolicy.SyncResult memory gateResult = BudgetGatePolicyHook.evaluateBudgetGate(
            IBudgetGatePolicy(gatePolicy),
            IBudgetGatePolicy.SyncContext({
                itemID: itemID,
                goalFlow: IFlow(goalFlow),
                childFlow: deployment.childFlow,
                budgetTreasury: deployment.budgetTreasury,
                coverageSource: address(0),
                coverageToCreditPpm: 0
            })
        );
        _emitBudgetGateFailures(itemID, deployment.budgetTreasury, gateResult.failures);
        if (!gateResult.shouldSetRecipientEnabled) return;

        try IFlow(goalFlow).setRecipientEnabled(itemID, gateResult.recipientEnabled) {} catch (bytes memory reason) {
            emit BudgetGatePolicyCallFailed(
                itemID,
                deployment.budgetTreasury,
                goalFlow,
                IFlow.setRecipientEnabled.selector,
                reason
            );
        }
    }

    function _recordBudgetStackTopology(
        bytes32 itemID,
        address childFlow_,
        address budgetTreasury_,
        address premiumEscrow_,
        address strategy_
    ) private {
        BudgetDeployment storage deployment = _budgetDeployments[itemID];

        address previousBudgetTreasury = deployment.budgetTreasury;
        if (previousBudgetTreasury != address(0) && _itemIdByBudgetTreasury[previousBudgetTreasury] == itemID) {
            delete _itemIdByBudgetTreasury[previousBudgetTreasury];
        }

        address previousChildFlow = deployment.childFlow;
        if (previousChildFlow != address(0) && _itemIdByChildFlow[previousChildFlow] == itemID) {
            delete _itemIdByChildFlow[previousChildFlow];
        }

        deployment.childFlow = childFlow_;
        deployment.budgetTreasury = budgetTreasury_;
        deployment.premiumEscrow = premiumEscrow_;
        deployment.strategy = strategy_;

        _itemIdByBudgetTreasury[budgetTreasury_] = itemID;
        _itemIdByChildFlow[childFlow_] = itemID;
    }

    function _pruneTerminalBudgetLocal(
        bytes32 itemID,
        BudgetDeployment storage deployment,
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

    function _validatedItemIdForBudgetTreasury(address budgetTreasury_) private view returns (bytes32 itemID) {
        itemID = _itemIdByBudgetTreasury[budgetTreasury_];
        if (itemID == bytes32(0)) return bytes32(0);
        if (_budgetDeployments[itemID].budgetTreasury != budgetTreasury_) return bytes32(0);
    }

    function _validatedItemIdForChildFlow(address childFlow_) private view returns (bytes32 itemID) {
        itemID = _itemIdByChildFlow[childFlow_];
        if (itemID == bytes32(0)) return bytes32(0);
        if (_budgetDeployments[itemID].childFlow != childFlow_) return bytes32(0);
    }

    function _requireActiveBudgetDeployment(bytes32 itemID) private view returns (BudgetDeployment storage deployment) {
        deployment = _budgetDeployments[itemID];
        if (deployment.budgetTreasury == address(0)) revert ITEM_NOT_DEPLOYED();
        if (!_isItemActive(itemID)) revert ITEM_NOT_ACTIVE();
    }

    function _budgetStackTopologyFromDeployment(
        BudgetDeployment storage deployment
    ) private view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology) {
        topology = IBudgetStackTopologyReader.BudgetStackTopology({
            childFlow: deployment.childFlow,
            budgetTreasury: deployment.budgetTreasury,
            premiumEscrow: deployment.premiumEscrow,
            strategy: deployment.strategy,
            allocationMechanism: address(0),
            allocationMechanismArbitrator: address(0)
        });
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

    function _requirePreparedStack(IBudgetStackDeployer.PreparationResult memory prepared) private pure {
        if (prepared.strategy == address(0)) revert ADDRESS_ZERO();
        if (prepared.budgetTreasury == address(0)) revert ADDRESS_ZERO();
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert ADDRESS_ZERO();
        if (account.code.length == 0) revert NOT_A_CONTRACT(account);
    }

    function _emitBudgetGateFailures(
        bytes32 itemID,
        address budgetTreasury_,
        IBudgetGatePolicy.CallFailure[] memory failures
    ) private {
        uint256 count = failures.length;
        for (uint256 i = 0; i < count; ) {
            IBudgetGatePolicy.CallFailure memory failure = failures[i];
            emit BudgetGatePolicyCallFailed(
                itemID,
                budgetTreasury_,
                failure.callTarget,
                failure.selector,
                failure.reason
            );
            unchecked {
                ++i;
            }
        }
    }
}
