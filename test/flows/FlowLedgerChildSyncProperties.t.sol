// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {ICustomFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";

contract FlowLedgerChildSyncPropertiesTest is FlowAllocationsBase {
    bytes32 internal constant PARENT_BUDGET_RECIPIENT_ID = bytes32(uint256(1001));
    address internal constant PARENT_BUDGET_RECIPIENT = address(0xA001);
    bytes32 internal constant SECOND_BUDGET_RECIPIENT_ID = bytes32(uint256(1002));
    address internal constant SECOND_BUDGET_RECIPIENT = address(0xA002);
    bytes32 internal constant CHILD_RECIPIENT_ID = bytes32(uint256(2002));
    uint32 internal constant FULL_SCALED = 1_000_000;
    uint32 internal constant HALF_SCALED = FULL_SCALED / 2;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    uint256 internal parentKey;

    FlowLedgerPropStakeVault internal stakeVault;
    FlowLedgerPropGoalTreasury internal goalTreasury;
    FlowLedgerPropLedger internal ledger;
    GoalFlowAllocationLedgerPipeline internal ledgerPipeline;
    FlowLedgerPropBudgetTreasury internal budgetTreasury;
    FlowLedgerPropPremiumEscrow internal premiumEscrow;
    FlowLedgerPropChildFlow internal childFlow;
    FlowLedgerPropChildStrategy internal childStrategy;

    function setUp() public override {
        super.setUp();

        parentKey = uint256(uint160(allocator));

        stakeVault = new FlowLedgerPropStakeVault();
        address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        goalTreasury = new FlowLedgerPropGoalTreasury(predictedFlow, address(stakeVault));
        ledger = new FlowLedgerPropLedger(address(goalTreasury));

        strategy.setStakeVault(address(stakeVault));
        strategy.setCanAllocate(parentKey, allocator, true);

        ledgerPipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        flow = _deployFlowWithConfig(owner, manager, managerRewardPool, address(ledgerPipeline), address(0), strategies);
        assertEq(address(flow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(flow), 500_000e18);

        childStrategy = new FlowLedgerPropChildStrategy();
        childFlow = new FlowLedgerPropChildFlow(address(childStrategy));
        premiumEscrow = new FlowLedgerPropPremiumEscrow();
        budgetTreasury = new FlowLedgerPropBudgetTreasury(address(childFlow), address(premiumEscrow));

        _registerBudgetRecipient(PARENT_BUDGET_RECIPIENT_ID, PARENT_BUDGET_RECIPIENT, address(budgetTreasury));
    }

    function testFuzz_allocate_withLedger_triggersCheckpointExactlyOncePerSuccessfulCall(
        uint96 stakeWeightASeed,
        uint96 stakeWeightBSeed
    ) public {
        uint256 stakeWeightA = bound(uint256(stakeWeightASeed), 1e18, 1e30 - UNIT_WEIGHT_SCALE);
        uint256 stakeWeightB = bound(uint256(stakeWeightBSeed), stakeWeightA + UNIT_WEIGHT_SCALE, 1e30);

        _setWeights(stakeWeightA);
        _allocateParentSingleRecipient();
        assertEq(ledger.checkpointCallCount(), 1);
        assertEq(premiumEscrow.checkpointCallCount(), 1);
        assertEq(premiumEscrow.lastCheckpointAccount(), allocator);

        _setWeights(stakeWeightB);
        _allocateParentSingleRecipient();
        assertEq(ledger.checkpointCallCount(), 2);
        assertEq(premiumEscrow.checkpointCallCount(), 2);
    }

    function test_allocate_withLedger_multipleChangedBudgets_checkpointsEachPremiumEscrow() public {
        FlowLedgerPropPremiumEscrow secondPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropChildFlow secondChildFlow =
            new FlowLedgerPropChildFlow(address(new FlowLedgerPropChildStrategy()));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury =
            new FlowLedgerPropBudgetTreasury(address(secondChildFlow), address(secondPremiumEscrow));

        _registerBudgetRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(secondBudgetTreasury));

        uint256 stakeWeight = 25e18;
        _setWeights(stakeWeight);
        bytes[][] memory allocationData = _parentAllocationData();

        bytes32[] memory recipientIds = new bytes32[](2);
        recipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        recipientIds[1] = SECOND_BUDGET_RECIPIENT_ID;

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;

        _allocateWithPrevStateForStrategy(
            allocator, allocationData, address(strategy), address(flow), recipientIds, scaled
        );

        assertEq(premiumEscrow.checkpointCallCount(), 1);
        assertEq(secondPremiumEscrow.checkpointCallCount(), 1);
        assertEq(premiumEscrow.lastCheckpointAccount(), allocator);
        assertEq(secondPremiumEscrow.lastCheckpointAccount(), allocator);
    }

    function test_allocate_withLedger_revertsWhenPremiumEscrowCheckpointReverts() public {
        premiumEscrow.setRevertOnCheckpoint(true);
        childFlow.setCommit(keccak256("child-commit"));

        _setWeights(50e18);
        bytes[][] memory allocationData = _parentAllocationData();
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            address(strategy),
            address(flow),
            recipientIds,
            scaled,
            abi.encodeWithSelector(FlowLedgerPropPremiumEscrow.CHECKPOINT_REVERT.selector)
        );

        assertEq(ledger.checkpointCallCount(), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(premiumEscrow.checkpointCallCount(), 0);
    }

    function test_allocate_withLedger_revertsWhenBudgetPremiumEscrowHasNoCode() public {
        address invalidPremiumEscrow = address(0xBEEF);
        FlowLedgerPropBudgetTreasury invalidBudgetTreasury =
            new FlowLedgerPropBudgetTreasury(address(childFlow), invalidPremiumEscrow);
        ledger.setBudget(PARENT_BUDGET_RECIPIENT_ID, address(invalidBudgetTreasury));

        _setWeights(50e18);
        bytes[][] memory allocationData = _parentAllocationData();
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            address(strategy),
            address(flow),
            recipientIds,
            scaled,
            abi.encodeWithSelector(
                GoalFlowAllocationLedgerPipeline.INVALID_BUDGET_PREMIUM_ESCROW.selector,
                address(invalidBudgetTreasury),
                invalidPremiumEscrow
            )
        );

        assertEq(ledger.checkpointCallCount(), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(premiumEscrow.checkpointCallCount(), 0);
    }

    function test_allocate_withLedger_multipleChangedBudgets_revertIsAtomicBeforeChildSync() public {
        FlowLedgerPropPremiumEscrow secondPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropChildFlow secondChildFlow =
            new FlowLedgerPropChildFlow(address(new FlowLedgerPropChildStrategy()));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury =
            new FlowLedgerPropBudgetTreasury(address(secondChildFlow), address(secondPremiumEscrow));
        _registerBudgetRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(secondBudgetTreasury));

        childFlow.setCommit(keccak256("child-commit-1"));
        secondChildFlow.setCommit(keccak256("child-commit-2"));
        secondPremiumEscrow.setRevertOnCheckpoint(true);

        _setWeights(25e18);
        bytes[][] memory allocationData = _parentAllocationData();

        bytes32[] memory recipientIds = new bytes32[](2);
        recipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        recipientIds[1] = SECOND_BUDGET_RECIPIENT_ID;

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;

        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            address(strategy),
            address(flow),
            recipientIds,
            scaled,
            abi.encodeWithSelector(FlowLedgerPropPremiumEscrow.CHECKPOINT_REVERT.selector)
        );

        assertEq(ledger.checkpointCallCount(), 0);
        assertEq(premiumEscrow.checkpointCallCount(), 0);
        assertEq(secondPremiumEscrow.checkpointCallCount(), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(secondChildFlow.syncCallCount(), 0);
    }

    function test_allocate_withLedger_unchangedEffectiveAllocation_skipsPremiumCheckpointAndChildSync() public {
        _setWeights(10e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        _setWeights(10e18);
        _allocateParentSingleRecipient();

        assertEq(ledger.checkpointCallCount(), 2);
        assertEq(premiumEscrow.checkpointCallCount(), 1);
        assertEq(childFlow.syncCallCount(), 0);
    }

    function testFuzz_allocate_changedStake_childCommitZeroDoesNotRequirePrevState(
        uint96 initialStakeSeed,
        uint96 reducedStakeSeed
    ) public {
        uint256 initialStake = bound(uint256(initialStakeSeed), 2e18, 1e30);
        uint256 reducedStake = bound(uint256(reducedStakeSeed), 1e18, initialStake - 1);

        _setWeights(initialStake);
        _allocateParentSingleRecipient();

        childFlow.setCommit(bytes32(0));

        _setWeights(reducedStake);
        _allocateParentSingleRecipient();

        assertEq(childFlow.syncCallCount(), 0);
    }

    function testFuzz_allocate_changedStake_childCommitNonZero_autoSyncsWithoutPrevStatePayload(
        uint96 initialStakeSeed,
        uint96 reducedStakeSeed
    ) public {
        uint256 initialStake = bound(uint256(initialStakeSeed), 2e18, 1e30);
        uint256 reducedStake = bound(uint256(reducedStakeSeed), 1e18, initialStake - UNIT_WEIGHT_SCALE);

        _setWeights(initialStake);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));

        _setWeights(reducedStake);
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        uint256 checkpointsBefore = ledger.checkpointCallCount();

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);

        assertEq(ledger.checkpointCallCount(), checkpointsBefore + 1);
        assertEq(childFlow.syncCallCount(), 1);
    }

    function testFuzz_allocate_goalResolved_childCommitNonZero_changedStake_doesNotCheckpointOrRequirePrevState(
        uint96 initialStakeSeed,
        uint96 reducedStakeSeed
    ) public {
        uint256 initialStake = bound(uint256(initialStakeSeed), 2e18, 1e30);
        uint256 reducedStake = bound(uint256(reducedStakeSeed), 1e18, initialStake - 1);

        _setWeights(initialStake);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        stakeVault.setGoalResolved(true);

        _setWeights(reducedStake);
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();
        ICustomFlow.ChildSyncRequirement[] memory reqs =
            flow.previewChildSyncRequirements(address(strategy), parentKey, recipientIds, scaled);
        assertEq(reqs.length, 0);

        uint256 checkpointsBefore = ledger.checkpointCallCount();
        _allocateParentSingleRecipient();

        assertEq(ledger.checkpointCallCount(), checkpointsBefore);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(reducedStake, FULL_SCALED));
        assertEq(
            flow.getAllocationCommitment(address(strategy), parentKey), keccak256(abi.encode(recipientIds, scaled))
        );
    }

    function testFuzz_allocate_unchangedStake_childCommitNonZero_doesNotRequirePrevState(uint96 stakeSeed) public {
        uint256 stake = bound(uint256(stakeSeed), 1e18, 1e30);

        _setWeights(stake);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));

        _setWeights(stake);
        _allocateParentSingleRecipient();

        assertEq(childFlow.syncCallCount(), 0);
    }

    function testFuzz_allocate_changedStake_childCommitNonZero_syncs(uint96 initialStakeSeed, uint96 reducedStakeSeed)
        public
    {
        uint256 initialStake = bound(uint256(initialStakeSeed), 2e18, 1e30);
        uint256 reducedStake = bound(uint256(reducedStakeSeed), 1e18, initialStake - UNIT_WEIGHT_SCALE);

        _setWeights(initialStake);
        _allocateParentSingleRecipient();

        bytes32[] memory childIds = new bytes32[](1);
        childIds[0] = CHILD_RECIPIENT_ID;
        uint32[] memory childScaled = new uint32[](1);
        childScaled[0] = FULL_SCALED;
        childFlow.setCommit(keccak256(abi.encode(childIds, childScaled)));

        _setWeights(reducedStake);

        bytes[][] memory allocationData = _parentAllocationData();
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        _updatePrevStateCacheForStrategy(allocator, allocationData, address(strategy), recipientIds, scaled);

        assertEq(childFlow.syncCallCount(), 1);
        assertEq(childFlow.lastAllocationKey(), parentKey);
        assertEq(childFlow.lastStrategy(), address(childStrategy));
    }

    function _setWeights(uint256 weight) internal {
        stakeVault.setWeight(allocator, weight);
        strategy.setWeight(parentKey, weight);
    }

    function _allocateParentSingleRecipient() internal {
        bytes[][] memory allocationData = _parentAllocationData();
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        _allocateWithPrevStateForStrategy(
            allocator, allocationData, address(strategy), address(flow), recipientIds, scaled
        );
    }

    function _parentAllocationData() internal view returns (bytes[][] memory allocationData) {
        allocationData = _defaultAllocationDataForKey(parentKey);
    }

    function _registerBudgetRecipient(bytes32 recipientId, address recipient, address budgetTreasuryAddress) internal {
        _addRecipient(recipientId, recipient);
        ledger.setBudget(recipientId, budgetTreasuryAddress);
    }

    function _singleParentAllocation() internal pure returns (bytes32[] memory recipientIds, uint32[] memory scaled) {
        recipientIds = new bytes32[](1);
        recipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;

        scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;
    }
}

