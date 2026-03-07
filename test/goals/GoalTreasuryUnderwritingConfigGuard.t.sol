// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { UnderwritingCoverageCapIntegrationTest } from "test/goals/UnderwritingIntegration.t.sol";

contract GoalTreasuryUnderwritingConfigGuardTest is UnderwritingCoverageCapIntegrationTest {
    function test_initializeRevertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

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

    function test_initializeAllowsSlashEnabledWhenCoverageLambdaIsZero_ifPremiumIsNonZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 0;
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        clone.initialize(address(this), config);

        assertEq(clone.coverageLambda(), config.coverageLambda);
        assertEq(uint256(clone.budgetPremiumPpm()), uint256(config.budgetPremiumPpm));
        assertEq(uint256(clone.budgetSlashPpm()), uint256(config.budgetSlashPpm));
    }

    function test_cloneInitializeRevertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

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

    function test_cloneInitializeAllowsSlashEnabledWhenCoverageLambdaIsZero_ifPremiumIsNonZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.coverageLambda = 0;
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        clone.initialize(address(this), config);

        assertEq(clone.coverageLambda(), config.coverageLambda);
        assertEq(uint256(clone.budgetPremiumPpm()), uint256(config.budgetPremiumPpm));
        assertEq(uint256(clone.budgetSlashPpm()), uint256(config.budgetSlashPpm));
    }

    function test_cloneInitializeAllowsSlashEnabledWhenPremiumAndCoverageAreNonZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

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

    function test_recordHookFunding_returnsFalseAtOrAfterDeadline_insteadOfReverting() public {
        vm.warp(treasury.deadline());

        vm.prank(address(hook));
        bool accepted = treasury.recordHookFunding(1e18);

        assertFalse(accepted);
    }
}
