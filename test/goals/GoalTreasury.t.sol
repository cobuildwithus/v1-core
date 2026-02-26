// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IGoalStakeVault } from "src/interfaces/IGoalStakeVault.sol";
import { IRewardEscrow } from "src/interfaces/IRewardEscrow.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {
    SharedMockCFA,
    SharedMockSuperfluidHost,
    SharedMockFlow,
    SharedMockStakeVault,
    SharedMockSuperToken,
    SharedMockUnderlying
} from "test/goals/helpers/TreasurySharedMocks.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";
import { TreasurySuccessAssertions } from "src/goals/library/TreasurySuccessAssertions.sol";

import { JBApprovalStatus } from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBRulesetApprovalHook } from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract GoalTreasuryTest is Test {
    uint256 internal constant PROJECT_ID = 9001;
    bytes32 internal constant ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");
    bytes32 internal constant SUCCESS_ASSERTION_RESOLUTION_FAIL_CLOSED_EVENT =
        keccak256("SuccessAssertionResolutionFailClosed(bytes32,uint8)");
    struct HookSplitMatrixCase {
        bool useUnderlyingSource;
        IGoalTreasury.GoalState state;
        bool mintingOpen;
        bool zeroSourceAmount;
    }

    event FlowRateSyncManualInterventionRequired(
        address indexed flow, int96 targetRate, int96 fallbackRate, int96 currentRate
    );
    event FlowRateSyncCallFailed(address indexed flow, bytes4 indexed selector, int96 attemptedRate, bytes reason);
    event SuccessAssertionResolutionFailClosed(bytes32 indexed assertionId, uint8 indexed reason);

    address internal owner = address(0xA11CE);
    address internal hook;
    address internal outsider = address(0xBEEF);
    address internal donor = address(0xD0D0);

    SharedMockUnderlying internal underlyingToken;
    SharedMockSuperToken internal superToken;
    SharedMockFlow internal flow;
    SharedMockStakeVault internal stakeVault;
    TreasuryMockRulesets internal rulesets;
    TreasuryMockDirectory internal directory;
    TreasuryMockTokens internal controllerTokens;
    TreasuryMockController internal controller;
    TreasuryMockHook internal hookAdapter;
    TreasuryMockOptimisticOracleV3 internal assertionOracle;
    TreasuryMockUmaResolverConfig internal successResolverConfig;
    GoalTreasury internal treasury;

    function setUp() public {
        underlyingToken = new SharedMockUnderlying();
        assertionOracle = new TreasuryMockOptimisticOracleV3();
        successResolverConfig = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            address(0),
            keccak256("goal-test-domain")
        );
        owner = address(successResolverConfig);
        superToken = new SharedMockSuperToken(address(underlyingToken));
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(0);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));
        flow = new SharedMockFlow(ISuperToken(address(superToken)));
        flow.setMaxSafeFlowRate(type(int96).max);
        stakeVault = new SharedMockStakeVault();
        stakeVault.setGoalToken(IERC20(address(underlyingToken)));
        rulesets = new TreasuryMockRulesets();
        rulesets.configureTwoRulesetSchedule(PROJECT_ID, uint48(block.timestamp + 30 days), 1e18);
        rulesets.setWeight(PROJECT_ID, 1e18);
        directory = new TreasuryMockDirectory();
        controllerTokens = new TreasuryMockTokens();
        controller = new TreasuryMockController(controllerTokens);
        directory.setController(PROJECT_ID, address(controller));
        controllerTokens.setProjectIdOf(address(underlyingToken), PROJECT_ID);
        hookAdapter = new TreasuryMockHook(directory);
        hook = address(hookAdapter);

        treasury = _deploy(uint64(block.timestamp + 3 days), 100e18);
    }

    function test_authority_returnsInitialOwner() public view {
        assertEq(treasury.authority(), owner);
    }

    function test_configureJurorSlasher_revertsWhenCallerNotAuthority() public {
        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_AUTHORITY.selector);
        treasury.configureJurorSlasher(makeAddr("slasher"));
    }

    function test_configureJurorSlasher_setsStakeVaultSlasher() public {
        address slasher = makeAddr("slasher");
        vm.prank(owner);
        treasury.configureJurorSlasher(slasher);
        assertEq(stakeVault.jurorSlasher(), slasher);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IGoalTreasury.ADDRESS_ZERO.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(0),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_setsCobuildRevnetIdZeroWhenCobuildTokenUnconfigured() public view {
        assertEq(treasury.goalRevnetId(), PROJECT_ID);
        assertEq(treasury.cobuildRevnetId(), 0);
    }

    function test_constructor_revertsWhenSuperTokenUnderlyingDiffersFromStakeVaultGoalToken() public {
        SharedMockUnderlying foreignUnderlying = new SharedMockUnderlying();
        SharedMockSuperToken foreignSuperToken = new SharedMockSuperToken(address(foreignUnderlying));
        SharedMockFlow foreignFlow = new SharedMockFlow(ISuperToken(address(foreignSuperToken)));
        foreignFlow.setMaxSafeFlowRate(type(int96).max);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        foreignFlow.setFlowOperator(predicted);
        foreignFlow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH.selector,
                address(underlyingToken),
                address(foreignUnderlying)
            )
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(foreignFlow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenGoalTokenMapsToDifferentRevnetId() public {
        uint256 foreignProjectId = PROJECT_ID + 1;
        controllerTokens.setProjectIdOf(address(underlyingToken), foreignProjectId);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.GOAL_TOKEN_REVNET_MISMATCH.selector,
                address(underlyingToken),
                PROJECT_ID,
                foreignProjectId
            )
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenGoalControllerMissingWithoutCobuildToken() public {
        directory.setController(PROJECT_ID, address(0));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_REVNET_CONTROLLER.selector, address(0)));
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenGoalDirectoryNotDerivable() public {
        TreasuryMockHook zeroDirectoryHook = new TreasuryMockHook(TreasuryMockDirectory(address(0)));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE.selector, address(underlyingToken))
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: address(zeroDirectoryHook),
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenCobuildTokenConfiguredAndGoalControllerMissing() public {
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));
        directory.setController(PROJECT_ID, address(0));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_REVNET_CONTROLLER.selector, address(0)));
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_initialize_clone_success_andBlocksReinitialize() public {
        GoalTreasury implementation = new GoalTreasury(
            address(0),
            IGoalTreasury.GoalConfig({
                flow: address(0),
                stakeVault: address(0),
                rewardEscrow: address(0),
                hook: address(0),
                goalRulesets: address(0),
                goalRevnetId: 0,
                minRaiseDeadline: 0,
                minRaise: 0,
                successSettlementRewardEscrowPpm: 0,
                successResolver: address(0),
                successAssertionLiveness: 0,
                successAssertionBond: 0,
                successOracleSpecHash: bytes32(0),
                successAssertionPolicyHash: bytes32(0)
            })
        );
        GoalTreasury clone = GoalTreasury(payable(Clones.clone(address(implementation))));
        stakeVault.setGoalTreasury(address(clone));
        flow.setFlowOperator(address(clone));
        flow.setSweeper(address(clone));

        IGoalTreasury.GoalConfig memory config = IGoalTreasury.GoalConfig({
            flow: address(flow),
            stakeVault: address(stakeVault),
            rewardEscrow: address(0),
            hook: hook,
            goalRulesets: address(rulesets),
            goalRevnetId: PROJECT_ID,
            minRaiseDeadline: uint64(block.timestamp + 3 days),
            minRaise: 100e18,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
        });

        clone.initialize(owner, config);

        assertEq(clone.flow(), address(flow));
        assertEq(clone.stakeVault(), address(stakeVault));
        assertEq(clone.rewardEscrow(), address(0));
        assertEq(clone.hook(), hook);
        assertEq(clone.authority(), owner);
        assertEq(clone.goalRevnetId(), PROJECT_ID);
        assertEq(clone.minRaise(), 100e18);

        address cloneSlasher = makeAddr("clone-slasher");
        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_AUTHORITY.selector);
        clone.configureJurorSlasher(cloneSlasher);

        vm.prank(owner);
        clone.configureJurorSlasher(cloneSlasher);
        assertEq(stakeVault.jurorSlasher(), cloneSlasher);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(owner, config);
    }

    function test_initialize_clone_revertsWhenFlowAuthorityNotDelegatedToTreasury() public {
        GoalTreasury implementation = new GoalTreasury(
            address(0),
            IGoalTreasury.GoalConfig({
                flow: address(0),
                stakeVault: address(0),
                rewardEscrow: address(0),
                hook: address(0),
                goalRulesets: address(0),
                goalRevnetId: 0,
                minRaiseDeadline: 0,
                minRaise: 0,
                successSettlementRewardEscrowPpm: 0,
                successResolver: address(0),
                successAssertionLiveness: 0,
                successAssertionBond: 0,
                successOracleSpecHash: bytes32(0),
                successAssertionPolicyHash: bytes32(0)
            })
        );
        GoalTreasury clone = GoalTreasury(payable(Clones.clone(address(implementation))));
        stakeVault.setGoalTreasury(address(clone));
        flow.setFlowOperator(address(0xBEEF));
        flow.setSweeper(address(0xCAFE));

        IGoalTreasury.GoalConfig memory config = IGoalTreasury.GoalConfig({
            flow: address(flow),
            stakeVault: address(stakeVault),
            rewardEscrow: address(0),
            hook: hook,
            goalRulesets: address(rulesets),
            goalRevnetId: PROJECT_ID,
            minRaiseDeadline: uint64(block.timestamp + 3 days),
            minRaise: 100e18,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.FLOW_AUTHORITY_MISMATCH.selector, address(clone), address(0xBEEF), address(0xCAFE)
            )
        );
        clone.initialize(owner, config);
    }

    function test_initialize_clone_revertsWhenCobuildProjectUnset() public {
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));

        GoalTreasury implementation = new GoalTreasury(
            address(0),
            IGoalTreasury.GoalConfig({
                flow: address(0),
                stakeVault: address(0),
                rewardEscrow: address(0),
                hook: address(0),
                goalRulesets: address(0),
                goalRevnetId: 0,
                minRaiseDeadline: 0,
                minRaise: 0,
                successSettlementRewardEscrowPpm: 0,
                successResolver: address(0),
                successAssertionLiveness: 0,
                successAssertionBond: 0,
                successOracleSpecHash: bytes32(0),
                successAssertionPolicyHash: bytes32(0)
            })
        );
        GoalTreasury clone = GoalTreasury(payable(Clones.clone(address(implementation))));
        stakeVault.setGoalTreasury(address(clone));
        flow.setFlowOperator(address(clone));
        flow.setSweeper(address(clone));

        IGoalTreasury.GoalConfig memory config = IGoalTreasury.GoalConfig({
            flow: address(flow),
            stakeVault: address(stakeVault),
            rewardEscrow: address(0),
            hook: hook,
            goalRulesets: address(rulesets),
            goalRevnetId: PROJECT_ID,
            minRaiseDeadline: uint64(block.timestamp + 3 days),
            minRaise: 100e18,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
        });

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE.selector, address(cobuildUnderlying))
        );
        clone.initialize(owner, config);
    }

    function test_initialize_clone_revertsWhenDerivedCobuildProjectControllerMissing() public {
        uint256 cobuildProjectId = PROJECT_ID + 1;
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));
        controllerTokens.setProjectIdOf(address(cobuildUnderlying), cobuildProjectId);

        GoalTreasury implementation = new GoalTreasury(
            address(0),
            IGoalTreasury.GoalConfig({
                flow: address(0),
                stakeVault: address(0),
                rewardEscrow: address(0),
                hook: address(0),
                goalRulesets: address(0),
                goalRevnetId: 0,
                minRaiseDeadline: 0,
                minRaise: 0,
                successSettlementRewardEscrowPpm: 0,
                successResolver: address(0),
                successAssertionLiveness: 0,
                successAssertionBond: 0,
                successOracleSpecHash: bytes32(0),
                successAssertionPolicyHash: bytes32(0)
            })
        );
        GoalTreasury clone = GoalTreasury(payable(Clones.clone(address(implementation))));
        stakeVault.setGoalTreasury(address(clone));
        flow.setFlowOperator(address(clone));
        flow.setSweeper(address(clone));

        IGoalTreasury.GoalConfig memory config = IGoalTreasury.GoalConfig({
            flow: address(flow),
            stakeVault: address(stakeVault),
            rewardEscrow: address(0),
            hook: hook,
            goalRulesets: address(rulesets),
            goalRevnetId: PROJECT_ID,
            minRaiseDeadline: uint64(block.timestamp + 3 days),
            minRaise: 100e18,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
        });

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE.selector, address(cobuildUnderlying))
        );
        clone.initialize(owner, config);
    }

    function test_constructor_revertsOnZeroOwner() public {
        stakeVault.setGoalTreasury(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vm.expectRevert(IGoalTreasury.ADDRESS_ZERO.selector);
        new GoalTreasury(
            address(0),
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsOnZeroStakeVault() public {
        vm.expectRevert(IGoalTreasury.ADDRESS_ZERO.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(0),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsOnZeroHook() public {
        vm.expectRevert(IGoalTreasury.ADDRESS_ZERO.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: address(0),
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsOnZeroRulesets() public {
        vm.expectRevert(IGoalTreasury.ADDRESS_ZERO.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(0),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenFlowSuperTokenIsZero() public {
        flow.setReturnZeroSuperToken(true);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);

        vm.expectRevert(IGoalTreasury.ADDRESS_ZERO.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenFlowAuthorityNotDelegatedToTreasury() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(address(0xBEEF));
        flow.setSweeper(address(0xCAFE));

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.FLOW_AUTHORITY_MISMATCH.selector, predicted, address(0xBEEF), address(0xCAFE)
            )
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 1,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenDeadlineNotDerivable_missingQueuedRuleset() public {
        TreasuryMockRulesets emptyRulesets = new TreasuryMockRulesets();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);

        vm.expectRevert(IGoalTreasury.DEADLINE_NOT_DERIVABLE.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(emptyRulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenDeadlineNotDerivable_badApprovalStatus() public {
        rulesets.setApprovalStatus(PROJECT_ID, JBApprovalStatus.Failed);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);

        vm.expectRevert(IGoalTreasury.DEADLINE_NOT_DERIVABLE.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenDeadlineNotDerivable_badBaseRuleset() public {
        rulesets.setBaseRuleset(PROJECT_ID, 1, 1, uint48(block.timestamp), 1e18);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);

        vm.expectRevert(IGoalTreasury.DEADLINE_NOT_DERIVABLE.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 1 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsOnInvalidDeadlines() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);
        vm.expectRevert(IGoalTreasury.INVALID_DEADLINES.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 31 days),
                minRaise: 1,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsOnStakeVaultGoalMismatch() public {
        stakeVault.setGoalTreasury(address(0xDEAD));

        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.STAKE_VAULT_GOAL_MISMATCH.selector, expected, address(0xDEAD))
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
            successSettlementRewardEscrowPpm: 0,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenRewardEscrowSuperTokenMismatch() public {
        SharedMockUnderlying otherUnderlying = new SharedMockUnderlying();
        SharedMockSuperToken otherSuperToken = new SharedMockSuperToken(address(otherUnderlying));
        TreasuryMockRewardEscrowSuperToken rewardEscrow =
            new TreasuryMockRewardEscrowSuperToken(ISuperToken(address(otherSuperToken)));

        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(expected);
        flow.setFlowOperator(expected);
        flow.setSweeper(expected);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.REWARD_ESCROW_SUPER_TOKEN_MISMATCH.selector,
                address(superToken),
                address(otherSuperToken)
            )
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(rewardEscrow),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_recordHookFunding_onlyHook() public {
        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_HOOK.selector);
        treasury.recordHookFunding(1e18);
    }

    function test_recordHookFunding_returnsFalseOnZeroAmount() public {
        vm.prank(hook);
        assertFalse(treasury.recordHookFunding(0));
        assertEq(treasury.totalRaised(), 0);
    }

    function test_processHookSplit_onlyHook() public {
        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_HOOK.selector);
        treasury.processHookSplit(address(superToken), 1e18);
    }

    function test_processHookSplit_returnsDeferredOnZeroAmount() public {
        vm.prank(hook);
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), 0);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.Deferred));
        assertEq(superTokenAmount, 0);
        assertEq(rewardAmount, 0);
        assertEq(burnAmount, 0);
        assertEq(treasury.deferredHookSuperTokenAmount(), 0);
        assertEq(treasury.totalRaised(), 0);
    }

    function test_processHookSplit_revertsOnInvalidSourceTokenEvenWhenAmountIsZero() public {
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_HOOK_SOURCE_TOKEN.selector, outsider));
        treasury.processHookSplit(outsider, 0);
    }

    function test_processHookSplit_revertsOnInvalidSourceToken() public {
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_HOOK_SOURCE_TOKEN.selector, outsider));
        treasury.processHookSplit(outsider, 1e18);
    }

    function test_processHookSplit_revertsWhenSourceTokenIsSuperToken() public {
        uint256 amount = 5e18;

        vm.prank(hook);
        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.INVALID_HOOK_SOURCE_TOKEN.selector, address(superToken))
        );
        treasury.processHookSplit(address(superToken), amount);
    }

    function test_processHookSplit_revertsWhenInsufficientHeldUnderlyingBalance() public {
        vm.warp(treasury.minRaiseDeadline() + 1);
        uint256 amount = 7e18;

        vm.prank(hook);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalTreasury.INSUFFICIENT_TREASURY_BALANCE.selector, address(underlyingToken), amount, uint256(0)
            )
        );
        treasury.processHookSplit(address(underlyingToken), amount);
    }

    function test_processHookSplit_fundsWhenGoalCanStillAcceptFunding() public {
        uint256 amount = 42e18;
        underlyingToken.mint(address(treasury), amount);
        uint256 flowBalanceBefore = superToken.balanceOf(address(flow));

        vm.prank(hook);
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), amount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.Funded));
        assertEq(superTokenAmount, amount);
        assertEq(rewardAmount, 0);
        assertEq(burnAmount, 0);
        assertEq(superToken.balanceOf(address(flow)), flowBalanceBefore + amount);
        assertEq(treasury.totalRaised(), amount);
        assertEq(treasury.deferredHookSuperTokenAmount(), 0);
    }

    function test_processHookSplit_defersWhenGoalCannotAcceptYetNotTerminal() public {
        vm.warp(treasury.minRaiseDeadline() + 1);
        uint256 amount = 19e18;
        underlyingToken.mint(address(treasury), amount);

        vm.prank(hook);
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), amount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.Deferred));
        assertEq(superTokenAmount, amount);
        assertEq(rewardAmount, 0);
        assertEq(burnAmount, 0);
        assertEq(treasury.deferredHookSuperTokenAmount(), amount);
        assertEq(treasury.totalRaised(), 0);
    }

    function test_processHookSplit_defersWhenActivePastDeadlineBeforeSync() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));

        vm.warp(treasury.deadline());

        uint256 amount = 13e18;
        underlyingToken.mint(address(treasury), amount);
        uint256 totalRaisedBefore = treasury.totalRaised();
        uint256 deferredBefore = treasury.deferredHookSuperTokenAmount();
        uint256 burnCallCountBefore = controller.burnCallCount();

        vm.prank(hook);
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), amount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.Deferred));
        assertEq(superTokenAmount, amount);
        assertEq(rewardAmount, 0);
        assertEq(burnAmount, 0);
        assertEq(treasury.totalRaised(), totalRaisedBefore);
        assertEq(treasury.deferredHookSuperTokenAmount(), deferredBefore + amount);
        assertEq(controller.burnCallCount(), burnCallCountBefore);
    }

    function test_processHookSplit_successSettlementSplitsToRewardEscrowAndBurn() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 250_000);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();
        vm.warp(block.timestamp + 7 days);

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        uint256 amount = 40e18;
        uint256 expectedReward = 10e18;
        uint256 expectedBurn = 30e18;
        uint256 burnCallCountBefore = controller.burnCallCount();
        uint256 rewardEscrowUnderlyingBefore = underlyingToken.balanceOf(address(rewardEscrow));
        underlyingToken.mint(address(rewardTreasury), amount);

        vm.prank(hook);
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount) =
            rewardTreasury.processHookSplit(address(underlyingToken), amount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.SuccessSettled));
        assertEq(superTokenAmount, 0);
        assertEq(rewardAmount, expectedReward);
        assertEq(burnAmount, expectedBurn);
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)), rewardEscrowUnderlyingBefore + expectedReward);
        assertEq(controller.burnCallCount(), burnCallCountBefore + 1);
        assertEq(controller.lastBurnAmount(), expectedBurn);
        assertEq(controller.lastBurnMemo(), "GOAL_SUCCESS_SETTLEMENT_BURN");
    }

    function test_processHookSplit_successSettlement_revertsWhenSourceTokenIsSuperToken() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 250_000);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();
        vm.warp(block.timestamp + 7 days);

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        uint256 amount = 40e18;
        uint256 burnCallCountBefore = controller.burnCallCount();
        uint256 rewardEscrowSuperBefore = superToken.balanceOf(address(rewardEscrow));
        uint256 rewardEscrowUnderlyingBefore = underlyingToken.balanceOf(address(rewardEscrow));
        superToken.mint(address(rewardTreasury), amount);

        vm.prank(hook);
        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.INVALID_HOOK_SOURCE_TOKEN.selector, address(superToken))
        );
        rewardTreasury.processHookSplit(address(superToken), amount);

        assertEq(superToken.balanceOf(address(rewardEscrow)), rewardEscrowSuperBefore);
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)), rewardEscrowUnderlyingBefore);
        assertEq(controller.burnCallCount(), burnCallCountBefore);
    }

    function test_processHookSplit_terminalSettlementConvertsThenBurnsWhenExpired() public {
        _expireFromFundingViaSync(treasury);

        uint256 amount = 23e18;
        uint256 burnCallCountBefore = controller.burnCallCount();
        underlyingToken.mint(address(treasury), amount);

        vm.prank(hook);
        (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount) =
            treasury.processHookSplit(address(underlyingToken), amount);

        assertEq(uint256(action), uint256(IGoalTreasury.HookSplitAction.TerminalSettled));
        assertEq(superTokenAmount, amount);
        assertEq(rewardAmount, 0);
        assertEq(burnAmount, amount);
        assertEq(controller.burnCallCount(), burnCallCountBefore + 1);
        assertEq(controller.lastBurnAmount(), amount);
        assertEq(controller.lastBurnMemo(), "GOAL_TERMINAL_RESIDUAL_BURN");
        assertEq(treasury.deferredHookSuperTokenAmount(), 0);
    }

    function test_processHookSplit_matrix_tokenStateMintingAndSourceAmount() public {
        for (uint256 tokenIdx; tokenIdx < 2; ++tokenIdx) {
            bool useUnderlyingSource = tokenIdx == 1;
            for (uint256 stateIdx; stateIdx < 4; ++stateIdx) {
                IGoalTreasury.GoalState state = IGoalTreasury.GoalState(stateIdx);
                for (uint256 mintingIdx; mintingIdx < 2; ++mintingIdx) {
                    bool mintingOpen = mintingIdx == 1;
                    for (uint256 amountIdx; amountIdx < 2; ++amountIdx) {
                        bool zeroSourceAmount = amountIdx == 0;
                        uint256 snapshot = vm.snapshotState();
                        HookSplitMatrixCase memory matrixCase = HookSplitMatrixCase({
                            useUnderlyingSource: useUnderlyingSource,
                            state: state,
                            mintingOpen: mintingOpen,
                            zeroSourceAmount: zeroSourceAmount
                        });
                        _runHookSplitMatrixCase(matrixCase);
                        vm.revertToState(snapshot);
                    }
                }
            }
        }
    }

    function test_donateUnderlyingAndUpgrade_updatesFlowBalanceAndTotalRaised() public {
        underlyingToken.mint(donor, 40e18);

        vm.startPrank(donor);
        underlyingToken.approve(address(treasury), type(uint256).max);
        uint256 received = treasury.donateUnderlyingAndUpgrade(40e18);
        vm.stopPrank();

        assertEq(received, 40e18);
        assertEq(superToken.balanceOf(address(flow)), 40e18);
        assertEq(treasury.totalRaised(), 40e18);
        assertEq(superToken.balanceOf(address(treasury)), 0);
    }

    function test_donateUnderlyingAndUpgrade_revertsWhenFundingNoLongerAccepted() public {
        vm.warp(treasury.minRaiseDeadline() + 1);

        underlyingToken.mint(donor, 10e18);
        vm.prank(donor);
        underlyingToken.approve(address(treasury), type(uint256).max);

        vm.prank(donor);
        vm.expectRevert(IGoalTreasury.INVALID_STATE.selector);
        treasury.donateUnderlyingAndUpgrade(10e18);
    }

    function test_recordHookFunding_returnsFalseWhenGoalAlreadyResolved() public {
        _expireFromFundingViaSync(treasury);

        vm.prank(hook);
        assertFalse(treasury.recordHookFunding(10e18));
        assertEq(treasury.totalRaised(), 0);
    }

    function test_rewardEscrow_getterDefaultsToZero_whenUnconfigured() public view {
        assertEq(treasury.rewardEscrow(), address(0));
    }

    function test_recordHookFunding_acceptsWhenMintingClosedButBeforeDeadline() public {
        rulesets.setWeight(PROJECT_ID, 0);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(10e18));
        assertEq(treasury.totalRaised(), 10e18);
    }

    function test_recordHookFunding_revertsAtGoalDeadline() public {
        vm.warp(treasury.deadline());

        vm.prank(hook);
        vm.expectRevert(IGoalTreasury.GOAL_DEADLINE_PASSED.selector);
        treasury.recordHookFunding(10e18);
    }

    function test_recordHookFunding_returnsFalseAfterMinRaiseDeadlineWhenBelowMinRaise() public {
        vm.warp(treasury.minRaiseDeadline() + 1);

        vm.prank(hook);
        assertFalse(treasury.recordHookFunding(10e18));
        assertEq(treasury.totalRaised(), 0);
    }

    function test_sync_fundingBelowMinRaise_noopBeforeMinRaiseDeadline() public {
        superToken.mint(address(flow), 99e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(99e18));

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Funding));
        assertFalse(treasury.resolved());
    }

    function test_activate_usesFlowBalanceForMinRaise() public {
        superToken.mint(address(flow), 100e18);

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_sync_noOpWhenResolved() public {
        _expireFromFundingViaSync(treasury);

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_fromFunding_atDeadline_expires() public {
        vm.warp(treasury.deadline());

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_activate_success_setsActiveAndFlowRate() public {
        superToken.mint(address(flow), 300e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_activate_ignoresFlowMaxSafeRateCap() public {
        superToken.mint(address(flow), 2_000_000e18);
        flow.setMaxSafeFlowRate(1_000);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();
        assertGt(treasury.targetFlowRate(), 1_000);
        assertEq(flow.targetOutflowRate(), treasury.targetFlowRate());
    }

    function test_activate_ignoresZeroMaxSafeRateCap() public {
        superToken.mint(address(flow), 300e18);
        flow.setMaxSafeFlowRate(0);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(flow.targetOutflowRate(), 0);
        assertEq(flow.targetOutflowRate(), treasury.targetFlowRate());
    }

    function test_activate_ignoresNegativeMaxSafeRateCap() public {
        superToken.mint(address(flow), 300e18);
        flow.setMaxSafeFlowRate(-1);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(flow.targetOutflowRate(), 0);
        assertEq(flow.targetOutflowRate(), treasury.targetFlowRate());
    }

    function test_activate_failsClosedWhenHostDependencyMissing() public {
        superToken.setHost(address(0));
        superToken.mint(address(flow), 300e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(treasury.targetFlowRate(), 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_activate_fallsBackToZeroWhenTargetWriteRevertsWithoutBufferCap() public {
        superToken.mint(address(flow), 2_000_000e18);
        flow.setMaxSafeFlowRate(1_000);
        flow.setMaxSettableFlowRate(1_000);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(treasury.targetFlowRate(), 1_000);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_activate_fallsBackToBufferAffordableRateWhenTargetWriteReverts() public {
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        superToken.mint(address(flow), 100e18);
        flow.setMaxSafeFlowRate(type(int96).max);
        flow.setMaxSettableFlowRate(100);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();

        assertGt(treasury.targetFlowRate(), 100);
        assertEq(flow.targetOutflowRate(), 99);
    }

    function test_activate_linearSpendDown_appliesProactiveHorizonCapNearDeadline() public {
        GoalTreasury linearTreasury = _deploy(uint64(block.timestamp + 3 days), 1);
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(1);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        superToken.mint(address(flow), 1_000);
        vm.prank(hook);
        assertTrue(linearTreasury.recordHookFunding(1));

        vm.warp(linearTreasury.deadline() - 100);
        linearTreasury.sync();

        assertEq(uint256(linearTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(linearTreasury.targetFlowRate(), 10);
        assertEq(flow.targetOutflowRate(), 9);
    }

    function test_activate_linearSpendDown_capsBeforeFallbackWhenTargetExceedsBufferRate() public {
        GoalTreasury linearTreasury = _deploy(uint64(block.timestamp + 3 days), 1);
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(100);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        superToken.mint(address(flow), 1_000);
        flow.setMaxSettableFlowRate(9);
        vm.prank(hook);
        assertTrue(linearTreasury.recordHookFunding(1));

        vm.warp(linearTreasury.deadline() - 10);
        linearTreasury.sync();

        assertEq(uint256(linearTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(linearTreasury.targetFlowRate(), 100);
        assertEq(flow.targetOutflowRate(), 9);
        assertEq(flow.setFlowRateCallCount(), 1);
    }

    function test_sync_active_linearSpendDown_capsBeforeFallbackWhenTargetExceedsBufferRate() public {
        GoalTreasury linearTreasury = _deploy(uint64(block.timestamp + 3 days), 1);
        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(1);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        superToken.mint(address(flow), 1_000);
        vm.prank(hook);
        assertTrue(linearTreasury.recordHookFunding(1));

        vm.warp(linearTreasury.deadline() - 50);
        linearTreasury.sync();

        assertEq(uint256(linearTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(flow.targetOutflowRate(), 19);

        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();
        cfa.setDepositPerFlowRate(100);
        flow.setMaxSettableFlowRate(9);

        vm.warp(linearTreasury.deadline() - 10);
        linearTreasury.sync();

        assertEq(linearTreasury.targetFlowRate(), 100);
        assertEq(flow.targetOutflowRate(), 9);
        assertEq(flow.setFlowRateCallCount(), setFlowRateCallsBefore + 1);
    }

    function test_activate_keepsZeroRateWhenTargetWriteRevertsFromZeroBaseline() public {
        superToken.mint(address(flow), 300e18);
        flow.setShouldRevertSetFlowRate(true);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(flow.targetOutflowRate(), 0);
        assertEq(flow.setFlowRateCallCount(), 0);
    }

    function test_sync_fundingBelowMinRaise_isNoop() public {
        superToken.mint(address(flow), 10e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(10e18));

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Funding));
    }

    function test_sync_fundingAboveMinRaise_activates() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
    }

    function test_sync_fundingAboveMinRaise_activatesPermissionlessly() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        vm.prank(outsider);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_sync_fundingAtDeadline_expires() public {
        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_fundingAtDeadline_withMinRaiseReached_expires() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_sync_fundingAfterMinRaiseDeadlineBelowMin_expires() public {
        vm.warp(treasury.minRaiseDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_activeBeforeDeadline_updatesFlowRate() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();
        superToken.mint(address(flow), 400e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertGt(flow.setFlowRateCallCount(), setFlowRateCallsBefore);
    }

    function test_sync_activeNoRateChange_reappliesCachedTargetOutflow() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();
        treasury.sync();
        assertEq(flow.setFlowRateCallCount(), setFlowRateCallsBefore + 1);
    }

    function test_sync_activeNoRateChange_refreshFailure_reportsManualInterventionWithoutRevert() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        int96 flowRateBefore = flow.targetOutflowRate();

        flow.setShouldRevertSetFlowRate(true);
        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit FlowRateSyncManualInterventionRequired(address(flow), flowRateBefore, flowRateBefore, flowRateBefore);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(flow.setFlowRateCallCount(), setFlowRateCallsBefore);
    }

    function test_sync_active_fallsBackToZeroWhenTargetAndSafeWritesRevert() public {
        superToken.mint(address(flow), 2_000_000e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        assertGt(flow.targetOutflowRate(), 0);

        flow.setMaxSafeFlowRate(1_000);
        flow.setMaxSettableFlowRate(0);
        superToken.mint(address(flow), 1e18);

        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(flow.targetOutflowRate(), 0);
        assertEq(flow.setFlowRateCallCount(), setFlowRateCallsBefore + 1);
    }

    function test_sync_active_allWritesFailAndFlowIsNonZero_reportsManualInterventionWithoutRevert() public {
        superToken.mint(address(flow), 2_000_000e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        int96 flowRateBefore = flow.targetOutflowRate();
        assertGt(flowRateBefore, 0);

        flow.setShouldRevertSetFlowRate(true);
        superToken.mint(address(flow), 1e18);
        int96 expectedTargetRate = treasury.targetFlowRate();
        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit FlowRateSyncManualInterventionRequired(address(flow), expectedTargetRate, expectedTargetRate, flowRateBefore);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(flow.setFlowRateCallCount(), setFlowRateCallsBefore);
    }

    function test_sync_active_allWritesFailWithFlowCapHint_reportsManualInterventionUsingUncappedFallback() public {
        superToken.mint(address(flow), 2_000_000e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        int96 flowRateBefore = flow.targetOutflowRate();
        assertGt(flowRateBefore, 0);

        int96 cappedFallbackRate = 1_000;
        flow.setMaxSafeFlowRate(cappedFallbackRate);
        flow.setShouldRevertSetFlowRate(true);
        superToken.mint(address(flow), 1e18);
        int96 expectedTargetRate = treasury.targetFlowRate();
        assertGt(expectedTargetRate, cappedFallbackRate);
        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit FlowRateSyncManualInterventionRequired(address(flow), expectedTargetRate, expectedTargetRate, flowRateBefore);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertEq(flow.targetOutflowRate(), flowRateBefore);
        assertEq(flow.setFlowRateCallCount(), setFlowRateCallsBefore);
    }

    function test_sync_whenMintingClosesBeforeDeadline_doesNotExpire() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        rulesets.setWeight(PROJECT_ID, 0);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
        assertFalse(stakeVault.goalResolved());
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_sync_whenMintingStatusUnknown_doesNotAutoExpire() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        rulesets.setShouldRevertCurrent(true);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
    }

    function test_sync_activeWithPendingSuccessAssertion_beforeDeadline_updatesFlowRate() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);
        uint256 setFlowRateCallsBefore = flow.setFlowRateCallCount();

        superToken.mint(address(flow), 400e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
        assertGt(flow.setFlowRateCallCount(), setFlowRateCallsBefore);
        assertNotEq(treasury.pendingSuccessAssertionId(), bytes32(0));
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_setsFlowRateToZeroWithoutFinalizing() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        assertGt(flow.targetOutflowRate(), 0);

        _registerSuccessAssertion(treasury);
        _setPendingSuccessAssertion(treasury, false, false);
        bytes32 pendingAssertionId = treasury.pendingSuccessAssertionId();

        vm.warp(treasury.deadline());
        vm.recordLogs();
        treasury.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(flow.targetOutflowRate(), 0);
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), pendingAssertionId);
        assertEq(_countFailClosedResolutionEvents(logs, address(treasury)), 0);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledTruthful_finalizesSuccess() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);

        vm.warp(treasury.deadline());
        vm.recordLogs();
        treasury.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertEq(_countFailClosedResolutionEvents(logs, address(treasury)), 0);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_settledFalse_opensReassertGrace() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);
        _setPendingSuccessAssertion(treasury, true, false);

        vm.warp(treasury.deadline());
        vm.recordLogs();
        treasury.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertTrue(treasury.reassertGraceUsed());
        assertGt(treasury.reassertGraceDeadline(), block.timestamp);
        assertEq(_countFailClosedResolutionEvents(logs, address(treasury)), 0);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_opensReassertGraceWhenResolverConfigOracleReadReverts(
    ) public {
        TreasuryMockUmaResolverConfigRevertingOracle resolverConfig = new TreasuryMockUmaResolverConfigRevertingOracle();
        GoalTreasury resolverFailTreasury =
            _deployWithSuccessResolver(uint64(block.timestamp + 3 days), 100e18, address(0), 0, address(resolverConfig));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(resolverFailTreasury.recordHookFunding(100e18));
        resolverFailTreasury.sync();

        bytes32 assertionId = keccak256("resolver-config-read-revert");
        vm.prank(address(resolverConfig));
        resolverFailTreasury.registerSuccessAssertion(assertionId);

        vm.warp(resolverFailTreasury.deadline());
        vm.expectEmit(true, true, false, false, address(resolverFailTreasury));
        emit SuccessAssertionResolutionFailClosed(
            assertionId, uint8(TreasurySuccessAssertions.FailClosedReason.ResolverConfigOracleReadFailed)
        );
        resolverFailTreasury.sync();

        assertEq(uint256(resolverFailTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(resolverFailTreasury.resolved());
        assertEq(resolverFailTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(resolverFailTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(resolverFailTreasury.reassertGraceUsed());
        assertGt(resolverFailTreasury.reassertGraceDeadline(), block.timestamp);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_opensReassertGraceWhenResolverConfigOracleIsZero(
    ) public {
        TreasuryMockUmaResolverConfigZeroOracle resolverConfig = new TreasuryMockUmaResolverConfigZeroOracle();
        GoalTreasury zeroOracleTreasury =
            _deployWithSuccessResolver(uint64(block.timestamp + 3 days), 100e18, address(0), 0, address(resolverConfig));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(zeroOracleTreasury.recordHookFunding(100e18));
        zeroOracleTreasury.sync();

        bytes32 assertionId = keccak256("resolver-config-zero-oracle");
        vm.prank(address(resolverConfig));
        zeroOracleTreasury.registerSuccessAssertion(assertionId);

        vm.warp(zeroOracleTreasury.deadline());
        vm.expectEmit(true, true, false, false, address(zeroOracleTreasury));
        emit SuccessAssertionResolutionFailClosed(
            assertionId, uint8(TreasurySuccessAssertions.FailClosedReason.OracleAddressZero)
        );
        zeroOracleTreasury.sync();

        assertEq(uint256(zeroOracleTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(zeroOracleTreasury.resolved());
        assertEq(zeroOracleTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(zeroOracleTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(zeroOracleTreasury.reassertGraceUsed());
        assertGt(zeroOracleTreasury.reassertGraceDeadline(), block.timestamp);
    }

    function test_sync_activeWithPendingSuccessAssertion_atDeadline_opensReassertGraceWhenOracleGetAssertionReverts(
    ) public {
        TreasuryMockOptimisticOracleV3RevertingGetAssertion revertingOracle =
            new TreasuryMockOptimisticOracleV3RevertingGetAssertion();
        TreasuryMockUmaResolverConfig resolverConfig = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(revertingOracle)),
            IERC20(address(underlyingToken)),
            address(0),
            keccak256("goal-get-assertion-revert-domain")
        );
        GoalTreasury oracleReadFailTreasury =
            _deployWithSuccessResolver(uint64(block.timestamp + 3 days), 100e18, address(0), 0, address(resolverConfig));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(oracleReadFailTreasury.recordHookFunding(100e18));
        oracleReadFailTreasury.sync();
        assertGt(flow.targetOutflowRate(), 0);

        bytes32 assertionId = keccak256("goal-oracle-get-assertion-revert");
        vm.prank(address(resolverConfig));
        oracleReadFailTreasury.registerSuccessAssertion(assertionId);

        vm.warp(oracleReadFailTreasury.deadline());
        vm.expectEmit(true, true, false, false, address(oracleReadFailTreasury));
        emit SuccessAssertionResolutionFailClosed(
            assertionId, uint8(TreasurySuccessAssertions.FailClosedReason.OracleAssertionReadFailed)
        );
        oracleReadFailTreasury.sync();

        assertEq(flow.targetOutflowRate(), 0);
        assertEq(uint256(oracleReadFailTreasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(oracleReadFailTreasury.resolved());
        assertEq(oracleReadFailTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(oracleReadFailTreasury.pendingSuccessAssertionAt(), 0);
        assertTrue(oracleReadFailTreasury.reassertGraceUsed());
        assertGt(oracleReadFailTreasury.reassertGraceDeadline(), block.timestamp);
    }

    function test_registerSuccessAssertion_onlySuccessResolver() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.registerSuccessAssertion(keccak256("goal-assertion"));
    }

    function test_registerSuccessAssertion_revertsOnZeroAssertionId() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.INVALID_ASSERTION_ID.selector);
        treasury.registerSuccessAssertion(bytes32(0));
    }

    function test_registerSuccessAssertion_revertsWhenAssertionAlreadyPending() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        bytes32 assertionId = keccak256("goal-first-assertion");
        vm.prank(owner);
        treasury.registerSuccessAssertion(assertionId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.SUCCESS_ASSERTION_ALREADY_PENDING.selector, assertionId));
        treasury.registerSuccessAssertion(keccak256("goal-second-assertion"));
    }

    function test_registerSuccessAssertion_afterDeadline_revertsWithoutReassertGrace() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        vm.warp(treasury.deadline());
        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.GOAL_DEADLINE_PASSED.selector);
        treasury.registerSuccessAssertion(keccak256("goal-after-deadline"));
    }

    function test_isReassertGraceActive_trueDuringGrace_falseAfterConsume() public {
        _openReassertGraceWindow(treasury);
        assertTrue(treasury.isReassertGraceActive());

        vm.prank(owner);
        treasury.registerSuccessAssertion(keccak256("goal-reassertion-active-getter"));

        assertFalse(treasury.isReassertGraceActive());
    }

    function test_isReassertGraceActive_falseAfterGraceDeadline() public {
        uint64 graceDeadline = _openReassertGraceWindow(treasury);
        vm.warp(graceDeadline);

        assertFalse(treasury.isReassertGraceActive());
    }

    function test_registerSuccessAssertion_afterDeadline_allowsSingleReassertDuringGrace() public {
        _openReassertGraceWindow(treasury);

        bytes32 reassertionId = keccak256("goal-reassertion-id");
        vm.prank(owner);
        treasury.registerSuccessAssertion(reassertionId);

        assertEq(treasury.pendingSuccessAssertionId(), reassertionId);
        assertEq(treasury.reassertGraceDeadline(), 0);
        assertTrue(treasury.reassertGraceUsed());

        vm.prank(owner);
        treasury.clearSuccessAssertion(reassertionId);
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));

        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.GOAL_DEADLINE_PASSED.selector);
        treasury.registerSuccessAssertion(keccak256("goal-reassertion-2"));
    }

    function test_clearSuccessAssertion_afterDeadline_activatesReassertGrace() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);
        bytes32 assertionId = treasury.pendingSuccessAssertionId();

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.clearSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
        assertTrue(treasury.reassertGraceUsed());
        assertEq(treasury.reassertGraceDeadline(), uint64(block.timestamp + 1 days));
    }

    function test_sync_afterReassertGraceExpiresWithoutPendingAssertion_expires() public {
        uint64 graceDeadline = _openReassertGraceWindow(treasury);

        vm.warp(graceDeadline);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_sync_afterGraceReassert_settledFalse_expiresWithoutSecondGrace() public {
        _openReassertGraceWindow(treasury);

        bytes32 reassertionId = keccak256("goal-reassertion-settled-false");
        vm.prank(owner);
        treasury.registerSuccessAssertion(reassertionId);
        _setPendingSuccessAssertion(treasury, true, false);

        vm.warp(block.timestamp + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.reassertGraceDeadline(), 0);
    }

    function test_clearSuccessAssertion_onlySuccessResolver() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.clearSuccessAssertion(assertionId);
    }

    function test_clearSuccessAssertion_revertsWhenNoPendingAssertion() public {
        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.SUCCESS_ASSERTION_NOT_PENDING.selector);
        treasury.clearSuccessAssertion(keccak256("goal-no-pending"));
    }

    function test_clearSuccessAssertion_revertsOnAssertionIdMismatch() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        bytes32 wrongAssertionId = keccak256("goal-wrong-assertion-id");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.SUCCESS_ASSERTION_ID_MISMATCH.selector, assertionId, wrongAssertionId)
        );
        treasury.clearSuccessAssertion(wrongAssertionId);
    }

    function test_registerAndClearSuccessAssertion_emitsEventsAndResetsPendingState() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        bytes32 assertionId = keccak256("goal-register-clear");

        vm.expectEmit(true, true, false, false, address(treasury));
        emit IGoalTreasury.SuccessAssertionRegistered(assertionId, uint64(block.timestamp));
        vm.prank(owner);
        treasury.registerSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), assertionId);
        assertEq(treasury.pendingSuccessAssertionAt(), uint64(block.timestamp));

        vm.expectEmit(true, false, false, false, address(treasury));
        emit IGoalTreasury.SuccessAssertionCleared(assertionId);
        vm.prank(owner);
        treasury.clearSuccessAssertion(assertionId);

        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
    }

    function test_resolveSuccess_succeedsEvenWhenMintingClosedBeforeDeadline() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        rulesets.setWeight(PROJECT_ID, 0);
        _registerSuccessAssertion(treasury);
        vm.prank(owner);
        treasury.resolveSuccess();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(treasury.pendingSuccessAssertionAt(), 0);
    }

    function test_resolveSuccess_onlySuccessResolver() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        _registerSuccessAssertion(treasury);

        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_revertsOnlySuccessResolverBeforeAssertionVerification() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        _registerSuccessAssertion(treasury);
        _setPendingSuccessAssertion(treasury, false, true);

        vm.prank(outsider);
        vm.expectRevert(IGoalTreasury.ONLY_SUCCESS_RESOLVER.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_succeedsForConfiguredResolverWhenAuthorityDiffers() public {
        TreasuryMockUmaResolverConfig alternateResolver = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            address(0),
            keccak256("goal-alt-resolver-domain")
        );
        GoalTreasury splitAuthorityTreasury =
            _deployWithSuccessResolver(uint64(block.timestamp + 3 days), 100e18, address(0), 0, address(alternateResolver));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(splitAuthorityTreasury.recordHookFunding(100e18));
        splitAuthorityTreasury.sync();

        bytes32 assertionId = keccak256("goal-alt-resolver-success");
        vm.prank(address(alternateResolver));
        splitAuthorityTreasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = splitAuthorityTreasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: address(alternateResolver),
                    escalationManager: alternateResolver.escalationManager()
                }),
                asserter: address(alternateResolver),
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + splitAuthorityTreasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: alternateResolver.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: splitAuthorityTreasury.successAssertionBond(),
                callbackRecipient: address(alternateResolver),
                disputer: address(0)
            })
        );

        vm.prank(address(alternateResolver));
        splitAuthorityTreasury.resolveSuccess();

        assertEq(uint256(splitAuthorityTreasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(splitAuthorityTreasury.resolved());
        assertEq(splitAuthorityTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(splitAuthorityTreasury.pendingSuccessAssertionAt(), 0);
    }

    function test_resolveSuccess_revertsOnlySuccessResolverBeforeAssertionVerification_whenCallerIsAuthority() public {
        TreasuryMockUmaResolverConfig alternateResolver = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(assertionOracle)),
            IERC20(address(underlyingToken)),
            address(0),
            keccak256("goal-alt-resolver-ordering-domain")
        );
        GoalTreasury splitAuthorityTreasury =
            _deployWithSuccessResolver(uint64(block.timestamp + 3 days), 100e18, address(0), 0, address(alternateResolver));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(splitAuthorityTreasury.recordHookFunding(100e18));
        splitAuthorityTreasury.sync();

        bytes32 assertionId = keccak256("goal-alt-resolver-ordering");
        vm.prank(address(alternateResolver));
        splitAuthorityTreasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = splitAuthorityTreasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: address(alternateResolver),
                    escalationManager: alternateResolver.escalationManager()
                }),
                asserter: address(alternateResolver),
                assertionTime: assertedAt,
                settled: false,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + splitAuthorityTreasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: alternateResolver.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: splitAuthorityTreasury.successAssertionBond(),
                callbackRecipient: address(alternateResolver),
                disputer: address(0)
            })
        );

        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.ONLY_SUCCESS_RESOLVER.selector);
        splitAuthorityTreasury.resolveSuccess();
    }

    function test_resolveSuccess_revertsWhenNotActive() public {
        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.INVALID_STATE.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_revertsWhenAssertionNotPending() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.SUCCESS_ASSERTION_NOT_PENDING.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_revertsWhenAssertionNotVerified() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);

        bytes32 assertionId = treasury.pendingSuccessAssertionId();
        uint64 assertedAt = treasury.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: false,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + treasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: treasury.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );

        vm.prank(owner);
        vm.expectRevert(IGoalTreasury.SUCCESS_ASSERTION_NOT_VERIFIED.selector);
        treasury.resolveSuccess();
    }

    function test_resolveSuccess_afterDeadline_succeedsWhenAssertionWasPendingPreDeadline() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);
        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.resolveSuccess();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(treasury.resolved());
    }

    function test_sync_fromFunding_beforeMinRaiseDeadline_noOp() public {
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Funding));
        assertFalse(treasury.resolved());
    }

    function test_sync_fromFunding_afterMinRaiseDeadline_belowMinRaise_expires() public {
        vm.warp(treasury.minRaiseDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_fromFunding_afterMinRaiseDeadline_whenMinRaiseReached_activates() public {
        uint256 raised = treasury.minRaise() + 1;
        superToken.mint(address(flow), raised);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(raised));

        vm.warp(treasury.minRaiseDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
        assertFalse(stakeVault.goalResolved());
        assertGt(flow.targetOutflowRate(), 0);
    }

    function test_sync_fromFunding_whenMinRaiseReachedAndMintingStatusUnknown_stillActivates() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        rulesets.setShouldRevertCurrent(true);

        vm.warp(treasury.minRaiseDeadline() + 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
    }

    function test_sync_fromActive_beforeDeadline_keepsActive() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        vm.warp(treasury.deadline() - 1);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Active));
        assertFalse(treasury.resolved());
    }

    function test_sync_fromActive_atDeadline_expires() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        vm.warp(treasury.deadline());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
    }

    function test_sync_noOpWhenAlreadyTerminal() public {
        _expireFromFundingViaSync(treasury);

        treasury.sync();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
    }

    function test_sync_noOpWhenSucceeded() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();

        _registerSuccessAssertion(treasury);
        vm.prank(owner);
        treasury.resolveSuccess();

        uint64 successAtBefore = treasury.successAt();
        uint256 flowRateSetCallsBefore = flow.setFlowRateCallCount();

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(treasury.resolved());
        assertEq(treasury.successAt(), successAtBefore);
        assertEq(flow.setFlowRateCallCount(), flowRateSetCallsBefore);
    }

    function test_isMintingOpen_returnsFalseWhenRulesetReadReverts() public {
        rulesets.setShouldRevertCurrent(true);
        assertFalse(treasury.isMintingOpen());
    }

    function test_canAcceptHookFunding_falseWhenResolved() public {
        _expireFromFundingViaSync(treasury);
        assertFalse(treasury.canAcceptHookFunding());
    }

    function test_lifecycleStatus_resolvedTracksTerminalState() public {
        IGoalTreasury.GoalLifecycleStatus memory fundingStatus = treasury.lifecycleStatus();
        assertEq(uint256(fundingStatus.currentState), uint256(IGoalTreasury.GoalState.Funding));
        assertFalse(fundingStatus.isResolved);
        assertFalse(treasury.resolved());

        _expireFromFundingViaSync(treasury);

        IGoalTreasury.GoalLifecycleStatus memory terminalStatus = treasury.lifecycleStatus();
        assertEq(uint256(terminalStatus.currentState), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(terminalStatus.isResolved);
        assertTrue(treasury.resolved());
    }

    function test_canAcceptHookFunding_falseAtDeadline() public {
        vm.warp(treasury.deadline());
        assertFalse(treasury.canAcceptHookFunding());
    }

    function test_canAcceptHookFunding_falseAfterMinRaiseDeadlineWhenBelowMinRaise() public {
        vm.warp(treasury.minRaiseDeadline() + 1);
        assertFalse(treasury.canAcceptHookFunding());
    }

    function test_getters_returnConfiguredAddresses() public view {
        assertEq(treasury.flow(), address(flow));
        assertEq(treasury.stakeVault(), address(stakeVault));
        assertEq(treasury.hook(), hook);
    }

    function test_targetFlowRate_capsAtInt96Max() public {
        superToken.mint(address(flow), type(uint256).max);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        assertEq(treasury.targetFlowRate(), type(int96).max);
    }

    function test_retryTerminalSideEffects_revertsWhenNotTerminal() public {
        vm.expectRevert(IGoalTreasury.INVALID_STATE.selector);
        treasury.retryTerminalSideEffects();
    }

    function test_finalize_keepsTerminalStateWhenFlowStopFails() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        int96 activeRate = flow.targetOutflowRate();
        flow.setShouldRevertSetFlowRate(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.resolvedAt(), uint64(block.timestamp));
        assertEq(flow.targetOutflowRate(), activeRate);
    }

    function test_finalize_keepsTerminalStateWhenFlowRateReadFails() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        flow.setShouldRevertTargetOutflowRate(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(treasury.resolvedAt(), uint64(block.timestamp));
        assertEq(flow.sweepCallCount(), 1);
        assertTrue(stakeVault.goalResolved());
    }

    function test_finalize_keepsTerminalStateWhenVaultMarkFails_andRetryCanResolveVault() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        stakeVault.setShouldRevertMark(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertFalse(stakeVault.goalResolved());

        stakeVault.setShouldRevertMark(false);
        vm.prank(outsider);
        treasury.retryTerminalSideEffects();

        assertTrue(stakeVault.goalResolved());
        assertEq(stakeVault.markCallCount(), 1);
    }

    function test_finalize_callsRewardEscrow_whenConfigured() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        assertTrue(rewardEscrow.finalized());
        assertEq(rewardEscrow.finalState(), uint8(IGoalTreasury.GoalState.Succeeded));
    }

    function test_finalize_callsRewardEscrow_withExpiredState_fromFunding() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        _expireFromFundingViaSync(rewardTreasury);

        assertTrue(rewardEscrow.finalized());
        assertEq(rewardEscrow.finalState(), uint8(IGoalTreasury.GoalState.Expired));
    }

    function test_finalize_callsRewardEscrow_withExpiredState_fromFunding_viaSyncWindowElapse() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 1 days), 100e18, 0);

        vm.warp(rewardTreasury.minRaiseDeadline() + 1);
        rewardTreasury.sync();

        assertTrue(rewardEscrow.finalized());
        assertEq(rewardEscrow.finalState(), uint8(IGoalTreasury.GoalState.Expired));
    }

    function test_finalize_rewardEscrowRunsAfterFlowStop_andBeforeVaultResolve() public {
        TreasuryMockRewardEscrowOrder rewardEscrow = new TreasuryMockRewardEscrowOrder(flow, stakeVault);
        GoalTreasury rewardTreasury = _deploy(uint64(block.timestamp + 3 days), 100e18, address(rewardEscrow));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();
        assertGt(flow.targetOutflowRate(), 0);
        assertFalse(stakeVault.goalResolved());

        vm.warp(rewardTreasury.deadline());
        vm.prank(owner);
        rewardTreasury.sync();

        assertEq(rewardEscrow.callCount(), 1);
        assertEq(rewardEscrow.lastFinalState(), uint8(IGoalTreasury.GoalState.Expired));
        assertEq(flow.targetOutflowRate(), 0);
        assertTrue(stakeVault.goalResolved());
    }

    function test_finalize_keepsTerminalStateWhenRewardEscrowFinalizeFails() public {
        address foreignGoalTreasury = address(0xF00D);
        BudgetStakeLedger ledger = new BudgetStakeLedger(foreignGoalTreasury);
        RewardEscrow rewardEscrow = new RewardEscrow(
            foreignGoalTreasury,
            IERC20(address(underlyingToken)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(superToken)),
            IBudgetStakeLedger(address(ledger))
        );
        GoalTreasury rewardTreasury = _deploy(uint64(block.timestamp + 3 days), 100e18, address(rewardEscrow));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        vm.warp(rewardTreasury.deadline());
        vm.prank(owner);
        rewardTreasury.sync();

        assertEq(uint256(rewardTreasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(rewardTreasury.resolved());
        assertFalse(rewardEscrow.finalized());
    }

    function test_retryTerminalSideEffects_rewardEscrowRetryUsesOriginalResolvedAt() public {
        TreasuryMockRetryableRewardEscrow rewardEscrow =
            new TreasuryMockRetryableRewardEscrow(ISuperToken(address(superToken)));
        GoalTreasury rewardTreasury = _deploy(uint64(block.timestamp + 3 days), 100e18, address(rewardEscrow));

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        vm.warp(rewardTreasury.deadline());
        vm.expectEmit(true, false, false, true, address(rewardTreasury));
        emit IGoalTreasury.TerminalSideEffectFailed(
            4, abi.encodeWithSelector(TreasuryMockRetryableRewardEscrow.FINALIZE_REVERT.selector)
        );
        vm.prank(owner);
        rewardTreasury.sync();

        uint64 expectedResolvedAt = rewardTreasury.resolvedAt();
        assertEq(uint256(rewardTreasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertEq(rewardEscrow.finalizeCallCount(), 0);
        assertFalse(rewardEscrow.finalized());

        vm.warp(block.timestamp + 7 days);
        rewardEscrow.setShouldRevertFinalize(false);

        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();

        assertTrue(rewardEscrow.finalized());
        assertEq(rewardEscrow.finalizeCallCount(), 1);
        assertEq(rewardEscrow.lastFinalState(), uint8(IGoalTreasury.GoalState.Expired));
        assertEq(rewardEscrow.lastFinalizedAt(), expectedResolvedAt);
        assertEq(rewardTreasury.resolvedAt(), expectedResolvedAt);
    }

    function test_constructor_revertsWhenSettlementPpmAboveScale() public {
        stakeVault.setGoalTreasury(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SETTLEMENT_SCALED.selector, 1_000_001));
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 1,
                successSettlementRewardEscrowPpm: 1_000_001,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenSettlementPpmRequiresEscrow() public {
        stakeVault.setGoalTreasury(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vm.expectRevert(IGoalTreasury.REWARD_ESCROW_NOT_CONFIGURED.selector);
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 1,
                successSettlementRewardEscrowPpm: 100_000,
            successResolver: owner,
            successAssertionLiveness: uint64(1 days),
            successAssertionBond: 10e18,
            successOracleSpecHash: keccak256("goal-oracle-spec"),
            successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_resolveSuccess_defersRewardsFinalizationWhenTrackedBudgetsUnresolved() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        TreasuryMockBudgetTreasury budget = _registerTrackedBudgetWithAllocation(rewardEscrow);
        assertFalse(rewardEscrow.allTrackedBudgetsResolved());

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        uint64 successTimestamp = uint64(block.timestamp);
        assertEq(uint256(rewardTreasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(rewardTreasury.resolved());
        assertTrue(stakeVault.goalResolved());
        assertFalse(rewardEscrow.finalized());
        assertTrue(rewardEscrow.finalizationInProgress());
        assertEq(rewardEscrow.goalFinalizedAt(), successTimestamp);

        vm.warp(block.timestamp + 1 days);
        budget.setState(uint8(IBudgetTreasury.BudgetState.Succeeded));
        budget.setResolvedAt(uint64(block.timestamp));
        assertTrue(rewardEscrow.allTrackedBudgetsResolved());

        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();

        assertTrue(rewardEscrow.finalized());
        assertEq(rewardTreasury.successAt(), successTimestamp);
        assertEq(rewardEscrow.goalFinalizedAt(), successTimestamp);
    }

    function test_resolveSuccess_doesNotCallAllTrackedBudgetsResolvedPrecheck() public {
        TreasuryMockRewardEscrowRevertingPrecheck rewardEscrow =
            new TreasuryMockRewardEscrowRevertingPrecheck(ISuperToken(address(superToken)));
        GoalTreasury rewardTreasury = _deploy(uint64(block.timestamp + 3 days), 100e18, address(rewardEscrow), 0);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        assertEq(uint256(rewardTreasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertEq(rewardEscrow.precheckCallCount(), 0);
        assertEq(rewardEscrow.finalizeCallCount(), 1);
        assertEq(rewardEscrow.lastFinalState(), uint8(IGoalTreasury.GoalState.Succeeded));
        assertEq(rewardEscrow.lastFinalizedAt(), rewardTreasury.successAt());
        assertTrue(rewardEscrow.finalized());
    }

    function test_sync_success_doesNotCallAllTrackedBudgetsResolvedPrecheck() public {
        TreasuryMockRewardEscrowRevertingPrecheck rewardEscrow =
            new TreasuryMockRewardEscrowRevertingPrecheck(ISuperToken(address(superToken)));
        GoalTreasury rewardTreasury = _deploy(uint64(block.timestamp + 3 days), 100e18, address(rewardEscrow), 0);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.warp(rewardTreasury.deadline());
        rewardTreasury.sync();

        assertEq(uint256(rewardTreasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertEq(rewardEscrow.precheckCallCount(), 0);
        assertEq(rewardEscrow.finalizeCallCount(), 1);
        assertEq(rewardEscrow.lastFinalState(), uint8(IGoalTreasury.GoalState.Succeeded));
        assertEq(rewardEscrow.lastFinalizedAt(), rewardTreasury.successAt());
        assertTrue(rewardEscrow.finalized());
    }

    function test_resolveSuccess_emitsSuccessRewardsFinalizedExactlyOnce() public {
        (GoalTreasury rewardTreasury,) = _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        vm.recordLogs();
        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 eventSignature = keccak256("SuccessRewardsFinalized(uint64,uint64)");
        uint256 seen;
        uint64 emittedSuccessAt;
        uint64 emittedFinalizedAt;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(rewardTreasury)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSignature) continue;

            seen++;
            (emittedSuccessAt, emittedFinalizedAt) = abi.decode(logs[i].data, (uint64, uint64));
        }

        assertEq(seen, 1);
        assertEq(emittedSuccessAt, rewardTreasury.successAt());
        assertEq(emittedFinalizedAt, rewardTreasury.successAt());
    }

    function test_retryTerminalSideEffects_emitsSuccessRewardsFinalizedWithRetryTimestamp() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        TreasuryMockBudgetTreasury budget = _registerTrackedBudgetWithAllocation(rewardEscrow);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.recordLogs();
        vm.prank(owner);
        rewardTreasury.resolveSuccess();
        Vm.Log[] memory resolveLogs = vm.getRecordedLogs();
        uint64 successTimestamp = rewardTreasury.successAt();

        bytes32 eventSignature = keccak256("SuccessRewardsFinalized(uint64,uint64)");
        uint256 resolveSeen;
        for (uint256 i = 0; i < resolveLogs.length; i++) {
            if (resolveLogs[i].emitter != address(rewardTreasury)) continue;
            if (resolveLogs[i].topics.length == 0 || resolveLogs[i].topics[0] != eventSignature) continue;
            resolveSeen++;
        }
        assertEq(resolveSeen, 0);

        vm.warp(block.timestamp + 1 days);
        budget.setState(uint8(IBudgetTreasury.BudgetState.Succeeded));
        budget.setResolvedAt(uint64(block.timestamp));

        vm.recordLogs();
        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        uint64 emittedSuccessAt;
        uint64 emittedFinalizedAt;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(rewardTreasury)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSignature) continue;

            seen++;
            (emittedSuccessAt, emittedFinalizedAt) = abi.decode(logs[i].data, (uint64, uint64));
        }

        assertEq(seen, 1);
        assertEq(emittedSuccessAt, successTimestamp);
        assertEq(emittedFinalizedAt, uint64(block.timestamp));
        assertGt(emittedFinalizedAt, emittedSuccessAt);
    }

    function test_retryTerminalSideEffects_successRewardsFinalizedEmitsOnlyOnFinalizeTransition() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 1_000_000);

        TreasuryMockBudgetTreasury budget = _registerTrackedBudgetWithAllocation(rewardEscrow);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        assertFalse(rewardEscrow.finalized());

        vm.warp(block.timestamp + 1 days);
        budget.setState(uint8(IBudgetTreasury.BudgetState.Succeeded));
        budget.setResolvedAt(uint64(block.timestamp));

        bytes32 eventSignature = keccak256("SuccessRewardsFinalized(uint64,uint64)");

        vm.recordLogs();
        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();
        Vm.Log[] memory firstRetryLogs = vm.getRecordedLogs();

        uint256 firstRetrySeen;
        for (uint256 i = 0; i < firstRetryLogs.length; i++) {
            if (firstRetryLogs[i].emitter != address(rewardTreasury)) continue;
            if (firstRetryLogs[i].topics.length == 0 || firstRetryLogs[i].topics[0] != eventSignature) continue;
            firstRetrySeen++;
        }

        assertTrue(rewardEscrow.finalized());
        assertEq(firstRetrySeen, 1);

        vm.recordLogs();
        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();
        Vm.Log[] memory secondRetryLogs = vm.getRecordedLogs();

        uint256 secondRetrySeen;
        for (uint256 i = 0; i < secondRetryLogs.length; i++) {
            if (secondRetryLogs[i].emitter != address(rewardTreasury)) continue;
            if (secondRetryLogs[i].topics.length == 0 || secondRetryLogs[i].topics[0] != eventSignature) continue;
            secondRetrySeen++;
        }

        assertEq(secondRetrySeen, 0);
    }

    function test_resolveSuccess_lateBudgetSuccessIncludedWhenEscrowFinalizesAfterResolution() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 1_000_000);

        TreasuryMockBudgetTreasury budget = _registerTrackedBudgetWithAllocation(rewardEscrow);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        assertFalse(rewardEscrow.finalized());
        assertFalse(rewardEscrow.budgetSucceededAtFinalize(address(budget)));
        assertEq(rewardEscrow.budgetResolvedAtFinalize(address(budget)), 0);
        assertEq(rewardEscrow.totalPointsSnapshot(), 0);
        assertEq(rewardEscrow.userSuccessfulPoints(address(0xCAFE)), 0);

        vm.warp(block.timestamp + 1 days);
        budget.setState(uint8(IBudgetTreasury.BudgetState.Succeeded));
        budget.setResolvedAt(uint64(block.timestamp));

        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();

        assertTrue(rewardEscrow.finalized());
        assertTrue(rewardEscrow.budgetSucceededAtFinalize(address(budget)));
        assertEq(rewardEscrow.budgetResolvedAtFinalize(address(budget)), uint64(block.timestamp));
        assertEq(rewardEscrow.totalPointsSnapshot(), rewardEscrow.userSuccessfulPoints(address(0xCAFE)));
    }

    function test_sync_success_defersRewardsFinalizationWhenTrackedBudgetsUnresolved() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        TreasuryMockBudgetTreasury budget = _registerTrackedBudgetWithAllocation(rewardEscrow);
        assertFalse(rewardEscrow.allTrackedBudgetsResolved());

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.warp(rewardTreasury.deadline());
        rewardTreasury.sync();

        uint64 successTimestamp = uint64(block.timestamp);
        assertEq(uint256(rewardTreasury.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        assertTrue(rewardTreasury.resolved());
        assertFalse(rewardEscrow.finalized());
        assertTrue(rewardEscrow.finalizationInProgress());
        assertEq(rewardEscrow.goalFinalizedAt(), successTimestamp);

        vm.warp(block.timestamp + 1 days);
        budget.setState(uint8(IBudgetTreasury.BudgetState.Succeeded));
        budget.setResolvedAt(uint64(block.timestamp));
        assertTrue(rewardEscrow.allTrackedBudgetsResolved());

        vm.prank(outsider);
        rewardTreasury.retryTerminalSideEffects();

        assertTrue(rewardEscrow.finalized());
        assertEq(rewardEscrow.goalFinalizedAt(), successTimestamp);
    }

    function test_finalize_failure_burnsAllSettledResidual() public {
        superToken.mint(address(flow), 75e18);

        _expireFromFundingViaSync(treasury);

        assertEq(flow.sweepCallCount(), 1);
        assertEq(flow.lastSweepTo(), address(treasury));
        assertEq(flow.lastSweepAmount(), 75e18);
        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnProjectId(), PROJECT_ID);
        assertEq(controller.lastBurnAmount(), 75e18);
        assertEq(superToken.balanceOf(address(flow)), 0);
    }

    function test_finalize_success_splitsResidualBetweenEscrowAndBurn() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 250_000);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();

        assertEq(flow.sweepCallCount(), 1);
        assertEq(flow.lastSweepTo(), address(rewardTreasury));
        assertEq(flow.lastSweepAmount(), 100e18);
        assertEq(superToken.balanceOf(address(rewardEscrow)), 0);
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)), 25e18);
        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnProjectId(), PROJECT_ID);
        assertEq(controller.lastBurnAmount(), 75e18);
    }

    function test_finalize_keepsTerminalStateWhenResidualSweepFails_andRetrySettlesResidual() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        flow.setShouldRevertSweep(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.sync();

        IGoalTreasury.GoalLifecycleStatus memory status = treasury.lifecycleStatus();
        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(uint256(status.currentState), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(status.isResolved);
        assertEq(flow.sweepCallCount(), 0);

        flow.setShouldRevertSweep(false);
        vm.prank(outsider);
        treasury.retryTerminalSideEffects();

        assertEq(flow.sweepCallCount(), 1);
        assertEq(flow.lastSweepAmount(), 100e18);
        assertEq(superToken.balanceOf(address(flow)), 0);
    }

    function test_finalize_keepsTerminalStateWhenControllerBurnFails_andRetryBurns() public {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(treasury.recordHookFunding(100e18));
        treasury.sync();
        controller.setShouldRevertBurn(true);

        vm.warp(treasury.deadline());
        vm.prank(owner);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IGoalTreasury.GoalState.Expired));
        assertTrue(treasury.resolved());
        assertEq(controller.burnCallCount(), 0);

        controller.setShouldRevertBurn(false);
        vm.prank(outsider);
        treasury.retryTerminalSideEffects();

        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnAmount(), 100e18);
        assertEq(superToken.balanceOf(address(flow)), 0);
    }

    function test_finalizeHelpers_revertWhenCallerNotSelf() public {
        vm.expectRevert(GoalTreasury.ONLY_SELF.selector);
        treasury.settleResidualForFinalize(IGoalTreasury.GoalState.Expired);

        vm.expectRevert(GoalTreasury.ONLY_SELF.selector);
        treasury.settleDeferredHookFundingForFinalize(IGoalTreasury.GoalState.Expired);
    }

    function test_settleLateResidual_revertsWhenUnresolved() public {
        vm.expectRevert(IGoalTreasury.INVALID_STATE.selector);
        treasury.settleLateResidual();
    }

    function test_settleLateResidual_failedPath_burnsLateInflow() public {
        superToken.mint(address(flow), 75e18);
        _expireFromFundingViaSync(treasury);
        assertEq(controller.burnCallCount(), 1);

        superToken.mint(address(flow), 40e18);

        vm.prank(outsider);
        treasury.settleLateResidual();

        assertEq(flow.sweepCallCount(), 2);
        assertEq(flow.lastSweepTo(), address(treasury));
        assertEq(flow.lastSweepAmount(), 40e18);
        assertEq(controller.burnCallCount(), 2);
        assertEq(controller.lastBurnAmount(), 40e18);
        assertEq(superToken.balanceOf(address(flow)), 0);
    }

    function test_settleLateResidual_successPath_preservesSplitPolicy() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 250_000);

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(rewardTreasury.recordHookFunding(100e18));
        rewardTreasury.sync();

        _registerSuccessAssertion(rewardTreasury);
        vm.prank(owner);
        rewardTreasury.resolveSuccess();
        assertEq(controller.burnCallCount(), 1);

        superToken.mint(address(flow), 40e18);
        uint256 rewardEscrowSuperBefore = superToken.balanceOf(address(rewardEscrow));
        uint256 rewardEscrowGoalBefore = underlyingToken.balanceOf(address(rewardEscrow));

        vm.prank(outsider);
        rewardTreasury.settleLateResidual();

        assertEq(flow.sweepCallCount(), 2);
        assertEq(flow.lastSweepTo(), address(rewardTreasury));
        assertEq(flow.lastSweepAmount(), 40e18);
        assertEq(superToken.balanceOf(address(rewardEscrow)) - rewardEscrowSuperBefore, 10e18);
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)), rewardEscrowGoalBefore);
        assertEq(controller.burnCallCount(), 2);
        assertEq(controller.lastBurnAmount(), 30e18);
        assertEq(superToken.balanceOf(address(flow)), 0);
    }

    function test_sweepFailedAndBurn_revertsWhenUnresolved() public {
        vm.expectRevert(IGoalTreasury.INVALID_STATE.selector);
        vm.prank(owner);
        treasury.sweepFailedAndBurn();
    }

    function test_sweepFailedAndBurn_allowsPermissionlessCaller() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        _expireFromFundingViaSync(rewardTreasury);

        underlyingToken.mint(address(rewardEscrow), 42e18);
        uint256 treasuryBalanceBefore = underlyingToken.balanceOf(address(rewardTreasury));

        vm.prank(outsider);
        uint256 swept = rewardTreasury.sweepFailedAndBurn();

        assertEq(swept, 42e18);
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)), 0);
        assertEq(underlyingToken.balanceOf(address(rewardTreasury)) - treasuryBalanceBefore, 42e18);
    }

    function test_sweepFailedAndBurn_revertsWhenEscrowUnconfigured() public {
        _expireFromFundingViaSync(treasury);

        vm.expectRevert(IGoalTreasury.INVALID_STATE.selector);
        vm.prank(owner);
        treasury.sweepFailedAndBurn();
    }

    function test_sweepFailedAndBurn_forwardsToEscrow() public {
        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        _expireFromFundingViaSync(rewardTreasury);

        underlyingToken.mint(address(rewardEscrow), 123e18);
        uint256 treasuryBalanceBefore = underlyingToken.balanceOf(address(rewardTreasury));

        vm.prank(owner);
        uint256 swept = rewardTreasury.sweepFailedAndBurn();

        assertEq(swept, 123e18);
        assertEq(underlyingToken.balanceOf(address(rewardEscrow)), 0);
        assertEq(underlyingToken.balanceOf(address(rewardTreasury)) - treasuryBalanceBefore, 123e18);
        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnAmount(), 123e18);
        assertEq(controller.lastBurnMemo(), "GOAL_FAILED_ESCROW_SWEEP_BURN");
    }

    function test_sweepFailedAndBurn_burnsCobuildSweepViaController() public {
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));
        controllerTokens.setProjectIdOf(address(cobuildUnderlying), PROJECT_ID);

        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        _expireFromFundingViaSync(rewardTreasury);

        cobuildUnderlying.mint(address(rewardEscrow), 77e18);

        vm.prank(owner);
        uint256 swept = rewardTreasury.sweepFailedAndBurn();

        assertEq(swept, 0);
        assertEq(cobuildUnderlying.balanceOf(address(rewardEscrow)), 0);
        assertEq(controller.burnCallCount(), 1);
        assertEq(controller.lastBurnProjectId(), PROJECT_ID);
        assertEq(controller.lastBurnAmount(), 77e18);
        assertEq(controller.lastBurnMemo(), "GOAL_FAILED_ESCROW_SWEEP_COBUILD_BURN");
    }

    function test_constructor_revertsWhenCobuildProjectUnset() public {
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE.selector, address(cobuildUnderlying))
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenControllerTokensLookupReverts() public {
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));

        TreasuryMockControllerRevertingTokens revertingController = new TreasuryMockControllerRevertingTokens();
        directory.setController(PROJECT_ID, address(revertingController));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE.selector, address(cobuildUnderlying))
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenControllerReturnsZeroTokensAddress() public {
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));

        TreasuryMockController zeroTokensController = new TreasuryMockController(TreasuryMockTokens(address(0)));
        directory.setController(PROJECT_ID, address(zeroTokensController));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE.selector, address(cobuildUnderlying))
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_constructor_revertsWhenDerivedCobuildProjectControllerMissing() public {
        uint256 cobuildProjectId = PROJECT_ID + 1;
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));
        controllerTokens.setProjectIdOf(address(cobuildUnderlying), cobuildProjectId);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE.selector, address(cobuildUnderlying))
        );
        new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: address(0),
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                successSettlementRewardEscrowPpm: 0,
                successResolver: owner,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function test_sweepFailedAndBurn_cobuildSweepUsesDerivedCobuildRevnetId() public {
        uint256 cobuildProjectId = PROJECT_ID + 1;
        uint256 cobuildSweepAmount = 77e18;
        SharedMockUnderlying cobuildUnderlying = new SharedMockUnderlying();
        stakeVault.setCobuildToken(IERC20(address(cobuildUnderlying)));

        TreasuryMockTokens goalControllerTokens = new TreasuryMockTokens();
        goalControllerTokens.setProjectIdOf(address(cobuildUnderlying), cobuildProjectId);
        goalControllerTokens.setProjectIdOf(address(underlyingToken), PROJECT_ID);

        TreasuryMockSupplyAwareController goalSupplyController = new TreasuryMockSupplyAwareController(goalControllerTokens);
        TreasuryMockSupplyAwareController cobuildSupplyController =
            new TreasuryMockSupplyAwareController(new TreasuryMockTokens());
        directory.setController(PROJECT_ID, address(goalSupplyController));
        directory.setController(cobuildProjectId, address(cobuildSupplyController));
        cobuildSupplyController.setProjectBalance(cobuildProjectId, cobuildSweepAmount);

        (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow) =
            _deployWithRealRewardEscrow(uint64(block.timestamp + 3 days), 100e18, 0);

        assertEq(rewardTreasury.cobuildRevnetId(), cobuildProjectId);

        _expireFromFundingViaSync(rewardTreasury);
        cobuildUnderlying.mint(address(rewardEscrow), cobuildSweepAmount);

        uint256 swept = rewardTreasury.sweepFailedAndBurn();

        assertEq(swept, 0);
        assertEq(cobuildUnderlying.balanceOf(address(rewardEscrow)), 0);
        assertEq(goalSupplyController.burnAttemptCount(), 0);
        assertEq(cobuildSupplyController.burnAttemptCount(), 1);
        assertEq(cobuildSupplyController.lastBurnProjectId(), cobuildProjectId);
        assertEq(cobuildSupplyController.lastBurnAmount(), cobuildSweepAmount);
        assertEq(cobuildSupplyController.projectBalance(cobuildProjectId), 0);
    }

    function _deploy(uint64 minRaiseDeadline, uint256 minRaise) internal returns (GoalTreasury) {
        return _deploy(minRaiseDeadline, minRaise, address(0), 0);
    }

    function _runHookSplitMatrixCase(HookSplitMatrixCase memory matrixCase) internal {
        GoalTreasury target = _deploy(uint64(block.timestamp + 3 days), 100e18);
        _setGoalTreasuryStateForHookSplitCase(target, matrixCase.state);
        rulesets.setWeight(PROJECT_ID, matrixCase.mintingOpen ? 1e18 : 0);

        address sourceToken = matrixCase.useUnderlyingSource ? address(underlyingToken) : address(superToken);
        uint256 sourceAmount = matrixCase.zeroSourceAmount ? 0 : 7e18;
        if (sourceAmount != 0) {
            if (matrixCase.useUnderlyingSource) {
                underlyingToken.mint(address(target), sourceAmount);
            } else {
                superToken.mint(address(target), sourceAmount);
            }
        }

        uint256 totalRaisedBefore = target.totalRaised();
        uint256 deferredBefore = target.deferredHookSuperTokenAmount();
        uint256 flowBalanceBefore = superToken.balanceOf(address(flow));
        uint256 burnCallCountBefore = controller.burnCallCount();
        if (!matrixCase.useUnderlyingSource) {
            vm.prank(hook);
            vm.expectRevert(
                abi.encodeWithSelector(IGoalTreasury.INVALID_HOOK_SOURCE_TOKEN.selector, address(superToken))
            );
            target.processHookSplit(sourceToken, sourceAmount);

            assertEq(target.totalRaised(), totalRaisedBefore);
            assertEq(target.deferredHookSuperTokenAmount(), deferredBefore);
            assertEq(superToken.balanceOf(address(flow)), flowBalanceBefore);
            assertEq(controller.burnCallCount(), burnCallCountBefore);
            return;
        }

        IGoalTreasury.HookSplitAction expectedAction =
            _expectedHookSplitActionForMatrix(matrixCase.state, matrixCase.mintingOpen, matrixCase.zeroSourceAmount);

        vm.prank(hook);
        (
            IGoalTreasury.HookSplitAction action,
            uint256 superTokenAmount,
            uint256 rewardAmount,
            uint256 burnAmount
        ) = target.processHookSplit(sourceToken, sourceAmount);

        assertEq(uint256(action), uint256(expectedAction));

        bool isFunded = expectedAction == IGoalTreasury.HookSplitAction.Funded;
        bool isSettled = expectedAction == IGoalTreasury.HookSplitAction.SuccessSettled
            || expectedAction == IGoalTreasury.HookSplitAction.TerminalSettled;
        uint256 expectedSuperTokenAmount =
            isFunded || expectedAction == IGoalTreasury.HookSplitAction.TerminalSettled ? sourceAmount : 0;
        uint256 expectedBurnAmount = isSettled ? sourceAmount : 0;
        uint256 expectedTotalRaised = isFunded ? totalRaisedBefore + sourceAmount : totalRaisedBefore;
        uint256 expectedFlowBalance = isFunded ? flowBalanceBefore + sourceAmount : flowBalanceBefore;
        uint256 expectedBurnCallCount = burnCallCountBefore + (isSettled ? 1 : 0);

        assertEq(superTokenAmount, expectedSuperTokenAmount);
        assertEq(rewardAmount, 0);
        assertEq(burnAmount, expectedBurnAmount);
        assertEq(target.totalRaised(), expectedTotalRaised);
        assertEq(target.deferredHookSuperTokenAmount(), deferredBefore);
        assertEq(superToken.balanceOf(address(flow)), expectedFlowBalance);
        assertEq(controller.burnCallCount(), expectedBurnCallCount);
    }

    function _setGoalTreasuryStateForHookSplitCase(GoalTreasury target, IGoalTreasury.GoalState desiredState) internal {
        if (desiredState == IGoalTreasury.GoalState.Funding) return;
        if (desiredState == IGoalTreasury.GoalState.Expired) {
            _expireFromFundingViaSync(target);
            assertEq(uint256(target.state()), uint256(IGoalTreasury.GoalState.Expired));
            return;
        }

        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(target.recordHookFunding(100e18));
        target.sync();
        assertEq(uint256(target.state()), uint256(IGoalTreasury.GoalState.Active));

        if (desiredState == IGoalTreasury.GoalState.Succeeded) {
            _registerSuccessAssertion(target);
            vm.prank(owner);
            target.resolveSuccess();
            assertEq(uint256(target.state()), uint256(IGoalTreasury.GoalState.Succeeded));
        }
    }

    function _expectedHookSplitActionForMatrix(
        IGoalTreasury.GoalState state,
        bool mintingOpen,
        bool zeroSourceAmount
    ) internal pure returns (IGoalTreasury.HookSplitAction) {
        if (zeroSourceAmount) return IGoalTreasury.HookSplitAction.Deferred;
        if (state == IGoalTreasury.GoalState.Funding || state == IGoalTreasury.GoalState.Active) {
            return IGoalTreasury.HookSplitAction.Funded;
        }
        if (state == IGoalTreasury.GoalState.Succeeded) {
            return mintingOpen ? IGoalTreasury.HookSplitAction.SuccessSettled : IGoalTreasury.HookSplitAction.TerminalSettled;
        }
        return IGoalTreasury.HookSplitAction.TerminalSettled;
    }

    function _countFailClosedResolutionEvents(
        Vm.Log[] memory logs,
        address emitter
    ) internal pure returns (uint256 seen) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != emitter) continue;
            if (
                logs[i].topics.length == 0
                    || logs[i].topics[0] != SUCCESS_ASSERTION_RESOLUTION_FAIL_CLOSED_EVENT
            ) continue;
            seen++;
        }
    }

    function _expireFromFundingViaSync(GoalTreasury target) internal {
        vm.warp(target.minRaiseDeadline() + 1);
        target.sync();
    }

    function _openReassertGraceWindow(GoalTreasury target) internal returns (uint64 graceDeadline) {
        superToken.mint(address(flow), 100e18);
        vm.prank(hook);
        assertTrue(target.recordHookFunding(100e18));
        target.sync();

        _registerSuccessAssertion(target);
        _setPendingSuccessAssertion(target, true, false);

        vm.warp(target.deadline());
        target.sync();

        graceDeadline = target.reassertGraceDeadline();
    }

    function _registerSuccessAssertion(GoalTreasury target) internal {
        bytes32 assertionId = keccak256(abi.encodePacked(address(target), block.timestamp));
        vm.prank(owner);
        target.registerSuccessAssertion(assertionId);

        _setPendingSuccessAssertion(target, true, true);
    }

    function _setPendingSuccessAssertion(GoalTreasury target, bool settled, bool settlementResolution) internal {
        bytes32 assertionId = target.pendingSuccessAssertionId();
        uint64 assertedAt = target.pendingSuccessAssertionAt();
        assertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: owner,
                    escalationManager: successResolverConfig.escalationManager()
                }),
                asserter: owner,
                assertionTime: assertedAt,
                settled: settled,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + target.successAssertionLiveness(),
                settlementResolution: settlementResolution,
                domainId: successResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: target.successAssertionBond(),
                callbackRecipient: owner,
                disputer: address(0)
            })
        );
    }

    function _registerTrackedBudgetWithAllocation(
        RewardEscrow rewardEscrow
    ) internal returns (TreasuryMockBudgetTreasury budget) {
        TreasuryMockBudgetFlow budgetFlow = new TreasuryMockBudgetFlow(address(flow));
        budget = new TreasuryMockBudgetTreasury(address(budgetFlow));
        bytes32 budgetRecipientId = keccak256("budget-recipient");
        flow.setRecipient(budgetRecipientId, address(budget));

        bytes32[] memory prevRecipientIds = new bytes32[](0);
        uint32[] memory prevScaled = new uint32[](0);
        bytes32[] memory newRecipientIds = new bytes32[](1);
        newRecipientIds[0] = budgetRecipientId;
        uint32[] memory newScaled = new uint32[](1);
        newScaled[0] = 1_000_000;

        vm.warp(block.timestamp + 1);
        IBudgetStakeLedger ledger = IBudgetStakeLedger(rewardEscrow.budgetStakeLedger());
        vm.mockCall(address(flow), abi.encodeWithSignature("recipientAdmin()"), abi.encode(address(this)));
        ledger.registerBudget(budgetRecipientId, address(budget));
        vm.prank(address(flow));
        ledger.checkpointAllocation(address(0xCAFE), 0, prevRecipientIds, prevScaled, 100e18, newRecipientIds, newScaled);
    }

    function _deploy(uint64 minRaiseDeadline, uint256 minRaise, address rewardEscrow) internal returns (GoalTreasury) {
        return _deploy(minRaiseDeadline, minRaise, rewardEscrow, 0);
    }

    function _deploy(
        uint64 minRaiseDeadline,
        uint256 minRaise,
        address rewardEscrow,
        uint32 successSettlementRewardEscrowPpm
    )
        internal
        returns (GoalTreasury)
    {
        return _deployWithSuccessResolver(minRaiseDeadline, minRaise, rewardEscrow, successSettlementRewardEscrowPpm, owner);
    }

    function _deployWithSuccessResolver(
        uint64 minRaiseDeadline,
        uint256 minRaise,
        address rewardEscrow,
        uint32 successSettlementRewardEscrowPpm,
        address configuredSuccessResolver
    ) internal returns (GoalTreasury) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stakeVault.setGoalTreasury(predicted);
        flow.setFlowOperator(predicted);
        flow.setSweeper(predicted);

        return new GoalTreasury(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                rewardEscrow: rewardEscrow,
                hook: hook,
                goalRulesets: address(rulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: minRaiseDeadline,
                minRaise: minRaise,
                successSettlementRewardEscrowPpm: successSettlementRewardEscrowPpm,
                successResolver: configuredSuccessResolver,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
    }

    function _deployWithRealRewardEscrow(
        uint64 minRaiseDeadline,
        uint256 minRaise,
        uint32 successSettlementRewardEscrowPpm
    )
        internal
        returns (GoalTreasury rewardTreasury, RewardEscrow rewardEscrow)
    {
        uint256 deployerNonce = vm.getNonce(address(this));
        address predictedTreasury = vm.computeCreateAddress(address(this), deployerNonce + 2);
        BudgetStakeLedger ledger = new BudgetStakeLedger(predictedTreasury);

        rewardEscrow = new RewardEscrow(
            predictedTreasury,
            IERC20(address(underlyingToken)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(superToken)),
            IBudgetStakeLedger(address(ledger))
        );

        rewardTreasury = _deploy(minRaiseDeadline, minRaise, address(rewardEscrow), successSettlementRewardEscrowPpm);
    }
}