contract FlowLedgerPropStakeVault {
    mapping(address => uint256) internal _weight;
    bool internal _goalResolved;

    function setWeight(address account, uint256 weight) external {
        _weight[account] = weight;
    }

    function setGoalResolved(bool resolved_) external {
        _goalResolved = resolved_;
    }

    function goalResolved() external view returns (bool) {
        return _goalResolved;
    }

    function weightOf(address account) external view returns (uint256) {
        return _weight[account];
    }
}

contract FlowLedgerPropGoalTreasury {
    address public flow;
    address public stakeVault;
    bool public resolved;

    constructor(address flow_, address stakeVault_) {
        flow = flow_;
        stakeVault = stakeVault_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}

contract FlowLedgerPropLedger {
    address public goalTreasury;
    uint256 public checkpointCallCount;

    mapping(bytes32 => address) internal _budgetByRecipient;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }

    function setBudget(bytes32 recipientId, address budgetTreasury) external {
        _budgetByRecipient[recipientId] = budgetTreasury;
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetByRecipient[recipientId];
    }

    function checkpointAllocation(
        address,
        uint256,
        bytes32[] calldata,
        uint32[] calldata,
        uint256,
        bytes32[] calldata,
        uint32[] calldata
    ) external {
        checkpointCallCount += 1;
    }
}

