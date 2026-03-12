// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IBudgetGatePolicy} from "src/interfaces/IBudgetGatePolicy.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {StakeCoverageGatePolicy} from "src/goals/policies/StakeCoverageGatePolicy.sol";
import {BudgetGatePolicyHook} from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import {NoopZeroCoverageBudgetGatePolicy} from "test/helpers/ZeroCoverageBudgetGatePolicies.sol";

contract BudgetGatePolicyHarness {
    IFlow internal immutable _goalFlow;

    constructor(address goalFlow_) {
        _goalFlow = IFlow(goalFlow_);
    }

    function applyPolicy(
        address policy,
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address coverageSource,
        uint32 coverageToCreditPpm
    ) external returns (IBudgetGatePolicy.SyncResult memory result) {
        result = BudgetGatePolicyHook.evaluateBudgetGate(
            IBudgetGatePolicy(policy),
            IBudgetGatePolicy.SyncContext({
                itemID: itemID,
                goalFlow: _goalFlow,
                childFlow: childFlow,
                budgetTreasury: budgetTreasury,
                coverageSource: coverageSource,
                coverageToCreditPpm: coverageToCreditPpm
            })
        );

        if (result.shouldSetRecipientEnabled) {
            _goalFlow.setRecipientEnabled(itemID, result.recipientEnabled);
        }
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
    uint256 internal _runwayCap;

    constructor(uint256 runwayCap_) {
        _runwayCap = runwayCap_;
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

contract RevertingBudgetGatePolicy {
    error POLICY_REVERT();

    function evaluateBudgetGate(IBudgetGatePolicy.SyncContext calldata)
        external
        pure
        returns (IBudgetGatePolicy.SyncResult memory)
    {
        revert POLICY_REVERT();
    }
}

contract BudgetTCRRunwayCapEnforcementTest is Test {
    BudgetGatePolicyHarness internal _controller;
    MockGoalFlow internal _goalFlow;
    MockBudgetStakeLedger internal _stakeLedger;
    StakeCoverageGatePolicy internal _stakePolicy;
    NoopZeroCoverageBudgetGatePolicy internal _noopPolicy;
    RevertingBudgetGatePolicy internal _revertingPolicy;

    bytes32 internal constant ITEM_ID = bytes32(uint256(0xB0D));
    address internal constant CHILD_FLOW = address(0xCAFE);

    function setUp() public {
        _goalFlow = new MockGoalFlow();
        _controller = new BudgetGatePolicyHarness(address(_goalFlow));
        _stakeLedger = new MockBudgetStakeLedger();
        _stakePolicy = new StakeCoverageGatePolicy();
        _noopPolicy = new NoopZeroCoverageBudgetGatePolicy();
        _revertingPolicy = new RevertingBudgetGatePolicy();
    }

    function test_recipientDisablesAtRunwayBoundaryEvenWhenInsuredLineAllowsMore() public {
        uint256 runwayCap = 5_000;
        uint256 coverage = 100_000;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap);

        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_recipientRemainsEnabledBelowRunwayBoundary() public {
        uint256 runwayCap = 5_000;
        uint256 coverage = 100_000;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(runwayCap);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, runwayCap - 1);

        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);

        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroRunwayCap_usesInsuredLineBoundary() public {
        uint256 coverage = 100;
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(0);
        _stakeLedger.setCoverage(address(budgetTreasury), coverage);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 9);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 10);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroInsuredLine_disablesEvenWhenRunwayCapAllowsMore() public {
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(5_000);
        _stakeLedger.setCoverage(address(budgetTreasury), 0);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 0);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_zeroRunwayCapAndZeroInsuredLine_disables() public {
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(0);
        _stakeLedger.setCoverage(address(budgetTreasury), 0);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 0);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_underwritingDisabled_hardDisablesEvenWhenRunwayCapIsNonzero() public {
        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(500);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 499);
        _applyStakePolicy(address(budgetTreasury), address(0), 0);
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_nonzeroRunwayCap_doesNotOverrideStricterInsuredLine() public {
        uint32 budgetSlashPpm = 100_000;
        uint256 insuredLine = 10;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(5_000);
        _stakeLedger.setCoverage(address(budgetTreasury), 100);

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, insuredLine - 1);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));

        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, insuredLine);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);
        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_stakeReadFailure_stillDisablesWhenRunwayCapExceeded() public {
        uint32 budgetSlashPpm = 100_000;

        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(500);
        RevertingBudgetStakeLedger revertingLedger = new RevertingBudgetStakeLedger();

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 500);
        _applyStakePolicy(address(budgetTreasury), address(revertingLedger), budgetSlashPpm);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_executionDurationReadFailureIsIgnoredBecausePolicyDoesNotReadIt() public {
        uint32 budgetSlashPpm = 100_000;

        RevertingExecutionDurationBudgetTreasury budgetTreasury = new RevertingExecutionDurationBudgetTreasury(0);
        _stakeLedger.setCoverage(address(budgetTreasury), 100);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, 10);
        _applyStakePolicy(address(budgetTreasury), address(_stakeLedger), budgetSlashPpm);

        assertFalse(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_noopPolicyLeavesActiveRecipientEnabledWithoutCoverageDependency() public {
        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(0);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        _goalFlow.setTotalReceivedByMember(CHILD_FLOW, type(uint256).max);
        _controller.applyPolicy(address(_noopPolicy), ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(0), 50_000);

        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function test_hookNormalizesPolicyRevertsWithoutChangingRecipientState() public {
        MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(0);

        _goalFlow.setRecipientEnabled(ITEM_ID, true);
        IBudgetGatePolicy.SyncResult memory result = _controller.applyPolicy(
            address(_revertingPolicy), ITEM_ID, CHILD_FLOW, address(budgetTreasury), address(0), 0
        );

        assertFalse(result.shouldSetRecipientEnabled);
        assertEq(result.failures.length, 1);
        assertEq(result.failures[0].callTarget, address(_revertingPolicy));
        assertEq(result.failures[0].selector, IBudgetGatePolicy.evaluateBudgetGate.selector);
        assertTrue(_goalFlow.recipientEnabled(ITEM_ID));
    }

    function _applyStakePolicy(address budgetTreasury, address coverageSource, uint32 coverageToCreditPpm)
        internal
        returns (IBudgetGatePolicy.SyncResult memory result)
    {
        result = _controller.applyPolicy(
            address(_stakePolicy), ITEM_ID, CHILD_FLOW, budgetTreasury, coverageSource, coverageToCreditPpm
        );
    }
}
