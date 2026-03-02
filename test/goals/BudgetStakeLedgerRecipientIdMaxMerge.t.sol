// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

contract BudgetStakeLedgerRecipientIdMaxMergeTest is Test {
    bytes32 internal constant MAX_RECIPIENT_ID = bytes32(type(uint256).max);
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant MANAGER = address(0xB0B);
    address internal constant PIPELINE = address(0xCAFE);
    uint32 internal constant FULL_ALLOCATION_PPM = FlowProtocolConstants.PPM_SCALE;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    RecipientIdMaxGoalFlow internal goalFlow;
    RecipientIdMaxGoalTreasury internal goalTreasury;
    RecipientIdMaxBudgetTreasury internal maxBudget;
    BudgetStakeLedger internal ledger;

    function setUp() public {
        goalFlow = new RecipientIdMaxGoalFlow(MANAGER, PIPELINE);
        goalTreasury = new RecipientIdMaxGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        RecipientIdMaxBudgetFlow budgetFlow = new RecipientIdMaxBudgetFlow(address(goalFlow));
        maxBudget = new RecipientIdMaxBudgetTreasury(address(budgetFlow));

        vm.prank(MANAGER);
        ledger.registerBudget(MAX_RECIPIENT_ID, address(maxBudget));
    }

    function test_checkpointAllocation_handlesMaxRecipientIdWhenOldListExhausted() public {
        bytes32[] memory newRecipientIds = new bytes32[](1);
        newRecipientIds[0] = MAX_RECIPIENT_ID;

        uint32[] memory newAllocationPpm = new uint32[](1);
        newAllocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            0,
            new bytes32[](0),
            new uint32[](0),
            7 * UNIT_WEIGHT_SCALE,
            newRecipientIds,
            newAllocationPpm
        );

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(maxBudget)), 7 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(maxBudget)), 7 * UNIT_WEIGHT_SCALE);
    }

    function test_checkpointAllocation_handlesMaxRecipientIdWhenNewListExhausted() public {
        _checkpointMaxRecipient(0, 9 * UNIT_WEIGHT_SCALE);

        bytes32[] memory prevRecipientIds = new bytes32[](1);
        prevRecipientIds[0] = MAX_RECIPIENT_ID;

        uint32[] memory prevAllocationPpm = new uint32[](1);
        prevAllocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            9 * UNIT_WEIGHT_SCALE,
            prevRecipientIds,
            prevAllocationPpm,
            0,
            new bytes32[](0),
            new uint32[](0)
        );

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(maxBudget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(maxBudget)), 0);
    }

    function _checkpointMaxRecipient(uint256 prevWeight, uint256 newWeight) internal {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = MAX_RECIPIENT_ID;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(ACCOUNT, prevWeight, recipientIds, allocationPpm, newWeight, recipientIds, allocationPpm);
    }
}

contract RecipientIdMaxGoalTreasury {
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

contract RecipientIdMaxGoalFlow {
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

contract RecipientIdMaxBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract RecipientIdMaxBudgetTreasury {
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
