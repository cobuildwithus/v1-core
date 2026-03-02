// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { UnderwritingCoverageCapIntegrationTest } from "test/goals/UnderwritingIntegration.t.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract GoalTreasuryUnderwritingConfigGuardTest is UnderwritingCoverageCapIntegrationTest {
    function test_initializeRevertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        _configurePredictedGoalTreasury();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 10;
        config.budgetPremiumPpm = 0;
        config.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                config.budgetPremiumPpm,
                config.budgetSlashPpm,
                config.coverageLambda
            )
        );
        new GoalTreasury(address(this), config);
    }

    function test_initializeRevertsWhenSlashEnabledAndCoverageLambdaIsZero() public {
        _configurePredictedGoalTreasury();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 0;
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                config.budgetPremiumPpm,
                config.budgetSlashPpm,
                config.coverageLambda
            )
        );
        new GoalTreasury(address(this), config);
    }

    function test_cloneInitializeRevertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalTreasury implementation = _deployGoalTreasuryImplementation();
        _configurePredictedGoalTreasury();
        GoalTreasury clone = GoalTreasury(Clones.clone(address(implementation)));

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 10;
        config.budgetPremiumPpm = 0;
        config.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                config.budgetPremiumPpm,
                config.budgetSlashPpm,
                config.coverageLambda
            )
        );
        clone.initialize(address(this), config);
    }

    function test_cloneInitializeRevertsWhenSlashEnabledAndCoverageLambdaIsZero() public {
        GoalTreasury implementation = _deployGoalTreasuryImplementation();
        _configurePredictedGoalTreasury();
        GoalTreasury clone = GoalTreasury(Clones.clone(address(implementation)));

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 0;
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                config.budgetPremiumPpm,
                config.budgetSlashPpm,
                config.coverageLambda
            )
        );
        clone.initialize(address(this), config);
    }

    function test_cloneInitializeAllowsSlashEnabledWhenPremiumAndCoverageAreNonZero() public {
        GoalTreasury implementation = _deployGoalTreasuryImplementation();
        _configurePredictedGoalTreasury();
        GoalTreasury clone = GoalTreasury(Clones.clone(address(implementation)));

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 10;
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        clone.initialize(address(this), config);

        assertEq(clone.coverageLambda(), config.coverageLambda);
        assertEq(uint256(clone.budgetPremiumPpm()), uint256(config.budgetPremiumPpm));
        assertEq(uint256(clone.budgetSlashPpm()), uint256(config.budgetSlashPpm));
    }

    function _deployGoalTreasuryImplementation() internal returns (GoalTreasury implementation) {
        IGoalTreasury.GoalConfig memory emptyConfig;
        implementation = new GoalTreasury(address(0), emptyConfig);
    }

    function _configurePredictedGoalTreasury() internal {
        address predictedTreasury = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predictedTreasury);
        budgetStakeLedger.setGoalTreasury(predictedTreasury);
        flow.setFlowOperator(predictedTreasury);
        flow.setSweeper(predictedTreasury);
    }
}
