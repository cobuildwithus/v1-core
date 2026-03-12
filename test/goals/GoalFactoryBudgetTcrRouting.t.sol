// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalFactoryBudgetTcrRouting } from "src/goals/library/GoalFactoryBudgetTcrRouting.sol";

contract GoalFactoryBudgetTcrRoutingTest is Test {
    function test_resolveOpenPresetRouting_usesNoGateAndNoPremiumModeWhenBothRatesAreZero() public pure {
        GoalFactoryBudgetTcrRouting.Routing memory routing = GoalFactoryBudgetTcrRouting.resolveOpenPresetRouting(
            0, 0, address(0xBEEF), address(0xCAFE), address(0xF00D)
        );

        assertEq(routing.budgetGatePolicy, address(0));
        assertEq(routing.premiumEscrowImplementation, address(0));
        assertEq(routing.underwriterSlasherRouter, address(0));
    }

    function test_resolveOpenPresetRouting_usesNoGateAndPreservesRiskWiringWhenSlashIsZero() public pure {
        GoalFactoryBudgetTcrRouting.Routing memory routing = GoalFactoryBudgetTcrRouting.resolveOpenPresetRouting(
            100_000, 0, address(0xBEEF), address(0xCAFE), address(0xF00D)
        );

        assertEq(routing.budgetGatePolicy, address(0));
        assertEq(routing.premiumEscrowImplementation, address(0xCAFE));
        assertEq(routing.underwriterSlasherRouter, address(0xF00D));
    }

    function test_resolveOpenPresetRouting_preservesGateAndRiskWiringWhenSlashIsEnabled() public pure {
        GoalFactoryBudgetTcrRouting.Routing memory routing = GoalFactoryBudgetTcrRouting.resolveOpenPresetRouting(
            100_000, 50_000, address(0xBEEF), address(0xCAFE), address(0xF00D)
        );

        assertEq(routing.budgetGatePolicy, address(0xBEEF));
        assertEq(routing.premiumEscrowImplementation, address(0xCAFE));
        assertEq(routing.underwriterSlasherRouter, address(0xF00D));
    }
}
