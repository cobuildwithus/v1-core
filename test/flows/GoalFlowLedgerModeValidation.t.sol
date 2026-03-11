// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalFlowLedgerMode } from "src/library/GoalFlowLedgerMode.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { GoalFlowLedgerModeHarness } from "test/harness/GoalFlowLedgerModeHarness.sol";
import { MockAllocationStrategy } from "test/mocks/MockAllocationStrategy.sol";

contract GoalFlowLedgerModeValidationTest is Test {
    address internal constant EXPECTED_FLOW = address(0xF10);

    GoalFlowLedgerModeHarness internal harness;
    MockAllocationStrategy internal strategy;
    GoalFlowLedgerModeValidationStakeVault internal stakeVault;
    GoalFlowLedgerModeValidationGoalTreasury internal treasury;
    GoalFlowLedgerModeValidationLedger internal ledger;

    function setUp() public {
        harness = new GoalFlowLedgerModeHarness();
        strategy = new MockAllocationStrategy();
        stakeVault = new GoalFlowLedgerModeValidationStakeVault();

        treasury = new GoalFlowLedgerModeValidationGoalTreasury(EXPECTED_FLOW, address(stakeVault));
        ledger = new GoalFlowLedgerModeValidationLedger(address(treasury));

        strategy.setGoalTreasury(address(treasury));

        harness.setStrategy(address(strategy));
    }

    function test_validateOrRevertView_succeedsWhenWiringMatches() public {
        (address goalTreasury, address resolvedStakeVault) = harness.validateView(address(ledger), EXPECTED_FLOW);

        assertEq(goalTreasury, address(treasury));
        assertEq(resolvedStakeVault, address(stakeVault));
    }

    function test_validateOrRevert_succeedsWhenWiringMatches() public {
        (address goalTreasury, address resolvedStakeVault) = harness.validate(address(ledger), EXPECTED_FLOW);

        assertEq(goalTreasury, address(treasury));
        assertEq(resolvedStakeVault, address(stakeVault));
    }

    function test_validateOrRevertView_revertsWhenLedgerHasNoCode() public {
        address invalidLedger = address(0xBADC0DE);
        vm.expectRevert(abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER.selector, invalidLedger));
        harness.validateView(invalidLedger, EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenTreasuryFlowDoesNotMatch() public {
        GoalFlowLedgerModeValidationGoalTreasury wrongFlowTreasury =
            new GoalFlowLedgerModeValidationGoalTreasury(address(0xBEEF), address(stakeVault));
        GoalFlowLedgerModeValidationLedger wrongFlowLedger =
            new GoalFlowLedgerModeValidationLedger(address(wrongFlowTreasury));

        vm.expectRevert(
            abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER_FLOW.selector, EXPECTED_FLOW, address(0xBEEF))
        );
        harness.validateView(address(wrongFlowLedger), EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenStrategyIsNotConfigured() public {
        harness.setStrategy(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(0),
                address(treasury),
                address(0)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenStrategyGoalTreasuryDoesNotMatch() public {
        strategy.setGoalTreasury(address(0x1234));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(strategy),
                address(treasury),
                address(0x1234)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenStrategyMissingGoalTreasuryCapability() public {
        GoalFlowLedgerModeValidationNoGoalTreasuryStrategy noGoalTreasuryStrategy =
            new GoalFlowLedgerModeValidationNoGoalTreasuryStrategy();

        harness.setStrategy(address(noGoalTreasuryStrategy));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(noGoalTreasuryStrategy),
                address(treasury),
                address(0)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateForInitializeView_revertsWhenBootstrapStrategyGoalTreasuryDoesNotMatch() public {
        GoalFlowLedgerModeValidationGoalTreasury bootstrapTreasury =
            new GoalFlowLedgerModeValidationGoalTreasury(address(0), address(0));
        GoalFlowLedgerModeValidationLedger bootstrapLedger =
            new GoalFlowLedgerModeValidationLedger(address(bootstrapTreasury));

        strategy.setGoalTreasury(address(0x1234));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(strategy),
                address(bootstrapTreasury),
                address(0x1234)
            )
        );
        harness.validateForInitializeView(address(bootstrapLedger), EXPECTED_FLOW);
    }

    function test_validateForInitializeView_revertsWhenBootstrapStrategyMissingGoalTreasuryCapability() public {
        GoalFlowLedgerModeValidationGoalTreasury bootstrapTreasury =
            new GoalFlowLedgerModeValidationGoalTreasury(address(0), address(0));
        GoalFlowLedgerModeValidationLedger bootstrapLedger =
            new GoalFlowLedgerModeValidationLedger(address(bootstrapTreasury));
        GoalFlowLedgerModeValidationNoGoalTreasuryStrategy noGoalTreasuryStrategy =
            new GoalFlowLedgerModeValidationNoGoalTreasuryStrategy();

        harness.setStrategy(address(noGoalTreasuryStrategy));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(noGoalTreasuryStrategy),
                address(bootstrapTreasury),
                address(0)
            )
        );
        harness.validateForInitializeView(address(bootstrapLedger), EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenStrategyAccountResolverDoesNotRoundTrip() public {
        GoalFlowLedgerModeValidationBadResolverStrategy badResolverStrategy =
            new GoalFlowLedgerModeValidationBadResolverStrategy(address(treasury));

        harness.setStrategy(address(badResolverStrategy));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER.selector, address(badResolverStrategy)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateOrRevert_revalidatesAfterSetStrategiesCacheReset() public {
        harness.validate(address(ledger), EXPECTED_FLOW);
        strategy.setGoalTreasury(address(0x1234));

        harness.setStrategy(address(strategy));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(strategy),
                address(treasury),
                address(0x1234)
            )
        );
        harness.validate(address(ledger), EXPECTED_FLOW);
    }
}

contract GoalFlowLedgerModeValidationLedger {
    address public goalTreasury;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }
}

contract GoalFlowLedgerModeValidationGoalTreasury {
    address public flow;
    address public stakeVault;
    bool public resolved;

    constructor(address flow_, address stakeVault_) {
        flow = flow_;
        stakeVault = stakeVault_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}

contract GoalFlowLedgerModeValidationStakeVault {}

contract GoalFlowLedgerModeValidationNoGoalTreasuryStrategy is IAllocationStrategy {
    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256 key) external pure returns (address) {
        return address(uint160(key));
    }

    function currentWeight(address, uint256) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(address, uint256, address) external pure returns (bool) {
        return true;
    }

    function strategyKey() external pure returns (string memory) {
        return "no-goal-treasury";
    }
}

contract GoalFlowLedgerModeValidationBadResolverStrategy is IAllocationStrategy {
    address public goalTreasury;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }

    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256) external pure returns (address) {
        return address(0xBEEF);
    }

    function currentWeight(address, uint256) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(address, uint256, address) external pure returns (bool) {
        return true;
    }

    function strategyKey() external pure returns (string memory) {
        return "bad-resolver";
    }
}
