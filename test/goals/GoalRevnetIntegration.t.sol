// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

import { GoalRevnetFixtureBase } from "test/goals/helpers/GoalRevnetFixtureBase.t.sol";
import { IRevnetHarness, RevnetHarnessDeployer } from "test/goals/helpers/RevnetHarnessDeployer.sol";
import { RevnetTestDirectory, RevnetTestRulesets } from "test/goals/helpers/RevnetTestHarness.sol";

import { JBApprovalStatus } from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesetApprovalHook } from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract GoalRevnetIntegrationTest is GoalRevnetFixtureBase {
    address internal alice = address(0xB0B);

    IStakeVault internal goalStrategy;

    function setUp() public override {
        super.setUp();

        _setUpGoalIntegration(_goalConfigPresetNoEscrow());
        _mintAndApproveStakeTokens(alice, 500e18, 500e18);
        goalStrategy = IStakeVault(address(vault));
    }

    function test_processSplitWith_reservedController_wrapsUnderlyingAndCreditsTreasury() public {
        uint256 amount = 25e18;
        underlyingToken.mint(address(hook), amount);

        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(underlyingToken.balanceOf(address(hook)), 0);
        assertEq(underlyingToken.balanceOf(address(treasury)), 0);
        assertEq(treasury.totalRaised(), amount);
    }

    function test_processSplitWith_revertsWhenContextTokenDoesNotMatchUnderlying() public {
        uint256 amount = 9e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalRevnetSplitHook.INVALID_SOURCE_TOKEN.selector, address(underlyingToken), address(superToken)
            )
        );
        _processAsController(_splitContext(address(superToken), amount, goalRevnetId, 1));
    }

    function test_processSplitWith_revertsWhenHookBalanceIsInsufficient() public {
        uint256 amount = 5e18;
        underlyingToken.mint(address(hook), amount - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalRevnetSplitHook.INSUFFICIENT_HOOK_BALANCE.selector,
                address(underlyingToken),
                amount,
                amount - 1
            )
        );
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));
    }

    function test_processSplitWith_revertsForUnauthorizedCaller() public {
        vm.prank(other);
        vm.expectRevert(GoalRevnetSplitHook.UNAUTHORIZED_CALLER.selector);
        hook.processSplitWith(_splitContext(address(underlyingToken), 5e18, goalRevnetId, 1));
    }

    function test_processSplitWith_usesLatestDirectoryController() public {
        uint256 amount = 6e18;
        address newController = address(0xCAFE);
        underlyingToken.mint(address(hook), amount);
        IJBDirectory directory = revnets.directory();

        vm.prank(address(revnets));
        directory.setControllerOf(goalRevnetId, IERC165(newController));

        vm.expectRevert(GoalRevnetSplitHook.UNAUTHORIZED_CALLER.selector);
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        vm.prank(newController);
        hook.processSplitWith(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(underlyingToken.balanceOf(address(hook)), 0);
        assertEq(underlyingToken.balanceOf(address(treasury)), 0);
        assertEq(treasury.totalRaised(), amount);
    }

    function test_processSplitWith_revertsWhenNotReservedGroup() public {
        underlyingToken.mint(address(hook), 1e18);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.INVALID_SPLIT_GROUP.selector, 1, 0));
        _processAsController(_splitContext(address(underlyingToken), 1e18, goalRevnetId, 0));
    }

    function test_hookFundingDefersWhenMintingStops_fromRealRulesets() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);

        assertTrue(treasury.canAcceptHookFunding());
        assertTrue(treasury.isMintingOpen());

        vm.warp(uint256(goalMintCloseTimestamp) + 1);

        assertFalse(treasury.isMintingOpen());
        assertFalse(treasury.canAcceptHookFunding());

        uint256 amount = 60e18;
        underlyingToken.mint(address(hook), amount);

        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(treasury.totalRaised(), minRaiseAmount);
        assertEq(treasury.deferredHookSuperTokenAmount(), amount);
    }

    function test_deferredHookFunding_settlesOnTerminalSync() public {
        uint256 amount = 17e18;
        vm.warp(treasury.deadline());
        underlyingToken.mint(address(hook), amount);

        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));
        assertEq(treasury.deferredHookSuperTokenAmount(), amount);
        assertEq(treasury.totalRaised(), 0);
        assertEq(underlyingToken.balanceOf(address(hook)), 0);

        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, amount, "GOAL_TERMINAL_RESIDUAL_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, amount, "GOAL_TERMINAL_RESIDUAL_BURN"
            )
        );

        treasury.sync();

        assertEq(treasury.deferredHookSuperTokenAmount(), 0);
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
    }

    function test_stakeWeightAndStrategy_followLiveRulesetsAndResolution() public {
        _stakeGoal(alice, 100e18);
        assertEq(vault.weightOf(alice), 50e18);

        _stakeCobuild(alice, 10e18);
        assertEq(vault.weightOf(alice), 60e18);

        uint256 key = uint256(uint160(alice));
        assertTrue(goalStrategy.canAllocate(key, alice));
        assertTrue(goalStrategy.canAccountAllocate(alice));
        assertEq(goalStrategy.currentWeight(key), 60e18);

        vm.warp(uint256(goalMintCloseTimestamp) + 1);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositCobuild(1e18);

        vm.warp(treasury.deadline());
        treasury.sync();

        assertFalse(goalStrategy.canAllocate(key, alice));
        assertFalse(goalStrategy.canAccountAllocate(alice));
        assertEq(goalStrategy.currentWeight(key), 0);
    }

    function test_processSplitWith_terminalTreasuryStateSettlesWithoutRevert() public {
        vm.warp(treasury.deadline());
        treasury.sync();

        uint256 amount = 7e18;
        underlyingToken.mint(address(hook), amount);
        uint256 flowBalanceBefore = superToken.balanceOf(address(flow));

        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, amount, "GOAL_TERMINAL_RESIDUAL_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, amount, "GOAL_TERMINAL_RESIDUAL_BURN"
            )
        );
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(superToken.balanceOf(address(flow)), flowBalanceBefore);
        assertEq(underlyingToken.balanceOf(address(hook)), 0);
        assertEq(treasury.totalRaised(), 0);
    }

    function test_successSettlement_afterResolveSuccess_isPermissionlessAndUsesBurnPath() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);
        treasury.sync();

        _resolveGoalSuccessViaAssertion();

        uint256 amount = 7e18;
        underlyingToken.mint(address(hook), amount);

        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, amount, "GOAL_SUCCESS_SETTLEMENT_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, amount, "GOAL_SUCCESS_SETTLEMENT_BURN"
            )
        );

        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(treasury.totalRaised(), minRaiseAmount);
    }
}

