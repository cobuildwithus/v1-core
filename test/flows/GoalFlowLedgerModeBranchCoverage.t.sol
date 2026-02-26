// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalFlowLedgerMode } from "src/library/GoalFlowLedgerMode.sol";
import { IFlow, ICustomFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IAllocationKeyAccountResolver } from "src/interfaces/IAllocationKeyAccountResolver.sol";
import { GoalFlowLedgerModeHarness } from "test/harness/GoalFlowLedgerModeHarness.sol";

contract GoalFlowLedgerModeBranchCoverageTest is Test {
    address internal constant EXPECTED_FLOW = address(0xF10);
    address internal constant ACCOUNT = address(0xA11CE);

    GoalFlowLedgerModeHarness internal harness;
    GoalFlowLedgerModeCoverageStrategy internal strategy;
    GoalFlowLedgerModeCoverageStakeVault internal stakeVault;
    GoalFlowLedgerModeCoverageGoalTreasury internal treasury;
    GoalFlowLedgerModeCoverageLedger internal ledger;

    function setUp() public {
        harness = new GoalFlowLedgerModeHarness();
        strategy = new GoalFlowLedgerModeCoverageStrategy();
        stakeVault = new GoalFlowLedgerModeCoverageStakeVault();
        treasury = new GoalFlowLedgerModeCoverageGoalTreasury(EXPECTED_FLOW, address(stakeVault));
        ledger = new GoalFlowLedgerModeCoverageLedger(address(treasury));

        strategy.setStakeVault(address(stakeVault));
        strategy.setKey(uint256(uint160(ACCOUNT)));

        address[] memory strategies = new address[](1);
        strategies[0] = address(strategy);
        harness.setStrategies(strategies);
    }

    function test_validateForInitializeView_returnsCachedResultWhenLedgerMatches() public {
        harness.validate(address(ledger), EXPECTED_FLOW);
        treasury.setFlow(address(0xBEEF));

        (address goalTreasury, address resolvedStakeVault) = harness.validateForInitializeView(address(ledger), EXPECTED_FLOW);

        assertEq(goalTreasury, address(treasury));
        assertEq(resolvedStakeVault, address(stakeVault));
    }

    function test_validateForInitializeView_allowsBootstrapWhenFlowAndStakeVaultAreUnset() public {
        GoalFlowLedgerModeCoverageGoalTreasury bootstrapTreasury =
            new GoalFlowLedgerModeCoverageGoalTreasury(address(0), address(0));
        GoalFlowLedgerModeCoverageLedger bootstrapLedger =
            new GoalFlowLedgerModeCoverageLedger(address(bootstrapTreasury));

        (address goalTreasury, address resolvedStakeVault) =
            harness.validateForInitializeView(address(bootstrapLedger), EXPECTED_FLOW);

        assertEq(goalTreasury, address(bootstrapTreasury));
        assertEq(resolvedStakeVault, address(0));
    }

    function test_validateForInitializeView_revertsWhenFlowProbeReverts() public {
        treasury.setRevertFlow(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector,
                address(ledger),
                address(treasury)
            )
        );
        harness.validateForInitializeView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateForInitializeView_revertsWhenStakeVaultProbeReverts() public {
        treasury.setRevertStakeVault(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector,
                address(ledger),
                address(treasury)
            )
        );
        harness.validateForInitializeView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateForInitializeView_revertsWhenStrategyAllocationKeyProbeReverts() public {
        strategy.setRevertAllocationKey(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector,
                address(strategy),
                address(stakeVault),
                address(stakeVault)
            )
        );
        harness.validateForInitializeView(address(ledger), EXPECTED_FLOW);
    }

    function test_detectCalldata_returnsEmptyArrayWhenLedgerIsZero() public {
        GoalFlowLedgerModeHarness.DetectParams memory params = GoalFlowLedgerModeHarness.DetectParams({
            percentageScale: 1_000_000,
            ledger: address(0),
            prevWeight: 0,
            newWeight: 0,
            prevRecipientIds: new bytes32[](0),
            prevAllocationsScaled: new uint32[](0),
            newRecipientIds: new bytes32[](0),
            newAllocationsScaled: new uint32[](0)
        });

        address[] memory deltas = harness.detectCalldata(params);
        assertEq(deltas.length, 0);
    }

    function test_prepareCheckpointContext_returnsNoCheckpointWhenLedgerIsZero() public {
        (uint256 weight, bool shouldCheckpoint) = harness.prepareCheckpointContextView(address(0), ACCOUNT, EXPECTED_FLOW);
        assertEq(weight, 0);
        assertFalse(shouldCheckpoint);
    }

    function test_prepareCheckpointContextView_returnsNoCheckpointWhenLedgerIsZero() public {
        (uint256 weight, bool shouldCheckpoint) = harness.prepareCheckpointContextView(address(0), ACCOUNT, EXPECTED_FLOW);
        assertEq(weight, 0);
        assertFalse(shouldCheckpoint);
    }

    function test_prepareCheckpointContextFromCommittedWeight_returnsNoCheckpointWhenLedgerIsZero() public {
        (uint256 resolvedWeight, bool shouldCheckpoint) =
            harness.prepareCheckpointContextFromCommittedWeight(address(0), 777, EXPECTED_FLOW);
        assertEq(resolvedWeight, 0);
        assertFalse(shouldCheckpoint);
    }

    function test_prepareCheckpointContext_returnsNoCheckpointWhenGoalResolved() public {
        stakeVault.setGoalResolved(true);

        (uint256 weight, bool shouldCheckpoint) =
            harness.prepareCheckpointContextView(address(ledger), ACCOUNT, EXPECTED_FLOW);
        assertEq(weight, 0);
        assertFalse(shouldCheckpoint);
    }

    function test_prepareCheckpointContext_returnsWeightWhenGoalActive() public {
        stakeVault.setWeight(ACCOUNT, 123);

        (uint256 weight, bool shouldCheckpoint) =
            harness.prepareCheckpointContextView(address(ledger), ACCOUNT, EXPECTED_FLOW);
        assertEq(weight, 123);
        assertTrue(shouldCheckpoint);
    }

    function test_prepareCheckpointContext_revertsWhenGoalResolvedProbeReverts() public {
        stakeVault.setRevertGoalResolved(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector,
                address(treasury),
                address(stakeVault)
            )
        );
        harness.prepareCheckpointContextView(address(ledger), ACCOUNT, EXPECTED_FLOW);
    }

    function test_prepareCheckpointContext_revertsWhenWeightProbeReverts() public {
        stakeVault.setRevertWeightOf(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector,
                address(treasury),
                address(stakeVault)
            )
        );
        harness.prepareCheckpointContextView(address(ledger), ACCOUNT, EXPECTED_FLOW);
    }

    function test_prepareCheckpointContextView_revertsWhenGoalResolvedProbeReverts() public {
        stakeVault.setRevertGoalResolved(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector,
                address(treasury),
                address(stakeVault)
            )
        );
        harness.prepareCheckpointContextView(address(ledger), ACCOUNT, EXPECTED_FLOW);
    }

    function test_prepareCheckpointContextView_revertsWhenWeightProbeReverts() public {
        stakeVault.setRevertWeightOf(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector,
                address(treasury),
                address(stakeVault)
            )
        );
        harness.prepareCheckpointContextView(address(ledger), ACCOUNT, EXPECTED_FLOW);
    }

    function test_requiredChildSyncRequirements_returnsEmptyWhenInputIsEmpty() public {
        address[] memory budgets = new address[](0);
        ICustomFlow.ChildSyncRequirement[] memory reqs = harness.requiredChildSyncRequirements(ACCOUNT, budgets);
        assertEq(reqs.length, 0);
    }

    function test_requiredChildSyncRequirements_revertsWhenTargetUnavailable() public {
        address[] memory budgets = new address[](1);
        budgets[0] = address(0xBADCAFE);

        vm.expectRevert(
            abi.encodeWithSelector(GoalFlowLedgerMode.CHILD_SYNC_TARGET_UNAVAILABLE.selector, budgets[0])
        );
        harness.requiredChildSyncRequirements(ACCOUNT, budgets);
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenBudgetHasNoCode() public {
        address[] memory budgets = new address[](1);
        budgets[0] = address(0xBADCAFE);

        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, budgets);
        assertEq(actions.length, 1);
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenBudgetFlowCallReverts() public {
        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(0));
        budget.setRevertFlow(true);

        address[] memory budgets = _singleBudget(address(budget));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, budgets);
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenStrategiesCallReverts() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        childFlow.setRevertStrategies(true);
        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));

        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenStrategyCountIsNotOne() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        GoalFlowLedgerModeCoverageStrategy strategy2 = new GoalFlowLedgerModeCoverageStrategy();
        address[] memory childStrategies = new address[](2);
        childStrategies[0] = address(strategy);
        childStrategies[1] = address(strategy2);
        childFlow.setStrategies(childStrategies);

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenAccountResolverReverts() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        strategy.setRevertAccountResolver(true);

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenResolvedAccountMismatches() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        strategy.setResolvedAccountOverride(address(0xDEAD));

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_buildChildSyncActions_marksTargetUnavailableWhenCommitReadReverts() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        childFlow.setRevertCommitment(true);

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        assertEq(actions[0].skipReason, bytes32("TARGET_UNAVAILABLE"));
    }

    function test_requiredChildSyncRequirements_skipsZeroCommitTargets() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        childFlow.setCommitment(bytes32(0));

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        ICustomFlow.ChildSyncRequirement[] memory reqs =
            harness.requiredChildSyncRequirements(ACCOUNT, _singleBudget(address(budget)));
        assertEq(reqs.length, 0);
    }

    function test_requiredChildSyncRequirements_returnsRequirementWhenCommitPresent() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        bytes32 commit = keccak256("commit");
        childFlow.setCommitment(commit);

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        ICustomFlow.ChildSyncRequirement[] memory reqs =
            harness.requiredChildSyncRequirements(ACCOUNT, _singleBudget(address(budget)));

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(budget));
        assertEq(reqs[0].childFlow, address(childFlow));
        assertEq(reqs[0].childStrategy, address(strategy));
        assertEq(reqs[0].allocationKey, uint256(uint160(ACCOUNT)));
        assertEq(reqs[0].expectedCommit, commit);
    }

    function test_executeChildSyncBestEffort_marksAttemptedAndSuccess() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        childFlow.setCommitment(keccak256("commit"));

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        GoalFlowLedgerMode.ChildSyncExecution[] memory executions = harness.executeChildSyncBestEffort(actions);

        assertEq(executions.length, 1);
        assertTrue(executions[0].attempted);
        assertTrue(executions[0].success);
    }

    function test_executeChildSyncBestEffort_marksAttemptedAndFailureWhenSyncReverts() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        childFlow.setCommitment(keccak256("commit"));
        childFlow.setRevertSync(true);

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));
        GoalFlowLedgerMode.ChildSyncExecution[] memory executions = harness.executeChildSyncBestEffort(actions);

        assertEq(executions.length, 1);
        assertTrue(executions[0].attempted);
        assertFalse(executions[0].success);
    }

    function test_executeChildSyncBestEffort_skipsWhenGasBudgetIsTooLow() public {
        GoalFlowLedgerModeCoverageChildFlow childFlow = new GoalFlowLedgerModeCoverageChildFlow();
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        childFlow.setStrategies(childStrategies);
        childFlow.setCommitment(keccak256("commit"));

        GoalFlowLedgerModeCoverageBudgetTreasury budget = new GoalFlowLedgerModeCoverageBudgetTreasury(address(childFlow));
        GoalFlowLedgerMode.ChildSyncAction[] memory actions = harness.buildChildSyncActions(ACCOUNT, _singleBudget(address(budget)));

        (bool ok, bytes memory returnData) = address(harness).call{ gas: 900_000 }(
            abi.encodeCall(GoalFlowLedgerModeHarness.executeChildSyncBestEffort, (actions))
        );
        assertTrue(ok);

        GoalFlowLedgerMode.ChildSyncExecution[] memory executions =
            abi.decode(returnData, (GoalFlowLedgerMode.ChildSyncExecution[]));
        assertEq(executions.length, 1);
        assertEq(executions[0].skipReason, bytes32("GAS_BUDGET"));
        assertFalse(executions[0].attempted);
        assertFalse(executions[0].success);
    }

    function test_validateView_revertsWhenLedgerHasNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER.selector, address(0xBAD)));
        harness.validateView(address(0xBAD), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenLedgerGoalTreasuryCallReverts() public {
        ledger.setRevertGoalTreasury(true);

        vm.expectRevert(abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER.selector, address(ledger)));
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenLedgerGoalTreasuryIsZero() public {
        ledger.setGoalTreasury(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector,
                address(ledger),
                address(0)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenGoalTreasuryHasNoCode() public {
        ledger.setGoalTreasury(address(0xBEEF));

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector,
                address(ledger),
                address(0xBEEF)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenGoalTreasuryFlowCallReverts() public {
        treasury.setRevertFlow(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector,
                address(ledger),
                address(treasury)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenGoalTreasuryStakeVaultCallReverts() public {
        treasury.setRevertStakeVault(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector,
                address(ledger),
                address(treasury)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenStakeVaultIsZeroAddress() public {
        treasury.setStakeVault(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector,
                address(treasury),
                address(0)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function test_validateView_revertsWhenStakeVaultHasNoCode() public {
        treasury.setStakeVault(address(0xCAFE));

        vm.expectRevert(
            abi.encodeWithSelector(
                IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector,
                address(treasury),
                address(0xCAFE)
            )
        );
        harness.validateView(address(ledger), EXPECTED_FLOW);
    }

    function _singleBudget(address budget) internal pure returns (address[] memory budgets) {
        budgets = new address[](1);
        budgets[0] = budget;
    }
}

contract GoalFlowLedgerModeCoverageLedger {
    address private _goalTreasury;
    bool private _revertGoalTreasury;

    constructor(address goalTreasury_) {
        _goalTreasury = goalTreasury_;
    }

    function setGoalTreasury(address goalTreasury_) external {
        _goalTreasury = goalTreasury_;
    }

    function setRevertGoalTreasury(bool shouldRevert) external {
        _revertGoalTreasury = shouldRevert;
    }

    function goalTreasury() external view returns (address) {
        if (_revertGoalTreasury) revert("goalTreasury");
        return _goalTreasury;
    }
}

contract GoalFlowLedgerModeCoverageGoalTreasury {
    address private _flow;
    address private _stakeVault;
    bool private _revertFlow;
    bool private _revertStakeVault;

    constructor(address flow_, address stakeVault_) {
        _flow = flow_;
        _stakeVault = stakeVault_;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function setStakeVault(address stakeVault_) external {
        _stakeVault = stakeVault_;
    }

    function setRevertFlow(bool shouldRevert) external {
        _revertFlow = shouldRevert;
    }

    function setRevertStakeVault(bool shouldRevert) external {
        _revertStakeVault = shouldRevert;
    }

    function flow() external view returns (address) {
        if (_revertFlow) revert("flow");
        return _flow;
    }

    function stakeVault() external view returns (address) {
        if (_revertStakeVault) revert("stakeVault");
        return _stakeVault;
    }
}

contract GoalFlowLedgerModeCoverageStakeVault {
    mapping(address => uint256) private _weights;
    bool private _goalResolved;
    bool private _revertGoalResolved;
    bool private _revertWeightOf;

    function setWeight(address account, uint256 weight) external {
        _weights[account] = weight;
    }

    function setGoalResolved(bool resolved) external {
        _goalResolved = resolved;
    }

    function setRevertGoalResolved(bool shouldRevert) external {
        _revertGoalResolved = shouldRevert;
    }

    function setRevertWeightOf(bool shouldRevert) external {
        _revertWeightOf = shouldRevert;
    }

    function goalResolved() external view returns (bool) {
        if (_revertGoalResolved) revert("goalResolved");
        return _goalResolved;
    }

    function weightOf(address account) external view returns (uint256) {
        if (_revertWeightOf) revert("weightOf");
        return _weights[account];
    }
}

contract GoalFlowLedgerModeCoverageBudgetTreasury {
    address private _flow;
    bool private _revertFlow;

    constructor(address flow_) {
        _flow = flow_;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function setRevertFlow(bool shouldRevert) external {
        _revertFlow = shouldRevert;
    }

    function flow() external view returns (address) {
        if (_revertFlow) revert("flow");
        return _flow;
    }
}

contract GoalFlowLedgerModeCoverageChildFlow {
    IAllocationStrategy[] private _strategies;
    bool private _revertStrategies;
    bool private _revertCommitment;
    bool private _revertSync;
    bytes32 private _commitment;

    function setStrategies(address[] memory strategies_) external {
        delete _strategies;
        uint256 count = strategies_.length;
        for (uint256 i = 0; i < count; ) {
            _strategies.push(IAllocationStrategy(strategies_[i]));
            unchecked {
                ++i;
            }
        }
    }

    function setRevertStrategies(bool shouldRevert) external {
        _revertStrategies = shouldRevert;
    }

    function setCommitment(bytes32 commitment_) external {
        _commitment = commitment_;
    }

    function setRevertCommitment(bool shouldRevert) external {
        _revertCommitment = shouldRevert;
    }

    function setRevertSync(bool shouldRevert) external {
        _revertSync = shouldRevert;
    }

    function strategies() external view returns (IAllocationStrategy[] memory strategies_) {
        if (_revertStrategies) revert("strategies");
        return _strategies;
    }

    function getAllocationCommitment(address, uint256) external view returns (bytes32) {
        if (_revertCommitment) revert("commitment");
        return _commitment;
    }

    function syncAllocation(address, uint256) external view {
        if (_revertSync) revert("sync");
    }
}

contract GoalFlowLedgerModeCoverageStrategy is IAllocationStrategy, IAllocationKeyAccountResolver {
    address private _stakeVault;
    uint256 private _key;
    bool private _revertAllocationKey;
    bool private _revertAccountResolver;
    bool private _useResolvedAccountOverride;
    address private _resolvedAccountOverride;

    function setStakeVault(address stakeVault_) external {
        _stakeVault = stakeVault_;
    }

    function setKey(uint256 key_) external {
        _key = key_;
    }

    function setRevertAllocationKey(bool shouldRevert) external {
        _revertAllocationKey = shouldRevert;
    }

    function setRevertAccountResolver(bool shouldRevert) external {
        _revertAccountResolver = shouldRevert;
    }

    function setResolvedAccountOverride(address account) external {
        _useResolvedAccountOverride = true;
        _resolvedAccountOverride = account;
    }

    function stakeVault() external view returns (address) {
        return _stakeVault;
    }

    function allocationKey(address caller, bytes calldata) external view returns (uint256) {
        if (_revertAllocationKey) revert("allocationKey");
        if (_key != 0) return _key;
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256 key) external view returns (address) {
        if (_revertAccountResolver) revert("accountForAllocationKey");
        if (_useResolvedAccountOverride) return _resolvedAccountOverride;
        return address(uint160(key));
    }

    function currentWeight(uint256) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(uint256, address) external pure returns (bool) {
        return true;
    }

    function canAccountAllocate(address) external pure returns (bool) {
        return true;
    }

    function accountAllocationWeight(address) external pure returns (uint256) {
        return 1;
    }

    function strategyKey() external pure returns (string memory) {
        return "goal-flow-ledger-mode-coverage";
    }
}
