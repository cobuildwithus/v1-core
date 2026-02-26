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

        strategy.setStakeVault(address(stakeVault));

        address[] memory strategies = new address[](1);
        strategies[0] = address(strategy);
        harness.setStrategies(strategies);

        treasury = new GoalFlowLedgerModeValidationGoalTreasury(EXPECTED_FLOW, address(stakeVault));
        ledger = new GoalFlowLedgerModeValidationLedger(address(treasury));
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

    function test_validateOrRevertView_revertsWhenMultipleStrategiesConfigured() public {
        MockAllocationStrategy secondStrategy = new MockAllocationStrategy();
        secondStrategy.setStakeVault(address(stakeVault));

        address[] memory strategies = new address[](2);
        strategies[0] = address(strategy);
        strategies[1] = address(secondStrategy);
        harness.setStrategies(strategies);

        vm.expectRevert(abi.encodeWithSelector(IFlow.ALLOCATION_LEDGER_REQUIRES_SINGLE_STRATEGY.selector, 2));
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenStrategyStakeVaultDoesNotMatch() public {
        strategy.setStakeVault(address(0x1234));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(strategy),
                address(stakeVault),
                address(0x1234)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateOrRevertView_revertsWhenStrategyMissingStakeVaultCapability() public {
        GoalFlowLedgerModeValidationNoStakeVaultStrategy noStakeVaultStrategy =
            new GoalFlowLedgerModeValidationNoStakeVaultStrategy();

        address[] memory strategies = new address[](1);
        strategies[0] = address(noStakeVaultStrategy);
        harness.setStrategies(strategies);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(noStakeVaultStrategy),
                address(stakeVault),
                address(0)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateOrRevert_revalidatesAfterSetStrategiesCacheReset() public {
        harness.validate(address(ledger), EXPECTED_FLOW);
        strategy.setStakeVault(address(0x1234));

        address[] memory strategies = new address[](1);
        strategies[0] = address(strategy);
        harness.setStrategies(strategies);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(strategy),
                address(stakeVault),
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

    constructor(address flow_, address stakeVault_) {
        flow = flow_;
        stakeVault = stakeVault_;
    }
}

contract GoalFlowLedgerModeValidationStakeVault {}

contract GoalFlowLedgerModeValidationNoStakeVaultStrategy is IAllocationStrategy {
    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256 key) external pure returns (address) {
        return address(uint160(key));
    }

    function currentWeight(uint256) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(uint256, address) external pure returns (bool) {
        return true;
    }

    function canAccountAllocate(address) external pure returns (bool) {
        return true;
    }

    function accountAllocationWeight(address) external pure returns (uint256) {
        return 1;
    }

    function strategyKey() external pure returns (string memory) {
        return "no-stake-vault";
    }
}
