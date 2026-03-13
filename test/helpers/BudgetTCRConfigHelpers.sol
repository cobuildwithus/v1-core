// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { BudgetStackPresetConfigLib } from "src/goals/library/BudgetStackPresetConfigLib.sol";
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
        config = BudgetStackPresetConfigLib.openPreset(premiumEscrowImplementation);
    }

    function noPremiumStackModuleConfig()
        internal
        pure
        returns (IBudgetStackDeployer.StackModuleConfig memory config)
    {
        config = BudgetStackPresetConfigLib.openPreset(address(0));
    }

    function fixedNoPremiumStackModuleConfig(
        address strategyFactory,
        address recipientAdmin
    ) internal pure returns (IBudgetStackDeployer.StackModuleConfig memory config) {
        config = BudgetStackPresetConfigLib.managedPreset(strategyFactory, recipientAdmin);
    }
}