contract TreasuryMockRulesets {
    struct RulesetPair {
        JBRuleset base;
        JBRuleset terminal;
        bool configured;
    }

    mapping(uint256 => uint112) internal _weightOf;
    mapping(uint256 => RulesetPair) internal _pairOf;
    mapping(uint256 => JBApprovalStatus) internal _approvalStatusOf;
    bool internal _shouldRevertCurrent;

    error CURRENT_REVERT();

    function configureTwoRulesetSchedule(uint256 projectId, uint48 terminalStart, uint112 openWeight) external {
        uint48 nowTs = uint48(block.timestamp);
        RulesetPair storage pair = _pairOf[projectId];
        pair.base = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: nowTs,
            duration: 0,
            weight: openWeight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.terminal = JBRuleset({
            cycleNumber: 2,
            id: 2,
            basedOnId: 1,
            start: terminalStart,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.configured = true;
        _weightOf[projectId] = openWeight;
        _approvalStatusOf[projectId] = JBApprovalStatus.Approved;
    }

    function setApprovalStatus(uint256 projectId, JBApprovalStatus status) external {
        _approvalStatusOf[projectId] = status;
    }

    function setBaseRuleset(uint256 projectId, uint48 id, uint48 basedOnId, uint48 start, uint112 weight) external {
        RulesetPair storage pair = _pairOf[projectId];
        pair.base = JBRuleset({
            cycleNumber: pair.base.cycleNumber == 0 ? 1 : pair.base.cycleNumber,
            id: id,
            basedOnId: basedOnId,
            start: start,
            duration: 0,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.configured = true;
    }

    function setTerminalRuleset(uint256 projectId, uint48 id, uint48 basedOnId, uint48 start, uint112 weight) external {
        RulesetPair storage pair = _pairOf[projectId];
        pair.terminal = JBRuleset({
            cycleNumber: pair.terminal.cycleNumber == 0 ? 2 : pair.terminal.cycleNumber,
            id: id,
            basedOnId: basedOnId,
            start: start,
            duration: 0,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.configured = true;
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

    function latestQueuedOf(uint256 projectId) external view returns (JBRuleset memory ruleset, JBApprovalStatus status) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return (ruleset, JBApprovalStatus.Empty);
        return (pair.terminal, _approvalStatusOf[projectId]);
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory ruleset) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return ruleset;
        if (rulesetId == pair.base.id) return pair.base;
        if (rulesetId == pair.terminal.id) return pair.terminal;
        return ruleset;
    }
}

contract TreasuryMockBudgetFlow {
    address private immutable _parent;

    constructor(address parent_) {
        _parent = parent_;
    }

    function parent() external view returns (address) {
        return _parent;
    }
}

contract TreasuryMockBudgetTreasury {
    address private immutable _flow;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;
    uint8 public state = uint8(IBudgetTreasury.BudgetState.Funding);
    uint64 public resolvedAt;

    constructor(address flow_) {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function setState(uint8 state_) external {
        state = state_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }
}

contract TreasuryMockRewardEscrowOrder {
    error FLOW_NOT_STOPPED();
    error VAULT_ALREADY_RESOLVED();

    SharedMockFlow private immutable _flow;
    SharedMockStakeVault private immutable _stakeVault;

    uint8 public lastFinalState;
    uint256 public callCount;

    constructor(SharedMockFlow flow_, SharedMockStakeVault stakeVault_) {
        _flow = flow_;
        _stakeVault = stakeVault_;
    }

    function allTrackedBudgetsResolved() external pure returns (bool) {
        return true;
    }

    function finalized() external view returns (bool) {
        return callCount != 0;
    }

    function rewardSuperToken() external view returns (ISuperToken) {
        return _flow.superToken();
    }

    function finalize(uint8 finalState_, uint64) external {
        if (_flow.targetOutflowRate() != 0) revert FLOW_NOT_STOPPED();
        if (_stakeVault.goalResolved()) revert VAULT_ALREADY_RESOLVED();

        lastFinalState = finalState_;
        callCount++;
    }
}

contract TreasuryMockRetryableRewardEscrow {
    error FINALIZE_REVERT();

    bool public shouldRevertFinalize = true;
    bool private _finalized;
    uint8 public lastFinalState;
    uint64 public lastFinalizedAt;
    uint256 public finalizeCallCount;
    ISuperToken private immutable _rewardSuperToken;

    constructor(ISuperToken rewardSuperToken_) {
        _rewardSuperToken = rewardSuperToken_;
    }

    function setShouldRevertFinalize(bool shouldRevert) external {
        shouldRevertFinalize = shouldRevert;
    }

    function allTrackedBudgetsResolved() external pure returns (bool) {
        return true;
    }

    function finalized() external view returns (bool) {
        return _finalized;
    }

    function rewardSuperToken() external view returns (ISuperToken) {
        return _rewardSuperToken;
    }

    function finalize(uint8 finalState_, uint64 finalizedAt_) external {
        finalizeCallCount += 1;
        if (shouldRevertFinalize) revert FINALIZE_REVERT();

        _finalized = true;
        lastFinalState = finalState_;
        lastFinalizedAt = finalizedAt_;
    }
}

contract TreasuryMockRewardEscrowRevertingPrecheck {
    error PRECHECK_SHOULD_NOT_BE_CALLED();

    uint256 public precheckCallCount;
    uint256 public finalizeCallCount;
    bool private _finalized;
    uint8 public lastFinalState;
    uint64 public lastFinalizedAt;
    ISuperToken private immutable _rewardSuperToken;

    constructor(ISuperToken rewardSuperToken_) {
        _rewardSuperToken = rewardSuperToken_;
    }

    function allTrackedBudgetsResolved() external returns (bool) {
        precheckCallCount += 1;
        revert PRECHECK_SHOULD_NOT_BE_CALLED();
    }

    function finalized() external view returns (bool) {
        return _finalized;
    }

    function rewardSuperToken() external view returns (ISuperToken) {
        return _rewardSuperToken;
    }

    function finalize(uint8 finalState_, uint64 finalizedAt_) external {
        finalizeCallCount += 1;
        _finalized = true;
        lastFinalState = finalState_;
        lastFinalizedAt = finalizedAt_;
    }
}

contract TreasuryMockRewardEscrowSuperToken {
    ISuperToken private immutable _rewardSuperToken;

    constructor(ISuperToken rewardSuperToken_) {
        _rewardSuperToken = rewardSuperToken_;
    }

    function rewardSuperToken() external view returns (ISuperToken) {
        return _rewardSuperToken;
    }
}

contract TreasuryMockUmaResolverConfigRevertingOracle {
    error OPTIMISTIC_ORACLE_REVERT();

    function optimisticOracle() external pure returns (OptimisticOracleV3Interface) {
        revert OPTIMISTIC_ORACLE_REVERT();
    }
}

contract TreasuryMockUmaResolverConfigZeroOracle {
    function optimisticOracle() external pure returns (OptimisticOracleV3Interface) {
        return OptimisticOracleV3Interface(address(0));
    }
}

contract TreasuryMockOptimisticOracleV3RevertingGetAssertion {
    error GET_ASSERTION_REVERT();

    function getAssertion(bytes32) external pure returns (OptimisticOracleV3Interface.Assertion memory) {
        revert GET_ASSERTION_REVERT();
    }
}

contract TreasuryMockDirectory {
    mapping(uint256 => address) private _controllerOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }
}

contract TreasuryMockTokens {
    mapping(address => uint256) private _projectIdOf;

    function setProjectIdOf(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}

contract TreasuryMockController {
    uint256 public burnCallCount;
    uint256 public lastBurnProjectId;
    uint256 public lastBurnAmount;
    string public lastBurnMemo;
    bool public shouldRevertBurn;
    TreasuryMockTokens private immutable _tokens;

    error BURN_REVERT();

    constructor(TreasuryMockTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (TreasuryMockTokens) {
        return _tokens;
    }

    function setShouldRevertBurn(bool shouldRevert) external {
        shouldRevertBurn = shouldRevert;
    }

    function burnTokensOf(address, uint256 projectId, uint256 tokenCount, string calldata memo) external {
        if (shouldRevertBurn) revert BURN_REVERT();
        burnCallCount += 1;
        lastBurnProjectId = projectId;
        lastBurnAmount = tokenCount;
        lastBurnMemo = memo;
    }
}

contract TreasuryMockControllerRevertingTokens {
    uint256 public burnCallCount;
    uint256 public lastBurnProjectId;
    uint256 public lastBurnAmount;
    string public lastBurnMemo;

    error TOKENS_REVERT();

    function TOKENS() external pure returns (TreasuryMockTokens) {
        revert TOKENS_REVERT();
    }

    function burnTokensOf(address, uint256 projectId, uint256 tokenCount, string calldata memo) external {
        burnCallCount += 1;
        lastBurnProjectId = projectId;
        lastBurnAmount = tokenCount;
        lastBurnMemo = memo;
    }
}

contract TreasuryMockSupplyAwareController {
    uint256 public burnCallCount;
    uint256 public burnAttemptCount;
    uint256 public lastBurnProjectId;
    uint256 public lastBurnAmount;
    string public lastBurnMemo;
    TreasuryMockTokens private immutable _tokens;

    mapping(uint256 => uint256) private _projectBalance;

    error INSUFFICIENT_PROJECT_BALANCE(uint256 projectId, uint256 available, uint256 requested);

    constructor(TreasuryMockTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (TreasuryMockTokens) {
        return _tokens;
    }

    function setProjectBalance(uint256 projectId, uint256 balance) external {
        _projectBalance[projectId] = balance;
    }

    function projectBalance(uint256 projectId) external view returns (uint256) {
        return _projectBalance[projectId];
    }

    function burnTokensOf(address, uint256 projectId, uint256 tokenCount, string calldata memo) external {
        burnAttemptCount += 1;
        lastBurnProjectId = projectId;
        lastBurnAmount = tokenCount;
        lastBurnMemo = memo;

        uint256 available = _projectBalance[projectId];
        if (available < tokenCount) {
            revert INSUFFICIENT_PROJECT_BALANCE(projectId, available, tokenCount);
        }

        _projectBalance[projectId] = available - tokenCount;
        burnCallCount += 1;
    }
}

contract TreasuryMockHook {
    TreasuryMockDirectory private immutable _directory;

    constructor(TreasuryMockDirectory directory_) {
        _directory = directory_;
    }

    function directory() external view returns (TreasuryMockDirectory) {
        return _directory;
    }
}
