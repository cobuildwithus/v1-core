// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IBudgetTCRStackDeployer } from "./interfaces/IBudgetTCRStackDeployer.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { IERC20VotesArbitrator } from "./interfaces/IERC20VotesArbitrator.sol";
import { AllocationMechanismTCR } from "./AllocationMechanismTCR.sol";
import { BudgetTCRStorageV1 } from "./storage/BudgetTCRStorageV1.sol";
import { BudgetTCRItems } from "./library/BudgetTCRItems.sol";
import { BudgetTCRValidationLib } from "./library/BudgetTCRValidationLib.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";
import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract BudgetTCR is GeneralizedTCR, IBudgetTCR, BudgetTCRStorageV1 {
    bytes32 private constant _SYNC_SKIP_NO_BUDGET_TREASURY = "NO_BUDGET_TREASURY";
    bytes32 private constant _SYNC_SKIP_STACK_INACTIVE = "STACK_INACTIVE";
    error BUDGET_TREASURY_MISMATCH();

    /// @notice Emitted when best-effort credit-line enforcement hits an external-call failure.
    event BudgetCreditCapEnforcementFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bytes4 indexed selector,
        bytes reason
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        RegistryConfig calldata registryConfig,
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
        if (deploymentConfig.goalTreasury.budgetStakeLedger() == address(0)) revert BUDGET_STAKE_LEDGER_NOT_CONFIGURED();

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
        budgetValidationBounds = budgetBounds;
        oracleValidationBounds = oracleBounds;

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

    function _verifyItemData(bytes calldata item) internal view override returns (bool valid) {
        return BudgetTCRValidationLib.verifyItemData(item, budgetValidationBounds, goalTreasury.deadline());
    }

    function _assertCanAddItem(bytes32 itemID, bytes calldata) internal view override {
        if (_pendingRemovalFinalizations[itemID]) revert REMOVAL_FINALIZATION_PENDING();
    }

    function isRegistrationPending(bytes32 itemId) external view override returns (bool pending) {
        pending = _pendingRegistrationActivations[itemId];
    }

    function isRemovalPending(bytes32 itemId) external view override returns (bool pending) {
        pending = _pendingRemovalFinalizations[itemId];
    }

    // slither-disable-next-line reentrancy-no-eth
    function activateRegisteredBudget(bytes32 itemID) external override nonReentrant returns (bool activated) {
        if (!_pendingRegistrationActivations[itemID]) revert REGISTRATION_NOT_PENDING();
        Item storage item = items[itemID];
        if (item.status != Status.Registered) revert ITEM_NOT_REGISTERED();
        if (!_budgetDeployments[itemID].active) {
            _deployBudgetStack(itemID, item.data);
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
            _clearRemovalPendingState(itemID);
            emit BudgetStackRemovalHandled(itemID, childFlow, budgetTreasury, false, true);
            return true;
        }

        IBudgetStakeLedger(_budgetStakeLedger()).removeBudget(itemID);
        bool removedFromParent = _removeRecipientFromGoalFlowIfPresent(itemID, childFlow);

        terminallyResolved = true;
        if (budgetTreasury != address(0)) {
            IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
            bool activationLocked = _isActivationLockedRemoval(treasury);
            if (activationLocked) {
                // Removal must stop budget spend immediately, but activated removals do not auto-force failure.
                treasury.forceFlowRateToZero();
                terminallyResolved = _resolved(treasury);
            } else {
                treasury.disableSuccessResolution();
                if (!_resolveBudgetTerminalStateStrict(treasury)) revert TERMINAL_RESOLUTION_FAILED();
            }
        }

        deployment.active = false;
        _clearRemovalPendingState(itemID);
        emit BudgetStackRemovalHandled(itemID, childFlow, budgetTreasury, removedFromParent, terminallyResolved);
    }

    // slither-disable-next-line reentrancy-no-eth
    function _onItemRegistered(bytes32 itemID, bytes memory) internal override {
        _clearRemovalPendingState(itemID);
        _pendingRegistrationActivations[itemID] = true;
        emit BudgetStackActivationQueued(itemID);
    }

    // slither-disable-next-line reentrancy-no-eth
    function _onItemRemoved(bytes32 itemID) internal override {
        _pendingRegistrationActivations[itemID] = false;

        BudgetDeployment storage deployment = _budgetDeployments[itemID];
        if (!deployment.active) {
            _clearRemovalPendingState(itemID);
            return;
        }

        address budgetTreasury = deployment.budgetTreasury;
        if (budgetTreasury != address(0)) {
            IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
            if (!_isActivationLockedRemoval(treasury)) {
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
            if (!_resolved(treasury)) {
                try treasury.sync() {} catch (bytes memory reason) {
                    emit BudgetTreasuryCallFailed(itemID, budgetTreasury, IBudgetTreasury.sync.selector, reason);
                }
            }
            terminallyResolved = _resolved(treasury);
        } else {
            terminallyResolved = _tryResolveBudgetTerminalState(itemID, treasury);
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
        if (!_resolved(treasury)) revert ITEM_NOT_TERMINAL();

        address childFlow = deployment.childFlow;
        removedFromParent = _removeRecipientFromGoalFlowIfPresent(itemID, childFlow);
        goalSynced = _trySyncGoalTreasury(itemID, budgetTreasury);

        emit BudgetTerminalRecipientPruned(itemID, childFlow, budgetTreasury, removedFromParent, goalSynced);
    }

    function syncBudgetTreasuries(
        bytes32[] calldata itemIDs
    ) external override nonReentrant returns (uint256 attempted, uint256 succeeded) {
        address budgetStakeLedger = _budgetStakeLedger();
        uint256 lambda = goalTreasury.coverageLambda();

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
            _bestEffortEnforceBudgetCreditCap(
                itemID,
                deployment.childFlow,
                budgetTreasury,
                budgetStakeLedger,
                lambda
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

    function _bestEffortEnforceBudgetCreditCap(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address budgetStakeLedger,
        uint256 lambda
    ) internal {
        // Underwriting disabled => never gate.
        if (lambda == 0) {
            try goalFlow.setRecipientEnabled(itemID, true) {} catch (bytes memory reason) {
                emit BudgetCreditCapEnforcementFailed(itemID, budgetTreasury, IFlow.setRecipientEnabled.selector, reason);
            }
            return;
        }

        uint256 coverage;
        try IBudgetStakeLedger(budgetStakeLedger).budgetTotalAllocatedStake(budgetTreasury) returns (uint256 cov) {
            coverage = cov;
        } catch (bytes memory reason) {
            emit BudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                IBudgetStakeLedger.budgetTotalAllocatedStake.selector,
                reason
            );
            return;
        }

        uint64 duration;
        try IBudgetTreasury(budgetTreasury).executionDuration() returns (uint64 dur) {
            duration = dur;
        } catch (bytes memory reason) {
            emit BudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                IBudgetTreasury.executionDuration.selector,
                reason
            );
            return;
        }

        uint256 creditLine;
        if (coverage == 0 || duration == 0) {
            creditLine = 0;
        } else {
            // creditLine = coverage * duration / lambda
            creditLine = Math.mulDiv(coverage, uint256(duration), lambda);
        }

        uint256 received;
        try goalFlow.getTotalReceivedByMember(childFlow) returns (uint256 totalReceived) {
            received = totalReceived;
        } catch (bytes memory reason) {
            emit BudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                IFlow.getTotalReceivedByMember.selector,
                reason
            );
            return;
        }

        bool enabled = (creditLine != 0) && (received < creditLine);
        try goalFlow.setRecipientEnabled(itemID, enabled) {} catch (bytes memory reason) {
            emit BudgetCreditCapEnforcementFailed(itemID, budgetTreasury, IFlow.setRecipientEnabled.selector, reason);
        }
    }

    function _budgetStakeLedger() internal view returns (address ledger) {
        ledger = goalTreasury.budgetStakeLedger();
        if (ledger == address(0)) revert BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
    }

    function _deployBudgetStack(bytes32 itemID, bytes memory item) internal {
        if (_budgetDeployments[itemID].active) revert STACK_ALREADY_ACTIVE();

        BudgetListing memory listing = BudgetTCRItems.decodeItemData(item);
        address budgetStakeLedger = _budgetStakeLedger();
        IBudgetTCRStackDeployer deployer = IBudgetTCRStackDeployer(stackDeployer);
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            goalToken,
            cobuildToken,
            goalRulesets,
            goalRevnetId,
            paymentTokenDecimals,
            budgetStakeLedger,
            address(goalFlow),
            underwriterSlasherRouter,
            budgetSlashPpm,
            itemID
        );

        IAllocationStrategy[] memory childStrategies = new IAllocationStrategy[](1);
        childStrategies[0] = IAllocationStrategy(prepared.strategy);
        address budgetTreasury = prepared.budgetTreasury;
        address premiumEscrow = prepared.premiumEscrow;
        address allocationMechanism = Clones.clone(deployer.allocationMechanismTcrImplementation());

        (, address childFlow) = goalFlow.addFlowRecipient(
            itemID,
            listing.metadata,
            allocationMechanism,
            budgetTreasury,
            budgetTreasury,
            premiumEscrow,
            budgetPremiumPpm,
            childStrategies
        );

        deployer.registerChildFlowRecipient(itemID, childFlow);

        emit BudgetStackDeployed(itemID, childFlow, budgetTreasury, prepared.strategy);

        address deployedBudgetTreasury = deployer.deployBudgetTreasury(
            budgetTreasury,
            premiumEscrow,
            childFlow,
            budgetStakeLedger,
            address(goalFlow),
            underwriterSlasherRouter,
            budgetSlashPpm,
            listing,
            budgetSuccessResolver,
            oracleValidationBounds.liveness,
            oracleValidationBounds.bondAmount
        );

        address managerRewardDistributionPool = address(IFlow(childFlow).managerRewardDistributionPool());
        if (managerRewardDistributionPool != address(0)) {
            IPremiumEscrow(premiumEscrow).connectManagerRewardPool(managerRewardDistributionPool);
        }
        if (deployedBudgetTreasury != budgetTreasury) {
            revert BUDGET_TREASURY_MISMATCH();
        }
        _itemIdByBudgetTreasury[budgetTreasury] = itemID;
        IBudgetStakeLedger(budgetStakeLedger).registerBudget(itemID, budgetTreasury);
        IUnderwriterSlasherRouter(underwriterSlasherRouter).setAuthorizedPremiumEscrow(premiumEscrow, true);
        address allocationMechanismArbitrator = _initializeBudgetAllocationMechanism(
            deployer,
            allocationMechanism,
            budgetTreasury
        );
        emit BudgetAllocationMechanismDeployed(
            itemID,
            allocationMechanism,
            allocationMechanismArbitrator,
            deployer.roundFactory()
        );

        _budgetDeployments[itemID] = BudgetDeployment({
            childFlow: childFlow,
            budgetTreasury: budgetTreasury,
            allocationMechanism: allocationMechanism,
            strategy: prepared.strategy,
            active: true
        });
    }

    function _initializeBudgetAllocationMechanism(
        IBudgetTCRStackDeployer deployer,
        address allocationMechanism,
        address budgetTreasury
    ) internal returns (address mechanismArbitrator) {
        IArbitrator.ArbitratorParams memory arbParams = arbitrator.getArbitratorParamsForFactory();
        mechanismArbitrator = Clones.clone(deployer.allocationMechanismArbitratorImplementation());

        IERC20VotesArbitrator(mechanismArbitrator).initializeWithConfig(
            IERC20VotesArbitrator.InitConfig({
                invalidRoundRewardsSink: IERC20VotesArbitrator(address(arbitrator)).invalidRoundRewardsSink(),
                votingToken: address(erc20),
                arbitrable: allocationMechanism,
                votingPeriod: arbParams.votingPeriod,
                votingDelay: arbParams.votingDelay,
                revealPeriod: arbParams.revealPeriod,
                arbitrationCost: arbParams.arbitrationCost,
                stakeVault: goalTreasury.stakeVault(),
                fixedBudgetTreasury: budgetTreasury,
                wrongOrMissedSlashBps: arbParams.wrongOrMissedSlashBps,
                slashCallerBountyBps: arbParams.slashCallerBountyBps
            })
        );

        AllocationMechanismTCR(allocationMechanism).initialize(
            budgetTreasury,
            deployer.roundFactory(),
            _mechanismRoundDefaults(arbParams),
            _mechanismRegistryConfig(mechanismArbitrator)
        );
    }

    function _mechanismRoundDefaults(
        IArbitrator.ArbitratorParams memory arbParams
    ) internal view returns (AllocationMechanismTCR.RoundDefaults memory defaults) {
        defaults = AllocationMechanismTCR.RoundDefaults({
            arbitratorExtraData: arbitratorExtraData,
            registrationMetaEvidence: registrationMetaEvidence,
            clearingMetaEvidence: clearingMetaEvidence,
            governor: governor,
            submissionBaseDeposit: submissionBaseDeposit,
            removalBaseDeposit: removalBaseDeposit,
            submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: removalChallengeBaseDeposit,
            challengePeriodDuration: challengePeriodDuration,
            votingPeriod: arbParams.votingPeriod,
            votingDelay: arbParams.votingDelay,
            revealPeriod: arbParams.revealPeriod,
            arbitrationCost: arbParams.arbitrationCost,
            wrongOrMissedSlashBps: arbParams.wrongOrMissedSlashBps,
            slashCallerBountyBps: arbParams.slashCallerBountyBps,
            roundOperator: governor
        });
    }

    function _mechanismRegistryConfig(
        address mechanismArbitrator
    ) internal view returns (AllocationMechanismTCR.RegistryConfig memory cfg) {
        cfg = AllocationMechanismTCR.RegistryConfig({
            arbitrator: IArbitrator(mechanismArbitrator),
            arbitratorExtraData: arbitratorExtraData,
            registrationMetaEvidence: registrationMetaEvidence,
            clearingMetaEvidence: clearingMetaEvidence,
            governor: governor,
            votingToken: IVotes(address(erc20)),
            submissionBaseDeposit: submissionBaseDeposit,
            submissionDepositStrategy: submissionDepositStrategy,
            removalBaseDeposit: removalBaseDeposit,
            submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: removalChallengeBaseDeposit,
            challengePeriodDuration: challengePeriodDuration
        });
    }

    function _tryResolveBudgetTerminalState(bytes32 itemID, IBudgetTreasury treasury) internal returns (bool) {
        if (_resolved(treasury)) return true;

        // Do not allow removal to complete unless spend is actually stopped.
        treasury.forceFlowRateToZero();
        if (_resolved(treasury)) return true;

        try treasury.resolveFailure() {} catch (bytes memory reason) {
            emit BudgetTerminalizationStepFailed(
                itemID,
                address(treasury),
                IBudgetTreasury.resolveFailure.selector,
                reason
            );
        }
        return _resolved(treasury);
    }

    function _resolveBudgetTerminalStateStrict(IBudgetTreasury treasury) internal returns (bool) {
        if (_resolved(treasury)) return true;

        // Do not allow removal to complete unless spend is actually stopped.
        treasury.forceFlowRateToZero();
        if (_resolved(treasury)) return true;

        treasury.resolveFailure();
        return _resolved(treasury);
    }

    function _resolved(IBudgetTreasury treasury) internal view returns (bool resolved_) {
        return treasury.resolved();
    }

    function _clearRemovalPendingState(bytes32 itemID) internal {
        _pendingRemovalFinalizations[itemID] = false;
    }

    function _isActivationLockedRemoval(IBudgetTreasury treasury) internal view returns (bool) {
        return treasury.activatedAt() != 0;
    }

    function _removeRecipientFromGoalFlowIfPresent(
        bytes32 itemID,
        address childFlow
    ) internal returns (bool) {
        if (childFlow == address(0) || !goalFlow.recipientExists(childFlow)) return false;

        goalFlow.removeRecipient(itemID);
        return true;
    }

    function _trySyncGoalTreasury(bytes32 itemID, address budgetTreasury) internal returns (bool) {
        try goalTreasury.sync() {
            return true;
        } catch (bytes memory reason) {
            emit BudgetTreasuryCallFailed(itemID, budgetTreasury, IGoalTreasury.sync.selector, reason);
            return false;
        }
    }
}
