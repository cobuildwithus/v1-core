// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {StakeVault} from "src/goals/StakeVault.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {ITreasuryRuntimeViews} from "src/interfaces/ITreasuryRuntimeViews.sol";
import {ICustomFlow} from "src/interfaces/IFlow.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {MockFeeOnTransferVotesToken} from "test/mocks/MockFeeOnTransferVotesToken.sol";
import {MockSelectiveFeeVotesToken} from "test/mocks/MockSelectiveFeeVotesToken.sol";

// Temporary test shim for goal-only juror APIs after hard cutover.
library StakeVaultGoalOnlyJuryCompat {
    function optInAsJuror(StakeVault vault, uint256 goalAmount, uint256, address delegate) internal {
        vault.optInAsJuror(goalAmount, delegate);
    }

    function requestJurorExit(StakeVault vault, uint256 goalAmount, uint256) internal {
        vault.requestJurorExit(goalAmount);
    }

    function jurorLockedCobuildOf(StakeVault, address) internal pure returns (uint256) {
        return 0;
    }
}

contract StakeVaultTest is Test {
    using StakeVaultGoalOnlyJuryCompat for StakeVault;

    uint256 internal constant GOAL_PROJECT_ID = 111;
    bytes4 internal constant FLOW_LOOKUP_SELECTOR = ITreasuryRuntimeViews.flow.selector;
    bytes4 internal constant SYNC_ALLOCATION_SELECTOR = ICustomFlow.syncAllocationForAccount.selector;
    bytes32 internal constant JUROR_OPTED_IN_EVENT_TOPIC = keccak256("JurorOptedIn(address,uint256,uint256,address)");
    bytes32 internal constant JUROR_DELEGATE_SET_EVENT_TOPIC = keccak256("JurorDelegateSet(address,address)");
    bytes32 internal constant JUROR_SLASHED_EVENT_TOPIC =
        keccak256("JurorSlashed(address,uint256,uint256,uint256,address)");
    bytes32 internal constant UNDERWRITER_SLASHED_EVENT_TOPIC =
        keccak256("UnderwriterSlashed(address,uint256,uint256,uint256,uint256,address)");
    event AllocationSyncFailed(address indexed account, address indexed target, bytes4 indexed selector, bytes reason);
    event UnderwriterSlashed(
        address indexed underwriter,
        uint256 requestedWeight,
        uint256 appliedWeight,
        uint256 goalAmount,
        uint256 cobuildAmount,
        address indexed recipient
    );

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal slashRecipient = address(0xBEEF);

    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    VaultMockRulesets internal goalRulesets;
    VaultMockDirectory internal directory;
    VaultMockTokens internal controllerTokens;
    VaultMockController internal controller;
    StakeVault internal vault;

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

        vault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        goalToken.mint(alice, 1_000e18);
        cobuildToken.mint(alice, 1_000e18);

        vm.prank(alice);
        goalToken.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(vault), type(uint256).max);
    }

    function budgetStakeLedger() external view returns (address) {
        return address(this);
    }

    function _assertAllocationFrozen(StakeVault targetVault, uint256 key, address account) internal {
        assertEq(targetVault.currentWeight(address(0), key), 0);
        assertEq(targetVault.accountAllocationWeight(account), 0);
        assertFalse(targetVault.canAllocate(address(0), key, account));
        assertFalse(targetVault.canAccountAllocate(account));
    }

    function registeredBudgetCount() external pure returns (uint256) {
        return 0;
    }

    function registeredBudgetAt(uint256) external pure returns (address) {
        return address(0);
    }

    function userAllocatedStakeOnBudget(address, address) external pure returns (uint256) {
        return 0;
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        new StakeVault(
            address(0),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_strategy_allocationKeyAndResolver_useAddressEncoding() public view {
        assertEq(vault.allocationKey(alice, ""), uint256(uint160(alice)));
        assertEq(vault.allocationKey(bob, abi.encode(uint256(123))), uint256(uint160(bob)));
        assertEq(vault.accountForAllocationKey(uint256(uint160(alice))), alice);
    }

    function test_strategy_accountResolution_revertsOnHighBits() public {
        vm.prank(alice);
        vault.depositGoal(20e18);

        uint256 canonicalKey = uint256(uint160(alice));
        uint256 aliasedKey = canonicalKey | (uint256(1) << 200);

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_ALLOCATION_KEY.selector, aliasedKey));
        vault.accountForAllocationKey(aliasedKey);

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_ALLOCATION_KEY.selector, aliasedKey));
        vault.currentWeight(address(0), aliasedKey);

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_ALLOCATION_KEY.selector, aliasedKey));
        vault.canAllocate(address(0), aliasedKey, alice);

        assertEq(vault.currentWeight(address(0), canonicalKey), 10e18);
        assertTrue(vault.canAllocate(address(0), canonicalKey, alice));
        assertFalse(vault.canAllocate(address(0), canonicalKey, bob));
    }

    function test_strategyKey_constant() public view {
        assertEq(vault.strategyKey(), "StakeVault");
    }

    function test_stakeVault_returnsSelf() public view {
        assertEq(vault.stakeVault(), address(vault));
    }

    function test_strategy_weightQueries_followVaultState() public {
        vm.prank(alice);
        vault.depositGoal(20e18);
        vm.prank(alice);
        vault.depositCobuild(5e18);

        uint256 key = uint256(uint160(alice));
        assertEq(vault.currentWeight(address(0), key), 15e18);
        assertEq(vault.accountAllocationWeight(alice), 15e18);
        assertTrue(vault.canAllocate(address(0), key, alice));
        assertFalse(vault.canAllocate(address(0), key, bob));
        assertTrue(vault.canAccountAllocate(alice));
        assertFalse(vault.canAccountAllocate(bob));
    }

    function test_strategy_whenResolved_allocationDisabledAndWeightZero() public {
        vm.prank(alice);
        vault.depositGoal(20e18);

        uint256 key = uint256(uint160(alice));
        assertEq(vault.currentWeight(address(0), key), 10e18);
        assertTrue(vault.canAllocate(address(0), key, alice));
        assertTrue(vault.canAccountAllocate(alice));

        vault.markGoalResolved();

        _assertAllocationFrozen(vault, key, alice);
    }

    function test_strategy_whenTreasuryReportsResolved_allocationDisabledAndWeightZero() public {
        VaultResolvedSignal signal = new VaultResolvedSignal();

        StakeVault signalVault = new StakeVault(
            address(signal),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.startPrank(alice);
        goalToken.approve(address(signalVault), type(uint256).max);
        cobuildToken.approve(address(signalVault), type(uint256).max);
        signalVault.depositGoal(20e18);
        signalVault.depositCobuild(5e18);
        vm.stopPrank();

        uint256 key = uint256(uint160(alice));
        assertEq(signalVault.currentWeight(address(0), key), 15e18);
        assertEq(signalVault.accountAllocationWeight(alice), 15e18);
        assertTrue(signalVault.canAllocate(address(0), key, alice));
        assertTrue(signalVault.canAccountAllocate(alice));
        assertFalse(signalVault.goalResolved());

        signal.setResolved(true);

        assertFalse(signalVault.goalResolved());
        _assertAllocationFrozen(signalVault, key, alice);
    }

    function test_constructor_revertsOnZeroGoalToken() public {
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        new StakeVault(
            address(this),
            IERC20(address(0)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsOnZeroCobuildToken() public {
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(0)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsOnZeroRulesets() public {
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsWhenRulesetsHasNoCode() public {
        address eoaRulesets = makeAddr("rulesets-eoa");

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.NOT_A_CONTRACT.selector, eoaRulesets));
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(eoaRulesets),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsOnDecimalsMismatch() public {
        VaultMockDecimalsToken token6 = new VaultMockDecimalsToken("USDC", "USDC", 6);
        VaultMockDecimalsToken token18 = new VaultMockDecimalsToken("Token", "TKN", 18);

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.DECIMALS_MISMATCH.selector, 6, 18));
        new StakeVault(
            address(this),
            IERC20(address(token6)),
            IERC20(address(token18)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsOnInvalidPaymentTokenDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_PAYMENT_TOKEN_DECIMALS.selector, 78));
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            78
        );
    }

    function test_constructor_revertsOnPaymentTokenDecimalsMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.PAYMENT_TOKEN_DECIMALS_MISMATCH.selector, 18, 6));
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            6
        );
    }

    function test_constructor_revertsWhenGoalProjectControllerMissing() public {
        directory.setController(GOAL_PROJECT_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_REVNET_CONTROLLER.selector, address(0)));
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsWhenGoalDirectoryNotDerivable() public {
        goalRulesets.setDirectory(IJBDirectory(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(IStakeVault.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE.selector, address(goalToken))
        );
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsWhenGoalTokenMapsToDifferentRevnetId() public {
        uint256 foreignProjectId = GOAL_PROJECT_ID + 1;
        controllerTokens.setProjectIdOf(address(goalToken), foreignProjectId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStakeVault.GOAL_TOKEN_REVNET_MISMATCH.selector, address(goalToken), GOAL_PROJECT_ID, foreignProjectId
            )
        );
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_constructor_revertsWhenReservedPercentIsFull() public {
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_RESERVED_PERCENT.selector, 10_000));
        new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_initialize_revertsOnConstructorDeployedInstance() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_clone_initialize_setsStateAndGuardsReinitialize() public {
        StakeVault implementation =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);
        StakeVault clone = StakeVault(Clones.clone(address(implementation)));

        clone.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        assertEq(address(clone.goalTreasury()), address(this));
        assertEq(address(clone.goalToken()), address(goalToken));
        assertEq(address(clone.cobuildToken()), address(cobuildToken));
        assertEq(clone.goalRevnetId(), GOAL_PROJECT_ID);
        assertEq(clone.paymentTokenDecimals(), 18);

        (uint256 weightOut,, uint256 weightScale) = clone.quoteGoalToCobuildWeightRatio(10e18);
        assertEq(weightScale, 1e18);
        assertEq(weightOut, 5e18);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_implementationSentinelConfig_disablesInitializers() public {
        StakeVault implementation =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_clone_initialize_supportsNonReentrantDepositFlow() public {
        StakeVault implementation =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);
        StakeVault clone = StakeVault(Clones.clone(address(implementation)));

        clone.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        goalToken.approve(address(clone), type(uint256).max);
        vm.prank(alice);
        clone.depositGoal(20e18);

        assertEq(clone.stakedGoalOf(alice), 20e18);
        assertEq(clone.weightOf(alice), 10e18);
    }

    function test_clone_initialize_revertsWhenReservedPercentIsFull() public {
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 10_000);

        StakeVault implementation =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);
        StakeVault clone = StakeVault(Clones.clone(address(implementation)));

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.INVALID_RESERVED_PERCENT.selector, 10_000));
        clone.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_clone_initialize_revertsOnDecimalsMismatch() public {
        StakeVault implementation =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);
        StakeVault clone = StakeVault(Clones.clone(address(implementation)));
        VaultMockDecimalsToken token6 = new VaultMockDecimalsToken("USDC", "USDC", 6);
        VaultMockDecimalsToken token18 = new VaultMockDecimalsToken("Token", "TKN", 18);
        controllerTokens.setProjectIdOf(address(token6), GOAL_PROJECT_ID);

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.DECIMALS_MISMATCH.selector, 6, 18));
        clone.initialize(
            address(this),
            IERC20(address(token6)),
            IERC20(address(token18)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
    }

    function test_clone_initialize_revertsOnPaymentTokenDecimalsMismatch() public {
        StakeVault implementation =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);
        StakeVault clone = StakeVault(Clones.clone(address(implementation)));

        vm.expectRevert(abi.encodeWithSelector(IStakeVault.PAYMENT_TOKEN_DECIMALS_MISMATCH.selector, 18, 6));
        clone.initialize(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            6
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
        vm.expectRevert(IStakeVault.INVALID_AMOUNT.selector);
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
        vm.expectRevert(IStakeVault.INVALID_AMOUNT.selector);
        vault.depositCobuild(0);
    }

    function test_depositGoal_revertsWhenResolved() public {
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_ALREADY_RESOLVED.selector);
        vault.depositGoal(1e18);
    }

    function test_depositCobuild_revertsWhenResolved() public {
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_ALREADY_RESOLVED.selector);
        vault.depositCobuild(1e18);
    }

    function test_depositGoal_revertsWhenGoalWeightZero() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 0);
        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositGoal(1e18);
    }

    function test_depositGoal_revertsWhenRulesetReadReverts() public {
        goalRulesets.setShouldRevertCurrent(true);
        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositGoal(1e18);
    }

    function test_depositGoal_revertsWhenWeightDeltaRoundsToZero() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 2e18);
        vm.prank(alice);
        vm.expectRevert(IStakeVault.ZERO_WEIGHT_DELTA.selector);
        vault.depositGoal(1);
    }

    function test_depositCobuild_revertsWhenGoalWeightZero() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 0);
        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.depositCobuild(1e18);
    }

    function test_depositGoal_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferVotesToken feeGoal = new MockFeeOnTransferVotesToken("FeeGoal", "fGOAL", 100, address(0xFEE));

        StakeVault feeVault = new StakeVault(
            address(this),
            IERC20(address(feeGoal)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        feeGoal.mint(alice, 100e18);
        vm.prank(alice);
        feeGoal.approve(address(feeVault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        feeVault.depositGoal(100e18);
    }

    function test_depositCobuild_revertsOnFeeOnTransferToken() public {
        MockFeeOnTransferVotesToken feeCobuild =
            new MockFeeOnTransferVotesToken("FeeCobuild", "fCOBUILD", 100, address(0xFEE));

        StakeVault feeVault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(feeCobuild)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        feeCobuild.mint(alice, 100e18);
        vm.prank(alice);
        feeCobuild.approve(address(feeVault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        feeVault.depositCobuild(100e18);
    }

    function test_quoteGoalToCobuildWeight_returnsExpected() public view {
        (uint256 out, uint112 goalWeight, uint256 weightRatio) = vault.quoteGoalToCobuildWeightRatio(10e18);
        assertEq(goalWeight, 2e18);
        assertEq(weightRatio, 1e18);
        assertEq(out, 5e18);
    }

    function test_quoteGoalToCobuildWeight_usesSnapshottedGoalWeight() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 1e18);
        (uint256 out, uint112 goalWeight, uint256 weightRatio) = vault.quoteGoalToCobuildWeightRatio(10e18);
        // Snapshot remains at the setUp value (2e18), so quote output is unchanged.
        assertEq(goalWeight, 2e18);
        assertEq(weightRatio, 1e18);
        assertEq(out, 5e18);
    }

    function test_quoteGoalToCobuildWeight_usesSnapshottedReservedPercent() public {
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);
        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault snapshotVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );
        metadataTreasury.setDeadline(uint64(block.timestamp + 1_000));

        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 0);

        (uint256 out, uint112 goalWeight, uint256 weightRatio) = snapshotVault.quoteGoalToCobuildWeightRatio(10e18);
        assertEq(goalWeight, 2e18);
        assertEq(weightRatio, 1e18);
        // Snapshot keeps the original 50% reserve boost (10e18 amount => 5e18 base => 10e18 boosted).
        assertEq(out, 10e18);
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

        StakeVault sixDecimalVault = new StakeVault(
            address(this),
            IERC20(address(goalToken6)),
            IERC20(address(cobuildToken6)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            6
        );

        (uint256 out, uint112 goalWeight, uint256 weightRatio) = sixDecimalVault.quoteGoalToCobuildWeightRatio(10e6);
        assertEq(goalWeight, 2e6);
        assertEq(weightRatio, 1e6);
        assertEq(out, 5e6);
    }

    function test_quoteGoalToCobuildWeight_revertsWhenStakingClosed() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 0);
        vm.expectRevert(IStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.quoteGoalToCobuildWeightRatio(1e18);
    }

    function test_quoteGoalToCobuildWeight_revertsWhenRulesetReadReverts() public {
        goalRulesets.setShouldRevertCurrent(true);
        vm.expectRevert(IStakeVault.GOAL_STAKING_CLOSED.selector);
        vault.quoteGoalToCobuildWeightRatio(1e18);
    }

    function test_quoteGoalToCobuildWeight_decayInterpolatesFromActivationToDeadline() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        uint64 activatedAt = uint64(block.timestamp + 100);
        uint64 deadline = activatedAt + 1_000;
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(deadline);

        vm.warp(activatedAt - 1);
        (uint256 preActivation,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(preActivation, 400e18);

        vm.warp(activatedAt);
        (uint256 atActivation, uint112 rulesetWeight, uint256 weightScale) =
            decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(atActivation, 400e18);
        assertEq(rulesetWeight, 5e17);
        assertEq(weightScale, 1e18);

        vm.warp(activatedAt + 500);
        (uint256 atMidpoint,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(atMidpoint, 300e18);

        vm.warp(deadline + 1);
        (uint256 afterDeadline,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(afterDeadline, 200e18);
    }

    function test_quoteAndDepositGoal_useSnapshottedValuesAfterRulesetMutation() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        goalToken.approve(address(decayVault), type(uint256).max);

        uint64 activatedAt = uint64(block.timestamp + 100);
        uint64 deadline = activatedAt + 1_000;
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(deadline);

        vm.warp(activatedAt + 500);
        goalRulesets.setWeight(GOAL_PROJECT_ID, 1e18);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 0);

        (uint256 quotedAfterMutation,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(quotedAfterMutation, 300e18);

        vm.prank(alice);
        decayVault.depositGoal(100e18);
        assertEq(decayVault.weightOf(alice), quotedAfterMutation);
    }

    function test_quoteGoalToCobuildWeight_whenDecayWindowDegenerate_returnsIssuanceBase() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        uint64 activatedAt = uint64(block.timestamp + 100);
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(activatedAt);

        vm.warp(activatedAt + 1);
        (uint256 out,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(out, 200e18);
    }

    function test_quoteGoalToCobuildWeight_whenReservedIsZero_ignoresDecayWindow() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 0);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        uint64 activatedAt = uint64(block.timestamp + 100);
        uint64 deadline = activatedAt + 1_000;
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(deadline);

        vm.warp(activatedAt - 1);
        (uint256 preActivation,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(preActivation, 200e18);

        vm.warp(activatedAt + 500);
        (uint256 atMidpoint,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(atMidpoint, 200e18);

        vm.warp(deadline + 1);
        (uint256 postDeadline,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(postDeadline, 200e18);
    }

    function test_depositGoal_decayAppliedOnlyAtDepositTime() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        goalToken.approve(address(decayVault), type(uint256).max);

        uint64 activatedAt = uint64(block.timestamp + 100);
        uint64 deadline = activatedAt + 1_000;
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(deadline);

        vm.warp(activatedAt);
        vm.prank(alice);
        decayVault.depositGoal(100e18);
        assertEq(decayVault.weightOf(alice), 400e18);

        vm.warp(activatedAt + 500);
        vm.prank(alice);
        decayVault.depositGoal(100e18);

        // First deposit keeps its originally-accounted weight; only the second deposit is decayed.
        assertEq(decayVault.stakedGoalOf(alice), 200e18);
        assertEq(decayVault.weightOf(alice), 700e18);
        assertEq(decayVault.totalWeight(), 700e18);
    }

    function test_quoteGoalToCobuildWeight_revertsWhenRequiredTreasuryMetadataReadFails() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        uint64 activatedAt = uint64(block.timestamp + 100);
        uint64 deadline = activatedAt + 1_000;
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(deadline);

        vm.warp(activatedAt + 500);
        (uint256 withMetadata,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(withMetadata, 300e18);

        metadataTreasury.setRevertActivatedAt(true);
        vm.expectRevert(IStakeVault.GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE.selector);
        decayVault.quoteGoalToCobuildWeightRatio(100e18);

        metadataTreasury.setRevertActivatedAt(false);
        metadataTreasury.setActivatedAt(0);
        (uint256 preActivationBoosted,,) = decayVault.quoteGoalToCobuildWeightRatio(100e18);
        assertEq(preActivationBoosted, 400e18);

        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setRevertDeadline(true);
        vm.expectRevert(IStakeVault.GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE.selector);
        decayVault.quoteGoalToCobuildWeightRatio(100e18);

        metadataTreasury.setRevertDeadline(false);
        metadataTreasury.setDeadline(0);
        vm.expectRevert(IStakeVault.GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE.selector);
        decayVault.quoteGoalToCobuildWeightRatio(100e18);
    }

    function test_quoteGoalToCobuildWeight_revertsWhenRequiredTreasuryMetadataContractMissing() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        StakeVault decayVault = new StakeVault(
            address(0x1234),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.expectRevert(IStakeVault.GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE.selector);
        decayVault.quoteGoalToCobuildWeightRatio(100e18);
    }

    function test_depositGoal_revertsWhenRequiredTreasuryMetadataReadFails() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 5e17);
        goalRulesets.setReservedPercent(GOAL_PROJECT_ID, 5_000);

        VaultGoalTreasuryDecayMetadata metadataTreasury = new VaultGoalTreasuryDecayMetadata();
        StakeVault decayVault = new StakeVault(
            address(metadataTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        goalToken.approve(address(decayVault), type(uint256).max);

        uint64 activatedAt = uint64(block.timestamp + 100);
        uint64 deadline = activatedAt + 1_000;
        metadataTreasury.setActivatedAt(activatedAt);
        metadataTreasury.setDeadline(deadline);

        vm.warp(activatedAt + 500);
        metadataTreasury.setRevertDeadline(true);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE.selector);
        decayVault.depositGoal(100e18);

        assertEq(decayVault.stakedGoalOf(alice), 0);
        assertEq(decayVault.weightOf(alice), 0);
    }

    function test_markGoalResolved_revertsForUnauthorizedWhenTreasuryNotResolved() public {
        VaultResolvedSignal signal = new VaultResolvedSignal();

        StakeVault signalVault = new StakeVault(
            address(signal),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(bob);
        vm.expectRevert(IStakeVault.GOAL_NOT_RESOLVED.selector);
        signalVault.markGoalResolved();
    }

    function test_markGoalResolved_permissionlessWhenTreasuryReportsResolved() public {
        VaultResolvedSignal signal = new VaultResolvedSignal();

        StakeVault signalVault = new StakeVault(
            address(signal),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        signal.setResolved(true);
        vm.prank(bob);
        signalVault.markGoalResolved();
        assertTrue(signalVault.goalResolved());
    }

    function test_markGoalResolved_normalizesZeroTimestampLatch() public {
        VaultResolvedSignal signal = new VaultResolvedSignal();

        StakeVault signalVault = new StakeVault(
            address(signal),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        signal.setResolved(true);
        vm.warp(0);

        vm.prank(bob);
        signalVault.markGoalResolved();

        assertTrue(signalVault.goalResolved());
        assertEq(signalVault.goalResolvedAt(), 1);
    }

    function test_markGoalResolved_doesNotForwardLegacyBudgetTreasuryLookup() public {
        VaultResolvedSignal downstreamTreasury = new VaultResolvedSignal();
        downstreamTreasury.setResolved(true);
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));

        StakeVault signalVault = new StakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(bob);
        vm.expectRevert(IStakeVault.GOAL_NOT_RESOLVED.selector);
        signalVault.markGoalResolved();
    }

    function test_markGoalResolved_revertsWhenTreasuryHasNoResolvedSurface() public {
        VaultNoAuthorityTreasury noResolvedTreasury = new VaultNoAuthorityTreasury();

        StakeVault signalVault = new StakeVault(
            address(noResolvedTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(bob);
        vm.expectRevert(IStakeVault.GOAL_NOT_RESOLVED.selector);
        signalVault.markGoalResolved();
    }

    function test_markGoalResolved_revertsWhenTreasuryHasNoCode() public {
        StakeVault eoaTreasuryVault = new StakeVault(
            address(0x1234),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(bob);
        vm.expectRevert(IStakeVault.GOAL_NOT_RESOLVED.selector);
        eoaTreasuryVault.markGoalResolved();
    }

    function test_markGoalResolved_revertsWhenAlreadyResolved() public {
        vault.markGoalResolved();

        vm.expectRevert(IStakeVault.GOAL_ALREADY_RESOLVED.selector);
        vault.markGoalResolved();
    }

    function test_withdrawGoal_revertsBeforeResolved() public {
        vm.prank(alice);
        vault.depositGoal(10e18);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.GOAL_NOT_RESOLVED.selector);
        vault.withdrawGoal(1e18, alice);
    }

    function test_withdrawGoal_revertsWhenNotPrepared() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.setUnderwriterSlasher(address(this));
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        vault.withdrawGoal(1e18, alice);
    }

    function test_prepareUnderwriterWithdrawal_partialBatch_keepsWithdrawLockedUntilComplete() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrowA = new VaultPreparePremiumEscrow();
        VaultPreparePremiumEscrow escrowB = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury budgetA = new VaultPrepareBudgetTreasury(address(escrowA));
        VaultPrepareBudgetTreasury budgetB = new VaultPrepareBudgetTreasury(address(escrowB));
        budgetA.setResolved(true);
        budgetB.setResolved(true);
        budgetAwareLedger.addBudget(address(budgetA));
        budgetAwareLedger.addBudget(address(budgetB));
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) = budgetAwareVault.prepareUnderwriterWithdrawal(1);
        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 2);
        assertFalse(complete);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 1);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), budgetAwareVault.goalResolvedAt());
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 0);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);

        vm.prank(alice);
        (nextBudgetIndex, budgetCount, complete) = budgetAwareVault.prepareUnderwriterWithdrawal(1);
        assertEq(nextBudgetIndex, 2);
        assertEq(budgetCount, 2);
        assertTrue(complete);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 2);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), budgetAwareVault.goalResolvedAt());
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 2);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedBudgetWithZeroExposure_canCompleteAndWithdraw() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        budgetAwareLedger.addBudget(address(unresolvedBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 1);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), budgetAwareVault.goalResolvedAt());
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 1);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_prepareUnderwriterWithdrawal_budgetWithoutPremiumEscrow_allowsPrepareAndWithdraw() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(0));
        unresolvedBudget.setActivatedAt(1);
        unresolvedBudget.setState(IBudgetTreasury.BudgetState.Active);
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        budgetAwareLedger.setCoverage(alice, address(unresolvedBudget), 1e18);

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 1);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), budgetAwareVault.goalResolvedAt());
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 1);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_withdrawGoal_skipsUnderwriterPreparationWhenUnderwriterSlasherIsUnset() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(0));
        unresolvedBudget.setActivatedAt(1);
        unresolvedBudget.setState(IBudgetTreasury.BudgetState.Active);
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        budgetAwareLedger.setCoverage(alice, address(unresolvedBudget), 1e18);

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);

        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 0);
    }

    function test_withdrawCobuild_skipsUnderwriterPreparationWhenUnderwriterSlasherIsUnset() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        unresolvedBudget.setActivatedAt(1);
        unresolvedBudget.setState(IBudgetTreasury.BudgetState.Active);
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        budgetAwareLedger.setCoverage(alice, address(unresolvedBudget), 1e18);

        vm.prank(alice);
        budgetAwareVault.depositCobuild(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        budgetAwareVault.withdrawCobuild(1e18, alice);

        assertEq(budgetAwareVault.stakedCobuildOf(alice), 9e18);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 0);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedPreActivationCurrentCoverage_allowsPrepareAndWithdraw()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        budgetAwareLedger.setCoverage(alice, address(unresolvedBudget), 1e18);

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedActivatedBudget_revertsAndKeepsWithdrawLocked() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        unresolvedBudget.setActivatedAt(1);
        unresolvedBudget.setState(IBudgetTreasury.BudgetState.Active);
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        budgetAwareLedger.setCoverage(alice, address(unresolvedBudget), 1e18);
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedActivatedBudgetWithoutExposure_allowsPrepareAndWithdraw()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        unresolvedBudget.setActivatedAt(1);
        unresolvedBudget.setState(IBudgetTreasury.BudgetState.Active);
        budgetAwareLedger.addBudget(address(unresolvedBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedBudgetWithEscrowExposure_revertsAndKeepsWithdrawLocked()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setUserCov(alice, 1);
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 0);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);
    }

    function test_prepareUnderwriterWithdrawal_budgetWithNonContractPremiumEscrow_revertsAndKeepsWithdrawLocked()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(makeAddr("premium-escrow-eoa"));
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 0);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedBudgetWithExposureIntegral_revertsAndKeepsWithdrawLocked()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setExposureIntegral(alice, 1);
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 0);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);
    }

    function test_prepareUnderwriterWithdrawal_unresolvedBudgetWithCreditDrawn_revertsAndKeepsWithdrawLocked() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setCreditDrawn(alice, 1);
        VaultPrepareBudgetTreasury unresolvedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        budgetAwareLedger.addBudget(address(unresolvedBudget));
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedForResolvedAt(alice), 0);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 0);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);
    }

    function test_prepareUnderwriterWithdrawal_failedBudgetWithExposure_callsSlashAndAllowsWithdraw() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setUserCov(alice, 1);
        VaultPrepareBudgetTreasury failedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        failedBudget.setResolved(true);
        failedBudget.setActivatedAt(1);
        failedBudget.setState(IBudgetTreasury.BudgetState.Failed);
        budgetAwareLedger.addBudget(address(failedBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertEq(failedBudget.retryTerminalSideEffectsCallCount(), 0);
        assertEq(escrow.slashCallCount(), 1);
        assertEq(escrow.slashCallCountFor(alice), 1);
        assertEq(escrow.lastSlashedUnderwriter(), alice);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_prepareUnderwriterWithdrawal_failedBudgetWithExposure_retriesTerminalSideEffectsWhenSlashReverts()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setUserCov(alice, 1);
        escrow.setShouldRevertSlash(true);
        VaultPrepareBudgetTreasury failedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        failedBudget.setResolved(true);
        failedBudget.setActivatedAt(1);
        failedBudget.setState(IBudgetTreasury.BudgetState.Failed);
        failedBudget.setClearSlashRevertOnRetry(true);
        budgetAwareLedger.addBudget(address(failedBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertEq(failedBudget.retryTerminalSideEffectsCallCount(), 1);
        assertEq(escrow.slashCallCount(), 1);
        assertEq(escrow.slashCallCountFor(alice), 1);
        assertEq(escrow.lastSlashedUnderwriter(), alice);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_prepareUnderwriterWithdrawal_expiredBudgetWithExposure_retriesTerminalSideEffectsWhenSlashReverts()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setUserCov(alice, 1);
        escrow.setShouldRevertSlash(true);
        VaultPrepareBudgetTreasury expiredBudget = new VaultPrepareBudgetTreasury(address(escrow));
        expiredBudget.setResolved(true);
        expiredBudget.setActivatedAt(1);
        expiredBudget.setState(IBudgetTreasury.BudgetState.Expired);
        expiredBudget.setClearSlashRevertOnRetry(true);
        budgetAwareLedger.addBudget(address(expiredBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) =
            budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);

        assertEq(nextBudgetIndex, 1);
        assertEq(budgetCount, 1);
        assertTrue(complete);
        assertEq(expiredBudget.retryTerminalSideEffectsCallCount(), 1);
        assertEq(escrow.slashCallCount(), 1);
        assertEq(escrow.slashCallCountFor(alice), 1);
        assertEq(escrow.lastSlashedUnderwriter(), alice);
    }

    function test_prepareUnderwriterWithdrawal_failedBudgetWithExposure_revertsWhenRetryTerminalSideEffectsReverts()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setUserCov(alice, 1);
        escrow.setShouldRevertSlash(true);
        VaultPrepareBudgetTreasury failedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        failedBudget.setResolved(true);
        failedBudget.setActivatedAt(1);
        failedBudget.setState(IBudgetTreasury.BudgetState.Failed);
        failedBudget.setShouldRevertRetryTerminalSideEffects(true);
        budgetAwareLedger.addBudget(address(failedBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "RETRY_TERMINAL_SIDE_EFFECTS_FAILED"));
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);
    }

    function test_prepareUnderwriterWithdrawal_failedBudgetWithExposure_revertsWhenSecondSlashStillRevertsAfterRetry()
        public
    {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        escrow.setUserCov(alice, 1);
        escrow.setShouldRevertSlash(true);
        VaultPrepareBudgetTreasury failedBudget = new VaultPrepareBudgetTreasury(address(escrow));
        failedBudget.setResolved(true);
        failedBudget.setActivatedAt(1);
        failedBudget.setState(IBudgetTreasury.BudgetState.Failed);
        failedBudget.setUseAltSlashRevertReasonOnRetry(true);
        budgetAwareLedger.addBudget(address(failedBudget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "SLASH_REVERTED_AFTER_RETRY"));
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);
    }

    function test_prepareUnderwriterWithdrawal_revertsOnZeroMaxBudgets() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrow = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury budget = new VaultPrepareBudgetTreasury(address(escrow));
        budget.setResolved(true);
        budgetAwareLedger.addBudget(address(budget));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.INVALID_AMOUNT.selector);
        budgetAwareVault.prepareUnderwriterWithdrawal(0);
    }

    function test_withdrawGoal_relocksWhenRegisteredBudgetCountIncreasesAfterPrepare() public {
        (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        ) = _deployBudgetAwareVault();

        VaultPreparePremiumEscrow escrowA = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury budgetA = new VaultPrepareBudgetTreasury(address(escrowA));
        budgetA.setResolved(true);
        budgetAwareLedger.addBudget(address(budgetA));
        _configureUnderwriterSlasher(budgetAwareVault, address(budgetAwareGoalTreasury));

        vm.prank(alice);
        budgetAwareVault.depositGoal(10e18);
        vm.prank(address(budgetAwareGoalTreasury));
        budgetAwareVault.markGoalResolved();

        vm.prank(alice);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 1);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 1);

        VaultPreparePremiumEscrow escrowB = new VaultPreparePremiumEscrow();
        VaultPrepareBudgetTreasury budgetB = new VaultPrepareBudgetTreasury(address(escrowB));
        budgetB.setResolved(true);
        budgetAwareLedger.addBudget(address(budgetB));

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        budgetAwareVault.withdrawGoal(1e18, alice);

        vm.prank(alice);
        budgetAwareVault.prepareUnderwriterWithdrawal(type(uint256).max);
        assertEq(budgetAwareVault.underwriterWithdrawalPrepareCursor(alice), 2);
        assertEq(budgetAwareVault.underwriterWithdrawalPreparedBudgetCount(alice), 2);

        vm.prank(alice);
        budgetAwareVault.withdrawGoal(1e18, alice);
        assertEq(budgetAwareVault.stakedGoalOf(alice), 9e18);
    }

    function test_withdrawGoal_revertsOnZeroAmount() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.INVALID_AMOUNT.selector);
        vault.withdrawGoal(0, alice);
    }

    function test_withdrawGoal_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        vault.withdrawGoal(1e18, address(0));
    }

    function test_withdrawGoal_revertsOnInsufficientStakedBalance() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.INSUFFICIENT_STAKED_BALANCE.selector);
        vault.withdrawGoal(11e18, alice);
    }

    function test_withdrawGoal_partial_updatesWeightProportionally() public {
        vm.prank(alice);
        vault.depositGoal(100e18); // 50e18 weight
        vm.prank(alice);
        vault.depositCobuild(20e18); // +20e18 weight
        assertEq(vault.weightOf(alice), 70e18);

        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);
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
        _prepareUnderwriterWithdrawal(vault, alice);

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
        vm.expectRevert(IStakeVault.GOAL_NOT_RESOLVED.selector);
        vault.withdrawCobuild(1e18, alice);
    }

    function test_withdrawCobuild_revertsWhenNotPrepared() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.setUnderwriterSlasher(address(this));
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNDERWRITER_WITHDRAWAL_NOT_PREPARED.selector);
        vault.withdrawCobuild(1e18, alice);
    }

    function test_withdrawCobuild_revertsOnZeroAmount() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.INVALID_AMOUNT.selector);
        vault.withdrawCobuild(0, alice);
    }

    function test_withdrawCobuild_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        vault.withdrawCobuild(1e18, address(0));
    }

    function test_withdrawCobuild_revertsOnInsufficientStakedBalance() public {
        vm.prank(alice);
        vault.depositCobuild(10e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.INSUFFICIENT_STAKED_BALANCE.selector);
        vault.withdrawCobuild(11e18, alice);
    }

    function test_withdrawCobuild_updatesWeight() public {
        vm.prank(alice);
        vault.depositCobuild(30e18);
        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vault.withdrawCobuild(10e18, alice);

        assertEq(vault.stakedCobuildOf(alice), 20e18);
        assertEq(vault.weightOf(alice), 20e18);
        assertEq(vault.totalWeight(), 20e18);
    }

    function test_withdrawGoal_revertsOnFeeDuringVaultTransfer() public {
        MockSelectiveFeeVotesToken selective = new MockSelectiveFeeVotesToken("Goal", "GOAL", 100, address(0xFEE));

        StakeVault selectiveVault = new StakeVault(
            address(this),
            IERC20(address(selective)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        selective.mint(alice, 100e18);
        vm.prank(alice);
        selective.approve(address(selectiveVault), type(uint256).max);
        vm.prank(alice);
        selectiveVault.depositGoal(100e18);

        selectiveVault.markGoalResolved();
        _prepareUnderwriterWithdrawal(selectiveVault, alice);
        selective.setFeeFrom(address(selectiveVault));

        vm.prank(alice);
        vm.expectRevert(IStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        selectiveVault.withdrawGoal(10e18, alice);
    }

    function test_withdrawCobuild_revertsOnFeeDuringVaultTransfer() public {
        MockSelectiveFeeVotesToken selective = new MockSelectiveFeeVotesToken("Cobuild", "COBUILD", 100, address(0xFEE));

        StakeVault selectiveVault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(selective)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        selective.mint(alice, 100e18);
        vm.prank(alice);
        selective.approve(address(selectiveVault), type(uint256).max);
        vm.prank(alice);
        selectiveVault.depositCobuild(100e18);

        selectiveVault.markGoalResolved();
        _prepareUnderwriterWithdrawal(selectiveVault, alice);
        selective.setFeeFrom(address(selectiveVault));

        vm.prank(alice);
        vm.expectRevert(IStakeVault.TRANSFER_AMOUNT_MISMATCH.selector);
        selectiveVault.withdrawCobuild(10e18, alice);
    }

    function test_optInJuror_updatesBalancesDelegateAndSnapshots() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(50e18);
        vault.optInAsJuror(40e18, 20e18, bob);
        vm.stopPrank();

        assertEq(vault.jurorLockedGoalOf(alice), 40e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 20e18);
        assertEq(vault.totalJurorWeight(), 20e18);
        assertEq(vault.jurorDelegateOf(alice), bob);

        vm.roll(block.number + 1);
        assertEq(vault.getPastJurorWeight(alice, block.number - 1), 20e18);
        assertEq(vault.getPastTotalJurorWeight(block.number - 1), 20e18);
    }

    function test_optInJuror_revertsWhenGoalAmountIsZeroAfterGoalOnlyCutover() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(50e18);

        vm.expectRevert(IStakeVault.INVALID_JUROR_LOCK.selector);
        vault.optInAsJuror(0, 50e18, bob);
        vm.stopPrank();
    }

    function test_totalJurorWeight_tracksLatestCheckpointAcrossJurorsAfterSameBlockUpdates() public {
        goalToken.mint(bob, 1_000e18);
        cobuildToken.mint(bob, 1_000e18);

        vm.startPrank(bob);
        goalToken.approve(address(vault), type(uint256).max);
        cobuildToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        vault.depositGoal(100e18); // 50e18 goal weight.
        vault.depositCobuild(40e18); // +40e18 cobuild weight.
        vault.optInAsJuror(100e18, 40e18, address(0)); // 50e18 juror weight.
        vm.stopPrank();

        vm.startPrank(bob);
        vault.depositGoal(80e18); // 40e18 goal weight.
        vault.depositCobuild(20e18); // +20e18 cobuild weight.
        vault.optInAsJuror(80e18, 20e18, address(0)); // 40e18 juror weight.
        vm.stopPrank();

        assertEq(vault.jurorWeightOf(alice), 50e18);
        assertEq(vault.jurorWeightOf(bob), 40e18);
        assertEq(vault.totalJurorWeight(), 90e18);

        vault.setJurorSlasher(address(this));
        vault.slashJurorStake(bob, 60e18, slashRecipient);

        assertEq(vault.jurorWeightOf(alice), 50e18);
        assertEq(vault.jurorWeightOf(bob), 0);
        assertEq(vault.totalJurorWeight(), 50e18);
        assertEq(vault.totalJurorWeight(), vault.jurorWeightOf(alice) + vault.jurorWeightOf(bob));

        vm.roll(block.number + 1);
        assertEq(vault.getPastTotalJurorWeight(block.number - 1), 50e18);
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
        vault.depositGoal(100e18);
        vault.optInAsJuror(60e18, 0, address(0));
        vault.requestJurorExit(30e18, 0);

        vm.expectRevert(IStakeVault.EXIT_NOT_READY.selector);
        vault.finalizeJurorExit();

        vm.warp(block.timestamp + 7 days);
        vault.finalizeJurorExit();
        vm.stopPrank();

        assertEq(vault.jurorLockedGoalOf(alice), 30e18);
        assertEq(vault.jurorWeightOf(alice), 15e18);
        assertEq(vault.totalJurorWeight(), 15e18);
    }

    function test_requestJurorExit_revertsWhenGoalAmountIsZeroAfterGoalOnlyCutover() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(50e18);
        vault.optInAsJuror(40e18, 50e18, address(0));

        vm.expectRevert(IStakeVault.INVALID_JUROR_LOCK.selector);
        vault.requestJurorExit(0, 50e18);
        vm.stopPrank();
    }

    function test_finalizeJurorExit_whenGoalResolvesAfterRequest_enforcesDelayFromGoalResolvedAt() public {
        uint256 requestedAt = block.timestamp;
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.optInAsJuror(60e18, 0, address(0));
        vault.requestJurorExit(30e18, 0);
        vm.stopPrank();

        uint256 resolvedAt = requestedAt + 7 days + 1;
        vm.warp(resolvedAt);
        vault.markGoalResolved();

        vm.prank(alice);
        vm.expectRevert(IStakeVault.EXIT_NOT_READY.selector);
        vault.finalizeJurorExit();

        vm.warp(resolvedAt + 7 days + 1);
        vm.prank(alice);
        vault.finalizeJurorExit();

        assertEq(vault.jurorLockedGoalOf(alice), 30e18);
        assertEq(vault.jurorWeightOf(alice), 15e18);
    }

    function test_finalizeJurorExit_afterJurorSlash_clampsToRemainingLockedGoal() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.optInAsJuror(100e18, 0, address(0));
        vault.requestJurorExit(100e18, 0);
        vm.stopPrank();

        vault.setJurorSlasher(address(this));
        vault.slashJurorStake(alice, 30e18, slashRecipient);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vault.finalizeJurorExit();

        assertEq(vault.stakedGoalOf(alice), 40e18);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.totalJurorWeight(), 0);
    }

    function test_regression_postResolutionJurorLock_canExitAndWithdraw() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(80e18, 80e18, address(0));
        vm.stopPrank();

        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.startPrank(alice);
        vm.expectRevert(IStakeVault.JUROR_WITHDRAWAL_LOCKED.selector);
        vault.withdrawGoal(21e18, alice);
        vault.withdrawCobuild(21e18, alice);

        vault.requestJurorExit(80e18, 80e18);
        vm.expectRevert(IStakeVault.EXIT_NOT_READY.selector);
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

        vault.setJurorSlasher(address(this));

        vm.roll(block.number + 1);
        uint256 snapshotWeight = vault.getPastJurorWeight(alice, block.number - 1);

        vm.startPrank(alice);
        vault.requestJurorExit(80e18, 80e18);
        vm.warp(block.timestamp + 7 days);
        vault.finalizeJurorExit();
        vm.stopPrank();

        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.totalJurorWeight(), 0);

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vault.slashJurorStake(alice, snapshotWeight / 2, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 40e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);

        assertEq(vault.stakedGoalOf(alice), 60e18);
        assertEq(vault.stakedCobuildOf(alice), 100e18);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.weightOf(alice), 130e18);
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
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.startPrank(alice);
        vault.withdrawGoal(vault.stakedGoalOf(alice), alice);
        vault.withdrawCobuild(vault.stakedCobuildOf(alice), alice);
        vm.stopPrank();

        assertEq(vault.weightOf(alice), 0);

        vault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vault.slashJurorStake(alice, 60e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(slashRecipient), collectorCobuildBefore);
    }

    function test_withdrawGoal_revertsWhenTryingToWithdrawLockedJurorStake() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.optInAsJuror(80e18, 0, address(0));
        vm.stopPrank();

        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vm.expectRevert(IStakeVault.JUROR_WITHDRAWAL_LOCKED.selector);
        vault.withdrawGoal(21e18, alice);

        vm.prank(alice);
        vault.withdrawGoal(20e18, alice);

        assertEq(vault.stakedGoalOf(alice), 80e18);
        assertEq(vault.jurorLockedGoalOf(alice), 80e18);
    }

    function test_withdrawCobuild_revertsWhenTryingToWithdrawLockedJurorStake() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(70e18, 0, address(0));
        vm.stopPrank();

        vault.markGoalResolved();
        _prepareUnderwriterWithdrawal(vault, alice);

        vm.prank(alice);
        vault.withdrawCobuild(31e18, alice);

        vm.prank(alice);
        vault.withdrawCobuild(30e18, alice);

        assertEq(vault.stakedCobuildOf(alice), 39e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
    }

    function test_setJurorSlasher_and_slashJurorStake_proportionalAcrossAssets() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vault.setJurorSlasher(address(this));

        vm.prank(alice);
        vm.expectRevert(IStakeVault.ONLY_JUROR_SLASHER.selector);
        vault.slashJurorStake(alice, 15e18, slashRecipient);

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vault.slashJurorStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 30e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);

        assertEq(vault.stakedGoalOf(alice), 70e18);
        assertEq(vault.stakedCobuildOf(alice), 100e18);
        assertEq(vault.jurorLockedGoalOf(alice), 70e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 35e18);
        assertEq(vault.weightOf(alice), 135e18);
        assertEq(vault.totalWeight(), 135e18);
    }

    function test_slashJurorStake_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vault.depositGoal(100e18);

        vault.setJurorSlasher(address(this));

        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        vault.slashJurorStake(alice, 1e18, address(0));
    }

    function test_slashJurorStake_withCobuildOnlyStake_isNoOpAndEmitsNothing() public {
        vm.prank(alice);
        vault.depositCobuild(100e18);

        vault.setJurorSlasher(address(this));

        uint256 goalBefore = vault.stakedGoalOf(alice);
        uint256 cobuildBefore = vault.stakedCobuildOf(alice);
        uint256 weightBefore = vault.weightOf(alice);
        uint256 totalWeightBefore = vault.totalWeight();
        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashJurorStake(alice, 25e18, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(vault.stakedGoalOf(alice), goalBefore);
        assertEq(vault.stakedCobuildOf(alice), cobuildBefore);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.weightOf(alice), weightBefore);
        assertEq(vault.totalWeight(), totalWeightBefore);
        assertEq(goalToken.balanceOf(slashRecipient), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(slashRecipient), collectorCobuildBefore);
        assertEq(_countLogsByTopic(logs, JUROR_SLASHED_EVENT_TOPIC), 0);
    }

    function test_slashJurorStake_zeroRequestedWeight_isNoOp() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(50e18);
        vault.optInAsJuror(60e18, 20e18, address(0));
        vm.stopPrank();

        vault.setJurorSlasher(address(this));

        uint256 goalBefore = vault.stakedGoalOf(alice);
        uint256 cobuildBefore = vault.stakedCobuildOf(alice);
        uint256 lockedGoalBefore = vault.jurorLockedGoalOf(alice);
        uint256 lockedCobuildBefore = vault.jurorLockedCobuildOf(alice);
        uint256 jurorWeightBefore = vault.jurorWeightOf(alice);
        uint256 weightBefore = vault.weightOf(alice);
        uint256 totalWeightBefore = vault.totalWeight();
        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashJurorStake(alice, 0, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(vault.stakedGoalOf(alice), goalBefore);
        assertEq(vault.stakedCobuildOf(alice), cobuildBefore);
        assertEq(vault.jurorLockedGoalOf(alice), lockedGoalBefore);
        assertEq(vault.jurorLockedCobuildOf(alice), lockedCobuildBefore);
        assertEq(vault.jurorWeightOf(alice), jurorWeightBefore);
        assertEq(vault.weightOf(alice), weightBefore);
        assertEq(vault.totalWeight(), totalWeightBefore);
        assertEq(goalToken.balanceOf(slashRecipient), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(slashRecipient), collectorCobuildBefore);
        assertEq(_countLogsByTopic(logs, JUROR_SLASHED_EVENT_TOPIC), 0);
    }

    function test_slashJurorStake_zeroCurrentStake_isNoOp() public {
        vault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashJurorStake(alice, 15e18, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(goalToken.balanceOf(slashRecipient), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(slashRecipient), collectorCobuildBefore);
        assertEq(vault.weightOf(alice), 0);
        assertEq(vault.totalWeight(), 0);
        assertEq(_countLogsByTopic(logs, JUROR_SLASHED_EVENT_TOPIC), 0);
    }

    function test_setUnderwriterSlasher_and_slashUnderwriterStake_proportionalAcrossAssets() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vault.setUnderwriterSlasher(address(this));

        vm.prank(alice);
        vm.expectRevert(IStakeVault.ONLY_UNDERWRITER_SLASHER.selector);
        vault.slashUnderwriterStake(alice, 15e18, slashRecipient);

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnderwriterSlashed(alice, 15e18, 15e18, 10e18, 10e18, slashRecipient);
        vault.slashUnderwriterStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 10e18);

        assertEq(vault.stakedGoalOf(alice), 90e18);
        assertEq(vault.stakedCobuildOf(alice), 90e18);
        assertEq(vault.jurorLockedGoalOf(alice), 90e18);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 45e18);
        assertEq(vault.weightOf(alice), 135e18);
        assertEq(vault.totalWeight(), 135e18);
    }

    function test_slashUnderwriterStake_invariant_totalWeightDeltaMatchesEventAndExactTransfers() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vault.setUnderwriterSlasher(address(this));
        vm.roll(block.number + 1);

        uint256 requestedWeight = 15e18;
        uint256 totalWeightBefore = vault.totalWeight();
        uint256 userWeightBefore = vault.weightOf(alice);
        uint256 jurorWeightBefore = vault.jurorWeightOf(alice);
        uint256 stakedGoalBefore = vault.stakedGoalOf(alice);
        uint256 stakedCobuildBefore = vault.stakedCobuildOf(alice);
        uint256 lockedGoalBefore = vault.jurorLockedGoalOf(alice);
        uint256 lockedCobuildBefore = vault.jurorLockedCobuildOf(alice);
        uint256 recipientGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 recipientCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashUnderwriterStake(alice, requestedWeight, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 emittedRequested, uint256 appliedWeight, uint256 goalAmount, uint256 cobuildAmount) =
            _decodeSlashEventAmounts(logs, UNDERWRITER_SLASHED_EVENT_TOPIC);
        (uint256 expectedJurorWeightDelta,,) = vault.quoteGoalToCobuildWeightRatio(goalAmount);

        assertEq(emittedRequested, requestedWeight);
        assertEq(totalWeightBefore - vault.totalWeight(), appliedWeight);
        assertEq(userWeightBefore - vault.weightOf(alice), appliedWeight);
        assertEq(jurorWeightBefore - vault.jurorWeightOf(alice), expectedJurorWeightDelta);

        assertEq(stakedGoalBefore - vault.stakedGoalOf(alice), goalAmount);
        assertEq(stakedCobuildBefore - vault.stakedCobuildOf(alice), cobuildAmount);
        assertEq(lockedGoalBefore - vault.jurorLockedGoalOf(alice), goalAmount);
        assertEq(lockedCobuildBefore - vault.jurorLockedCobuildOf(alice), 0);

        assertEq(goalToken.balanceOf(slashRecipient) - recipientGoalBefore, goalAmount);
        assertEq(cobuildToken.balanceOf(slashRecipient) - recipientCobuildBefore, cobuildAmount);
    }

    function test_slashJurorStake_invariant_totalWeightDeltaMatchesEventAndExactTransfers() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(100e18, 100e18, address(0));
        vm.stopPrank();

        vault.setJurorSlasher(address(this));
        vm.roll(block.number + 1);

        uint256 requestedWeight = 15e18;
        uint256 totalWeightBefore = vault.totalWeight();
        uint256 userWeightBefore = vault.weightOf(alice);
        uint256 jurorWeightBefore = vault.jurorWeightOf(alice);
        uint256 stakedGoalBefore = vault.stakedGoalOf(alice);
        uint256 stakedCobuildBefore = vault.stakedCobuildOf(alice);
        uint256 lockedGoalBefore = vault.jurorLockedGoalOf(alice);
        uint256 lockedCobuildBefore = vault.jurorLockedCobuildOf(alice);
        uint256 recipientGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 recipientCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashJurorStake(alice, requestedWeight, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 emittedRequested, uint256 appliedWeight, uint256 goalAmount, uint256 cobuildAmount) =
            _decodeSlashEventAmounts(logs, JUROR_SLASHED_EVENT_TOPIC);

        assertEq(emittedRequested, requestedWeight);
        assertEq(totalWeightBefore - vault.totalWeight(), appliedWeight);
        assertEq(userWeightBefore - vault.weightOf(alice), appliedWeight);
        assertEq(jurorWeightBefore - vault.jurorWeightOf(alice), appliedWeight);

        assertEq(stakedGoalBefore - vault.stakedGoalOf(alice), goalAmount);
        assertEq(stakedCobuildBefore - vault.stakedCobuildOf(alice), cobuildAmount);
        assertEq(lockedGoalBefore - vault.jurorLockedGoalOf(alice), goalAmount);
        assertEq(lockedCobuildBefore - vault.jurorLockedCobuildOf(alice), cobuildAmount);

        assertEq(goalToken.balanceOf(slashRecipient) - recipientGoalBefore, goalAmount);
        assertEq(cobuildToken.balanceOf(slashRecipient) - recipientCobuildBefore, cobuildAmount);
    }

    function test_slashUnderwriterStake_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vault.depositGoal(100e18);

        vault.setUnderwriterSlasher(address(this));

        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        vault.slashUnderwriterStake(alice, 1e18, address(0));
    }

    function test_slashUnderwriterStake_zeroRequestedWeight_isNoOp() public {
        vm.startPrank(alice);
        vault.depositGoal(100e18);
        vault.depositCobuild(50e18);
        vault.optInAsJuror(60e18, 20e18, address(0));
        vm.stopPrank();

        vault.setUnderwriterSlasher(address(this));

        uint256 goalBefore = vault.stakedGoalOf(alice);
        uint256 cobuildBefore = vault.stakedCobuildOf(alice);
        uint256 lockedGoalBefore = vault.jurorLockedGoalOf(alice);
        uint256 lockedCobuildBefore = vault.jurorLockedCobuildOf(alice);
        uint256 jurorWeightBefore = vault.jurorWeightOf(alice);
        uint256 weightBefore = vault.weightOf(alice);
        uint256 totalWeightBefore = vault.totalWeight();
        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashUnderwriterStake(alice, 0, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(vault.stakedGoalOf(alice), goalBefore);
        assertEq(vault.stakedCobuildOf(alice), cobuildBefore);
        assertEq(vault.jurorLockedGoalOf(alice), lockedGoalBefore);
        assertEq(vault.jurorLockedCobuildOf(alice), lockedCobuildBefore);
        assertEq(vault.jurorWeightOf(alice), jurorWeightBefore);
        assertEq(vault.weightOf(alice), weightBefore);
        assertEq(vault.totalWeight(), totalWeightBefore);
        assertEq(goalToken.balanceOf(slashRecipient), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(slashRecipient), collectorCobuildBefore);
        assertEq(_countLogsByTopic(logs, UNDERWRITER_SLASHED_EVENT_TOPIC), 0);
    }

    function test_slashUnderwriterStake_zeroCurrentStake_isNoOp() public {
        vault.setUnderwriterSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vm.recordLogs();
        vault.slashUnderwriterStake(alice, 15e18, slashRecipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(goalToken.balanceOf(slashRecipient), collectorGoalBefore);
        assertEq(cobuildToken.balanceOf(slashRecipient), collectorCobuildBefore);
        assertEq(vault.weightOf(alice), 0);
        assertEq(vault.totalWeight(), 0);
        assertEq(_countLogsByTopic(logs, UNDERWRITER_SLASHED_EVENT_TOPIC), 0);
    }

    function test_slashUnderwriterStake_maxRequestedWeight_clampsToDerivedStakeWeight_andKeepsAggregateInSync() public {
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

        vault.setUnderwriterSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vault.slashUnderwriterStake(alice, type(uint256).max, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 100e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 40e18);

        assertEq(vault.stakedGoalOf(alice), 0);
        assertEq(vault.stakedCobuildOf(alice), 0);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.weightOf(alice), 0);

        assertEq(vault.totalWeight(), vault.weightOf(alice) + vault.weightOf(bob));
        assertEq(vault.totalWeight(), 40e18);
    }

    function test_slashUnderwriterStake_bestEffortGoalFlowSync_callsSyncForUnderwriterWhenFlowPresent() public {
        VaultRecordingSyncFlow recordingFlow = new VaultRecordingSyncFlow();
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(recordingFlow));
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setUnderwriterSlasher(address(this));

        syncingVault.slashUnderwriterStake(alice, 15e18, slashRecipient);

        assertEq(recordingFlow.syncCallCount(), 1);
        assertEq(recordingFlow.lastSyncedAccount(), alice);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashUnderwriterStake_bestEffortGoalFlowSyncDoesNotRevertOnSyncFailure() public {
        VaultRevertingSyncFlow revertingFlow = new VaultRevertingSyncFlow();
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(revertingFlow));
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setUnderwriterSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "SYNC_FAILURE");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(revertingFlow), SYNC_ALLOCATION_SELECTOR, expectedReason);
        syncingVault.slashUnderwriterStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 10e18);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashUnderwriterStake_bestEffortGoalFlowSyncDoesNotRevertWhenFlowLookupReverts() public {
        VaultGoalTreasuryRevertingFlowLookup treasuryWithRevertingLookup = new VaultGoalTreasuryRevertingFlowLookup();
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithRevertingLookup),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setUnderwriterSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "FLOW_LOOKUP_FAILURE");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(treasuryWithRevertingLookup), FLOW_LOOKUP_SELECTOR, expectedReason);
        syncingVault.slashUnderwriterStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 10e18);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashUnderwriterStake_bestEffortGoalFlowSync_doesNotForwardLegacyBudgetTreasuryLookup() public {
        VaultRecordingSyncFlow recordingFlow = new VaultRecordingSyncFlow();
        VaultGoalTreasuryWithFlow downstreamTreasury = new VaultGoalTreasuryWithFlow(address(recordingFlow));
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));
        StakeVault syncingVault = new StakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setUnderwriterSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "BUDGET_TREASURY_ONLY");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(legacyForwarder), FLOW_LOOKUP_SELECTOR, expectedReason);
        syncingVault.slashUnderwriterStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 10e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 10e18);
        assertEq(recordingFlow.syncCallCount(), 0);
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

        vault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        vault.slashJurorStake(alice, type(uint256).max, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 100e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);

        assertEq(vault.stakedGoalOf(alice), 0);
        assertEq(vault.stakedCobuildOf(alice), 40e18);
        assertEq(vault.jurorLockedGoalOf(alice), 0);
        assertEq(vault.jurorLockedCobuildOf(alice), 0);
        assertEq(vault.jurorWeightOf(alice), 0);
        assertEq(vault.weightOf(alice), 40e18);

        assertEq(vault.totalWeight(), vault.weightOf(alice) + vault.weightOf(bob));
        assertEq(vault.totalWeight(), 80e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSync_callsSyncForJurorWhenFlowPresent() public {
        VaultRecordingSyncFlow recordingFlow = new VaultRecordingSyncFlow();
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(recordingFlow));
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setJurorSlasher(address(this));

        syncingVault.slashJurorStake(alice, 15e18, slashRecipient);

        assertEq(recordingFlow.syncCallCount(), 1);
        assertEq(recordingFlow.lastSyncedAccount(), alice);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSync_doesNotRevertWhenFlowUnset() public {
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(0));
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        syncingVault.slashJurorStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 30e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSyncDoesNotRevertOnSyncFailure() public {
        VaultRevertingSyncFlow revertingFlow = new VaultRevertingSyncFlow();
        VaultGoalTreasuryWithFlow treasuryWithFlow = new VaultGoalTreasuryWithFlow(address(revertingFlow));
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithFlow),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "SYNC_FAILURE");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(revertingFlow), SYNC_ALLOCATION_SELECTOR, expectedReason);
        syncingVault.slashJurorStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 30e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSyncDoesNotRevertWhenFlowLookupReverts() public {
        VaultGoalTreasuryRevertingFlowLookup treasuryWithRevertingLookup = new VaultGoalTreasuryRevertingFlowLookup();
        StakeVault syncingVault = new StakeVault(
            address(treasuryWithRevertingLookup),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "FLOW_LOOKUP_FAILURE");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(treasuryWithRevertingLookup), FLOW_LOOKUP_SELECTOR, expectedReason);
        syncingVault.slashJurorStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 30e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);
        assertEq(syncingVault.weightOf(alice), 135e18);
    }

    function test_slashJurorStake_bestEffortGoalFlowSync_doesNotForwardLegacyBudgetTreasuryLookup() public {
        VaultRecordingSyncFlow recordingFlow = new VaultRecordingSyncFlow();
        VaultGoalTreasuryWithFlow downstreamTreasury = new VaultGoalTreasuryWithFlow(address(recordingFlow));
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));
        StakeVault syncingVault = new StakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
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
        syncingVault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "BUDGET_TREASURY_ONLY");

        vm.expectEmit(true, true, true, true, address(syncingVault));
        emit AllocationSyncFailed(alice, address(legacyForwarder), FLOW_LOOKUP_SELECTOR, expectedReason);
        syncingVault.slashJurorStake(alice, 15e18, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 30e18);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);
        assertEq(recordingFlow.syncCallCount(), 0);
    }

    function test_setJurorSlasher_revertsWhenUnauthorized() public {
        VaultAuthorityTreasury controlledTreasury = new VaultAuthorityTreasury(bob);

        StakeVault controlledVault = new StakeVault(
            address(controlledTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNAUTHORIZED.selector);
        controlledVault.setJurorSlasher(bob);
    }

    function test_setUnderwriterSlasher_revertsWhenUnauthorized() public {
        VaultAuthorityTreasury controlledTreasury = new VaultAuthorityTreasury(bob);

        StakeVault controlledVault = new StakeVault(
            address(controlledTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        vm.expectRevert(IStakeVault.UNAUTHORIZED.selector);
        controlledVault.setUnderwriterSlasher(bob);
    }

    function test_setJurorSlasher_revertsWhenCallerIsNotGoalTreasury_evenWithLegacyForwarder() public {
        VaultAuthorityTreasury downstreamTreasury = new VaultAuthorityTreasury(bob);
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));

        StakeVault controlledVault = new StakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(bob);
        vm.expectRevert(IStakeVault.UNAUTHORIZED.selector);
        controlledVault.setJurorSlasher(alice);
    }

    function test_setUnderwriterSlasher_revertsWhenCallerIsNotGoalTreasury_evenWithLegacyForwarder() public {
        VaultAuthorityTreasury downstreamTreasury = new VaultAuthorityTreasury(bob);
        VaultLegacyTreasuryForwarder legacyForwarder = new VaultLegacyTreasuryForwarder(address(downstreamTreasury));

        StakeVault controlledVault = new StakeVault(
            address(legacyForwarder),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(bob);
        vm.expectRevert(IStakeVault.UNAUTHORIZED.selector);
        controlledVault.setUnderwriterSlasher(alice);
    }

    function test_setJurorSlasher_revertsWhenAlreadySet() public {
        vault.setJurorSlasher(address(this));

        vm.expectRevert(IStakeVault.JUROR_SLASHER_ALREADY_SET.selector);
        vault.setJurorSlasher(alice);
    }

    function test_setUnderwriterSlasher_revertsWhenAlreadySet() public {
        vault.setUnderwriterSlasher(address(this));

        vm.expectRevert(IStakeVault.UNDERWRITER_SLASHER_ALREADY_SET.selector);
        vault.setUnderwriterSlasher(alice);
    }

    function test_setUnderwriterSlasher_revertsOnZeroAddress() public {
        vm.expectRevert(IStakeVault.ADDRESS_ZERO.selector);
        vault.setUnderwriterSlasher(address(0));
    }

    function test_setJurorSlasher_allowsGoalTreasuryCaller() public {
        VaultAuthorityTreasury ownedTreasury = new VaultAuthorityTreasury(bob);

        StakeVault ownedVault = new StakeVault(
            address(ownedTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(address(ownedTreasury));
        ownedVault.setJurorSlasher(address(this));
        assertEq(ownedVault.jurorSlasher(), address(this));
    }

    function test_setUnderwriterSlasher_allowsGoalTreasuryCaller() public {
        VaultAuthorityTreasury ownedTreasury = new VaultAuthorityTreasury(bob);

        StakeVault ownedVault = new StakeVault(
            address(ownedTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(address(ownedTreasury));
        ownedVault.setUnderwriterSlasher(address(this));
        assertEq(ownedVault.underwriterSlasher(), address(this));
    }

    function test_setJurorSlasher_revertsWhenSlasherHasNoCode() public {
        vm.expectRevert(IStakeVault.INVALID_JUROR_SLASHER.selector);
        vault.setJurorSlasher(alice);
    }

    function test_setUnderwriterSlasher_revertsWhenSlasherHasNoCode() public {
        vm.expectRevert(IStakeVault.INVALID_UNDERWRITER_SLASHER.selector);
        vault.setUnderwriterSlasher(alice);
    }

    function test_slashJurorStake_doesNotOverslashGoalWeightFromRounding() public {
        goalRulesets.setWeight(GOAL_PROJECT_ID, 1);

        StakeVault roundingVault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        goalToken.approve(address(roundingVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(roundingVault), type(uint256).max);

        vm.startPrank(alice);
        roundingVault.depositGoal(1);
        roundingVault.depositCobuild(1e18);
        roundingVault.optInAsJuror(1, 1e18, address(0));
        vm.stopPrank();

        roundingVault.setJurorSlasher(address(this));

        uint256 collectorGoalBefore = goalToken.balanceOf(slashRecipient);
        uint256 collectorCobuildBefore = cobuildToken.balanceOf(slashRecipient);

        roundingVault.slashJurorStake(alice, 1e15, slashRecipient);

        assertEq(goalToken.balanceOf(slashRecipient) - collectorGoalBefore, 0);
        assertEq(cobuildToken.balanceOf(slashRecipient) - collectorCobuildBefore, 0);

        assertEq(roundingVault.stakedGoalOf(alice), 1);
        assertEq(roundingVault.jurorLockedGoalOf(alice), 1);
        assertEq(roundingVault.stakedCobuildOf(alice), 1e18);
        assertEq(roundingVault.jurorLockedCobuildOf(alice), 0);
        assertEq(roundingVault.jurorWeightOf(alice), 1e18);
        assertEq(roundingVault.weightOf(alice), 2e18);
        assertEq(roundingVault.totalWeight(), 2e18);
    }

    function test_getPastJurorWeight_revertsForCurrentBlock() public {
        vm.prank(alice);
        vault.depositGoal(10e18);
        vm.prank(alice);
        vault.optInAsJuror(10e18, 0, address(0));

        vm.expectRevert(IStakeVault.BLOCK_NOT_YET_MINED.selector);
        vault.getPastJurorWeight(alice, block.number);
    }

    function _countLogsByTopic(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                ++count;
            }
        }
    }

    function _decodeSlashEventAmounts(Vm.Log[] memory logs, bytes32 topic0)
        internal
        pure
        returns (uint256 requestedWeight, uint256 appliedWeight, uint256 goalAmount, uint256 cobuildAmount)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                if (topic0 == JUROR_SLASHED_EVENT_TOPIC) {
                    (requestedWeight, appliedWeight, goalAmount) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                    cobuildAmount = 0;
                    return (requestedWeight, appliedWeight, goalAmount, cobuildAmount);
                }
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        revert("SLASH_EVENT_NOT_FOUND");
    }

    function _prepareUnderwriterWithdrawal(StakeVault targetVault, address underwriter) internal {
        vm.prank(underwriter);
        targetVault.prepareUnderwriterWithdrawal(type(uint256).max);
    }

    function _configureUnderwriterSlasher(StakeVault targetVault, address goalTreasuryCaller) internal {
        vm.prank(goalTreasuryCaller);
        targetVault.setUnderwriterSlasher(address(this));
    }

    function _deployBudgetAwareVault()
        internal
        returns (
            StakeVault budgetAwareVault,
            VaultPrepareGoalTreasury budgetAwareGoalTreasury,
            VaultPrepareBudgetStakeLedger budgetAwareLedger
        )
    {
        budgetAwareLedger = new VaultPrepareBudgetStakeLedger();
        budgetAwareGoalTreasury = new VaultPrepareGoalTreasury(address(budgetAwareLedger));
        budgetAwareVault = new StakeVault(
            address(budgetAwareGoalTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(goalRulesets)),
            GOAL_PROJECT_ID,
            18
        );

        vm.prank(alice);
        goalToken.approve(address(budgetAwareVault), type(uint256).max);
        vm.prank(alice);
        cobuildToken.approve(address(budgetAwareVault), type(uint256).max);
    }
}

contract VaultMockRulesets {
    mapping(uint256 => uint112) internal _weightOf;
    mapping(uint256 => uint16) internal _reservedPercentOf;
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

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        _reservedPercentOf[projectId] = reservedPercent;
    }

    function setShouldRevertCurrent(bool shouldRevert) external {
        _shouldRevertCurrent = shouldRevert;
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        if (_shouldRevertCurrent) revert CURRENT_REVERT();
        ruleset.weight = _weightOf[projectId];
        // Metadata version `1` in bits [0..3], reserved percent in bits [4..19].
        ruleset.metadata = 1 | (uint256(_reservedPercentOf[projectId]) << 4);
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

contract VaultGoalTreasuryWithDeadline {
    uint64 internal immutable _deadline;

    constructor(uint64 deadline_) {
        _deadline = deadline_;
    }

    function deadline() external view returns (uint64) {
        return _deadline;
    }
}

contract VaultGoalTreasuryDecayMetadata {
    uint64 internal _activatedAt;
    uint64 internal _deadline;
    bool internal _revertActivatedAt;
    bool internal _revertDeadline;

    function setActivatedAt(uint64 activatedAt_) external {
        _activatedAt = activatedAt_;
    }

    function setDeadline(uint64 deadline_) external {
        _deadline = deadline_;
    }

    function setRevertActivatedAt(bool shouldRevert_) external {
        _revertActivatedAt = shouldRevert_;
    }

    function setRevertDeadline(bool shouldRevert_) external {
        _revertDeadline = shouldRevert_;
    }

    function activatedAt() external view returns (uint64) {
        if (_revertActivatedAt) revert("ACTIVATED_AT_FAILURE");
        return _activatedAt;
    }

    function deadline() external view returns (uint64) {
        if (_revertDeadline) revert("DEADLINE_FAILURE");
        return _deadline;
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

contract VaultPrepareGoalTreasury {
    address internal immutable _budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        _budgetStakeLedger = budgetStakeLedger_;
    }

    function budgetStakeLedger() external view returns (address) {
        return _budgetStakeLedger;
    }
}

contract VaultPrepareBudgetStakeLedger {
    address[] internal _registeredBudgets;
    mapping(address account => mapping(address budget => uint256 coverage)) internal _coverageByUserAndBudget;

    function addBudget(address budget) external {
        _registeredBudgets.push(budget);
    }

    function setCoverage(address account, address budget, uint256 coverage) external {
        _coverageByUserAndBudget[account][budget] = coverage;
    }

    function registeredBudgetCount() external view returns (uint256) {
        return _registeredBudgets.length;
    }

    function registeredBudgetAt(uint256 index) external view returns (address) {
        return _registeredBudgets[index];
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256) {
        return _coverageByUserAndBudget[account][budget];
    }
}

contract VaultPrepareBudgetTreasury {
    address internal _premiumEscrow;
    bool internal _resolved;
    uint64 internal _activatedAt;
    IBudgetTreasury.BudgetState internal _state;
    bool internal _shouldRevertRetryTerminalSideEffects;
    bool internal _clearSlashRevertOnRetry;
    bool internal _useAltSlashRevertReasonOnRetry;
    uint256 internal _retryTerminalSideEffectsCallCount;

    constructor(address premiumEscrow_) {
        _premiumEscrow = premiumEscrow_;
        _state = IBudgetTreasury.BudgetState.Funding;
    }

    function setResolved(bool resolved_) external {
        _resolved = resolved_;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        _activatedAt = activatedAt_;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        _state = state_;
    }

    function setPremiumEscrow(address premiumEscrow_) external {
        _premiumEscrow = premiumEscrow_;
    }

    function premiumEscrow() external view returns (address) {
        return _premiumEscrow;
    }

    function resolved() external view returns (bool) {
        return _resolved;
    }

    function state() external view returns (IBudgetTreasury.BudgetState) {
        return _state;
    }

    function activatedAt() external view returns (uint64) {
        return _activatedAt;
    }

    function setShouldRevertRetryTerminalSideEffects(bool shouldRevert_) external {
        _shouldRevertRetryTerminalSideEffects = shouldRevert_;
    }

    function setClearSlashRevertOnRetry(bool clearOnRetry_) external {
        _clearSlashRevertOnRetry = clearOnRetry_;
    }

    function setUseAltSlashRevertReasonOnRetry(bool useAltReason_) external {
        _useAltSlashRevertReasonOnRetry = useAltReason_;
    }

    function retryTerminalSideEffectsCallCount() external view returns (uint256) {
        return _retryTerminalSideEffectsCallCount;
    }

    function retryTerminalSideEffects() external {
        _retryTerminalSideEffectsCallCount += 1;
        if (_shouldRevertRetryTerminalSideEffects) revert("RETRY_TERMINAL_SIDE_EFFECTS_FAILED");
        if (_clearSlashRevertOnRetry) {
            VaultPreparePremiumEscrow(_premiumEscrow).setShouldRevertSlash(false);
        }
        if (_useAltSlashRevertReasonOnRetry) {
            VaultPreparePremiumEscrow(_premiumEscrow).setUseAltSlashRevertReason(true);
        }
    }
}

contract VaultPreparePremiumEscrow {
    mapping(address account => uint256 cov) internal _userCov;
    mapping(address account => uint256 integral) internal _exposureIntegral;
    mapping(address account => uint256 credit) internal _creditDrawn;
    bool internal _shouldRevertSlash;
    bool internal _useAltSlashRevertReason;
    uint256 internal _slashCallCount;
    mapping(address account => uint256 count) internal _slashCallCountFor;
    address internal _lastSlashedUnderwriter;

    function setUserCov(address account, uint256 cov) external {
        _userCov[account] = cov;
    }

    function setExposureIntegral(address account, uint256 integral) external {
        _exposureIntegral[account] = integral;
    }

    function setCreditDrawn(address account, uint256 credit) external {
        _creditDrawn[account] = credit;
    }

    function userCov(address account) external view returns (uint256) {
        return _userCov[account];
    }

    function exposureIntegral(address account) external view returns (uint256) {
        return _exposureIntegral[account];
    }

    function creditDrawn(address account) external view returns (uint256) {
        return _creditDrawn[account];
    }

    function slashCallCount() external view returns (uint256) {
        return _slashCallCount;
    }

    function setShouldRevertSlash(bool shouldRevert_) external {
        _shouldRevertSlash = shouldRevert_;
    }

    function setUseAltSlashRevertReason(bool useAlt_) external {
        _useAltSlashRevertReason = useAlt_;
    }

    function slashCallCountFor(address account) external view returns (uint256) {
        return _slashCallCountFor[account];
    }

    function lastSlashedUnderwriter() external view returns (address) {
        return _lastSlashedUnderwriter;
    }

    function slash(address underwriter) external returns (uint256) {
        if (_shouldRevertSlash) {
            if (_useAltSlashRevertReason) revert("SLASH_REVERTED_AFTER_RETRY");
            revert("SLASH_REVERTED");
        }
        _slashCallCount += 1;
        _slashCallCountFor[underwriter] += 1;
        _lastSlashedUnderwriter = underwriter;
        return 0;
    }
}
