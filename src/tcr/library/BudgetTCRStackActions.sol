// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { BudgetStackTypes } from "src/interfaces/BudgetStackTypes.sol";
import { IBudgetStackDiscoveryEmitter } from "src/interfaces/IBudgetStackDiscoveryEmitter.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { BudgetTCRStorageV1 } from "src/tcr/storage/BudgetTCRStorageV1.sol";
import { GeneralizedTCRStorageV1 } from "src/tcr/storage/GeneralizedTCRStorageV1.sol";
import { BudgetTCRItems } from "src/tcr/library/BudgetTCRItems.sol";
import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";
import { BudgetStackInstantiationLib } from "src/goals/library/BudgetStackInstantiationLib.sol";
import { BudgetTopologyRegistryLib } from "src/goals/library/BudgetTopologyRegistryLib.sol";
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

    function deployBudgetStack(
        mapping(bytes32 => BudgetTopologyRegistryLib.BudgetDeployment) storage budgetDeployments,
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
        IBudgetStackDeployer deployer = IBudgetStackDeployer(budgetStore.stackDeployer());
        IBudgetStackDiscoveryEmitter discoveryEmitter = IBudgetStackDiscoveryEmitter(budgetStore.discoveryEmitter());
        address underwriterSlasherRouter = budgetStore.underwriterSlasherRouter();
        uint32 budgetPremiumPpm = budgetStore.budgetPremiumPpm();
        uint32 budgetSlashPpm = budgetStore.budgetSlashPpm();
        bool requiresPremiumModule = budgetPremiumPpm != 0 || budgetSlashPpm != 0;
        IBudgetTCR.BudgetListing memory listing = BudgetTCRItems.decodeItemData(item);
        BudgetStackTypes.PreparationResult memory prepared = deployer.prepareBudgetStack(
            budgetStakeLedger,
            address(goalFlow)
        );

        address allocationMechanism = prepared.allocationMechanism;
        (uint64 oracleLiveness, uint256 oracleBondAmount) = budgetStore.oracleValidationBounds();
        BudgetStackInstantiationLib.InstantiatedBudgetStack memory deployed = requiresPremiumModule
            ? BudgetStackInstantiationLib.instantiatePreparedBudgetStackWithRiskModule(
                BudgetStackInstantiationLib.PreparedBudgetStackContext({
                    itemID: itemID,
                    metadata: listing.metadata,
                    goalFlow: ICustomFlow(address(goalFlow)),
                    deployer: deployer,
                    prepared: prepared,
                    lifecycleConfig: BudgetStackInstantiationLib.BudgetLifecycleConfig({
                        fundingDeadline: listing.fundingDeadline,
                        executionDuration: listing.executionDuration,
                        activationThreshold: listing.activationThreshold,
                        runwayCap: listing.runwayCap,
                        successOracleSpecHash: listing.oracleConfig.oracleSpecHash,
                        successAssertionPolicyHash: listing.oracleConfig.assertionPolicyHash
                    }),
                    runtimeConfig: BudgetStackInstantiationLib.BudgetRuntimeConfig({
                        successResolver: budgetStore.budgetSuccessResolver(),
                        successAssertionLiveness: oracleLiveness,
                        successAssertionBond: oracleBondAmount,
                        spendPolicy: budgetStore.budgetSpendPolicy()
                    }),
                    premiumPpm: budgetPremiumPpm
                }),
                BudgetStackTypes.RiskModuleInitConfig({
                    budgetStakeLedger: budgetStakeLedger,
                    goalFlow: address(goalFlow),
                    underwriterSlasherRouter: underwriterSlasherRouter,
                    budgetSlashPpm: budgetSlashPpm
                })
            )
            : BudgetStackInstantiationLib.instantiatePreparedBudgetStackWithoutRiskModule(
                BudgetStackInstantiationLib.PreparedBudgetStackContext({
                    itemID: itemID,
                    metadata: listing.metadata,
                    goalFlow: ICustomFlow(address(goalFlow)),
                    deployer: deployer,
                    prepared: prepared,
                    lifecycleConfig: BudgetStackInstantiationLib.BudgetLifecycleConfig({
                        fundingDeadline: listing.fundingDeadline,
                        executionDuration: listing.executionDuration,
                        activationThreshold: listing.activationThreshold,
                        runwayCap: listing.runwayCap,
                        successOracleSpecHash: listing.oracleConfig.oracleSpecHash,
                        successAssertionPolicyHash: listing.oracleConfig.assertionPolicyHash
                    }),
                    runtimeConfig: BudgetStackInstantiationLib.BudgetRuntimeConfig({
                        successResolver: budgetStore.budgetSuccessResolver(),
                        successAssertionLiveness: oracleLiveness,
                        successAssertionBond: oracleBondAmount,
                        spendPolicy: budgetStore.budgetSpendPolicy()
                    }),
                    premiumPpm: budgetPremiumPpm
                })
            );

        emit BudgetStackDeployed(itemID, deployed.childFlow, deployed.budgetTreasury, deployed.strategy);
        discoveryEmitter.onBudgetStackDeployed(
            itemID,
            deployed.childFlow,
            deployed.budgetTreasury,
            deployed.premiumEscrow,
            deployed.strategy
        );

        address allocationMechanismArbitrator;
        if (allocationMechanism != address(0)) {
            allocationMechanismArbitrator = _initializeBudgetAllocationMechanism(
                deployer,
                allocationMechanism,
                deployed.budgetTreasury,
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
                childFlow: deployed.childFlow,
                budgetTreasury: deployed.budgetTreasury,
                premiumEscrow: deployed.premiumEscrow,
                strategy: deployed.strategy,
                allocationMechanism: allocationMechanism,
                allocationMechanismArbitrator: allocationMechanismArbitrator
            })
        );

        budgetDeployments[itemID].active = true;
        IBudgetStakeLedger(budgetStakeLedger).registerBudget(itemID, deployed.budgetTreasury);
        if (underwriterSlasherRouter != address(0)) {
            IUnderwriterSlasherRouter(underwriterSlasherRouter).setAuthorizedPremiumEscrow(
                deployed.premiumEscrow,
                true
            );
        }
        if (allocationMechanism != address(0)) {
            emit BudgetAllocationMechanismDeployed(
                itemID,
                allocationMechanism,
                allocationMechanismArbitrator,
                deployer.roundFactory()
            );
            discoveryEmitter.onBudgetAllocationMechanismDeployed(
                itemID,
                allocationMechanism,
                allocationMechanismArbitrator,
                deployer.roundFactory()
            );
        }
    }

    function _initializeBudgetAllocationMechanism(
        IBudgetStackDeployer deployer,
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
        mapping(bytes32 => BudgetTopologyRegistryLib.BudgetDeployment) storage budgetDeployments,
        mapping(address => bytes32) storage itemIdByBudgetTreasury,
        mapping(address => bytes32) storage itemIdByChildFlow,
        bytes32 itemID,
        IBudgetStackTopologyReader.BudgetStackTopology memory topology
    ) private {
        BudgetTopologyRegistryLib.recordBudgetStackTopology(
            budgetDeployments,
            itemIdByBudgetTreasury,
            itemIdByChildFlow,
            itemID,
            topology
        );
    }
}
