// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTCRStackDeployer } from "src/tcr/interfaces/IBudgetTCRStackDeployer.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { BudgetTCRStorageV1 } from "src/tcr/storage/BudgetTCRStorageV1.sol";
import { GeneralizedTCRStorageV1 } from "src/tcr/storage/GeneralizedTCRStorageV1.sol";
import { BudgetTCRItems } from "src/tcr/library/BudgetTCRItems.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";
import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

library BudgetTCRStackActions {
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

    error BUDGET_TREASURY_MISMATCH();
    error PREMIUM_ESCROW_REQUIRES_ZERO_RATES();

    function deployBudgetStack(
        mapping(bytes32 => BudgetTCRStorageV1.BudgetDeployment) storage budgetDeployments,
        mapping(address => bytes32) storage itemIdByBudgetTreasury,
        mapping(address => bytes32) storage itemIdByChildFlow,
        bytes32 itemID,
        bytes memory item
    ) external {
        if (budgetDeployments[itemID].active) {
            revert IBudgetTCR.STACK_ALREADY_ACTIVE();
        }

        BudgetTCRStorageV1 budgetStore = BudgetTCRStorageV1(address(this));
        GeneralizedTCRStorageV1 tcrStore = GeneralizedTCRStorageV1(address(this));
        IGoalTreasury goalTreasury = budgetStore.goalTreasury();

        address budgetStakeLedger = goalTreasury.budgetStakeLedger();
        if (budgetStakeLedger == address(0)) revert IBudgetTCR.BUDGET_STAKE_LEDGER_NOT_CONFIGURED();

        IFlow goalFlow = budgetStore.goalFlow();
        IBudgetTCRStackDeployer deployer = IBudgetTCRStackDeployer(budgetStore.stackDeployer());
        address underwriterSlasherRouter = budgetStore.underwriterSlasherRouter();
        IBudgetTCRStackDeployer.StackModuleConfig memory stackModuleConfig = deployer.stackModuleConfig();
        uint32 budgetPremiumPpm = budgetStore.budgetPremiumPpm();
        uint32 budgetSlashPpm = budgetStore.budgetSlashPpm();
        if (stackModuleConfig.requireZeroPremiumAndSlashRates && (budgetPremiumPpm != 0 || budgetSlashPpm != 0)) {
            revert PREMIUM_ESCROW_REQUIRES_ZERO_RATES();
        }
        IBudgetTCR.BudgetListing memory listing = BudgetTCRItems.decodeItemData(item);
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            budgetStakeLedger,
            address(goalFlow),
            underwriterSlasherRouter
        );

        address budgetTreasury = prepared.budgetTreasury;
        address premiumEscrow = prepared.premiumEscrow;
        address allocationMechanism = prepared.allocationMechanism;
        bool hasAllocationMechanism = allocationMechanism != address(0);

        (, address childFlow) = goalFlow.addFlowRecipient(
            itemID,
            listing.metadata,
            prepared.childFlowRecipientAdmin,
            budgetTreasury,
            budgetTreasury,
            premiumEscrow,
            budgetPremiumPpm,
            IAllocationStrategy(prepared.strategy)
        );

        deployer.registerChildFlowRecipient(itemID, childFlow);

        emit BudgetStackDeployed(itemID, childFlow, budgetTreasury, prepared.strategy);
        deployer.emitBudgetStackDeployed(itemID, childFlow, budgetTreasury, premiumEscrow, prepared.strategy);

        (uint64 oracleLiveness, uint256 oracleBondAmount) = budgetStore.oracleValidationBounds();
        address deployedBudgetTreasury = deployer.deployBudgetTreasury(
            budgetTreasury,
            premiumEscrow,
            childFlow,
            budgetStakeLedger,
            address(goalFlow),
            underwriterSlasherRouter,
            budgetSlashPpm,
            listing,
            budgetStore.budgetSuccessResolver(),
            budgetStore.budgetSpendPolicy(),
            oracleLiveness,
            oracleBondAmount
        );

        address managerRewardDistributionPool = address(IFlow(childFlow).managerRewardDistributionPool());
        if (managerRewardDistributionPool == address(0)) {
            revert IBudgetTCR.MANAGER_REWARD_DISTRIBUTION_POOL_NOT_CONFIGURED();
        }
        IPremiumEscrow(premiumEscrow).connectManagerRewardPool(managerRewardDistributionPool);
        if (deployedBudgetTreasury != budgetTreasury) {
            revert BUDGET_TREASURY_MISMATCH();
        }

        address allocationMechanismArbitrator;
        if (hasAllocationMechanism) {
            allocationMechanismArbitrator = _initializeBudgetAllocationMechanism(
                deployer,
                allocationMechanism,
                budgetTreasury,
                goalTreasury,
                budgetStore,
                tcrStore
            );
        }

        _recordBudgetStackTopology(
            budgetDeployments,
            itemIdByBudgetTreasury,
            itemIdByChildFlow,
            itemID,
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: childFlow,
                budgetTreasury: budgetTreasury,
                premiumEscrow: premiumEscrow,
                strategy: prepared.strategy,
                allocationMechanism: allocationMechanism,
                allocationMechanismArbitrator: allocationMechanismArbitrator
            })
        );

        IBudgetStakeLedger(budgetStakeLedger).registerBudget(itemID, budgetTreasury);
        IUnderwriterSlasherRouter(underwriterSlasherRouter).setAuthorizedPremiumEscrow(premiumEscrow, true);
        if (hasAllocationMechanism) {
            emit BudgetAllocationMechanismDeployed(
                itemID,
                allocationMechanism,
                allocationMechanismArbitrator,
                deployer.roundFactory()
            );
            deployer.emitBudgetAllocationMechanismDeployed(
                itemID,
                allocationMechanism,
                allocationMechanismArbitrator,
                deployer.roundFactory()
            );
        }
    }

    function _initializeBudgetAllocationMechanism(
        IBudgetTCRStackDeployer deployer,
        address allocationMechanism,
        address budgetTreasury,
        IGoalTreasury goalTreasury,
        BudgetTCRStorageV1 budgetStore,
        GeneralizedTCRStorageV1 tcrStore
    ) private returns (address mechanismArbitrator) {
        IArbitrator arbitrator = tcrStore.arbitrator();
        IArbitrator.ArbitratorParams memory arbParams = arbitrator.getArbitratorParamsForFactory();
        mechanismArbitrator = Clones.clone(deployer.allocationMechanismArbitratorImplementation());

        IERC20VotesArbitrator(mechanismArbitrator).initializeWithConfig(
            IERC20VotesArbitrator.InitConfig({
                invalidRoundRewardsSink: IERC20VotesArbitrator(address(arbitrator)).invalidRoundRewardsSink(),
                votingToken: address(tcrStore.erc20()),
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

        address[] memory initialMechanismFactories = deployer.initialMechanismFactories();
        AllocationMechanismTCR(allocationMechanism).initialize(
            budgetTreasury,
            initialMechanismFactories,
            _mechanismInitConfig(mechanismArbitrator, budgetStore, tcrStore)
        );
    }

    function _mechanismInitConfig(
        address mechanismArbitrator,
        BudgetTCRStorageV1 budgetStore,
        GeneralizedTCRStorageV1 tcrStore
    ) private view returns (AllocationMechanismTCR.InitConfig memory cfg) {
        cfg = AllocationMechanismTCR.InitConfig({
            tcrConfig: IGeneralizedTCRConfig.RegistryConfig({
                arbitrator: IArbitrator(mechanismArbitrator),
                votingToken: IVotes(address(tcrStore.erc20())),
                submissionDepositStrategy: tcrStore.submissionDepositStrategy(),
                registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                    arbitratorExtraData: tcrStore.arbitratorExtraData(),
                    registrationMetaEvidence: tcrStore.registrationMetaEvidence(),
                    clearingMetaEvidence: tcrStore.clearingMetaEvidence(),
                    submissionBaseDeposit: tcrStore.submissionBaseDeposit(),
                    removalBaseDeposit: tcrStore.removalBaseDeposit(),
                    submissionChallengeBaseDeposit: tcrStore.submissionChallengeBaseDeposit(),
                    removalChallengeBaseDeposit: tcrStore.removalChallengeBaseDeposit(),
                    challengePeriodDuration: tcrStore.challengePeriodDuration()
                })
            }),
            factoryManager: budgetStore.allocationMechanismAdmin()
        });
    }

    function _recordBudgetStackTopology(
        mapping(bytes32 => BudgetTCRStorageV1.BudgetDeployment) storage budgetDeployments,
        mapping(address => bytes32) storage itemIdByBudgetTreasury,
        mapping(address => bytes32) storage itemIdByChildFlow,
        bytes32 itemID,
        IBudgetStackTopologyReader.BudgetStackTopology memory topology
    ) private {
        BudgetTCRStorageV1.BudgetDeployment storage deployment = budgetDeployments[itemID];

        address previousBudgetTreasury = deployment.budgetTreasury;
        if (previousBudgetTreasury != address(0) && itemIdByBudgetTreasury[previousBudgetTreasury] == itemID) {
            delete itemIdByBudgetTreasury[previousBudgetTreasury];
        }

        address previousChildFlow = deployment.childFlow;
        if (previousChildFlow != address(0) && itemIdByChildFlow[previousChildFlow] == itemID) {
            delete itemIdByChildFlow[previousChildFlow];
        }

        deployment.childFlow = topology.childFlow;
        deployment.budgetTreasury = topology.budgetTreasury;
        deployment.premiumEscrow = topology.premiumEscrow;
        deployment.strategy = topology.strategy;
        deployment.allocationMechanism = topology.allocationMechanism;
        deployment.allocationMechanismArbitrator = topology.allocationMechanismArbitrator;
        deployment.active = true;

        itemIdByBudgetTreasury[topology.budgetTreasury] = itemID;
        itemIdByChildFlow[topology.childFlow] = itemID;
    }
}