contract GoalRevnetIntegrationDeferredSuccessSettlementTest is GoalRevnetFixtureBase {
    uint32 internal constant SCALE_1E6 = 1_000_000;

    event HookDeferredFundingSettled(
        IGoalTreasury.GoalState indexed finalState,
        uint256 superTokenAmount,
        uint256 rewardEscrowAmount,
        uint256 controllerBurnAmount
    );

    function setUp() public override {
        super.setUp();
        GoalIntegrationConfig memory config = _goalConfigPresetWithEscrow();
        config.successSettlementRewardEscrowPpm = 400_000;
        _setUpGoalIntegration(config);
    }

    function test_deferredHookFunding_settlesOnSuccessfulTerminalSync_withTreasuryEscrowSplit() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);
        treasury.sync();

        _registerGoalSuccessAssertion();

        vm.warp(treasury.deadline());

        uint256 amount = 9e18;
        uint256 treasurySettlementScaled = treasury.successSettlementRewardEscrowPpm();
        uint256 expectedReward = (amount * treasurySettlementScaled) / SCALE_1E6;
        uint256 expectedBurn = amount - expectedReward;

        underlyingToken.mint(address(hook), amount);
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(treasury.deferredHookSuperTokenAmount(), amount);
        assertEq(underlyingToken.balanceOf(address(hook)), 0);
        assertEq(treasury.totalRaised(), minRaiseAmount);

        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_RESIDUAL_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_RESIDUAL_BURN"
            )
        );
        vm.expectEmit(true, false, false, true, address(treasury));
        emit HookDeferredFundingSettled(IGoalTreasury.GoalState.Succeeded, amount, expectedReward, expectedBurn);
        vm.expectCall(
            address(superToken),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), address(rewardEscrow), expectedReward)
        );

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertEq(treasury.deferredHookSuperTokenAmount(), 0);
        assertEq(expectedReward + expectedBurn, amount);
        assertEq(treasury.totalRaised(), minRaiseAmount);
    }
}

