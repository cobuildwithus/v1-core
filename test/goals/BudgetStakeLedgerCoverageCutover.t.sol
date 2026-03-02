// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

contract BudgetStakeLedgerCoverageCutoverTest is Test {
    bytes32 internal constant RECIPIENT = bytes32(uint256(1));
    bytes32 internal constant SECOND_RECIPIENT = bytes32(uint256(2));
    bytes32 internal constant THIRD_RECIPIENT = bytes32(uint256(3));
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);
    address internal constant PIPELINE = address(0xCAFE);
    uint32 internal constant FULL_ALLOCATION_PPM = FlowProtocolConstants.PPM_SCALE;
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

    function test_registeredBudgetEnumeration_retainsRemovedBudgets() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        vm.prank(MANAGER);
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));

        vm.prank(MANAGER);
        ledger.removeBudget(SECOND_RECIPIENT);

        assertEq(ledger.trackedBudgetCount(), 1);
        assertEq(ledger.registeredBudgetCount(), 2);
        assertEq(ledger.registeredBudgetAt(0), address(budget));
        assertEq(ledger.registeredBudgetAt(1), address(secondBudget));
    }

    function test_registeredBudgetEnumeration_duplicateRegistrationDoesNotAppend() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        vm.startPrank(MANAGER);
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        vm.stopPrank();

        assertEq(ledger.trackedBudgetCount(), 2);
        assertEq(ledger.registeredBudgetCount(), 2);
        assertEq(ledger.registeredBudgetAt(0), address(budget));
        assertEq(ledger.registeredBudgetAt(1), address(secondBudget));
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

    function test_checkpointAllocation_sortedMerge_handlesOldSharedAndNewRecipientsDeterministically() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        BudgetStakeLedgerCoverageBudgetTreasury thirdBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        vm.startPrank(MANAGER);
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        ledger.registerBudget(THIRD_RECIPIENT, address(thirdBudget));
        vm.stopPrank();

        bytes32[] memory oldRecipientIds = new bytes32[](2);
        oldRecipientIds[0] = RECIPIENT;
        oldRecipientIds[1] = SECOND_RECIPIENT;

        uint32[] memory oldAllocationPpm = new uint32[](2);
        oldAllocationPpm[0] = 500_000;
        oldAllocationPpm[1] = 500_000;

        bytes32[] memory newRecipientIds = new bytes32[](2);
        newRecipientIds[0] = SECOND_RECIPIENT;
        newRecipientIds[1] = THIRD_RECIPIENT;

        uint32[] memory newAllocationPpm = new uint32[](2);
        newAllocationPpm[0] = 500_000;
        newAllocationPpm[1] = 500_000;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT, 0, new bytes32[](0), new uint32[](0), 10 * UNIT_WEIGHT_SCALE, oldRecipientIds, oldAllocationPpm
        );

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            10 * UNIT_WEIGHT_SCALE,
            oldRecipientIds,
            oldAllocationPpm,
            8 * UNIT_WEIGHT_SCALE,
            newRecipientIds,
            newAllocationPpm
        );

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget)), 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(thirdBudget)), 4 * UNIT_WEIGHT_SCALE);

        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(thirdBudget)), 4 * UNIT_WEIGHT_SCALE);
    }

    function test_checkpointAllocation_revertsOnAllocationDrift() public {
        _checkpointSingle(ACCOUNT, 0, 10 * UNIT_WEIGHT_SCALE);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.ALLOCATION_DRIFT.selector,
                ACCOUNT,
                address(budget),
                10 * UNIT_WEIGHT_SCALE,
                9 * UNIT_WEIGHT_SCALE
            )
        );
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            9 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm,
            8 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm
        );
    }

    function _checkpointSingle(address account, uint256 prevWeight, uint256 newWeight) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(account, prevWeight, ids, allocationPpm, newWeight, ids, allocationPpm);
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
