// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { GoalStakeVault } from "src/goals/GoalStakeVault.sol";
import { IGoalStakeVault } from "src/interfaces/IGoalStakeVault.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { ICustomFlow } from "src/interfaces/IFlow.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { MockFeeOnTransferVotesToken } from "test/mocks/MockFeeOnTransferVotesToken.sol";
import { MockSelectiveFeeVotesToken } from "test/mocks/MockSelectiveFeeVotesToken.sol";

contract GoalStakeVaultTest is Test {
    uint256 internal constant GOAL_PROJECT_ID = 111;
    uint256 internal constant RENT_RATE_WAD_PER_SECOND = 1e10;
    bytes4 internal constant FLOW_LOOKUP_SELECTOR = IGoalTreasury.flow.selector;
    bytes4 internal constant SYNC_ALLOCATION_SELECTOR = ICustomFlow.syncAllocationForAccount.selector;
    bytes32 internal constant JUROR_OPTED_IN_EVENT_TOPIC =
        keccak256("JurorOptedIn(address,uint256,uint256,uint256,address)");
    bytes32 internal constant JUROR_DELEGATE_SET_EVENT_TOPIC = keccak256("JurorDelegateSet(address,address)");
    event AllocationSyncFailed(address indexed account, address indexed target, bytes4 indexed selector, bytes reason);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal rentCollector = address(0xBEEF);

    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    VaultMockRulesets internal goalRulesets;
    VaultMockDirectory internal directory;
    VaultMockTokens internal controllerTokens;
    VaultMockController internal controller;
    GoalStakeVault internal vault;

    function setUp() public {
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        goalRulesets = new VaultMockRulesets();
        directory = new VaultMockDirectory();
        controllerTokens = new VaultMockTokens();
        controller = new VaultMockController(controllerTokens);

        goalRulesets.setWeight(GOAL_PROJECT_ID, 2e18);
        goalRulesets.setDirectory(IJBDirectory(address(directory)));
        directory.setController(GOAL_PROJECT_ID, address(controller));
        controllerTokens.setDefaultProjectId(GOAL_PROJECT_ID);
        controllerTokens.setProjectIdOf(address(goalToken), GOAL_PROJECT_ID);

        vault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        goalToken.mint(alice, 1_000e18);
        cobuildToken.mint(alice, 1_000e18);

        vm.prank(alice);
        goalToken.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(vault), type(uint256).max);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IGoalStakeVault.ADDRESS_ZERO.selector);
        new GoalStakeVault(
            address(0),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnZeroGoalToken() public {
        vm.expectRevert(IGoalStakeVault.ADDRESS_ZERO.selector);
        new GoalStakeVault(
            address(this),
            IERC20(address(0)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnZeroCobuildToken() public {
        vm.expectRevert(IGoalStakeVault.ADDRESS_ZERO.selector);
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(0)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnZeroRulesets() public {
        vm.expectRevert(IGoalStakeVault.ADDRESS_ZERO.selector);
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnDecimalsMismatch() public {
        VaultMockDecimalsToken token6 = new VaultMockDecimalsToken("USDC", "USDC", 6);
        VaultMockDecimalsToken token18 = new VaultMockDecimalsToken("Token", "TKN", 18);

        vm.expectRevert(abi.encodeWithSelector(IGoalStakeVault.DECIMALS_MISMATCH.selector, 6, 18));
        new GoalStakeVault(
            address(this),
            IERC20(address(token6)),
            IERC20(address(token18)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnInvalidPaymentTokenDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(IGoalStakeVault.INVALID_PAYMENT_TOKEN_DECIMALS.selector, 78));
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            78,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnPaymentTokenDecimalsMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(IGoalStakeVault.PAYMENT_TOKEN_DECIMALS_MISMATCH.selector, 18, 6));
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            6,
            address(0),
            0
        );
    }

    function test_constructor_revertsOnInvalidRentConfig() public {
        vm.expectRevert(IGoalStakeVault.INVALID_RENT_CONFIG.selector);
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            RENT_RATE_WAD_PER_SECOND
        );

        vm.expectRevert(IGoalStakeVault.INVALID_RENT_CONFIG.selector);
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            0
        );
    }

    function test_constructor_revertsWhenGoalProjectControllerMissing() public {
        directory.setController(GOAL_PROJECT_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(IGoalStakeVault.INVALID_REVNET_CONTROLLER.selector, address(0)));
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsWhenGoalDirectoryNotDerivable() public {
        goalRulesets.setDirectory(IJBDirectory(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(IGoalStakeVault.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE.selector, address(goalToken))
        );
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_constructor_revertsWhenGoalTokenMapsToDifferentRevnetId() public {
        uint256 foreignProjectId = GOAL_PROJECT_ID + 1;
        controllerTokens.setProjectIdOf(address(goalToken), foreignProjectId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalStakeVault.GOAL_TOKEN_REVNET_MISMATCH.selector,
                address(goalToken),
                GOAL_PROJECT_ID,
                foreignProjectId
            )
        );
        new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );
    }

    function test_depositGoal_updatesConvertedWeight() public {
        vm.prank(alice);
        vault.depositGoal(100e18);

        assertEq(vault.stakedGoalOf(alice), 100e18);
        assertEq(vault.weightOf(alice), 50e18);
        assertEq(vault.totalWeight(), 50e18);
    }

    function test_depositGoal_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.INVALID_AMOUNT.selector);
        vault.depositGoal(0);
    }

    function test_depositCobuild_updatesWeightOneToOne() public {
        vm.prank(alice);
        vault.depositCobuild(70e18);

        assertEq(vault.stakedCobuildOf(alice), 70e18);
        assertEq(vault.weightOf(alice), 70e18);
        assertEq(vault.totalWeight(), 70e18);
    }

    function test_depositCobuild_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.INVALID_AMOUNT.selector);
        vault.depositCobuild(0);
    }

    function test_depositGoal_revertsWhenResolved() public {
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_ALREADY_RESOLVED.selector);
        vault.depositGoal(1e18);
    }

    function test_depositCobuild_revertsWhenResolved() public {
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_ALREADY_RESOLVED.selector);
        vault.depositCobuild(1e18);
    }

    function test_depositGoal_revertsWhenGoalWeightZero() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 0);
        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositGoal(1e18);
    }

    function test_depositGoal_revertsWhenRulesetReadReverts() public {
        goalRulesets.setShouldRevertCurrent(true);
        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositGoal(1e18);
    }

    function test_depositGoal_revertsWhenWeightDeltaRoundsToZero() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 2e18);
        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.ZERO_WEIGHT_DELTA.selector);
        vault.depositGoal(1);
    }

    function test_depositCobuild_revertsWhenGoalWeightZero() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 0);
        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositCobuild(1e18);
    }

    function test_depositGoal_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferVotesToken feeGoal = new MockFeeOnTransferVotesToken("FeeGoal", "fGOAL", 100, address(0xFEE));

        GoalStakeVault feeVault = new GoalStakeVault(
            address(this),
            IERC20(address(feeGoal)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        feeGoal.mint(alice, 100e18);
        vm.prank(alice);
        feeGoal.approve(address(feeVault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        feeVault.depositGoal(100e18);
    }

    function test_depositCobuild_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferVotesToken feeCobuild =
            new MockFeeOnTransferVotesToken("FeeCobuild", "fCOBUILD", 100, address(0xFEE));

        GoalStakeVault feeVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(feeCobuild)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        feeCobuild.mint(alice, 100e18);
        vm.prank(alice);
        feeCobuild.approve(address(feeVault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        feeVault.depositCobuild(100e18);
    }

    function test_quoteGoalToCobuildWeight_returnsExpected() public view {
        (uint256 out, uint112 goalWeight, uint256 weightRatio) = vault.quoteGoalToCobuildWeightRatio(10e18);
        assertEq(goalWeight, 2e18);
        assertEq(weightRatio, 1e18);
        assertEq(out, 5e18);
    }

    function test_quoteGoalToCobuildWeight_returnsZeroForZeroAmount() public view {
        (uint256 out, uint112 goalWeight, uint256 weightRatio) = vault.quoteGoalToCobuildWeightRatio(0);
        assertEq(out, 0);
        assertEq(goalWeight, 0);
        assertEq(weightRatio, 0);
    }

    function test_quoteGoalToCobuildWeight_usesConfiguredPaymentTokenDecimals() public {
        VaultMockDecimalsToken goalToken6 = new VaultMockDecimalsToken("Goal 6", "GOAL6", 6);
        VaultMockDecimalsToken cobuildToken6 = new VaultMockDecimalsToken("Cobuild 6", "COB6", 6);
        goalRulesets.setWeight(GOAL_PROJECT_ID, 2e6);

        GoalStakeVault sixDecimalVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken6)),
            IERC20(address(cobuildToken6)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            6,
            address(0),
            0
        );

        (uint256 out, uint112 goalWeight, uint256 weightRatio) = sixDecimalVault.quoteGoalToCobuildWeightRatio(10e6);
        assertEq(goalWeight, 2e6);
        assertEq(weightRatio, 1e6);
        assertEq(out, 5e6);
    }

    function test_quoteGoalToCobuildWeight_revertsWhenStakingClosed() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 0);
        vm.expectRevert(IGoalStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.quoteGoalToCobuildWeightRatio(1e18);
    }

    function test_quoteGoalToCobuildWeight_revertsWhenRulesetReadReverts() public {
        goalRulesets.setShouldRevertCurrent(true);
        vm.expectRevert(IGoalStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.quoteGoalToCobuildWeightRatio(1e18);
    }

    function test_markGoalResolved_revertsForUnauthorizedWhenTreasuryNotResolved() public {
        VaultResolvedSignal signal = new VaultResolvedSignal();

        GoalStakeVault signalVault = new GoalStakeVault(
            address(signal),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(bob);
        vm.expectRevert(IGoalStakeVault.GOAL_NOT_RESOLVED.selector);
        signalVault.markGoalResolved();
    }

    function test_markGoalResolved_permissionlessWhenTreasuryReportsResolved() public {
        VaultResolvedSignal signal = new VaultResolvedSignal();

        GoalStakeVault signalVault = new GoalStakeVault(
            address(signal),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        signal.setResolved(true);
        vm.prank(bob);
        signalVault.markGoalResolved();
        assertTrue(signalVault.goalResolved());
    }

    function test_markGoalResolved_doesNotForwardLegacyBudgetTreasuryLookup() public {
        VaultResolvedSignal downstreamTreasury = new VaultResolvedSignal();
        downstreamTreasury.setResolved(true);
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));

        GoalStakeVault signalVault = new GoalStakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(bob);
        vm.expectRevert(IGoalStakeVault.GOAL_NOT_RESOLVED.selector);
        signalVault.markGoalResolved();
    }

    function test_markGoalResolved_revertsWhenTreasuryHasNoResolvedSurface() public {
        VaultNoAuthorityTreasury noResolvedTreasury = new VaultNoAuthorityTreasury();

        GoalStakeVault signalVault = new GoalStakeVault(
            address(noResolvedTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(bob);
        vm.expectRevert(IGoalStakeVault.GOAL_NOT_RESOLVED.selector);
        signalVault.markGoalResolved();
    }

    function test_markGoalResolved_revertsWhenTreasuryHasNoCode() public {
        GoalStakeVault eoaTreasuryVault = new GoalStakeVault(
            address(0x1234),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(bob);
        vm.expectRevert(IGoalStakeVault.GOAL_NOT_RESOLVED.selector);
        eoaTreasuryVault.markGoalResolved();
    }

    function test_markGoalResolved_revertsWhenAlreadyResolved() public {
        vault.markGoalResolved();

        vm.expectRevert(IGoalStakeVault.GOAL_ALREADY_RESOLVED.selector);
        vault.markGoalResolved();
    }

    function test_withdrawGoal_revertsBeforeResolved() public {
        vm.prank(alice);
        vault.depositGoal(10e18);

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_NOT_RESOLVED.selector);
        vault.withdrawGoal(1e18, alice);
    }

    function test_withdrawGoal_revertsOnZeroAmount() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.INVALID_AMOUNT.selector);
        vault.withdrawGoal(0, alice);
    }

    function test_withdrawGoal_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.ADDRESS_ZERO.selector);
        vault.withdrawGoal(1e18, address(0));
    }

    function test_withdrawGoal_revertsOnInsufficientStakedBalance() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.INSUFFICIENT_STAKED_BALANCE.selector);
        vault.withdrawGoal(11e18, alice);
    }

    function test_withdrawGoal_partial_updatesWeightProportionally() public {
        vm.prank(alice);
        vault.depositGoal(100e18); // 50e18 weight
        vm.prank(alice);
        vault.depositCobuild(20e18); // +20e18 weight
        assertEq(vault.weightOf(alice), 70e18);

        vault.markGoalResolved();
        vm.prank(alice);
        vault.withdrawGoal(40e18, alice); // remove 40% of goal stake => remove 20e18 goal weight

        assertEq(vault.stakedGoalOf(alice), 60e18);
        assertEq(vault.weightOf(alice), 50e18); // 30e18 goal-weight + 20e18 cobuild-weight
        assertEq(vault.totalWeight(), 50e18);
    }

    function test_withdrawGoal_fullWithdrawal_removesAllGoalWeight() public {
        vm.prank(alice);
        vault.depositGoal(100e18); // 50e18 goal-weight.
        vm.prank(alice);
        vault.depositCobuild(20e18); // +20e18 cobuild-weight.
        vault.markGoalResolved();

        vm.prank(alice);
        vault.withdrawGoal(100e18, alice);

        assertEq(vault.stakedGoalOf(alice), 0);
        assertEq(vault.stakedCobuildOf(alice), 20e18);
        assertEq(vault.weightOf(alice), 20e18);
        assertEq(vault.totalStakedGoal(), 0);
        assertEq(vault.totalWeight(), 20e18);
    }

    function test_withdrawCobuild_revertsBeforeResolved() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.GOAL_NOT_RESOLVED.selector);
        vault.withdrawCobuild(1e18, alice);
    }

    function test_withdrawCobuild_revertsOnZeroAmount() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.INVALID_AMOUNT.selector);
        vault.withdrawCobuild(0, alice);
    }

    function test_withdrawCobuild_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.ADDRESS_ZERO.selector);
        vault.withdrawCobuild(1e18, address(0));
    }

    function test_withdrawCobuild_revertsOnInsufficientStakedBalance() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.INSUFFICIENT_STAKED_BALANCE.selector);
        vault.withdrawCobuild(11e18, alice);
    }

    function test_withdrawCobuild_updatesWeight() public {
        vm.prank(alice);
        vault.depositCobuild(30e18);
        vault.markGoalResolved();

        vm.prank(alice);
        vault.withdrawCobuild(10e18, alice);

        assertEq(vault.stakedCobuildOf(alice), 20e18);
        assertEq(vault.weightOf(alice), 20e18);
        assertEq(vault.totalWeight(), 20e18);
    }

    function test_withdrawGoal_withholdsRent_andCapsAtGoalResolvedAt() public {
        GoalStakeVault rentVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            RENT_RATE_WAD_PER_SECOND
        );

        vm.prank(alice);
        goalToken.approve(address(rentVault), type(uint256).max);

        vm.prank(alice);
        rentVault.depositGoal(100e18);

        vm.warp(block.timestamp + 2 days);
        rentVault.markGoalResolved();
        vm.warp(block.timestamp + 3 days);

        uint256 expectedRent = Math.mulDiv(100e18, Math.mulDiv(RENT_RATE_WAD_PER_SECOND, 2 days, 1), 1e18);
        uint256 expectedNet = 10e18 - expectedRent;

        uint256 collectorBefore = goalToken.balanceOf(rentCollector);
        uint256 aliceBefore = goalToken.balanceOf(alice);

        vm.prank(alice);
        rentVault.withdrawGoal(10e18, alice);

        assertEq(goalToken.balanceOf(rentCollector) - collectorBefore, expectedRent);
        assertEq(goalToken.balanceOf(alice) - aliceBefore, expectedNet);
        assertEq(rentVault.pendingGoalRentOf(alice), 0);
    }

    function test_withdrawCobuild_whenRentExceedsWithdrawal_withholdsFullAmount() public {
        uint256 aggressiveRate = 1e14;
        GoalStakeVault rentVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            aggressiveRate
        );

        vm.prank(alice);
        cobuildToken.approve(address(rentVault), type(uint256).max);

        vm.prank(alice);
        rentVault.depositCobuild(5e18);

        vm.warp(block.timestamp + 1 days);
        rentVault.markGoalResolved();

        uint256 collectorBefore = cobuildToken.balanceOf(rentCollector);
        uint256 aliceBefore = cobuildToken.balanceOf(alice);

        vm.prank(alice);
        rentVault.withdrawCobuild(1e18, alice);

        assertEq(cobuildToken.balanceOf(rentCollector) - collectorBefore, 1e18);
        assertEq(cobuildToken.balanceOf(alice) - aliceBefore, 0);
        assertGt(rentVault.pendingCobuildRentOf(alice), 0);
        assertEq(rentVault.stakedCobuildOf(alice), 4e18);
    }

    function test_withdrawCobuild_partialWithdrawals_carryAndSettleRentDebt() public {
        uint256 moderateRate = 4e12;
        GoalStakeVault rentVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            moderateRate
        );

        vm.prank(alice);
        cobuildToken.approve(address(rentVault), type(uint256).max);

        vm.prank(alice);
        rentVault.depositCobuild(5e18);

        skip(1 days);
        rentVault.markGoalResolved();

        uint256 expectedRent = Math.mulDiv(5e18, Math.mulDiv(moderateRate, 1 days, 1), 1e18);

        uint256 collectorBefore = cobuildToken.balanceOf(rentCollector);
        uint256 aliceBefore = cobuildToken.balanceOf(alice);

        vm.prank(alice);
        rentVault.withdrawCobuild(1e18, alice);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorBefore, 1e18);
        assertEq(cobuildToken.balanceOf(alice) - aliceBefore, 0);
        assertEq(rentVault.stakedCobuildOf(alice), 4e18);

        vm.prank(alice);
        rentVault.withdrawCobuild(4e18, alice);

        assertEq(cobuildToken.balanceOf(rentCollector) - collectorBefore, expectedRent);
        assertEq(cobuildToken.balanceOf(alice) - aliceBefore, 5e18 - expectedRent);
        assertEq(rentVault.pendingCobuildRentOf(alice), 0);
        assertEq(rentVault.stakedCobuildOf(alice), 0);
    }

    function test_withdrawCobuild_fullExit_clearsUncollectableRentDebt() public {
        uint256 aggressiveRate = 2e14;
        GoalStakeVault rentVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            aggressiveRate
        );

        vm.prank(alice);
        cobuildToken.approve(address(rentVault), type(uint256).max);

        vm.prank(alice);
        rentVault.depositCobuild(5e18);

        skip(7 days);
        rentVault.markGoalResolved();

        vm.prank(alice);
        rentVault.withdrawCobuild(5e18, alice);

        assertEq(rentVault.stakedCobuildOf(alice), 0);
        assertEq(rentVault.pendingCobuildRentOf(alice), 0);
    }

    function test_pendingRentViews_includeLiveAccrual_andFreezeAfterResolution() public {
        GoalStakeVault rentVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            RENT_RATE_WAD_PER_SECOND
        );

        vm.prank(alice);
        cobuildToken.approve(address(rentVault), type(uint256).max);

        vm.prank(alice);
        rentVault.depositCobuild(50e18);

        vm.warp(block.timestamp + 2 days);
        uint256 expectedAtDay2 = Math.mulDiv(50e18, Math.mulDiv(RENT_RATE_WAD_PER_SECOND, 2 days, 1), 1e18);
        assertEq(rentVault.pendingCobuildRentOf(alice), expectedAtDay2);

        rentVault.markGoalResolved();
        uint256 pendingAtResolve = rentVault.pendingCobuildRentOf(alice);

        vm.warp(block.timestamp + 3 days);
        assertEq(rentVault.pendingCobuildRentOf(alice), pendingAtResolve);
    }

    function test_secondDeposit_accruesPriorStakeRentBeforeIncreasingPrincipal() public {
        GoalStakeVault rentVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            rentCollector,
            RENT_RATE_WAD_PER_SECOND
        );

        vm.prank(alice);
        goalToken.approve(address(rentVault), type(uint256).max);

        vm.prank(alice);
        rentVault.depositGoal(100e18);

        skip(1 days);
        vm.prank(alice);
        rentVault.depositGoal(100e18);

        skip(1 days);
        rentVault.markGoalResolved();

        uint256 expectedRentFirstInterval = Math.mulDiv(100e18, Math.mulDiv(RENT_RATE_WAD_PER_SECOND, 1 days, 1), 1e18);
        uint256 expectedRentSecondInterval = Math.mulDiv(200e18, Math.mulDiv(RENT_RATE_WAD_PER_SECOND, 1 days, 1), 1e18);
        uint256 expectedRent = expectedRentFirstInterval + expectedRentSecondInterval;

        uint256 collectorBefore = goalToken.balanceOf(rentCollector);
        uint256 aliceBefore = goalToken.balanceOf(alice);

        vm.prank(alice);
        rentVault.withdrawGoal(200e18, alice);

        assertEq(goalToken.balanceOf(rentCollector) - collectorBefore, expectedRent);
        assertEq(goalToken.balanceOf(alice) - aliceBefore, 200e18 - expectedRent);
        assertEq(rentVault.pendingGoalRentOf(alice), 0);
    }

    function test_withdrawGoal_revertsOnFeeDuringVaultTransfer() public {
        MockSelectiveFeeVotesToken selective = new MockSelectiveFeeVotesToken("Goal", "GOAL", 100, address(0xFEE));

        GoalStakeVault selectiveVault = new GoalStakeVault(
            address(this),
            IERC20(address(selective)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        selective.mint(alice, 100e18);
        vm.prank(alice);
        selective.approve(address(selectiveVault), type(uint256).max);
        vm.prank(alice);
        selectiveVault.depositGoal(100e18);

        selectiveVault.markGoalResolved();
        selective.setFeeFrom(address(selectiveVault));

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        selectiveVault.withdrawGoal(10e18, alice);
    }

    function test_withdrawCobuild_revertsOnFeeDuringVaultTransfer() public {
        MockSelectiveFeeVotesToken selective = new MockSelectiveFeeVotesToken("Cobuild", "COBUILD", 100, address(0xFEE));

        GoalStakeVault selectiveVault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(selective)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        selective.mint(alice, 100e18);
        vm.prank(alice);
        selective.approve(address(selectiveVault), type(uint256).max);
        vm.prank(alice);
        selectiveVault.depositCobuild(100e18);

        selectiveVault.markGoalResolved();
        selective.setFeeFrom(address(selectiveVault));

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        selectiveVault.withdrawCobuild(10e18, alice);
    }

    function test_optInJuror_updatesBalancesDelegateAndSnapshots() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(50e18);
        vault.optInAsJuror(40e18, 20e18, bob);
        vm.stopPrank();

        assertEq(vault.jurorLockedGoalOf(alice), 40e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 20e18);
        assertEq(vault.jurorWeightOf(alice), 40e18); // 20 goal-weight + 20 cobuild-weight.
        assertEq(vault.totalJurorWeight(), 40e18);
        assertEq(vault.jurorDelegateOf(alice), bob);

        vm.roll(block.number + 1);
        assertEq(vault.getPastJurorWeight(alice, block.number - 1), 40e18);
        assertEq(vault.getPastTotalJurorWeight(block.number - 1), 40e18);
    }

    function test_optInJuror_emitsOnlyJurorOptedIn() public {
        vm.prank(alice);
        vault.depositGoal(100e18);
        vm.prank(alice);
        vault.depositCobuild(50e18);

        vm.recordLogs();
        vm.prank(alice);
        vault.optInAsJuror(40e18, 20e18, bob);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogsByTopic(logs, JUROR_OPTED_IN_EVENT_TOPIC), 1);
        assertEq(_countLogsByTopic(logs, JUROR_DELEGATE_SET_EVENT_TOPIC), 0);
        assertEq(vault.jurorDelegateOf(alice), bob);
    }

    function test_setJurorDelegate_emitsJurorDelegateSetOnce() public {
        vm.recordLogs();
        vm.prank(alice);
        vault.setJurorDelegate(bob);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogsByTopic(logs, JUROR_DELEGATE_SET_EVENT_TOPIC), 1);
        assertEq(vault.jurorDelegateOf(alice), bob);
    }

    function test_requestAndFinalizeJurorExit_unlocksAfterDelay() public {
        vm.startPrank(alice);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(0, 60e18, address(0));
        vault.requestJurorExit(0, 30e18);

        vm.expectRevert(IGoalStakeVault.EXIT_NOT_READY.selector);
        vault.finalizeJurorExit();

        vm.warp(block.timestamp + 7 days);
        vault.finalizeJurorExit();
        vm.stopPrank();

        assertEq(vault.jurorLockedCobuildOf(alice), 30e18);
        assertEq(vault.jurorWeightOf(alice), 30e18);
        assertEq(vault.totalJurorWeight(), 30e18);
    }

    function test_finalizeJurorExit_whenGoalResolvesAfterRequest_enforcesDelayFromGoalResolvedAt() public {
        uint256 requestedAt = block.timestamp;
        vm.startPrank(alice);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(0, 60e18, address(0));
        vault.requestJurorExit(0, 30e18);
        vm.stopPrank();

        uint256 resolvedAt = requestedAt + 7 days + 1;
        vm.warp(resolvedAt);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.EXIT_NOT_READY.selector);
        vault.finalizeJurorExit();

        vm.warp(resolvedAt + 7 days + 1);
        vm.prank(alice);
        vault.finalizeJurorExit();

        assertEq(vault.jurorLockedCobuildOf(alice), 30e18);
        assertEq(vault.jurorWeightOf(alice), 30e18);
    }

    function test_regression_postResolutionJurorLock_canExitAndWithdraw() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(80e18, 80e18, address(0));
        vm.stopPrank();

        vault.markGoalResolved();

        vm.startPrank(alice);
        vm.expectRevert(IGoalStakeVault.JUROR_WITHDRAWAL_LOCKED.selector);
        vault.withdrawGoal(21e18, alice);
        vm.expectRevert(IGoalStakeVault.JUROR_WITHDRAWAL_LOCKED.selector);
        vault.withdrawCobuild(21e18, alice);

        vault.requestJurorExit(80e18, 80e18);
        vm.expectRevert(IGoalStakeVault.EXIT_NOT_READY.selector);
        vault.finalizeJurorExit();

        vm.warp(block.timestamp + 7 days + 1);
        vault.finalizeJurorExit();

        vault.withdrawGoal(vault.stakedGoalOf(alice), alice);
        vault.withdrawCobuild(vault.stakedCobuildOf(alice), alice);
        vm.stopPrank();

        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.totalJurorWeight(), 0);
        assertEq(vault.stakedGoalOf(alice), 0);
        assertEq(vault.stakedCobuildOf(alice), 0);
    }

    function test_slashJurorStake_regression_exitFinalizationCannotZeroSlashableStake() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(80e18, 80e18, address(0));
        vm.stopPrank();

        vault.setJurorSlasher(bob);

        vm.roll(block.number + 1);
        uint256 snapshotWeight = vault.getPastJurorWeight(alice, block.number - 1);

        vm.startPrank(alice);
        vault.requestJurorExit(80e18, 80e18);
        vm.warp(block.timestamp + 7 days);
        vault.finalizeJurorExit();
        vm.stopPrank();

        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.totalJurorWeight(), 0);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);

        vm.prank(bob);
        vault.slashJurorStake(alice, snapshotWeight / 2, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 40e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 40e18);

        assertEq(vault.stakedGoalOf(alice), 60e18);
        assertEq(vault.stakedCobuildOf(alice), 60e18);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.weightOf(alice), 90e18);
    }

    function test_slashJurorStake_afterGoalResolved_withdrawThenSlash_appliesZero() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(80e18, 80e18, address(0));
        vault.requestJurorExit(80e18, 80e18);
        vm.warp(block.timestamp + 7 days);
        vault.finalizeJurorExit();
        vm.stopPrank();

        vault.markGoalResolved();

        vm.startPrank(alice);
        vault.withdrawGoal(vault.stakedGoalOf(alice), alice);
        vault.withdrawCobuild(vault.stakedCobuildOf(alice), alice);
        vm.stopPrank();

        assertEq(vault.weightOf(alice), 0);

        vault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);

        vm.prank(bob);
        vault.slashJurorStake(alice, 60e18, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(rentCollector), collectorCobuildBefore);
    }

    function test_withdrawGoal_revertsWhenTryingToWithdrawLockedJurorStake() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.optInAsJuror(80e18, 0, address(0));
        vm.stopPrank();

        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.JUROR_WITHDRAWAL_LOCKED.selector);
        vault.withdrawGoal(21e18, alice);

        vm.prank(alice);
        vault.withdrawGoal(20e18, alice);

        assertEq(vault.stakedGoalOf(alice), 80e18);
        assertEq(vault.jurorLockedGoalOf(alice), 80e18);
    }

    function test_withdrawCobuild_revertsWhenTryingToWithdrawLockedJurorStake() public {
        vm.startPrank(alice);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(0, 70e18, address(0));
        vm.stopPrank();

        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.JUROR_WITHDRAWAL_LOCKED.selector);
        vault.withdrawCobuild(31e18, alice);

        vm.prank(alice);
        vault.withdrawCobuild(30e18, alice);

        assertEq(vault.stakedCobuildOf(alice), 70e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 70e18);
    }

    function test_setJurorSlasher_and_slashJurorStake_proportionalAcrossAssets() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vault.setJurorSlasher(bob);

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.ONLY_JUROR_SLASHER.selector);
        vault.slashJurorStake(alice, 15e18, rentCollector);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);

        vm.prank(bob);
        vault.slashJurorStake(alice, 15e18, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 10e18);

        assertEq(vault.stakedGoalOf(alice), 90e18);
        assertEq(vault.stakedCobuildOf(alice), 90e18);
        assertEq(vault.jurorLockedGoalOf(alice), 90e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 90e18);
        assertEq(vault.jurorWeightOf(alice), 135e18);
        assertEq(vault.weightOf(alice), 135e18);
        assertEq(vault.totalWeight(), 135e18);
    }

    function test_slashJurorStake_maxRequestedWeight_clampsToDerivedStakeWeight_andKeepsAggregateInSync() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18); // 50e18 goal weight.
        vault.depositCobuild(40e18); // +40e18 cobuild weight.
        vault.optInAsJuror(100e18, 40e18, address(0));
        vm.stopPrank();

        goalToken.mint(bob, 1_000e18);
        cobuildToken.mint(bob, 1_000e18);

        vm.startPrank(bob);
        goalToken.approve(address(vault), type(uint256).max);
        cobuildToken.approve(address(vault), type(uint256).max);
        vault.depositGoal(20e18); // 10e18 goal weight.
        vault.depositCobuild(30e18); // +30e18 cobuild weight.
        vm.stopPrank();

        assertEq(vault.weightOf(alice), 90e18);
        assertEq(vault.weightOf(bob), 40e18);
        assertEq(vault.totalWeight(), 130e18);

        vault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);

        vm.prank(bob);
        vault.slashJurorStake(alice, type(uint256).max, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 100e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 40e18);

        assertEq(vault.stakedGoalOf(alice), 0);
        assertEq(vault.stakedCobuildOf(alice), 0);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.weightOf(alice), 0);

        assertEq(vault.totalWeight(), vault.weightOf(alice) + vault.weightOf(bob));
        assertEq(vault.totalWeight(), 40e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSync_callsSyncForJurorWhenFlowPresent() public {
        VaultRecordingSyncFlow recordingFlow = new VaultRecordingSyncFlow();
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(recordingFlow));
        GoalStakeVault syncingVault = new GoalStakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        goalToken.approve(address(syncingVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(syncingVault), type(uint256).max);

        vm.startPrank(alice);
        syncingVault.depositGoal(100e18);
        syncingVault.depositCobuild(100e18);
        syncingVault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vm.prank(address(treasuryWithFlow));
        syncingVault.setJurorSlasher(bob);

        vm.prank(bob);
        syncingVault.slashJurorStake(alice, 15e18, rentCollector);

        assertEq(recordingFlow.syncCallCount(), 1);
        assertEq(recordingFlow.lastSyncedAccount(), alice);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSync_doesNotRevertWhenFlowUnset() public {
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(0));
        GoalStakeVault syncingVault = new GoalStakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        goalToken.approve(address(syncingVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(syncingVault), type(uint256).max);

        vm.startPrank(alice);
        syncingVault.depositGoal(100e18);
        syncingVault.depositCobuild(100e18);
        syncingVault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vm.prank(address(treasuryWithFlow));
        syncingVault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);

        vm.prank(bob);
        syncingVault.slashJurorStake(alice, 15e18, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 10e18);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSyncDoesNotRevertOnSyncFailure() public {
        VaultRevertingSyncFlow revertingFlow = new VaultRevertingSyncFlow();
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(revertingFlow));
        GoalStakeVault syncingVault = new GoalStakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        goalToken.approve(address(syncingVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(syncingVault), type(uint256).max);

        vm.startPrank(alice);
        syncingVault.depositGoal(100e18);
        syncingVault.depositCobuild(100e18);
        syncingVault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vm.prank(address(treasuryWithFlow));
        syncingVault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "SYNC_FAILURE");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(revertingFlow), SYNC_ALLOCATION_SELECTOR, expectedReason);
        vm.prank(bob);
        syncingVault.slashJurorStake(alice, 15e18, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 10e18);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSyncDoesNotRevertWhenFlowLookupReverts() public {
        VaultGoalTreasuryRevertingFlowLookup treasuryWithRevertingLookup = new VaultGoalTreasuryRevertingFlowLookup();
        GoalStakeVault syncingVault = new GoalStakeVault(
            address(treasuryWithRevertingLookup),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        goalToken.approve(address(syncingVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(syncingVault), type(uint256).max);

        vm.startPrank(alice);
        syncingVault.depositGoal(100e18);
        syncingVault.depositCobuild(100e18);
        syncingVault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vm.prank(address(treasuryWithRevertingLookup));
        syncingVault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "FLOW_LOOKUP_FAILURE");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(treasuryWithRevertingLookup), FLOW_LOOKUP_SELECTOR, expectedReason);
        vm.prank(bob);
        syncingVault.slashJurorStake(alice, 15e18, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 10e18);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSync_doesNotForwardLegacyBudgetTreasuryLookup() public {
        VaultRecordingSyncFlow recordingFlow = new VaultRecordingSyncFlow();
        VaultGoalTreasuryWithFlow downstreamTreasury = new VaultGoalTreasuryWithFlow(address(recordingFlow));
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));
        GoalStakeVault syncingVault = new GoalStakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        goalToken.approve(address(syncingVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(syncingVault), type(uint256).max);

        vm.startPrank(alice);
        syncingVault.depositGoal(100e18);
        syncingVault.depositCobuild(100e18);
        syncingVault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vm.prank(address(legacyForwarder));
        syncingVault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "BUDGET_TREASURY_ONLY");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(legacyForwarder), FLOW_LOOKUP_SELECTOR, expectedReason);
        vm.prank(bob);
        syncingVault.slashJurorStake(alice, 15e18, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 10e18);
        assertEq(recordingFlow.syncCallCount(), 0);
    }

    function test_setJurorSlasher_revertsWhenUnauthorized() public {
        VaultAuthorityTreasury controlledTreasury = new VaultAuthorityTreasury(bob);

        GoalStakeVault controlledVault = new GoalStakeVault(
            address(controlledTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.UNAUTHORIZED.selector);
        controlledVault.setJurorSlasher(bob);
    }

    function test_setJurorSlasher_doesNotForwardLegacyBudgetTreasuryAuthorityLookup() public {
        VaultAuthorityTreasury downstreamTreasury = new VaultAuthorityTreasury(bob);
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));

        GoalStakeVault controlledVault = new GoalStakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalStakeVault.INVALID_TREASURY_AUTHORITY_SURFACE.selector, address(legacyForwarder)
            )
        );
        controlledVault.setJurorSlasher(alice);
    }

    function test_setJurorSlasher_revertsWhenAlreadySet() public {
        vault.setJurorSlasher(bob);

        vm.expectRevert(IGoalStakeVault.JUROR_SLASHER_ALREADY_SET.selector);
        vault.setJurorSlasher(alice);
    }

    function test_setJurorSlasher_allowsTreasuryAuthority() public {
        VaultAuthorityTreasury ownedTreasury = new VaultAuthorityTreasury(bob);

        GoalStakeVault ownedVault = new GoalStakeVault(
            address(ownedTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(bob);
        ownedVault.setJurorSlasher(alice);
        assertEq(ownedVault.jurorSlasher(), alice);
    }

    function test_setJurorSlasher_revertsWhenTreasuryReportsZeroAuthority() public {
        VaultAuthorityTreasury controlledTreasury = new VaultAuthorityTreasury(address(0));

        GoalStakeVault controlledVault = new GoalStakeVault(
            address(controlledTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        vm.expectRevert(IGoalStakeVault.UNAUTHORIZED.selector);
        controlledVault.setJurorSlasher(alice);
    }

    function test_setJurorSlasher_revertsWhenTreasuryHasNoAuthoritySurface() public {
        VaultNoAuthorityTreasury noAuthorityTreasury = new VaultNoAuthorityTreasury();

        GoalStakeVault controlledVault = new GoalStakeVault(
            address(noAuthorityTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalStakeVault.INVALID_TREASURY_AUTHORITY_SURFACE.selector, address(noAuthorityTreasury)
            )
        );
        controlledVault.setJurorSlasher(alice);
    }

    function test_slashJurorStake_doesNotOverslashGoalWeightFromRounding() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 1);

        vm.startPrank(alice);
        vault.depositGoal(1);
        vault.depositCobuild(1e18);
        vault.optInAsJuror(1, 1e18, address(0));
        vm.stopPrank();

        vault.setJurorSlasher(bob);

        uint256 collectorGoalBefore = goalToken.balanceOf(rentCollector);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(rentCollector);

        vm.prank(bob);
        vault.slashJurorStake(alice, 1e15, rentCollector);

        assertEq(goalToken.balanceOf(rentCollector) - collectorGoalBefore, 0);
        assertEq(cobuildToken.balanceOf(rentCollector) - collectorCobuildBefore, 1e15);

        assertEq(vault.stakedGoalOf(alice), 1);
        assertEq(vault.jurorLockedGoalOf(alice), 1);
        assertEq(vault.stakedCobuildOf(alice), 1e18 - 1e15);
        assertEq(vault.jurorLockedCobuildOf(alice), 1e18 - 1e15);
        assertEq(vault.jurorWeightOf(alice), 2e18 - 1e15);
        assertEq(vault.weightOf(alice), 2e18 - 1e15);
        assertEq(vault.totalWeight(), 2e18 - 1e15);
    }

    function test_getPastJurorWeight_revertsForCurrentBlock() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vm.prank(alice);
        vault.optInAsJuror(0, 10e18, address(0));

        vm.expectRevert(IGoalStakeVault.BLOCK_NOT_YET_MINED.selector);
        vault.getPastJurorWeight(alice, block.number);
    }

    function _countLogsByTopic(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                ++count;
            }
        }
    }
}

