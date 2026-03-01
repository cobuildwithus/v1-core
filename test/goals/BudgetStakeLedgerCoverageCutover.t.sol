// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

contract BudgetStakeLedgerCoverageCutoverTest is Test {
    bytes32 internal constant RECIPIENT = bytes32(uint256(1));
    bytes32 internal constant SECOND_RECIPIENT = bytes32(uint256(2));
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);
    address internal constant PIPELINE = address(0xCAFE);
    uint32 internal constant FULL_SCALED = 1_000_000;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    BudgetStakeLedgerCoverageGoalFlow internal goalFlow;
    BudgetStakeLedgerCoverageGoalTreasury internal goalTreasury;
    BudgetStakeLedgerCoverageBudgetFlow internal budgetFlow;
    BudgetStakeLedgerCoverageBudgetTreasury internal budget;
    BudgetStakeLedger internal ledger;

    function setUp() public {
        goalFlow = new BudgetStakeLedgerCoverageGoalFlow(MANAGER, PIPELINE);
        goalTreasury = new BudgetStakeLedgerCoverageGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        budgetFlow = new BudgetStakeLedgerCoverageBudgetFlow(address(goalFlow));
        budget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        ledger.registerBudget(RECIPIENT, address(budget));
    }

    function test_checkpointAllocation_updatesCoverageOnlyStakeAccounting() public {
        _checkpointSingle(ACCOUNT, 0, 12 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 12 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 12 * UNIT_WEIGHT_SCALE);

        _checkpointSingle(ACCOUNT, 12 * UNIT_WEIGHT_SCALE, 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 4 * UNIT_WEIGHT_SCALE);

        IBudgetStakeLedger.TrackedBudgetSummary[] memory summaries = ledger.trackedBudgetSlice(0, 1);
        assertEq(summaries.length, 1);
        assertEq(summaries[0].budget, address(budget));
        assertEq(summaries[0].totalAllocatedStake, 4 * UNIT_WEIGHT_SCALE);
        assertEq(summaries[0].resolvedOrRemovedAt, 0);
    }

    function test_removeBudget_marksTerminalRemovalAndUntracksBudget() public {
        budget.setResolvedAt(80);

        uint64 removedAt = uint64(block.timestamp + 100);
        vm.warp(removedAt);
        vm.prank(MANAGER);
        ledger.removeBudget(RECIPIENT);

        assertEq(ledger.trackedBudgetCount(), 0);
        assertEq(ledger.budgetForRecipient(RECIPIENT), address(0));

        IBudgetStakeLedger.BudgetInfoView memory info = ledger.budgetInfo(address(budget));
        assertFalse(info.isTracked);
        assertEq(info.removedAt, removedAt);
        assertEq(info.resolvedOrRemovedAt, 80);
    }

    function test_allTrackedBudgetsResolved_ignoresRemovedBudgetsAndRequiresActiveTrackedResolved() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        vm.prank(MANAGER);
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));

        assertFalse(ledger.allTrackedBudgetsResolved());

        budget.setResolvedAt(10);
        assertFalse(ledger.allTrackedBudgetsResolved());

        vm.warp(block.timestamp + 20);
        vm.prank(MANAGER);
        ledger.removeBudget(SECOND_RECIPIENT);

        assertTrue(ledger.allTrackedBudgetsResolved());
    }

    function test_checkpointAllocation_noopsAfterGoalResolved() public {
        goalTreasury.setResolved(true);

        _checkpointSingle(ACCOUNT, 0, 9 * UNIT_WEIGHT_SCALE);

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);
    }

    function _checkpointSingle(address account, uint256 prevWeight, uint256 newWeight) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;

        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(account, prevWeight, ids, scaled, newWeight, ids, scaled);
    }
}

contract BudgetStakeLedgerCoverageGoalTreasury {
    address private _flow;
    bool private _resolved;

    constructor(address flow_) {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function setResolved(bool resolved_) external {
        _resolved = resolved_;
    }

    function resolved() external view returns (bool) {
        return _resolved;
    }
}

contract BudgetStakeLedgerCoverageGoalFlow {
    address private _recipientAdmin;
    address private _allocationPipeline;

    constructor(address recipientAdmin_, address allocationPipeline_) {
        _recipientAdmin = recipientAdmin_;
        _allocationPipeline = allocationPipeline_;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }

    function allocationPipeline() external view returns (address) {
        return _allocationPipeline;
    }
}

contract BudgetStakeLedgerCoverageBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasury {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 1 days;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Funding;

    constructor(address flow_) {
        flow = flow_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }
}
