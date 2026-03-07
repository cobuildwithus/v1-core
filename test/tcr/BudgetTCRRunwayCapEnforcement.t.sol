// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRCreditCapActions } from "src/tcr/library/BudgetTCRCreditCapActions.sol";
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
        uint32 budgetSlashPpm
    ) external {
        BudgetTCRCreditCapActions.bestEffortEnforceBudgetCreditCap(
            goalFlow,
            itemID,
            childFlow,
            budgetTreasury,
            budgetStakeLedger,
            budgetSlashPpm
        );
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

    function test_recipientDisablesAtRunwayBoundaryEvenWhenInsuredLineAllowsMore() public {
        uint64 duration = 100;
        uint256 runwayCap = 5_000;
        uint256 coverage = 100_000;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        // insuredLine = 100_000 * 10% = 10_000, so runwayCap is the lower ceiling.
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);

        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_recipientRemainsEnabledBelowRunwayBoundary() public {
        uint64 duration = 100;
        uint256 runwayCap = 5_000;
        uint256 coverage = 100_000;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        // One unit below runway cap => should still be enabled (insured line is much larger).
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap - 1);

        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );

        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroRunwayCap_usesInsuredLineBoundary() public {
        uint64 duration = 10;
        uint256 runwayCap = 0; // no runway cap
        uint256 coverage = 100;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 9);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 10);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroInsuredLine_disablesEvenWhenRunwayCapAllowsMore() public {
        uint64 duration = 100;
        uint256 runwayCap = 5_000;
        uint256 coverage = 0;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        // Even with received below runway cap, a zero insured line should disable.
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 0);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroRunwayCapAndZeroInsuredLine_disables() public {
        uint64 duration = 100;
        uint256 runwayCap = 0;
        uint256 coverage = 0;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 0);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_underwritingDisabled_hardDisablesEvenWhenRunwayCapIsNonzero() public {
        uint64 duration = 100;
        uint256 runwayCap = 500;
        uint32 budgetSlashPpm = 0;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap - 1);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_nonzeroRunwayCap_doesNotOverrideStricterInsuredLine() public {
        uint64 duration = 10;
        uint256 runwayCap = 5_000;
        uint256 coverage = 100;
        uint32 budgetSlashPpm = 100_000;
        uint256 insuredLine = 10;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, insuredLine - 1);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, insuredLine);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_underwritingDisabled_withoutRunwayCap_forceDisablesRecipient() public {
        uint64 duration = 100;
        uint256 runwayCap = 0;
        uint32 budgetSlashPpm = 0;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(duration, runwayCap);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, type(uint256).max);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_stakeReadFailure_stillDisablesWhenRunwayCapExceeded() public {
        uint256 runwayCap = 500;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(100, runwayCap);
        RevertingBudgetStakeLedger revertingLedger = new RevertingBudgetStakeLedger();

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(revertingLedger), budgetSlashPpm
        );

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_executionDurationReadFailureIsIgnoredBecauseEnforcementNoLongerReadsIt() public {
        uint256 runwayCap = 0;
        uint32 budgetSlashPpm = 100_000;

        RevertingExecutionDurationBudgetTreasury budgetTreasury = new RevertingExecutionDurationBudgetTreasury(runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), 100);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 10);
        _tcr.enforceBudgetInflowCaps(
            ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(_stakeLedger), budgetSlashPpm
        );

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }
}
