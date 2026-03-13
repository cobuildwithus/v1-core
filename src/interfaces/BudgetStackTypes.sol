// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

library BudgetStackTypes {
    enum ChildFlowStrategyMode {
        SharedBudgetFlowRouter,
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
}
