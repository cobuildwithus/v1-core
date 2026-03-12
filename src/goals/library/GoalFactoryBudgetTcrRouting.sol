// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

library GoalFactoryBudgetTcrRouting {
    function resolveOpenPresetRouting(
        uint32 budgetPremiumPpm,
        uint32 budgetSlashPpm,
        address openBudgetGatePolicy,
        address premiumEscrowImplementation,
        address underwriterSlasherRouter
    ) internal pure returns (IBudgetTCR.RiskModuleRouting memory routing) {
        bool usesExplicitNoPremiumMode = budgetPremiumPpm == 0 && budgetSlashPpm == 0;
        return
            IBudgetTCR.RiskModuleRouting({
                budgetGatePolicy: budgetSlashPpm == 0 ? address(0) : openBudgetGatePolicy,
                premiumEscrowImplementation: usesExplicitNoPremiumMode ? address(0) : premiumEscrowImplementation,
                underwriterSlasherRouter: usesExplicitNoPremiumMode ? address(0) : underwriterSlasherRouter,
                requireZeroPremiumAndSlashRates: usesExplicitNoPremiumMode
            });
    }
}
