// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

contract BudgetStakeLedgerBranchCoverageTest is Test {
    bytes32 internal constant RECIPIENT = bytes32(uint256(1));
    bytes32 internal constant SECOND_RECIPIENT = bytes32(uint256(2));
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);
    address internal constant OUTSIDER = address(0xBEEF);
    uint32 internal constant FULL_SCALED = 1_000_000;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;
    uint256 internal constant USER_BUDGET_CHECKPOINTS_SLOT = 4;
    uint256 internal constant BUDGET_CHECKPOINTS_SLOT = 5;

    BudgetStakeLedgerCoverageGoalFlow internal goalFlow;
    BudgetStakeLedgerCoverageGoalTreasury internal goalTreasury;
    BudgetStakeLedgerCoverageBudgetFlow internal budgetFlow;
    BudgetStakeLedgerCoverageBudgetTreasury internal budget;
    BudgetStakeLedger internal ledger;

    function setUp() public {
        goalFlow = new BudgetStakeLedgerCoverageGoalFlow(MANAGER);
        goalTreasury = new BudgetStakeLedgerCoverageGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        budgetFlow = new BudgetStakeLedgerCoverageBudgetFlow(address(goalFlow));
        budget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        ledger.registerBudget(RECIPIENT, address(budget));
    }

    function test_constructor_revertsWhenGoalTreasuryIsZero() public {
        vm.expectRevert(IBudgetStakeLedger.ADDRESS_ZERO.selector);
        new BudgetStakeLedger(address(0));
    }

    function test_finalize_allowsConfiguredRewardEscrowCaller() public {
        address rewardEscrow = address(0xEE);
        goalTreasury.setRewardEscrow(rewardEscrow);

        vm.prank(rewardEscrow);
        ledger.finalize(uint8(IGoalTreasury.GoalState.Expired), uint64(block.timestamp));

        assertTrue(ledger.finalized());
    }

    function test_finalize_revertsWhenCallerIsNotGoalTreasuryOrRewardEscrow() public {
        goalTreasury.setRewardEscrow(address(0xEE));

        vm.prank(OUTSIDER);
        vm.expectRevert(IBudgetStakeLedger.ONLY_GOAL_TREASURY.selector);
        ledger.finalize(uint8(IGoalTreasury.GoalState.Expired), uint64(block.timestamp));
    }

    function test_finalize_revertsOnInvalidFinalState() public {
        vm.prank(address(goalTreasury));
        vm.expectRevert(IBudgetStakeLedger.INVALID_FINAL_STATE.selector);
        ledger.finalize(1, uint64(block.timestamp));
    }

    function test_finalize_revertsWhenFinalizedAtIsZero() public {
        vm.prank(address(goalTreasury));
        vm.expectRevert(abi.encodeWithSelector(IBudgetStakeLedger.INVALID_FINALIZATION_TIMESTAMP.selector, uint64(0)));
        ledger.finalize(uint8(IGoalTreasury.GoalState.Expired), 0);
    }

    function test_finalize_revertsWhenFinalizedAtIsInFuture() public {
        uint64 future = uint64(block.timestamp + 1);
        vm.prank(address(goalTreasury));
        vm.expectRevert(abi.encodeWithSelector(IBudgetStakeLedger.INVALID_FINALIZATION_TIMESTAMP.selector, future));
        ledger.finalize(uint8(IGoalTreasury.GoalState.Expired), future);
    }

    function test_registerBudget_revertsWhenBudgetAddressIsZero() public {
        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.ADDRESS_ZERO.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(0));
    }

    function test_registerBudget_revertsWhenBudgetAddressHasNoCode() public {
        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(0xCAFE));
    }

    function test_registerBudget_revertsWhenGoalFlowIsUnset() public {
        goalTreasury.setFlow(address(0));
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IBudgetStakeLedger.INVALID_GOAL_FLOW.selector, address(0)));
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetFlowIsUnset() public {
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(0));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetMissingFlowSurface() public {
        BudgetStakeLedgerCoverageBudgetTreasuryMissingFlow budget2 =
            new BudgetStakeLedgerCoverageBudgetTreasuryMissingFlow();

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetFlowMissingParentSurface() public {
        BudgetStakeLedgerCoverageBudgetFlowMissingParent budgetFlow2 = new BudgetStakeLedgerCoverageBudgetFlowMissingParent();
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow2));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetFlowAddressHasNoCode() public {
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(0xD00D));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetParentIsNotGoalFlow() public {
        BudgetStakeLedgerCoverageBudgetFlow budgetFlow2 = new BudgetStakeLedgerCoverageBudgetFlow(address(0xD00D));
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow2));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetMissingResolvedAtSurface() public {
        BudgetStakeLedgerCoverageBudgetTreasuryMissingResolvedAt budget2 =
            new BudgetStakeLedgerCoverageBudgetTreasuryMissingResolvedAt(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetMissingStateSurface() public {
        BudgetStakeLedgerCoverageBudgetTreasuryMissingState budget2 =
            new BudgetStakeLedgerCoverageBudgetTreasuryMissingState(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetMissingExecutionDurationSurface() public {
        BudgetStakeLedgerCoverageBudgetTreasuryMissingExecutionDuration budget2 =
            new BudgetStakeLedgerCoverageBudgetTreasuryMissingExecutionDuration(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetMissingFundingDeadlineSurface() public {
        BudgetStakeLedgerCoverageBudgetTreasuryMissingFundingDeadline budget2 =
            new BudgetStakeLedgerCoverageBudgetTreasuryMissingFundingDeadline(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenBudgetMissingActivatedAtSurface() public {
        BudgetStakeLedgerCoverageBudgetTreasuryMissingActivatedAt budget2 =
            new BudgetStakeLedgerCoverageBudgetTreasuryMissingActivatedAt(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenExecutionDurationIsZero() public {
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        budget2.setExecutionDuration(0);

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_revertsWhenFundingDeadlineIsZero() public {
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        budget2.setFundingDeadline(0);

        vm.prank(MANAGER);
        vm.expectRevert(IBudgetStakeLedger.INVALID_BUDGET.selector);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_registerBudget_setsMinimumMaturationPeriodWhenScoringWindowBelowDivisor() public {
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        budget2.setFundingDeadline(uint64(block.timestamp + 1));

        vm.prank(MANAGER);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));

        IBudgetStakeLedger.BudgetInfoView memory info = ledger.budgetInfo(address(budget2));
        assertEq(info.maturationPeriodSeconds, 1);
    }

    function test_registerBudget_clampsScoringStartToPastFundingDeadlineAndPreventsPointAccrual() public {
        vm.warp(100);
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        budget2.setFundingDeadline(95);

        vm.prank(MANAGER);
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));

        IBudgetStakeLedger.BudgetInfoView memory info = ledger.budgetInfo(address(budget2));
        assertEq(info.scoringEndsAt, 95);
        assertEq(info.scoringStartsAt, 95);
        assertEq(info.maturationPeriodSeconds, 1);

        bytes32[] memory newIds = new bytes32[](1);
        newIds[0] = SECOND_RECIPIENT;
        uint32[] memory newScaled = new uint32[](1);
        newScaled[0] = FULL_SCALED;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(ACCOUNT, 0, new bytes32[](0), new uint32[](0), 20 * UNIT_WEIGHT_SCALE, newIds, newScaled);

        vm.warp(150);
        assertEq(ledger.userPointsOnBudget(ACCOUNT, address(budget2)), 0);
        assertEq(ledger.budgetPoints(address(budget2)), 0);
    }

    function test_registerBudget_revertsWhenGoalFlowIsNotContract() public {
        goalTreasury.setFlow(address(0xBEEF));
        BudgetStakeLedgerCoverageBudgetTreasury budget2 = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IBudgetStakeLedger.INVALID_GOAL_FLOW.selector, address(0xBEEF)));
        ledger.registerBudget(SECOND_RECIPIENT, address(budget2));
    }

    function test_removeBudget_isNoOpWhenRecipientIsUnknown() public {
        uint256 trackedBefore = ledger.trackedBudgetCount();

        vm.prank(MANAGER);
        ledger.removeBudget(bytes32(uint256(999)));

        assertEq(ledger.trackedBudgetCount(), trackedBefore);
        assertEq(ledger.budgetForRecipient(bytes32(uint256(999))), address(0));
    }

    function test_checkpointAllocation_takeOldBranchClearsRemovedRecipientStake() public {
        uint256 oldWeight = 12 * UNIT_WEIGHT_SCALE;
        _checkpointSingle(ACCOUNT, 0, oldWeight);

        bytes32[] memory prevIds = new bytes32[](1);
        prevIds[0] = RECIPIENT;
        uint32[] memory prevScaled = new uint32[](1);
        prevScaled[0] = FULL_SCALED;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(ACCOUNT, oldWeight, prevIds, prevScaled, 0, new bytes32[](0), new uint32[](0));

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);
    }

    function test_checkpointAllocation_increasePathUpdatesUnmaturedAndAllocatedTotals() public {
        uint256 newWeight = 25 * UNIT_WEIGHT_SCALE;
        _checkpointSingle(ACCOUNT, 0, newWeight);

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), newWeight);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), newWeight);

        IBudgetStakeLedger.UserBudgetCheckpointView memory checkpoint =
            ledger.userBudgetCheckpoint(ACCOUNT, address(budget));
        assertEq(checkpoint.unmaturedStake, newWeight);
    }

    function test_checkpointAllocation_clampsUnmaturedWhenCorruptedStateExceedsNewAllocation() public {
        uint256 oldAllocated = 100 * UNIT_WEIGHT_SCALE;
        uint256 newAllocated = 50 * UNIT_WEIGHT_SCALE;
        uint256 corruptedUnmatured = 300 * UNIT_WEIGHT_SCALE;

        _setUserAllocated(ACCOUNT, address(budget), oldAllocated);
        _setUserUnmatured(ACCOUNT, address(budget), corruptedUnmatured);
        _setBudgetTotalAllocated(address(budget), oldAllocated);
        _setBudgetTotalUnmatured(address(budget), corruptedUnmatured);

        _checkpointSingle(ACCOUNT, oldAllocated, newAllocated);

        IBudgetStakeLedger.UserBudgetCheckpointView memory userCheckpoint =
            ledger.userBudgetCheckpoint(ACCOUNT, address(budget));
        assertEq(userCheckpoint.allocatedStake, newAllocated);
        assertEq(userCheckpoint.unmaturedStake, newAllocated);
    }

    function test_checkpointAllocation_revertsOnTotalUnmaturedUnderflowFromCorruptedState() public {
        uint256 oldAllocated = 100 * UNIT_WEIGHT_SCALE;
        uint256 newAllocated = 50 * UNIT_WEIGHT_SCALE;
        uint256 totalUnmatured = 10 * UNIT_WEIGHT_SCALE;
        uint256 expectedDecrease = 50 * UNIT_WEIGHT_SCALE;

        _setUserAllocated(ACCOUNT, address(budget), oldAllocated);
        _setUserUnmatured(ACCOUNT, address(budget), oldAllocated);
        _setBudgetTotalAllocated(address(budget), oldAllocated);
        _setBudgetTotalUnmatured(address(budget), totalUnmatured);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.TOTAL_UNMATURED_UNDERFLOW.selector,
                address(budget),
                totalUnmatured,
                expectedDecrease
            )
        );
        _checkpointSingle(ACCOUNT, oldAllocated, newAllocated);
    }

    function test_checkpointAllocation_revertsOnTotalAllocatedUnderflowFromCorruptedState() public {
        uint256 oldAllocated = 100 * UNIT_WEIGHT_SCALE;
        uint256 newAllocated = 50 * UNIT_WEIGHT_SCALE;
        uint256 totalAllocated = 10 * UNIT_WEIGHT_SCALE;
        uint256 expectedDecrease = 50 * UNIT_WEIGHT_SCALE;

        _setUserAllocated(ACCOUNT, address(budget), oldAllocated);
        _setUserUnmatured(ACCOUNT, address(budget), 0);
        _setBudgetTotalAllocated(address(budget), totalAllocated);
        _setBudgetTotalUnmatured(address(budget), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.TOTAL_ALLOCATED_UNDERFLOW.selector,
                address(budget),
                totalAllocated,
                expectedDecrease
            )
        );
        _checkpointSingle(ACCOUNT, oldAllocated, newAllocated);
    }

    function test_userAndBudgetPointsOnUntrackedBudget_returnZero() public {
        address unknownBudget = address(0x1234);
        assertEq(ledger.userPointsOnBudget(ACCOUNT, unknownBudget), 0);
        assertEq(ledger.budgetPoints(unknownBudget), 0);
    }

    function test_getPastUserAllocationWeight_returnsSnapshotValueByBlock() public {
        uint256 weight1 = 25 * UNIT_WEIGHT_SCALE;
        uint256 weight2 = 10 * UNIT_WEIGHT_SCALE;
        uint256 startBlock = block.number;

        vm.roll(startBlock + 1);
        _checkpointSingle(ACCOUNT, 0, weight1);
        vm.roll(startBlock + 2);
        _checkpointSingle(ACCOUNT, weight1, weight2);
        vm.roll(startBlock + 3);

        assertEq(ledger.getPastUserAllocationWeight(ACCOUNT, startBlock + 1), weight1);
        assertEq(ledger.getPastUserAllocationWeight(ACCOUNT, startBlock + 2), weight2);
    }

    function test_getPastUserAllocationWeight_preservesSnapshotAcrossUnchangedCheckpoint() public {
        uint256 weight = 25 * UNIT_WEIGHT_SCALE;
        uint256 startBlock = block.number;

        vm.roll(startBlock + 1);
        _checkpointSingle(ACCOUNT, 0, weight);
        vm.roll(startBlock + 2);
        _checkpointSingle(ACCOUNT, weight, weight);
        vm.roll(startBlock + 3);

        assertEq(ledger.getPastUserAllocationWeight(ACCOUNT, startBlock + 1), weight);
        assertEq(ledger.getPastUserAllocationWeight(ACCOUNT, startBlock + 2), weight);
    }

    function test_getPastUserAllocationWeight_revertsForCurrentBlock() public {
        vm.expectRevert(IBudgetStakeLedger.BLOCK_NOT_YET_MINED.selector);
        ledger.getPastUserAllocationWeight(ACCOUNT, block.number);
    }

    function _checkpointSingle(address account, uint256 prevWeight, uint256 newWeight) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(account, prevWeight, ids, scaled, newWeight, ids, scaled);
    }

    function _setUserAllocated(address account, address budgetAddress, uint256 value) internal {
        bytes32 base = _userBudgetCheckpointBase(account, budgetAddress);
        vm.store(address(ledger), base, bytes32(value));
    }

    function _setUserUnmatured(address account, address budgetAddress, uint256 value) internal {
        bytes32 base = _userBudgetCheckpointBase(account, budgetAddress);
        vm.store(address(ledger), bytes32(uint256(base) + 1), bytes32(value));
    }

    function _setBudgetTotalAllocated(address budgetAddress, uint256 value) internal {
        bytes32 base = _budgetCheckpointBase(budgetAddress);
        vm.store(address(ledger), base, bytes32(value));
    }

    function _setBudgetTotalUnmatured(address budgetAddress, uint256 value) internal {
        bytes32 base = _budgetCheckpointBase(budgetAddress);
        vm.store(address(ledger), bytes32(uint256(base) + 1), bytes32(value));
    }

    function _userBudgetCheckpointBase(address account, address budgetAddress) internal pure returns (bytes32) {
        bytes32 outer = keccak256(abi.encode(account, USER_BUDGET_CHECKPOINTS_SLOT));
        return keccak256(abi.encode(budgetAddress, outer));
    }

    function _budgetCheckpointBase(address budgetAddress) internal pure returns (bytes32) {
        return keccak256(abi.encode(budgetAddress, BUDGET_CHECKPOINTS_SLOT));
    }
}

