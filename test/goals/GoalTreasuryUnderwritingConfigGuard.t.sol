// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {UnderwritingCoverageCapIntegrationTest} from "test/goals/UnderwritingIntegration.t.sol";

contract GoalTreasuryUnderwritingConfigGuardTest is UnderwritingCoverageCapIntegrationTest {
    function test_initializeRevertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.budgetPremiumPpm = 0;
        config.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INVALID_UNDERWRITING_SLASH_CONFIG.selector, config.budgetPremiumPpm, config.budgetSlashPpm
            )
        );
        clone.initialize(config);
    }

    function test_initializeAllowsSlashEnabledWhenPremiumIsNonZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        clone.initialize(config);

        assertEq(uint256(clone.budgetPremiumPpm()), uint256(config.budgetPremiumPpm));
        assertEq(uint256(clone.budgetSlashPpm()), uint256(config.budgetSlashPpm));
    }

    function test_cloneInitializeRevertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.budgetPremiumPpm = 0;
        config.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INVALID_UNDERWRITING_SLASH_CONFIG.selector, config.budgetPremiumPpm, config.budgetSlashPpm
            )
        );
        clone.initialize(config);
    }

    function test_cloneInitializeAllowsSlashEnabledWhenPremiumIsNonZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        clone.initialize(config);

        assertEq(uint256(clone.budgetPremiumPpm()), uint256(config.budgetPremiumPpm));
        assertEq(uint256(clone.budgetSlashPpm()), uint256(config.budgetSlashPpm));
    }

    function test_cloneInitializeAllowsSlashEnabledWhenPremiumAndSlashAreNonZero() public {
        GoalTreasury clone = _cloneGoalTreasuryWithPredictedAddress();

        IGoalTreasury.GoalConfig memory config =
            _defaultGoalConfig(address(rulesets), address(hook), address(budgetStakeLedger));
        config.budgetPremiumPpm = 100_000;
        config.budgetSlashPpm = 50_000;

        clone.initialize(config);

        assertEq(uint256(clone.budgetPremiumPpm()), uint256(config.budgetPremiumPpm));
        assertEq(uint256(clone.budgetSlashPpm()), uint256(config.budgetSlashPpm));
    }

    function test_processHookSplit_atOrAfterDeadline_defersFunding_insteadOfReverting() public {
        vm.warp(treasury.deadline());

        (
            IGoalTreasury.HookSplitAction action,
            uint256 superTokenAmount,
            uint256 burnAmount
        ) = _processGoalHookSplit(treasury, 1e18);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.Deferred));
        assertEq(superTokenAmount, 1e18);
        assertEq(burnAmount, 0);
        assertEq(treasury.totalRaised(), 0);
        assertEq(treasury.deferredHookSuperTokenAmount(), 1e18);
    }
}