contract FlowLedgerPropBudgetTreasury {
    address public flow;
    address public premiumEscrow;

    constructor(address flow_, address premiumEscrow_) {
        flow = flow_;
        premiumEscrow = premiumEscrow_;
    }
}

contract FlowLedgerPropPremiumEscrow {
    error CHECKPOINT_REVERT();

    uint256 public checkpointCallCount;
    address public lastCheckpointAccount;
    bool public revertOnCheckpoint;

    function setRevertOnCheckpoint(bool shouldRevert) external {
        revertOnCheckpoint = shouldRevert;
    }

    function checkpoint(address account) external {
        if (revertOnCheckpoint) revert CHECKPOINT_REVERT();
        checkpointCallCount += 1;
        lastCheckpointAccount = account;
    }
}

contract FlowLedgerPropChildStrategy is IAllocationStrategy {
    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256 key) external pure returns (address) {
        return address(uint160(key));
    }

    function currentWeight(uint256) external pure returns (uint256) {
        return 0;
    }

    function canAllocate(uint256, address) external pure returns (bool) {
        return false;
    }

    function canAccountAllocate(address) external pure returns (bool) {
        return false;
    }

    function accountAllocationWeight(address) external pure returns (uint256) {
        return 0;
    }

    function strategyKey() external pure returns (string memory) {
        return "FlowLedgerPropChild";
    }
}

contract FlowLedgerPropChildFlow {
    IAllocationStrategy[] internal _strategies;

    bytes32 internal _commit;
    uint256 public syncCallCount;
    address public lastStrategy;
    uint256 public lastAllocationKey;

    constructor(address strategy_) {
        _strategies = new IAllocationStrategy[](1);
        _strategies[0] = IAllocationStrategy(strategy_);
    }

    function setCommit(bytes32 commit_) external {
        _commit = commit_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory) {
        return _strategies;
    }

    function getAllocationCommitment(address, uint256) external view returns (bytes32) {
        return _commit;
    }

    function syncAllocation(address strategy, uint256 allocationKey) external {
        syncCallCount += 1;
        lastStrategy = strategy;
        lastAllocationKey = allocationKey;
    }
}