contract GoalRevnetIntegrationWithEscrowTest is GoalRevnetFixtureBase {
    uint32 internal constant SCALE_1E6 = 1_000_000;

    function setUp() public override {
        super.setUp();
        _setUpGoalIntegration(_goalConfigPresetWithEscrow());
    }

    function test_successSettlement_withEscrow_sendsRewardShareAndBurnsComplement() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);
        treasury.sync();

        _resolveGoalSuccessViaAssertion();

        uint256 amount = 8e18;
        uint256 rewardScaled = treasury.successSettlementRewardEscrowPpm();
        uint256 expectedReward = (amount * rewardScaled) / SCALE_1E6;
        uint256 expectedBurn = amount - expectedReward;
        uint256 escrowBefore = underlyingToken.balanceOf(address(rewardEscrow));

        underlyingToken.mint(address(hook), amount);

        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_SETTLEMENT_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_SETTLEMENT_BURN"
            )
        );

        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(underlyingToken.balanceOf(address(rewardEscrow)) - escrowBefore, expectedReward);
        assertEq(expectedReward + expectedBurn, amount);
        assertEq(treasury.totalRaised(), minRaiseAmount);
    }

    function test_successSettlement_windowBoundary_fromRealRulesets() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);
        treasury.sync();

        _resolveGoalSuccessViaAssertion();

        uint256 amount = 9e18;
        uint256 expectedReward = (amount * treasury.successSettlementRewardEscrowPpm()) / SCALE_1E6;
        uint256 expectedBurn = amount - expectedReward;
        uint256 underlyingEscrowBefore = underlyingToken.balanceOf(address(rewardEscrow));
        uint256 superEscrowBefore = superToken.balanceOf(address(rewardEscrow));

        underlyingToken.mint(address(hook), amount);
        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_SETTLEMENT_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_SETTLEMENT_BURN"
            )
        );
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)) - underlyingEscrowBefore, expectedReward);
        assertEq(superToken.balanceOf(address(rewardEscrow)) - superEscrowBefore, 0);

        vm.warp(uint256(goalMintCloseTimestamp) + 1);
        assertFalse(treasury.isMintingOpen());

        underlyingToken.mint(address(hook), amount);
        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector,
                address(treasury),
                goalRevnetId,
                expectedBurn,
                "GOAL_SUCCESS_RESIDUAL_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector,
                address(treasury),
                goalRevnetId,
                expectedBurn,
                "GOAL_SUCCESS_RESIDUAL_BURN"
            )
        );
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)) - underlyingEscrowBefore, expectedReward);
        assertEq(superToken.balanceOf(address(rewardEscrow)) - superEscrowBefore, expectedReward);
    }

    function test_successSettlement_doesNotAffectFlowBalanceOrRate() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);
        treasury.sync();

        _resolveGoalSuccessViaAssertion();

        uint256 flowBalanceBefore = superToken.balanceOf(address(flow));
        int96 flowRateBefore = flow.targetOutflowRate();
        uint256 treasuryRaisedBefore = treasury.totalRaised();

        uint256 amount = 12e18;
        uint256 expectedReward = (amount * treasury.successSettlementRewardEscrowPpm()) / SCALE_1E6;
        uint256 expectedBurn = amount - expectedReward;

        underlyingToken.mint(address(hook), amount);
        vm.mockCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_SETTLEMENT_BURN"
            ),
            bytes("")
        );
        vm.expectCall(
            address(revnets),
            abi.encodeWithSelector(
                IJBController.burnTokensOf.selector, address(treasury), goalRevnetId, expectedBurn, "GOAL_SUCCESS_SETTLEMENT_BURN"
            )
        );

        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

        assertEq(superToken.balanceOf(address(flow)), flowBalanceBefore);
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(treasury.totalRaised(), treasuryRaisedBefore);
    }

    function test_successSettlement_multipleCalls_conserveValueAndKeepRaisedUnchanged() public {
        uint256 minRaiseAmount = treasury.minRaise();
        _fundViaHookUnderlying(minRaiseAmount);
        treasury.sync();

        _resolveGoalSuccessViaAssertion();

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 3e18;
        amounts[1] = 5e18;
        amounts[2] = 11e18;

        uint256 rewardScaled = treasury.successSettlementRewardEscrowPpm();
        uint256 escrowBefore = underlyingToken.balanceOf(address(rewardEscrow));
        uint256 totalAmount;
        uint256 totalExpectedReward;
        uint256 totalExpectedBurn;

        for (uint256 i; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            uint256 expectedReward = (amount * rewardScaled) / SCALE_1E6;
            uint256 expectedBurn = amount - expectedReward;

            underlyingToken.mint(address(hook), amount);
            vm.mockCall(
                address(revnets),
                abi.encodeWithSelector(
                    IJBController.burnTokensOf.selector,
                    address(treasury),
                    goalRevnetId,
                    expectedBurn,
                    "GOAL_SUCCESS_SETTLEMENT_BURN"
                ),
                bytes("")
            );
            vm.expectCall(
                address(revnets),
                abi.encodeWithSelector(
                    IJBController.burnTokensOf.selector,
                    address(treasury),
                    goalRevnetId,
                    expectedBurn,
                    "GOAL_SUCCESS_SETTLEMENT_BURN"
                )
            );

            _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));

            totalAmount += amount;
            totalExpectedReward += expectedReward;
            totalExpectedBurn += expectedBurn;
        }

        assertEq(underlyingToken.balanceOf(address(rewardEscrow)) - escrowBefore, totalExpectedReward);
        assertEq(totalExpectedReward + totalExpectedBurn, totalAmount);
        assertEq(treasury.totalRaised(), minRaiseAmount);
    }
}

