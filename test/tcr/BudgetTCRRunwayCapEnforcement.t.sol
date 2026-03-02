// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { IFlow } from "src/interfaces/IFlow.sol";

/// @dev Minimal harness to exercise BudgetTCR's internal cap-enforcement logic in isolation.
contract BudgetTCRHarness is BudgetTCR {
    function setGoalFlow(address goalFlow_) external {
        goalFlow = IFlow(goalFlow_);
    }

    function enforceBudgetInflowCaps(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address budgetStakeLedger,
        uint256 lambda
    ) external {
        _bestEffortEnforceBudgetCreditCap(itemID, childFlow, budgetTreasury, budgetStakeLedger, lambda);
    }
}

contract MockGoalFlow {
    mapping(address => uint256) internal _totalReceived;
    mapping(bytes32 => bool) internal _enabled;

    function setTotalReceivedByMember(address member, uint256 amount) external {
        _totalReceived[member] = amount;
    }

    function getTotalReceivedByMember(address member) external view returns (uint256) {
        return _totalReceived[member];
    }

    function setRecipientEnabled(bytes32 recipientId, bool enabled) external {
        _enabled[recipientId] = enabled;
    }

    function recipientEnabled(bytes32 recipientId) external view returns (bool) {
        return _enabled[recipientId];
    }
}

contract MockBudgetStakeLedger {
    mapping(address => uint256) internal _coverage;

    function setCoverage(address budgetTreasury, uint256 coverage) external {
        _coverage[budgetTreasury] = coverage;
    }

    function budgetTotalAllocatedStake(address budgetTreasury) external view returns (uint256) {
        return _coverage[budgetTreasury];
    }
}

contract RevertingBudgetStakeLedger {
    function budgetTotalAllocatedStake(address) external pure returns (uint256) {
        revert("STAKE_READ_FAIL");
    }
}

contract MockBudgetTreasury {
    uint64 internal _executionDuration;
    uint256 internal _runwayCap;

    constructor(uint64 duration, uint256 runwayCap_) {
        _executionDuration = duration;
        _runwayCap = runwayCap_;
    }

    function executionDuration() external view returns (uint64) {
        return _executionDuration;
    }

    function runwayCap() external view returns (uint256) {
        return _runwayCap;
    }
}

contract RevertingExecutionDurationBudgetTreasury {
    uint256 internal _runwayCap;

    constructor(uint256 runwayCap_) {
        _runwayCap = runwayCap_;
    }

    function executionDuration() external pure returns (uint64) {
        revert("DURATION_READ_FAIL");
    }

    function runwayCap() external view returns (uint256) {
        return _runwayCap;
    }
}

contract BudgetTCRRunwayCapEnforcementTest is Test {
    BudgetTCRHarness internal _tcr;
    MockGoalFlow internal _goalFlow;
    MockBudgetStakeLedger internal _stakeLedger;

    bytes32 internal constant ITEM_ID = bytes32(uint256(0xB0D));
    address internal constant CHILD_FLOW = address(0xCAFE);

    function setUp() public {
        _tcr = new BudgetTCRHarness();
        _goalFlow = new MockGoalFlow();
        _stakeLedger = new MockBudgetStakeLedger();

        _tcr.setGoalFlow(address(_goalFlow));
    }

    function test_recipientDisablesAtRunwayBoundaryEvenWhenCreditLineAllowsMore() public {
        // creditLine = coverage * duration / lambda
        // Choose parameters such that creditLine >> runwayCap.
        uint64 duration = 100;
        uint256 runwayCap = 5_000;
        uint256 coverage = 1_000;
        uint256 lambda = 1;

        // creditLine = 1000 * 100 / 1 = 100_000
        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        // Received hits runway cap, but still below credit line.
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);

        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_recipientRemainsEnabledBelowRunwayBoundary() public {
        uint64 duration = 100;
        uint256 runwayCap = 5_000;
        uint256 coverage = 1_000;
        uint256 lambda = 1;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        // One unit below runway cap => should still be enabled (credit line is much larger).
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap - 1);

        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);

        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroRunwayCap_usesCreditLineBoundary() public {
        uint64 duration = 10;
        uint256 runwayCap = 0; // no runway cap
        uint256 coverage = 100;
        uint256 lambda = 1;

        // creditLine = 100 * 10 / 1 = 1_000
        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 999);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 1_000);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroCreditLine_disablesEvenWhenRunwayCapAllowsMore() public {
        uint64 duration = 100;
        uint256 runwayCap = 5_000;
        uint256 coverage = 0; // => creditLine = 0
        uint256 lambda = 1;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        // Even with received below runway cap, a zero credit line should disable.
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 0);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroRunwayCapAndZeroCreditLine_disables() public {
        uint64 duration = 100;
        uint256 runwayCap = 0;
        uint256 coverage = 0; // => creditLine = 0
        uint256 lambda = 1;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 0);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_underwritingDisabled_stillEnforcesRunwayCapWhenNonzero() public {
        uint64 duration = 100;
        uint256 runwayCap = 500;
        uint256 lambda = 0; // underwriting disabled

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap - 1);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_nonzeroRunwayCap_doesNotOverrideStricterCreditLine() public {
        uint64 duration = 10;
        uint256 runwayCap = 5_000;
        uint256 coverage = 100;
        uint256 lambda = 1;
        uint256 creditLine = 1_000; // coverage * duration / lambda

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, creditLine - 1);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, creditLine);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_underwritingDisabled_withoutRunwayCap_forceEnablesRecipient() public {
        uint64 duration = 100;
        uint256 runwayCap = 0;
        uint256 lambda = 0; // underwriting disabled

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);

        _goalFlow.setRecipientEnabled(ITEM_ID, false);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, type(uint256).max);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);

        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_stakeReadFailure_stillDisablesWhenRunwayCapExceeded() public {
        uint256 runwayCap = 500;
        uint256 lambda = 1;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(100, runwayCap);
        RevertingBudgetStakeLedger revertingLedger = new RevertingBudgetStakeLedger();

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(revertingLedger), lambda);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_executionDurationReadFailure_stillDisablesWhenRunwayCapExceeded() public {
        uint256 runwayCap = 500;
        uint256 lambda = 1;

        RevertingExecutionDurationBudgetTreasury budgetTreasury = new RevertingExecutionDurationBudgetTreasury(runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), 1_000);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);
        _tcr.enforceBudgetInflowCaps(ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), lambda);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }
}
