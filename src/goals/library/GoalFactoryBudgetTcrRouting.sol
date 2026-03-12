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
        bool usesNoPremiumMode = budgetPremiumPpm == 0 && budgetSlashPpm == 0;
        return
            IBudgetTCR.RiskModuleRouting({
                budgetGatePolicy: budgetSlashPpm == 0 ? address(0) : openBudgetGatePolicy,
                premiumEscrowImplementation: usesNoPremiumMode ? address(0) : premiumEscrowImplementation,
                underwriterSlasherRouter: usesNoPremiumMode ? address(0) : underwriterSlasherRouter
            });
    }
}