contract VaultMockRulesets {
    mapping(uint256 => uint112) internal _weightOf;
    bool internal _shouldRevertCurrent;
    IJBDirectory internal _directory;

    error CURRENT_REVERT();

    function setDirectory(IJBDirectory directory_) external {
        _directory = directory_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function setWeight(uint256 projectId, uint112 weight) external {
        _weightOf[projectId] = weight;
    }

    function setShouldRevertCurrent(bool shouldRevert) external {
        _shouldRevertCurrent = shouldRevert;
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        if (_shouldRevertCurrent) revert CURRENT_REVERT();
        ruleset.weight = _weightOf[projectId];
    }
}

contract VaultMockDirectory {
    mapping(uint256 => address) internal _controllerOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }
}

contract VaultMockTokens {
    mapping(address => uint256) internal _projectIdOf;
    uint256 internal _defaultProjectId;

    function setProjectIdOf(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function setDefaultProjectId(uint256 projectId) external {
        _defaultProjectId = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        uint256 projectId = _projectIdOf[address(token)];
        if (projectId != 0) return projectId;
        return _defaultProjectId;
    }
}

contract VaultMockController {
    VaultMockTokens internal _tokens;

    constructor(VaultMockTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (VaultMockTokens) {
        return _tokens;
    }
}

contract VaultResolvedSignal {
    bool private _resolved;

    function setResolved(bool resolved_) external {
        _resolved = resolved_;
    }

    function resolved() external view returns (bool) {
        return _resolved;
    }
}

contract VaultAuthorityTreasury {
    address private _authority;

    constructor(address authority_) {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }
}

contract VaultLegacyTreasuryForwarder {
    address private _budgetTreasury;

    constructor(address budgetTreasury_) {
        _budgetTreasury = budgetTreasury_;
    }

    function budgetTreasury() external view returns (address) {
        return _budgetTreasury;
    }

    fallback() external payable {
        revert("BUDGET_TREASURY_ONLY");
    }
}

contract VaultNoAuthorityTreasury {}

contract VaultGoalTreasuryWithFlow {
    address internal _flow;

    constructor(address flow_) {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function authority() external pure returns (address) {
        return address(0);
    }
}

contract VaultGoalTreasuryRevertingFlowLookup {
    function flow() external pure returns (address) {
        revert("FLOW_LOOKUP_FAILURE");
    }

    function authority() external pure returns (address) {
        return address(0);
    }
}

contract VaultRevertingSyncFlow {
    function syncAllocationForAccount(address) external pure {
        revert("SYNC_FAILURE");
    }
}

contract VaultRecordingSyncFlow {
    uint256 public syncCallCount;
    address public lastSyncedAccount;

    function syncAllocationForAccount(address account) external {
        syncCallCount += 1;
        lastSyncedAccount = account;
    }
}

contract VaultMockDecimalsToken is ERC20 {
    uint8 internal immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}
