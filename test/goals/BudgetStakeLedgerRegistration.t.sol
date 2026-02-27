// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

contract BudgetStakeLedgerRegistrationTest is Test {
    bytes32 internal constant RECIPIENT_A = bytes32(uint256(1));
    bytes32 internal constant RECIPIENT_B = bytes32(uint256(2));
    bytes32 internal constant RECIPIENT_C = bytes32(uint256(3));

    address internal manager = address(0xB0B);

    MockGoalFlow internal goalFlow;
    MockGoalTreasury internal goalTreasury;
    MockBudgetFlow internal budgetFlow;
    MockBudgetTreasury internal budget;

    BudgetStakeLedger internal ledger;

    function setUp() public {
        goalFlow = new MockGoalFlow(manager);
        goalTreasury = new MockGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        budgetFlow = new MockBudgetFlow(address(goalFlow));
        budget = new MockBudgetTreasury(address(budgetFlow));
    }

    function test_registerBudget_revertsWhenSameBudgetAlreadyRegisteredToDifferentRecipient() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(manager);
        vm.expectRevert(IBudgetStakeLedger.BUDGET_ALREADY_REGISTERED.selector);
        ledger.registerBudget(RECIPIENT_B, address(budget));

        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(budget));
        assertEq(ledger.budgetForRecipient(RECIPIENT_B), address(0));
        assertEq(ledger.trackedBudgetCount(), 1);
    }

    function test_registerBudget_sameRecipientAndBudget_isNoop() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(budget));
        assertEq(ledger.trackedBudgetCount(), 1);
        assertEq(ledger.trackedBudgetAt(0), address(budget));
    }

    function test_registerBudget_removedBudgetCannotBeRegisteredAgain() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(manager);
        ledger.removeBudget(RECIPIENT_A);

        vm.prank(manager);
        vm.expectRevert(IBudgetStakeLedger.BUDGET_ALREADY_REGISTERED.selector);
        ledger.registerBudget(RECIPIENT_B, address(budget));
    }

    function test_registerBudget_removedRecipientCanBeReusedWithNewBudget_andTrackedCountIsPruned() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(manager);
        ledger.removeBudget(RECIPIENT_A);
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));

        MockBudgetFlow replacementFlow = new MockBudgetFlow(address(goalFlow));
        MockBudgetTreasury replacementBudget = new MockBudgetTreasury(address(replacementFlow));

        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(replacementBudget));

        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(replacementBudget));
        assertEq(ledger.trackedBudgetCount(), 1);
        assertEq(ledger.trackedBudgetAt(0), address(replacementBudget));
    }

    function test_removeBudget_prunesMiddleTrackedBudget_andKeepsOtherTrackedBudgetsAddressable() public {
        MockBudgetFlow budgetFlowB = new MockBudgetFlow(address(goalFlow));
        MockBudgetTreasury budgetB = new MockBudgetTreasury(address(budgetFlowB));
        MockBudgetFlow budgetFlowC = new MockBudgetFlow(address(goalFlow));
        MockBudgetTreasury budgetC = new MockBudgetTreasury(address(budgetFlowC));

        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_B, address(budgetB));
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_C, address(budgetC));
        assertEq(ledger.trackedBudgetCount(), 3);

        vm.prank(manager);
        ledger.removeBudget(RECIPIENT_B);

        assertEq(ledger.budgetForRecipient(RECIPIENT_B), address(0));
        assertEq(ledger.trackedBudgetCount(), 2);

        address tracked0 = ledger.trackedBudgetAt(0);
        address tracked1 = ledger.trackedBudgetAt(1);
        assertTrue(tracked0 != address(budgetB) && tracked1 != address(budgetB));
        assertTrue(tracked0 == address(budget) || tracked1 == address(budget));
        assertTrue(tracked0 == address(budgetC) || tracked1 == address(budgetC));

        budget.setResolvedAt(1);
        assertFalse(ledger.allTrackedBudgetsResolved());
        budgetC.setResolvedAt(2);
        assertTrue(ledger.allTrackedBudgetsResolved());
    }

    function test_registerBudget_trackingAllowsLegacyCapPlusOneReadds_withPruning() public {
        uint256 legacyCap = 170;
        for (uint256 i = 0; i < legacyCap + 1; i++) {
            MockBudgetFlow budgetFlow_ = new MockBudgetFlow(address(goalFlow));
            MockBudgetTreasury budget_ = new MockBudgetTreasury(address(budgetFlow_));

            vm.prank(manager);
            ledger.registerBudget(RECIPIENT_A, address(budget_));

            vm.prank(manager);
            ledger.removeBudget(RECIPIENT_A);
        }

        MockBudgetFlow additionalFlow = new MockBudgetFlow(address(goalFlow));
        MockBudgetTreasury additionalBudget = new MockBudgetTreasury(address(additionalFlow));
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(additionalBudget));

        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(additionalBudget));
        assertEq(ledger.trackedBudgetCount(), 1);
    }

    function test_registerBudget_andRemoveBudget_revertAfterFinalizationStarts() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(address(goalTreasury));
        ledger.finalize(uint8(IGoalTreasury.GoalState.Succeeded), uint64(block.timestamp));

        MockBudgetFlow anotherFlow = new MockBudgetFlow(address(goalFlow));
        MockBudgetTreasury anotherBudget = new MockBudgetTreasury(address(anotherFlow));

        vm.prank(manager);
        vm.expectRevert(IBudgetStakeLedger.REGISTRATION_CLOSED.selector);
        ledger.registerBudget(RECIPIENT_B, address(anotherBudget));

        vm.prank(manager);
        vm.expectRevert(IBudgetStakeLedger.REGISTRATION_CLOSED.selector);
        ledger.removeBudget(RECIPIENT_A);
    }

    function test_registerBudget_requiresFlowRecipientAdmin_notLegacyManager() public {
        address recipientAdmin = address(0xACE);
        goalFlow.setRecipientAdmin(recipientAdmin);

        vm.prank(manager);
        vm.expectRevert(IBudgetStakeLedger.ONLY_BUDGET_REGISTRY_MANAGER.selector);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(recipientAdmin);
        ledger.registerBudget(RECIPIENT_A, address(budget));
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(budget));

        vm.prank(manager);
        vm.expectRevert(IBudgetStakeLedger.ONLY_BUDGET_REGISTRY_MANAGER.selector);
        ledger.removeBudget(RECIPIENT_A);

        vm.prank(recipientAdmin);
        ledger.removeBudget(RECIPIENT_A);
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));
    }

    function test_removeBudget_marksBudgetAsResolvedForAllTrackedBudgetsResolved() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        vm.prank(manager);
        ledger.removeBudget(RECIPIENT_A);

        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));
        assertEq(ledger.trackedBudgetCount(), 0);
        assertTrue(ledger.allTrackedBudgetsResolved());

        budget.setResolvedAt(1);
        assertTrue(ledger.allTrackedBudgetsResolved());
    }

    function test_removeBudget_activeButNotActivatedBudgetDoesNotLockRewardHistory() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        budget.setDeadline(1);
        budget.setState(IBudgetTreasury.BudgetState.Active);
        budget.setActivatedAt(0);

        vm.prank(manager);
        bool lockRewardHistory = ledger.removeBudget(RECIPIENT_A);

        assertFalse(lockRewardHistory);
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));
        assertEq(ledger.trackedBudgetCount(), 0);
        assertTrue(ledger.allTrackedBudgetsResolved());
    }

    function test_removeBudget_activationLockedBudgetStaysTrackedUntilResolved() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        budget.setActivatedAt(uint64(block.timestamp));
        budget.setDeadline(1);
        budget.setState(IBudgetTreasury.BudgetState.Active);

        vm.prank(manager);
        bool lockRewardHistory = ledger.removeBudget(RECIPIENT_A);

        assertTrue(lockRewardHistory);
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));
        assertEq(ledger.trackedBudgetCount(), 1);
        assertFalse(ledger.allTrackedBudgetsResolved());

        budget.setResolvedAt(2);
        budget.setState(IBudgetTreasury.BudgetState.Succeeded);
        assertTrue(ledger.allTrackedBudgetsResolved());
    }

    function test_removeBudget_activationLockedBudgetFailedResolutionStillCountsAsResolved() public {
        vm.prank(manager);
        ledger.registerBudget(RECIPIENT_A, address(budget));

        budget.setActivatedAt(uint64(block.timestamp));
        budget.setDeadline(1);
        budget.setState(IBudgetTreasury.BudgetState.Active);

        vm.prank(manager);
        bool lockRewardHistory = ledger.removeBudget(RECIPIENT_A);

        assertTrue(lockRewardHistory);
        assertEq(ledger.budgetForRecipient(RECIPIENT_A), address(0));
        assertEq(ledger.trackedBudgetCount(), 1);
        assertFalse(ledger.allTrackedBudgetsResolved());

        budget.setResolvedAt(2);
        budget.setState(IBudgetTreasury.BudgetState.Failed);
        assertTrue(ledger.allTrackedBudgetsResolved());
    }
}

contract MockGoalTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract MockGoalFlow {
    address public manager;
    address private _recipientAdmin;

    constructor(address manager_) {
        manager = manager_;
        _recipientAdmin = manager_;
    }

    function setRecipientAdmin(address recipientAdmin_) external {
        _recipientAdmin = recipientAdmin_;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }
}

contract MockBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract MockBudgetTreasury {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;
    uint64 public deadline;
    uint256 public activationThreshold = 1;
    uint256 public treasuryBalance;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        activatedAt = activatedAt_;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }

    function setExecutionDuration(uint64 executionDuration_) external {
        executionDuration = executionDuration_;
    }

    function setFundingDeadline(uint64 fundingDeadline_) external {
        fundingDeadline = fundingDeadline_;
    }

    function setDeadline(uint64 deadline_) external {
        deadline = deadline_;
    }

    function setActivationThreshold(uint256 activationThreshold_) external {
        activationThreshold = activationThreshold_;
    }

    function setTreasuryBalance(uint256 treasuryBalance_) external {
        treasuryBalance = treasuryBalance_;
    }
}