contract BudgetStakeLedgerCoverageGoalTreasury {
    address private _flow;
    address private _rewardEscrow;

    constructor(address flow_) {
        _flow = flow_;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        _rewardEscrow = rewardEscrow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function rewardEscrow() external view returns (address) {
        return _rewardEscrow;
    }
}

contract BudgetStakeLedgerCoverageGoalFlow {
    address private _recipientAdmin;
    address private _allocationPipeline;

    constructor(address recipientAdmin_) {
        _recipientAdmin = recipientAdmin_;
    }

    function setRecipientAdmin(address recipientAdmin_) external {
        _recipientAdmin = recipientAdmin_;
    }

    function setAllocationPipeline(address allocationPipeline_) external {
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

    function setParent(address parent_) external {
        parent = parent_;
    }
}

contract BudgetStakeLedgerCoverageBudgetFlowMissingParent { }

contract BudgetStakeLedgerCoverageBudgetTreasury {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }

    function setExecutionDuration(uint64 executionDuration_) external {
        executionDuration = executionDuration_;
    }

    function setFundingDeadline(uint64 fundingDeadline_) external {
        fundingDeadline = fundingDeadline_;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasuryMissingFlow {
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state;

    constructor() {
        state = IBudgetTreasury.BudgetState.Funding;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasuryMissingExecutionDuration {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasuryMissingFundingDeadline {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasuryMissingActivatedAt {
    address public flow;
    uint64 public resolvedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasuryMissingResolvedAt {
    address public flow;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }
}

contract BudgetStakeLedgerCoverageBudgetTreasuryMissingState {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;

    constructor(address flow_) {
        flow = flow_;
    }
}
