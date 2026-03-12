// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

library BudgetTCRConfigHelpers {
    function openRiskModuleRouting(
        address budgetGatePolicy,
        address premiumEscrowImplementation,
        address underwriterSlasherRouter
    ) internal pure returns (IBudgetTCR.RiskModuleRouting memory routing) {
        routing = IBudgetTCR.RiskModuleRouting({
            budgetGatePolicy: budgetGatePolicy,
            premiumEscrowImplementation: premiumEscrowImplementation,
            underwriterSlasherRouter: underwriterSlasherRouter
        });
    }

    function noPremiumRiskModuleRouting(address budgetGatePolicy)
        internal
        pure
        returns (IBudgetTCR.RiskModuleRouting memory routing)
    {
        routing = IBudgetTCR.RiskModuleRouting({
            budgetGatePolicy: budgetGatePolicy,
            premiumEscrowImplementation: address(0),
            underwriterSlasherRouter: address(0)
        });
    }

    function openStackModuleConfig(
        address premiumEscrowImplementation
    ) internal pure returns (IBudgetStackDeployer.StackModuleConfig memory config) {
        config = IBudgetStackDeployer.StackModuleConfig({
            childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.SharedBudgetFlowRouter,
            childFlowStrategyTarget: address(0),
            mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.AllocationMechanismTCR,
            childFlowRecipientAdmin: address(0),
            premiumEscrowMode: IBudgetStackDeployer.PremiumEscrowMode.Clone,
            premiumEscrowImplementation: premiumEscrowImplementation
        });
    }

    function noPremiumStackModuleConfig()
        internal
        pure
        returns (IBudgetStackDeployer.StackModuleConfig memory config)
    {
        config = IBudgetStackDeployer.StackModuleConfig({
            childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.SharedBudgetFlowRouter,
            childFlowStrategyTarget: address(0),
            mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.AllocationMechanismTCR,
            childFlowRecipientAdmin: address(0),
            premiumEscrowMode: IBudgetStackDeployer.PremiumEscrowMode.None,
            premiumEscrowImplementation: address(0)
        });
    }

    function fixedNoPremiumStackModuleConfig(
        address strategy,
        address recipientAdmin
    ) internal pure returns (IBudgetStackDeployer.StackModuleConfig memory config) {
        config = IBudgetStackDeployer.StackModuleConfig({
            childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.Fixed,
            childFlowStrategyTarget: strategy,
            mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.None,
            childFlowRecipientAdmin: recipientAdmin,
            premiumEscrowMode: IBudgetStackDeployer.PremiumEscrowMode.None,
            premiumEscrowImplementation: address(0)
        });
    }
}
