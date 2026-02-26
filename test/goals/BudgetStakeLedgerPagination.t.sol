// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

contract BudgetStakeLedgerPaginationTest is Test {
    uint8 internal constant GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint32 internal constant FULL_SCALED = 1_000_000;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;
    uint256 internal constant BUDGET_COUNT = 40;
    uint256 internal constant PREP_STEP = 5;

    address internal constant ACCOUNT = address(0xA11CE);

    PaginationMockGoalFlow internal goalFlow;
    PaginationMockGoalTreasury internal goalTreasury;
    BudgetStakeLedger internal ledger;

    PaginationMockBudgetTreasury[] internal budgets;
    bytes32[] internal recipientIds;

    function setUp() public {
        goalFlow = new PaginationMockGoalFlow(address(this));
        goalTreasury = new PaginationMockGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        _registerBudgets(BUDGET_COUNT);
    }

    function test_finalize_success_canProgressInChunks() public {
        uint64 finalizeTs = uint64(block.timestamp);
        _markAllBudgetsResolved(IBudgetTreasury.BudgetState.Succeeded, finalizeTs);

        vm.prank(address(goalTreasury));
        ledger.finalize(GOAL_SUCCEEDED, finalizeTs);

        assertTrue(ledger.finalizationInProgress());
        assertFalse(ledger.finalized());
        uint256 cursorAfterInit = ledger.finalizeCursor();
        assertGt(cursorAfterInit, 0);
        assertLt(cursorAfterInit, BUDGET_COUNT);

        vm.expectRevert(IBudgetStakeLedger.INVALID_STEP_SIZE.selector);
        ledger.finalizeStep(0);

        uint256 guard;
        while (ledger.finalizationInProgress()) {
            ledger.finalizeStep(4);
            unchecked {
                ++guard;
            }
            assertLe(guard, 20);
        }

        assertTrue(ledger.finalized());
        assertFalse(ledger.finalizationInProgress());
        assertEq(ledger.finalizeCursor(), BUDGET_COUNT);
        assertTrue(ledger.budgetSucceededAtFinalize(address(budgets[0])));
        assertTrue(ledger.budgetSucceededAtFinalize(address(budgets[BUDGET_COUNT - 1])));
        assertEq(ledger.budgetResolvedAtFinalize(address(budgets[0])), finalizeTs);

        vm.expectRevert(IBudgetStakeLedger.FINALIZATION_NOT_IN_PROGRESS.selector);
        ledger.finalizeStep(1);
    }

    function test_finalize_success_stallsOnUnresolvedBudgetUntilResolution() public {
        uint64 finalizeTs = uint64(block.timestamp);
        _markAllBudgetsResolved(IBudgetTreasury.BudgetState.Succeeded, finalizeTs);

        uint256 unresolvedIndex = 5;
        budgets[unresolvedIndex].setResolvedAt(0);
        budgets[unresolvedIndex].setState(IBudgetTreasury.BudgetState.Active);

        vm.prank(address(goalTreasury));
        ledger.finalize(GOAL_SUCCEEDED, finalizeTs);

        assertTrue(ledger.finalizationInProgress());
        assertFalse(ledger.finalized());
        assertEq(ledger.finalizeCursor(), unresolvedIndex);

        (bool done, uint256 processed) = ledger.finalizeStep(4);
        assertFalse(done);
        assertEq(processed, 0);
        assertEq(ledger.finalizeCursor(), unresolvedIndex);
        assertTrue(ledger.finalizationInProgress());

        uint64 resolvedAt = finalizeTs + 1;
        budgets[unresolvedIndex].setState(IBudgetTreasury.BudgetState.Succeeded);
        budgets[unresolvedIndex].setResolvedAt(resolvedAt);

        uint256 guard;
        while (ledger.finalizationInProgress()) {
            ledger.finalizeStep(6);
            unchecked {
                ++guard;
            }
            assertLe(guard, 20);
        }

        assertTrue(ledger.finalized());
        assertEq(ledger.finalizeCursor(), BUDGET_COUNT);
        assertTrue(ledger.budgetSucceededAtFinalize(address(budgets[unresolvedIndex])));
        assertEq(ledger.budgetResolvedAtFinalize(address(budgets[unresolvedIndex])), resolvedAt);
    }

    function test_finalize_success_doesNotStallOnRemovedBudgetWithZeroResolvedAt() public {
        uint64 finalizeTs = uint64(block.timestamp);
        _markAllBudgetsResolved(IBudgetTreasury.BudgetState.Succeeded, finalizeTs);

        uint256 removedIndex = 5;
        address removedBudget = address(budgets[removedIndex]);
        ledger.removeBudget(recipientIds[removedIndex]);
        budgets[removedIndex].setResolvedAt(0);
        budgets[removedIndex].setState(IBudgetTreasury.BudgetState.Active);

        vm.prank(address(goalTreasury));
        ledger.finalize(GOAL_SUCCEEDED, finalizeTs);

        assertTrue(ledger.finalizationInProgress());
        assertGt(ledger.finalizeCursor(), removedIndex);

        uint256 guard;
        while (ledger.finalizationInProgress()) {
            ledger.finalizeStep(6);
            unchecked {
                ++guard;
            }
            assertLe(guard, 20);
        }

        assertTrue(ledger.finalized());
        assertEq(ledger.finalizeCursor(), ledger.trackedBudgetCount());
        assertFalse(ledger.budgetSucceededAtFinalize(removedBudget));
        assertEq(ledger.budgetResolvedAtFinalize(removedBudget), 0);
    }

    function test_finalize_success_removedMiddleBudgetStillStallsOnSwappedUnresolvedBudget() public {
        uint64 finalizeTs = uint64(block.timestamp);
        _markAllBudgetsResolved(IBudgetTreasury.BudgetState.Succeeded, finalizeTs);

        uint256 removedIndex = 5;
        PaginationMockBudgetTreasury swappedBudget = budgets[BUDGET_COUNT - 1];
        address removedBudget = address(budgets[removedIndex]);

        ledger.removeBudget(recipientIds[removedIndex]);
        assertEq(ledger.budgetForRecipient(recipientIds[removedIndex]), address(0));

        swappedBudget.setResolvedAt(0);
        swappedBudget.setState(IBudgetTreasury.BudgetState.Active);

        vm.prank(address(goalTreasury));
        ledger.finalize(GOAL_SUCCEEDED, finalizeTs);

        assertTrue(ledger.finalizationInProgress());
        assertEq(ledger.finalizeCursor(), removedIndex);

        (bool done, uint256 processed) = ledger.finalizeStep(4);
        assertFalse(done);
        assertEq(processed, 0);
        assertEq(ledger.finalizeCursor(), removedIndex);

        uint64 resolvedAt = finalizeTs + 1;
        swappedBudget.setState(IBudgetTreasury.BudgetState.Succeeded);
        swappedBudget.setResolvedAt(resolvedAt);

        uint256 guard;
        while (ledger.finalizationInProgress()) {
            ledger.finalizeStep(6);
            unchecked {
                ++guard;
            }
            assertLe(guard, 20);
        }

        assertTrue(ledger.finalized());
        assertEq(ledger.trackedBudgetCount(), BUDGET_COUNT - 1);
        assertEq(ledger.finalizeCursor(), ledger.trackedBudgetCount());
        assertFalse(ledger.budgetSucceededAtFinalize(removedBudget));
        assertTrue(ledger.budgetSucceededAtFinalize(address(swappedBudget)));
        assertEq(ledger.budgetResolvedAtFinalize(address(swappedBudget)), resolvedAt);
    }

    function test_finalize_revertsWhenCalledAgainWhileInProgress() public {
        uint64 finalizeTs = uint64(block.timestamp);
        _markAllBudgetsResolved(IBudgetTreasury.BudgetState.Succeeded, finalizeTs);

        vm.prank(address(goalTreasury));
        ledger.finalize(GOAL_SUCCEEDED, finalizeTs);
        assertTrue(ledger.finalizationInProgress());

        vm.prank(address(goalTreasury));
        vm.expectRevert(IBudgetStakeLedger.FINALIZATION_ALREADY_IN_PROGRESS.selector);
        ledger.finalize(GOAL_SUCCEEDED, finalizeTs);
    }

    function test_prepareUserSuccessfulPoints_canProgressInChunks() public {
        (bytes32[] memory ids, uint32[] memory scaled) = _allocationAcrossAllBudgets();
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        vm.warp(100);
        _checkpoint(ACCOUNT, 0, emptyIds, emptyScaled, _scaledWeight(100), ids, scaled);

        vm.warp(200);
        _checkpoint(ACCOUNT, _scaledWeight(100), ids, scaled, _scaledWeight(100), ids, scaled);

        vm.warp(300);
        _markAllBudgetsResolved(IBudgetTreasury.BudgetState.Succeeded, 300);

        vm.prank(address(goalTreasury));
        ledger.finalize(GOAL_SUCCEEDED, 300);
        while (ledger.finalizationInProgress()) {
            ledger.finalizeStep(6);
        }

        uint256 directPoints = ledger.userSuccessfulPoints(ACCOUNT);
        assertGt(directPoints, 0);

        (bool preparedInitially,, uint256 initialCursor) = ledger.preparedUserSuccessfulPoints(ACCOUNT);
        assertFalse(preparedInitially);
        assertEq(initialCursor, 0);

        uint256 preparedPoints;
        bool done;
        uint256 nextCursor;
        uint256 guard;
        while (!done) {
            (preparedPoints, done, nextCursor) = ledger.prepareUserSuccessfulPoints(ACCOUNT, PREP_STEP);
            unchecked {
                ++guard;
            }
            assertLe(guard, 20);
        }

        assertEq(preparedPoints, directPoints);
        assertEq(nextCursor, BUDGET_COUNT);

        (bool prepared, uint256 cachedPoints, uint256 cursor) = ledger.preparedUserSuccessfulPoints(ACCOUNT);
        assertTrue(prepared);
        assertEq(cachedPoints, directPoints);
        assertEq(cursor, BUDGET_COUNT);

        vm.expectRevert(IBudgetStakeLedger.INVALID_STEP_SIZE.selector);
        ledger.prepareUserSuccessfulPoints(ACCOUNT, 0);
    }

    function _registerBudgets(uint256 count) internal {
        for (uint256 i = 0; i < count; ) {
            bytes32 recipientId = bytes32(i + 1);
            PaginationMockBudgetFlow budgetFlow = new PaginationMockBudgetFlow(address(goalFlow));
            PaginationMockBudgetTreasury budget = new PaginationMockBudgetTreasury(address(budgetFlow));
            budgets.push(budget);
            recipientIds.push(recipientId);

            vm.prank(address(this));
            ledger.registerBudget(recipientId, address(budget));

            unchecked {
                ++i;
            }
        }
    }

    function _markAllBudgetsResolved(IBudgetTreasury.BudgetState state, uint64 resolvedAt) internal {
        for (uint256 i = 0; i < budgets.length; ) {
            budgets[i].setState(state);
            budgets[i].setResolvedAt(resolvedAt);
            unchecked {
                ++i;
            }
        }
    }

    function _allocationAcrossAllBudgets() internal view returns (bytes32[] memory ids, uint32[] memory scaled) {
        ids = new bytes32[](BUDGET_COUNT);
        scaled = new uint32[](BUDGET_COUNT);
        uint32 perBudget = uint32(FULL_SCALED / BUDGET_COUNT);

        for (uint256 i = 0; i < BUDGET_COUNT; ) {
            ids[i] = recipientIds[i];
            scaled[i] = perBudget;
            unchecked {
                ++i;
            }
        }
    }

    function _checkpoint(
        address account,
        uint256 prevWeight,
        bytes32[] memory prevIds,
        uint32[] memory prevScaled,
        uint256 newWeight,
        bytes32[] memory newIds,
        uint32[] memory newScaled
    ) internal {
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(account, prevWeight, prevIds, prevScaled, newWeight, newIds, newScaled);
    }

    function _scaledWeight(uint256 weight) internal pure returns (uint256) {
        return weight * UNIT_WEIGHT_SCALE;
    }
}

contract PaginationMockGoalTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract PaginationMockGoalFlow {
    address private _recipientAdmin;

    constructor(address recipientAdmin_) {
        _recipientAdmin = recipientAdmin_;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }
}

contract PaginationMockBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract PaginationMockBudgetTreasury {
    IBudgetTreasury.BudgetState public state;
    address public flow;
    uint64 public resolvedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }
}
