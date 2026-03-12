// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

library GoalFactoryBudgetTcrRouting {
    struct Routing {
        address budgetGatePolicy;
        address premiumEscrowImplementation;
        address underwriterSlasherRouter;
    }

    function resolveOpenPresetRouting(
        uint32 budgetPremiumPpm,
        uint32 budgetSlashPpm,
        address openBudgetGatePolicy,
        address premiumEscrowImplementation,
        address underwriterSlasherRouter
    ) internal pure returns (Routing memory routing) {
        bool usesExplicitNoPremiumMode = budgetPremiumPpm == 0 && budgetSlashPpm == 0;
        routing = Routing({
            budgetGatePolicy: budgetSlashPpm == 0 ? address(0) : openBudgetGatePolicy,
            premiumEscrowImplementation: usesExplicitNoPremiumMode ? address(0) : premiumEscrowImplementation,
            underwriterSlasherRouter: usesExplicitNoPremiumMode ? address(0) : underwriterSlasherRouter
        });
    }
}
