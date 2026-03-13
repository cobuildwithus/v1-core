// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "./IBudgetTreasury.sol";

interface IBudgetStackDeployer {
    enum ChildFlowStrategyMode {
        SharedBudgetFlowRouter,
        Fixed,
        Factory
    }

    enum MechanismLayerMode {
        AllocationMechanismTCR,
        None
    }

    struct StackModuleConfig {
        ChildFlowStrategyMode childFlowStrategyMode;
        address childFlowStrategyTarget;
        MechanismLayerMode mechanismLayerMode;
        address childFlowRecipientAdmin;
        address premiumEscrowImplementation;
    }

    struct PreparationResult {
        address strategy;
        address budgetTreasury;
        address premiumEscrow;
        address childFlowRecipientAdmin;
        address allocationMechanism;
    }

    struct RiskModuleInitConfig {
        address budgetStakeLedger;
        address goalFlow;
        address underwriterSlasherRouter;
        uint32 budgetSlashPpm;
    }

    error ADDRESS_ZERO();
    error ONLY_CONTROLLER();

    function controller() external view returns (address);
    function initializeWithConfig(
        address controller_,
        StackModuleConfig calldata stackModuleConfig_,
        address discoveryEmitter_
    ) external;

    function prepareBudgetStack(
        address budgetStakeLedger,
        address goalFlow
    ) external returns (PreparationResult memory result);

    function deployBudgetTreasury(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig
    ) external returns (address deployedBudgetTreasury);

    function deployBudgetTreasuryWithRiskModule(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig,
        RiskModuleInitConfig calldata riskModuleInitConfig
    ) external returns (address deployedBudgetTreasury);

    function registerChildFlowRecipient(bytes32 recipientId, address childFlow) external;

    function emitBudgetStackDeployed(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    ) external;

    function emitBudgetAllocationMechanismDeployed(
        bytes32 itemID,
        address allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory
    ) external;

    function stackModuleConfig() external view returns (StackModuleConfig memory config);
    function premiumEscrowImplementation() external view returns (address implementation);
    function initialMechanismFactories() external view returns (address[] memory);
    function roundFactory() external view returns (address);
    function allocationMechanismTcrImplementation() external view returns (address);
    function allocationMechanismArbitratorImplementation() external view returns (address);
}
