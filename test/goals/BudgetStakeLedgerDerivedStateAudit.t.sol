// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

contract BudgetStakeLedgerDerivedStateAuditTest is Test {
    bytes32 internal constant RECIPIENT = bytes32(uint256(1));
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);
    address internal constant PIPELINE = address(0xCAFE);
    uint32 internal constant FULL_ALLOCATION_PPM = FlowProtocolConstants.PPM_SCALE;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    BudgetStakeLedgerDerivedStateGoalFlow internal goalFlow;
    BudgetStakeLedgerDerivedStateGoalTreasury internal goalTreasury;
    BudgetStakeLedgerDerivedStateBudgetTreasury internal budget;
    BudgetStakeLedger internal ledger;

    function setUp() public {
        goalFlow = new BudgetStakeLedgerDerivedStateGoalFlow(MANAGER, PIPELINE);
        goalTreasury = new BudgetStakeLedgerDerivedStateGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        BudgetStakeLedgerDerivedStateBudgetFlow budgetFlow = new BudgetStakeLedgerDerivedStateBudgetFlow(address(goalFlow));
        budget = new BudgetStakeLedgerDerivedStateBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        ledger.registerBudget(RECIPIENT, address(budget));
    }

    function test_userBudgetCheckpoint_allocatedStakeTracksLatestCheckpoint() public {
        _checkpointSingle(0, 12 * UNIT_WEIGHT_SCALE);

        IBudgetStakeLedger.UserBudgetCheckpointView memory first = ledger.userBudgetCheckpoint(ACCOUNT, address(budget));
        assertEq(first.allocatedStake, 12 * UNIT_WEIGHT_SCALE);
        assertGt(first.lastCheckpoint, 0);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), first.allocatedStake);

        vm.warp(block.timestamp + 13);
        _checkpointSingle(12 * UNIT_WEIGHT_SCALE, 4 * UNIT_WEIGHT_SCALE);

        IBudgetStakeLedger.UserBudgetCheckpointView memory second = ledger.userBudgetCheckpoint(ACCOUNT, address(budget));
        assertEq(second.allocatedStake, 4 * UNIT_WEIGHT_SCALE);
        assertGt(second.lastCheckpoint, first.lastCheckpoint);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), second.allocatedStake);
    }

    function test_checkpointAllocation_allocationDriftUsesLatestCheckpointValue() public {
        _checkpointSingle(0, 10 * UNIT_WEIGHT_SCALE);
        _checkpointSingle(10 * UNIT_WEIGHT_SCALE, 7 * UNIT_WEIGHT_SCALE);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.ALLOCATION_DRIFT.selector,
                ACCOUNT,
                address(budget),
                7 * UNIT_WEIGHT_SCALE,
                10 * UNIT_WEIGHT_SCALE
            )
        );

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            10 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm,
            6 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm
        );

        IBudgetStakeLedger.UserBudgetCheckpointView memory checkpoint = ledger.userBudgetCheckpoint(ACCOUNT, address(budget));
        assertEq(checkpoint.allocatedStake, 7 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 7 * UNIT_WEIGHT_SCALE);
    }

    function _checkpointSingle(uint256 prevWeight, uint256 newWeight) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(ACCOUNT, prevWeight, ids, allocationPpm, newWeight, ids, allocationPpm);
    }
}

contract BudgetStakeLedgerDerivedStateGoalTreasury {
    address private _flow;
    bool private _resolved;

    constructor(address flow_) {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function resolved() external view returns (bool) {
        return _resolved;
    }
}

contract BudgetStakeLedgerDerivedStateGoalFlow {
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

contract BudgetStakeLedgerDerivedStateBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract BudgetStakeLedgerDerivedStateBudgetTreasury {
    address public flow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 1 days;
    uint64 public fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Funding;

    constructor(address flow_) {
        flow = flow_;
    }
}