contract GoalRevnetHarnessSmokeTest is Test {
    function _newRulesetsForProject(uint256 projectId) internal returns (RevnetTestRulesets rulesets) {
        RevnetTestDirectory directory = new RevnetTestDirectory(address(this));
        rulesets = new RevnetTestRulesets(IJBDirectory(address(directory)));
        directory.setControllerOf(projectId, IERC165(address(this)));
    }

    function test_createRevnet_setsControllerAndRulesetWeight() public {
        IRevnetHarness harness = RevnetHarnessDeployer.deploy(vm);
        uint256 revnetId = harness.createRevnet(3e18);

        assertEq(address(harness.directory().controllerOf(revnetId)), address(harness));
        assertEq(IJBRulesets(address(harness.rulesets())).currentOf(revnetId).weight, 3e18);
    }

    function test_createRevnetWithMintClose_transitionsAtBoundary_andRetainsBaseLink() public {
        IRevnetHarness harness = RevnetHarnessDeployer.deploy(vm);

        uint40 mintClose = uint40(block.timestamp + 10 days);
        uint256 revnetId = harness.createRevnetWithMintClose(3e18, mintClose);

        JBRuleset memory currentBefore = IJBRulesets(address(harness.rulesets())).currentOf(revnetId);
        assertEq(currentBefore.weight, 3e18);

        (JBRuleset memory terminal, JBApprovalStatus status) =
            IJBRulesets(address(harness.rulesets())).latestQueuedOf(revnetId);
        assertEq(uint256(status), uint256(JBApprovalStatus.Empty));
        assertEq(terminal.weight, 0);
        assertEq(terminal.start, mintClose);
        assertEq(terminal.basedOnId, currentBefore.id);

        JBRuleset memory base = IJBRulesets(address(harness.rulesets())).getRulesetOf(revnetId, terminal.basedOnId);
        assertEq(base.id, currentBefore.id);
        assertEq(base.basedOnId, 0);
        assertEq(base.weight, 3e18);
        assertLt(base.start, terminal.start);

        vm.warp(mintClose);
        JBRuleset memory currentAtBoundary = IJBRulesets(address(harness.rulesets())).currentOf(revnetId);
        assertEq(currentAtBoundary.id, terminal.id);
        assertEq(currentAtBoundary.weight, 0);
    }

    function test_rulesets_latestQueuedOf_unconfiguredProject_returnsEmpty() public {
        IRevnetHarness harness = RevnetHarnessDeployer.deploy(vm);

        (JBRuleset memory latest, JBApprovalStatus status) = IJBRulesets(address(harness.rulesets())).latestQueuedOf(999_999);
        assertEq(latest.id, 0);
        assertEq(uint256(status), uint256(JBApprovalStatus.Empty));
    }

    function test_rulesets_queueFor_revertsWhenCalledExternally() public {
        IRevnetHarness harness = RevnetHarnessDeployer.deploy(vm);
        uint256 revnetId = harness.createRevnet(1e18);
        IJBRulesets rulesets = IJBRulesets(address(harness.rulesets()));

        vm.expectRevert(abi.encodeWithSelector(RevnetTestRulesets.UNAUTHORIZED.selector, address(this)));
        rulesets.queueFor(
            revnetId,
            0,
            1,
            0,
            IJBRulesetApprovalHook(address(0)),
            0,
            block.timestamp
        );
    }

    function test_rulesets_currentOf_returnsEmptyIfNoRulesetHasStarted() public {
        uint256 projectId = 1234;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);
        uint256 futureStart = block.timestamp + 1 days;

        rulesets.queueFor(projectId, 0, 2e18, 0, IJBRulesetApprovalHook(address(0)), 0, futureStart);

        JBRuleset memory current = rulesets.currentOf(projectId);
        assertEq(current.id, 0);
        assertEq(current.weight, 0);
    }

    function test_rulesets_currentOf_prefersLatestStartedRuleset() public {
        uint256 projectId = 7;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);

        rulesets.queueFor(projectId, 0, 1e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);
        vm.warp(block.timestamp + 1 days);
        rulesets.queueFor(projectId, 0, 2e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);

        JBRuleset memory current = rulesets.currentOf(projectId);
        assertEq(current.weight, 2e18);
    }

    function test_rulesets_currentOf_tieBreaksByHigherIdWhenStartMatches() public {
        uint256 projectId = 8;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);
        uint256 start = block.timestamp + 1 days;

        JBRuleset memory first = rulesets.queueFor(projectId, 0, 1e18, 0, IJBRulesetApprovalHook(address(0)), 0, start);
        JBRuleset memory second = rulesets.queueFor(projectId, 0, 3e18, 0, IJBRulesetApprovalHook(address(0)), 0, start);

        vm.warp(start);
        JBRuleset memory current = rulesets.currentOf(projectId);
        assertEq(current.id, second.id);
        assertEq(current.start, first.start);
        assertEq(current.weight, 3e18);
    }

    function test_rulesets_latestQueuedOf_returnsMostRecentRuleset_withEmptyStatusWithoutApprovalHook() public {
        uint256 projectId = 9;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);

        JBRuleset memory first = rulesets.queueFor(projectId, 0, 1e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);
        JBRuleset memory second =
            rulesets.queueFor(projectId, 0, 2e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);

        (JBRuleset memory latest, JBApprovalStatus status) = rulesets.latestQueuedOf(projectId);
        assertEq(uint256(status), uint256(JBApprovalStatus.Empty));
        assertEq(latest.id, second.id);
        assertEq(latest.basedOnId, first.id);
        assertEq(latest.weight, 2e18);
    }

    function test_rulesets_currentApprovalStatusForLatestRuleset_matchesLatestQueuedStatus() public {
        uint256 projectId = 10;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);

        rulesets.queueFor(projectId, 0, 1e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);
        assertEq(uint256(rulesets.currentApprovalStatusForLatestRulesetOf(projectId)), uint256(JBApprovalStatus.Empty));
    }

    function test_rulesets_queueFor_assignsBasedOnIdChain() public {
        uint256 projectId = 11;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);

        JBRuleset memory first = rulesets.queueFor(projectId, 0, 1e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);
        JBRuleset memory second =
            rulesets.queueFor(projectId, 0, 2e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);
        JBRuleset memory third =
            rulesets.queueFor(projectId, 0, 3e18, 0, IJBRulesetApprovalHook(address(0)), 0, block.timestamp);

        assertEq(first.basedOnId, 0);
        assertEq(second.basedOnId, first.id);
        assertEq(third.basedOnId, second.id);
    }

    function test_rulesets_queueFor_revertsOnOutOfRangeValues() public {
        uint256 projectId = 1;
        RevnetTestRulesets rulesets = _newRulesetsForProject(projectId);

        vm.expectRevert(
            abi.encodeWithSelector(RevnetTestRulesets.INVALID_DURATION.selector, uint256(type(uint32).max) + 1)
        );
        rulesets.queueFor(
            projectId,
            uint256(type(uint32).max) + 1,
            1,
            0,
            IJBRulesetApprovalHook(address(0)),
            0,
            block.timestamp
        );

        vm.expectRevert(abi.encodeWithSelector(RevnetTestRulesets.INVALID_WEIGHT.selector, uint256(type(uint112).max) + 1));
        rulesets.queueFor(
            projectId,
            0,
            uint256(type(uint112).max) + 1,
            0,
            IJBRulesetApprovalHook(address(0)),
            0,
            block.timestamp
        );

        vm.expectRevert(
            abi.encodeWithSelector(RevnetTestRulesets.INVALID_WEIGHT_CUT_PERCENT.selector, uint256(type(uint32).max) + 1)
        );
        rulesets.queueFor(
            projectId,
            0,
            1,
            uint256(type(uint32).max) + 1,
            IJBRulesetApprovalHook(address(0)),
            0,
            block.timestamp
        );

        vm.expectRevert(
            abi.encodeWithSelector(RevnetTestRulesets.INVALID_START.selector, uint256(type(uint48).max) + 1)
        );
        rulesets.queueFor(
            projectId, 0, 1, 0, IJBRulesetApprovalHook(address(0)), 0, uint256(type(uint48).max) + 1
        );
    }
}
