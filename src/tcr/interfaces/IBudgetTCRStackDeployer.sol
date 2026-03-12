// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "./IBudgetTCR.sol";

interface IBudgetTCRStackDeployer {
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
        bool requireZeroPremiumAndSlashRates;
    }

    struct PreparationResult {
        address strategy;
        address budgetTreasury;
        address premiumEscrow;
        address childFlowRecipientAdmin;
        address allocationMechanism;
    }

    error ADDRESS_ZERO();
    error ONLY_BUDGET_TCR();

    function prepareBudgetStack(
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter
    ) external returns (PreparationResult memory result);

    function deployBudgetTreasury(
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        address spendPolicy,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
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
    function initialMechanismFactories() external view returns (address[] memory);
    function roundFactory() external view returns (address);
    function allocationMechanismTcrImplementation() external view returns (address);
    function allocationMechanismArbitratorImplementation() external view returns (address);
}
