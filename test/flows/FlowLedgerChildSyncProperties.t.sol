// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowAllocationsBase} from "test/flows/FlowAllocations.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IAllocationPipeline} from "src/interfaces/IAllocationPipeline.sol";
import {IAllocationKeyAccountResolver} from "src/interfaces/IAllocationKeyAccountResolver.sol";
import {IBudgetStakeLedger} from "src/interfaces/IBudgetStakeLedger.sol";
import {IBudgetStackTopologyReader} from "src/interfaces/IBudgetStackTopologyReader.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {GoalFlowLedgerMode} from "src/library/GoalFlowLedgerMode.sol";
import {FlowProtocolConstants} from "src/library/FlowProtocolConstants.sol";
import {SortedRecipientMerge} from "src/library/SortedRecipientMerge.sol";
import {SingleAllocatorStrategy} from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";

contract FlowLedgerChildSyncPropertiesTest is FlowAllocationsBase {
    bytes32 internal constant CHILD_ALLOCATION_SYNC_FAILED_SIG =
        keccak256("ChildAllocationSyncFailed(address,address,address,uint256,address,address,uint256,bytes)");
    bytes32 internal constant CHILD_SYNC_DEBT_CLEARED_SIG =
        keccak256("ChildSyncDebtCleared(address,address,address,bytes32)");
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
    FlowLedgerPropBudgetTreasury internal budgetTreasury;
    FlowLedgerPropPremiumEscrow internal premiumEscrow;
    FlowLedgerPropChildFlow internal childFlow;
    FlowLedgerPropChildStrategy internal childStrategy;
    GoalFlowAllocationLedgerPipeline internal allocationPipeline;

    function setUp() public override {
        super.setUp();

        parentKey = uint256(uint160(allocator));

        stakeVault = new FlowLedgerPropStakeVault();
        address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        goalTreasury = new FlowLedgerPropGoalTreasury(predictedFlow);
        ledger = new FlowLedgerPropLedger(address(goalTreasury));

        strategy.setStakeVault(address(stakeVault));
        strategy.setGoalTreasury(address(goalTreasury));
        strategy.setCanAllocate(parentKey, allocator, true);

        allocationPipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));
        IAllocationStrategy configuredStrategy = IAllocationStrategy(address(strategy));
        flow = _deployFlowWithConfig(
            owner, manager, managerRewardPool, address(allocationPipeline), address(0), configuredStrategy
        );
        assertEq(address(flow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(flow), 500_000e18);

        childStrategy = new FlowLedgerPropChildStrategy();
        childFlow = new FlowLedgerPropChildFlow(address(childStrategy));
        premiumEscrow = new FlowLedgerPropPremiumEscrow();
        budgetTreasury =
            new FlowLedgerPropBudgetTreasury(address(childFlow), address(childStrategy), address(premiumEscrow));

        _registerBudgetRecipient(PARENT_BUDGET_RECIPIENT_ID, PARENT_BUDGET_RECIPIENT, address(budgetTreasury));
    }

    function test_pipelineClone_initialize_setsLedgerOnce_andRejectsReinitialize() public {
        GoalFlowAllocationLedgerPipeline implementation = new GoalFlowAllocationLedgerPipeline(address(0));
        GoalFlowAllocationLedgerPipeline clone = GoalFlowAllocationLedgerPipeline(Clones.clone(address(implementation)));

        assertEq(clone.allocationLedger(), address(0));
        clone.initialize(address(ledger));
        assertEq(clone.allocationLedger(), address(ledger));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(0xBEEF));
    }

    function test_pipelineClone_initialize_zeroAddress_allowedOnce_thenLocked() public {
        GoalFlowAllocationLedgerPipeline implementation = new GoalFlowAllocationLedgerPipeline(address(0));
        GoalFlowAllocationLedgerPipeline clone = GoalFlowAllocationLedgerPipeline(Clones.clone(address(implementation)));

        clone.initialize(address(0));
        assertEq(clone.allocationLedger(), address(0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(ledger));
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
        FlowLedgerPropChildStrategy secondChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondChildFlow = new FlowLedgerPropChildFlow(address(secondChildStrategy));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(secondChildFlow), address(secondChildStrategy), address(secondPremiumEscrow)
        );

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
            new FlowLedgerPropBudgetTreasury(address(childFlow), address(childStrategy), invalidPremiumEscrow);
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

    function test_allocate_withLedger_revertsWhenPremiumEscrowLookupReverts() public {
        FlowLedgerPropBudgetTreasuryPremiumEscrowReverting revertingBudgetTreasury =
            new FlowLedgerPropBudgetTreasuryPremiumEscrowReverting(address(childFlow), address(childStrategy));
        ledger.setBudget(PARENT_BUDGET_RECIPIENT_ID, address(revertingBudgetTreasury));

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
                FlowLedgerPropBudgetTreasuryPremiumEscrowReverting.PREMIUM_ESCROW_LOOKUP_REVERT.selector
            )
        );

        assertEq(ledger.checkpointCallCount(), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(premiumEscrow.checkpointCallCount(), 0);
    }

    function test_allocate_withLedger_multipleChangedBudgets_revertIsAtomicBeforeChildSync() public {
        FlowLedgerPropPremiumEscrow secondPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropChildStrategy secondChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondChildFlow = new FlowLedgerPropChildFlow(address(secondChildStrategy));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(secondChildFlow), address(secondChildStrategy), address(secondPremiumEscrow)
        );
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

    function test_allocate_withLedger_multipleChangedBudgets_invalidFirstPremiumEscrow_revertIsAtomicBeforeChildSync()
        public
    {
        FlowLedgerPropPremiumEscrow secondPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropChildStrategy secondChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondChildFlow = new FlowLedgerPropChildFlow(address(secondChildStrategy));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(secondChildFlow), address(secondChildStrategy), address(secondPremiumEscrow)
        );
        _registerBudgetRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(secondBudgetTreasury));

        address invalidPremiumEscrow = address(0xBEEF);
        FlowLedgerPropBudgetTreasury invalidBudgetTreasury =
            new FlowLedgerPropBudgetTreasury(address(childFlow), address(childStrategy), invalidPremiumEscrow);
        ledger.setBudget(PARENT_BUDGET_RECIPIENT_ID, address(invalidBudgetTreasury));

        childFlow.setCommit(keccak256("child-commit-1"));
        secondChildFlow.setCommit(keccak256("child-commit-2"));

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
            abi.encodeWithSelector(
                GoalFlowAllocationLedgerPipeline.INVALID_BUDGET_PREMIUM_ESCROW.selector,
                address(invalidBudgetTreasury),
                invalidPremiumEscrow
            )
        );

        assertEq(ledger.checkpointCallCount(), 0);
        assertEq(premiumEscrow.checkpointCallCount(), 0);
        assertEq(secondPremiumEscrow.checkpointCallCount(), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(secondChildFlow.syncCallCount(), 0);
    }

    function test_allocate_withLedger_multipleChangedBudgets_secondPremiumEscrowLookupRevertIsAtomicBeforeChildSync()
        public
    {
        FlowLedgerPropChildStrategy secondChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondChildFlow = new FlowLedgerPropChildFlow(address(secondChildStrategy));
        FlowLedgerPropBudgetTreasuryPremiumEscrowReverting revertingBudgetTreasury = new FlowLedgerPropBudgetTreasuryPremiumEscrowReverting(
            address(secondChildFlow), address(secondChildStrategy)
        );
        _registerBudgetRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(revertingBudgetTreasury));

        childFlow.setCommit(keccak256("child-commit-1"));
        secondChildFlow.setCommit(keccak256("child-commit-2"));

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
            abi.encodeWithSelector(
                FlowLedgerPropBudgetTreasuryPremiumEscrowReverting.PREMIUM_ESCROW_LOOKUP_REVERT.selector
            )
        );

        assertEq(ledger.checkpointCallCount(), 0);
        assertEq(premiumEscrow.checkpointCallCount(), 0);
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

    function test_allocate_withSingleAllocatorStrategy_checkpointsAndSyncsUsingControllerIdentity() public {
        address controller = address(new FlowLedgerPropManagedController());

        uint256 nonce = vm.getNonce(address(this));
        address predictedFlow = vm.computeCreateAddress(address(this), nonce + 4);
        FlowLedgerPropGoalTreasury managedGoalTreasury = new FlowLedgerPropGoalTreasury(predictedFlow);
        FlowLedgerPropLedger managedLedger = new FlowLedgerPropLedger(address(managedGoalTreasury));
        SingleAllocatorStrategy managedStrategy = new SingleAllocatorStrategy(address(managedGoalTreasury), controller);
        GoalFlowAllocationLedgerPipeline managedPipeline = new GoalFlowAllocationLedgerPipeline(address(managedLedger));

        ICustomFlow managedFlow = ICustomFlow(
            address(
                _deployFlowWithConfig(
                    owner,
                    manager,
                    managerRewardPool,
                    address(managedPipeline),
                    address(0),
                    IAllocationStrategy(address(managedStrategy))
                )
            )
        );
        assertEq(address(managedFlow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(managedFlow), 500_000e18);

        FlowLedgerPropChildStrategy managedChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow managedChildFlow = new FlowLedgerPropChildFlow(address(managedChildStrategy));
        FlowLedgerPropPremiumEscrow managedPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropBudgetTreasury managedBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(managedChildFlow), address(managedChildStrategy), address(managedPremiumEscrow)
        );

        vm.prank(manager);
        managedFlow.addRecipient(PARENT_BUDGET_RECIPIENT_ID, PARENT_BUDGET_RECIPIENT, recipientMetadata);
        managedLedger.setBudget(PARENT_BUDGET_RECIPIENT_ID, address(managedBudgetTreasury));

        managedChildFlow.setCommit(keccak256("managed-child-commit"));

        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();
        vm.prank(controller);
        managedFlow.allocate(recipientIds, scaled);

        assertEq(managedLedger.checkpointCallCount(), 1);
        assertEq(managedPremiumEscrow.checkpointCallCount(), 1);
        assertEq(managedPremiumEscrow.lastCheckpointAccount(), controller);
        assertEq(managedChildFlow.syncCallCount(), 1);
        assertEq(managedChildFlow.lastStrategy(), address(managedChildStrategy));
        assertEq(managedChildFlow.lastAllocationKey(), uint256(uint160(controller)));
    }

    function test_allocate_withSingleAllocatorStrategy_skipsCheckpointAndSyncWhenTreasuryResolved() public {
        address controller = address(new FlowLedgerPropManagedController());

        uint256 nonce = vm.getNonce(address(this));
        address predictedFlow = vm.computeCreateAddress(address(this), nonce + 4);
        FlowLedgerPropGoalTreasury managedGoalTreasury = new FlowLedgerPropGoalTreasury(predictedFlow);
        FlowLedgerPropLedger managedLedger = new FlowLedgerPropLedger(address(managedGoalTreasury));
        SingleAllocatorStrategy managedStrategy = new SingleAllocatorStrategy(address(managedGoalTreasury), controller);
        GoalFlowAllocationLedgerPipeline managedPipeline = new GoalFlowAllocationLedgerPipeline(address(managedLedger));

        ICustomFlow managedFlow = ICustomFlow(
            address(
                _deployFlowWithConfig(
                    owner,
                    manager,
                    managerRewardPool,
                    address(managedPipeline),
                    address(0),
                    IAllocationStrategy(address(managedStrategy))
                )
            )
        );
        assertEq(address(managedFlow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(managedFlow), 500_000e18);

        FlowLedgerPropChildStrategy managedChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow managedChildFlow = new FlowLedgerPropChildFlow(address(managedChildStrategy));
        FlowLedgerPropPremiumEscrow managedPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropBudgetTreasury managedBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(managedChildFlow), address(managedChildStrategy), address(managedPremiumEscrow)
        );
        FlowLedgerPropChildStrategy secondManagedChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondManagedChildFlow =
            new FlowLedgerPropChildFlow(address(secondManagedChildStrategy));
        FlowLedgerPropPremiumEscrow secondManagedPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropBudgetTreasury secondManagedBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(secondManagedChildFlow), address(secondManagedChildStrategy), address(secondManagedPremiumEscrow)
        );

        vm.startPrank(manager);
        managedFlow.addRecipient(PARENT_BUDGET_RECIPIENT_ID, PARENT_BUDGET_RECIPIENT, recipientMetadata);
        managedFlow.addRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, recipientMetadata);
        vm.stopPrank();
        managedLedger.setBudget(PARENT_BUDGET_RECIPIENT_ID, address(managedBudgetTreasury));
        managedLedger.setBudget(SECOND_BUDGET_RECIPIENT_ID, address(secondManagedBudgetTreasury));

        managedChildFlow.setCommit(keccak256("managed-child-commit-1"));
        secondManagedChildFlow.setCommit(keccak256("managed-child-commit-2"));

        (bytes32[] memory firstRecipientIds, uint32[] memory firstScaled) = _singleParentAllocation();
        vm.prank(controller);
        managedFlow.allocate(firstRecipientIds, firstScaled);

        uint256 managedAllocationKey = uint256(uint160(controller));
        assertEq(managedLedger.checkpointCallCount(), 1);
        assertEq(managedPremiumEscrow.checkpointCallCount(), 1);
        assertEq(secondManagedPremiumEscrow.checkpointCallCount(), 0);
        assertEq(managedChildFlow.syncCallCount(), 1);
        assertEq(secondManagedChildFlow.syncCallCount(), 0);

        managedGoalTreasury.setResolved(true);

        (bytes32[] memory secondRecipientIds, uint32[] memory secondScaled) =
            _singleAllocation(SECOND_BUDGET_RECIPIENT_ID);
        ICustomFlow.ChildSyncRequirement[] memory reqs =
            managedFlow.previewChildSyncRequirements(managedAllocationKey, secondRecipientIds, secondScaled);
        assertEq(reqs.length, 0);

        uint256 checkpointsBefore = managedLedger.checkpointCallCount();
        uint256 premiumCheckpointsBefore = managedPremiumEscrow.checkpointCallCount();

        vm.prank(controller);
        managedFlow.allocate(secondRecipientIds, secondScaled);

        assertEq(managedLedger.checkpointCallCount(), checkpointsBefore);
        assertEq(managedPremiumEscrow.checkpointCallCount(), premiumCheckpointsBefore);
        assertEq(secondManagedPremiumEscrow.checkpointCallCount(), 0);
        assertEq(managedChildFlow.syncCallCount(), 1);
        assertEq(secondManagedChildFlow.syncCallCount(), 0);
        assertEq(managedFlow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), 0);
        assertEq(managedFlow.distributionPool().getUnits(SECOND_BUDGET_RECIPIENT), _units(1e24, FULL_SCALED));
        assertEq(
            managedFlow.getAllocationCommitment(address(managedStrategy), managedAllocationKey),
            keccak256(abi.encode(secondRecipientIds, secondScaled))
        );
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

    function test_allocate_changedStake_childSyncRevert_emitsFailureReasonTelemetry() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);

        _setWeights(40e18);
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        vm.recordLogs();
        vm.prank(allocator);
        flow.allocate(recipientIds, scaled);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory expectedReason = abi.encodeWithSelector(FlowLedgerPropChildFlow.SYNC_REVERT.selector);
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != CHILD_ALLOCATION_SYNC_FAILED_SIG) continue;
            if (logEntry.emitter != flow.allocationPipeline()) continue;

            (uint256 allocationKey,,,, bytes memory reason) =
                abi.decode(logEntry.data, (uint256, address, address, uint256, bytes));
            assertEq(allocationKey, parentKey);
            assertEq(reason, expectedReason);
            found = true;
            break;
        }

        assertTrue(found);
        assertEq(childFlow.syncCallCount(), 0);
    }

    function test_allocate_childSyncDebt_blocksFollowupAllocationsUntilRepaired() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);

        _setWeights(40e18);
        _allocateParentSingleRecipient();

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);
        GoalFlowAllocationLedgerPipeline.ChildSyncDebtView memory debt =
            allocationPipeline.childSyncDebt(allocator, address(budgetTreasury));
        assertTrue(debt.exists);
        assertEq(debt.childFlow, address(childFlow));
        assertEq(debt.childStrategy, address(childStrategy));
        assertEq(debt.allocationKey, parentKey);
        assertEq(debt.reason, bytes32("SYNC_FAILED"));

        FlowLedgerPropPremiumEscrow secondPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropChildStrategy secondChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondChildFlow = new FlowLedgerPropChildFlow(address(secondChildStrategy));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(secondChildFlow), address(secondChildStrategy), address(secondPremiumEscrow)
        );
        _registerBudgetRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(secondBudgetTreasury));

        uint256 checkpointsBefore = ledger.checkpointCallCount();
        bytes[][] memory allocationData = _parentAllocationData();
        bytes32[] memory recipientIds = new bytes32[](2);
        recipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        recipientIds[1] = SECOND_BUDGET_RECIPIENT_ID;

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;
        _setWeights(30e18);
        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            address(strategy),
            address(flow),
            recipientIds,
            scaled,
            abi.encodeWithSelector(GoalFlowAllocationLedgerPipeline.ACCOUNT_HAS_CHILD_SYNC_DEBT.selector, allocator, 1)
        );
        assertEq(ledger.checkpointCallCount(), checkpointsBefore);

        childFlow.setRevertSync(false);
        bool repaired = allocationPipeline.repairChildSyncDebt(allocator, address(budgetTreasury));
        assertTrue(repaired);
        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);

        _setWeights(30e18);
        _allocateParentSingleRecipient();
    }

    function test_syncAllocationForAccount_weightOnlyCommit_proceedsEvenWhenChildSyncDebtExists() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);

        _setWeights(40e18);
        _allocateParentSingleRecipient();

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(40e18, FULL_SCALED));

        uint256 checkpointsBefore = ledger.checkpointCallCount();
        _setWeights(20e18);
        vm.prank(allocator);
        flow.syncAllocationForAccount(allocator);

        // Debt can remain open while child sync keeps failing, but parent weight sync must still apply.
        assertEq(ledger.checkpointCallCount(), checkpointsBefore + 1);
        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(20e18, FULL_SCALED));
    }

    function test_syncAllocationForAccount_weightOnlyCommit_freshSyncFailure_doesNotOpenChildSyncDebt() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);

        _setWeights(40e18);
        vm.prank(other);
        flow.syncAllocationForAccount(allocator);

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(40e18, FULL_SCALED));
    }

    function test_syncAllocationForAccount_weightOnlyCommit_lowGasSkip_doesNotOpenChildSyncDebt() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));

        _setWeights(40e18);
        vm.prank(other);
        flow.syncAllocationForAccount{gas: 1_800_000}(allocator);

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(40e18, FULL_SCALED));
    }

    function test_syncAllocationForAccount_weightOnlyCommit_recoveredChildSync_clearsDebtAndEmitsTelemetry() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);

        _setWeights(40e18);
        _allocateParentSingleRecipient();

        GoalFlowAllocationLedgerPipeline.ChildSyncDebtView memory debtBefore =
            allocationPipeline.childSyncDebt(allocator, address(budgetTreasury));
        assertTrue(debtBefore.exists);
        assertEq(debtBefore.reason, bytes32("SYNC_FAILED"));

        childFlow.setRevertSync(false);
        _setWeights(20e18);
        vm.recordLogs();
        vm.prank(other);
        flow.syncAllocationForAccount(allocator);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool clearedEventFound;
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != CHILD_SYNC_DEBT_CLEARED_SIG) continue;
            if (logEntry.emitter != flow.allocationPipeline()) continue;

            assertEq(logEntry.topics[1], bytes32(uint256(uint160(allocator))));
            assertEq(logEntry.topics[2], bytes32(uint256(uint160(address(budgetTreasury)))));
            assertEq(logEntry.topics[3], bytes32(uint256(uint160(address(childFlow)))));

            bytes32 reason = abi.decode(logEntry.data, (bytes32));
            assertEq(reason, bytes32("SYNCED"));
            clearedEventFound = true;
            break;
        }

        assertTrue(clearedEventFound);
        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);
        assertEq(childFlow.syncCallCount(), 1);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(20e18, FULL_SCALED));
    }

    function test_allocate_weightOnlyCommit_underDebt_proceedsAndClearsWhenChildSyncRecovers() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);

        _setWeights(40e18);
        _allocateParentSingleRecipient();
        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);

        _setWeights(20e18);
        _allocateParentSingleRecipient();

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(20e18, FULL_SCALED));
        assertEq(childFlow.syncCallCount(), 0);

        childFlow.setRevertSync(false);
        _setWeights(10e18);
        _allocateParentSingleRecipient();

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(10e18, FULL_SCALED));
        assertEq(childFlow.syncCallCount(), 1);
    }

    function test_repairChildSyncDebt_clearsWhenChildCommitMissing() public {
        _setWeights(80e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        childFlow.setRevertSync(true);
        _setWeights(40e18);
        _allocateParentSingleRecipient();

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);

        childFlow.setCommit(bytes32(0));
        bool cleared = allocationPipeline.repairChildSyncDebt(allocator, address(budgetTreasury));
        assertTrue(cleared);
        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);
    }

    function test_repairChildSyncDebt_clearsWhenChildTargetUnavailable() public {
        FlowLedgerPropChildStrategy unavailableChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow unavailableChildFlow = new FlowLedgerPropChildFlow(address(unavailableChildStrategy));
        FlowLedgerPropMutableBudgetTreasury unavailableBudgetTreasury = new FlowLedgerPropMutableBudgetTreasury(
            address(unavailableChildFlow), address(unavailableChildStrategy), address(premiumEscrow)
        );

        _registerBudgetRecipient(
            SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(unavailableBudgetTreasury)
        );

        bytes[][] memory allocationData = _parentAllocationData();
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleAllocation(SECOND_BUDGET_RECIPIENT_ID);

        _setWeights(80e18);
        _allocateWithPrevStateForStrategy(
            allocator, allocationData, address(strategy), address(flow), recipientIds, scaled
        );

        unavailableChildFlow.setCommit(keccak256("child-commit"));
        unavailableChildFlow.setRevertSync(true);
        _setWeights(40e18);
        _allocateWithPrevStateForStrategy(
            allocator, allocationData, address(strategy), address(flow), recipientIds, scaled
        );

        assertEq(allocationPipeline.childSyncDebtCount(allocator), 1);
        GoalFlowAllocationLedgerPipeline.ChildSyncDebtView memory debt =
            allocationPipeline.childSyncDebt(allocator, address(unavailableBudgetTreasury));
        assertTrue(debt.exists);
        assertEq(debt.reason, bytes32("SYNC_FAILED"));

        unavailableBudgetTreasury.setFlow(address(0xBEEF));

        bool cleared = allocationPipeline.repairChildSyncDebt(allocator, address(unavailableBudgetTreasury));
        assertTrue(cleared);
        assertEq(allocationPipeline.childSyncDebtCount(allocator), 0);
    }

    function testFuzz_allocate_stakeVaultResolved_childCommitNonZero_changedStake_stillCheckpointsAndSyncs(
        uint96 initialStakeSeed,
        uint96 reducedStakeSeed
    ) public {
        uint256 initialStake = bound(uint256(initialStakeSeed), 2e18, 1e30);
        uint256 reducedStake = bound(uint256(reducedStakeSeed), 1e18, initialStake - UNIT_WEIGHT_SCALE);

        _setWeights(initialStake);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit"));
        stakeVault.setGoalResolved(true);

        _setWeights(reducedStake);
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();
        ICustomFlow.ChildSyncRequirement[] memory reqs =
            flow.previewChildSyncRequirements(parentKey, recipientIds, scaled);
        assertEq(reqs.length, 1);

        uint256 checkpointsBefore = ledger.checkpointCallCount();
        _allocateParentSingleRecipient();

        assertEq(ledger.checkpointCallCount(), checkpointsBefore + 1);
        assertEq(childFlow.syncCallCount(), 1);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), _units(reducedStake, FULL_SCALED));
        assertEq(
            flow.getAllocationCommitment(address(strategy), parentKey), keccak256(abi.encode(recipientIds, scaled))
        );
    }

    function test_allocate_treasuryResolvedBeforeStakeVaultResolved_redirectsUnitsWhileSkippingLedgerAndChildSync()
        public
    {
        FlowLedgerPropPremiumEscrow secondPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropChildStrategy secondChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow secondChildFlow = new FlowLedgerPropChildFlow(address(secondChildStrategy));
        FlowLedgerPropBudgetTreasury secondBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(secondChildFlow), address(secondChildStrategy), address(secondPremiumEscrow)
        );
        _registerBudgetRecipient(SECOND_BUDGET_RECIPIENT_ID, SECOND_BUDGET_RECIPIENT, address(secondBudgetTreasury));

        _setWeights(25e18);
        _allocateParentSingleRecipient();

        childFlow.setCommit(keccak256("child-commit-1"));
        secondChildFlow.setCommit(keccak256("child-commit-2"));

        goalTreasury.setResolved(true);
        assertFalse(stakeVault.goalResolved());

        bytes[][] memory allocationData = _parentAllocationData();
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleAllocation(SECOND_BUDGET_RECIPIENT_ID);
        ICustomFlow.ChildSyncRequirement[] memory reqs =
            flow.previewChildSyncRequirements(parentKey, recipientIds, scaled);
        assertEq(reqs.length, 0);

        uint256 checkpointsBefore = ledger.checkpointCallCount();
        uint256 premiumCheckpointsBefore = premiumEscrow.checkpointCallCount();

        _allocateWithPrevStateForStrategy(
            allocator, allocationData, address(strategy), address(flow), recipientIds, scaled
        );

        assertEq(ledger.checkpointCallCount(), checkpointsBefore);
        assertEq(premiumEscrow.checkpointCallCount(), premiumCheckpointsBefore);
        assertEq(secondPremiumEscrow.checkpointCallCount(), 0);
        assertEq(childFlow.syncCallCount(), 0);
        assertEq(secondChildFlow.syncCallCount(), 0);
        assertEq(flow.distributionPool().getUnits(PARENT_BUDGET_RECIPIENT), 0);
        assertEq(flow.distributionPool().getUnits(SECOND_BUDGET_RECIPIENT), _units(25e18, FULL_SCALED));
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

    function test_allocate_withRealBudgetStakeLedger_registerAndCheckpointStakeAccounting() public {
        FlowLedgerPropBudgetRegistryManager budgetRegistryManager = new FlowLedgerPropBudgetRegistryManager();
        FlowLedgerPropStakeVault realStakeVault = new FlowLedgerPropStakeVault();

        uint256 nonce = vm.getNonce(address(this));
        address predictedFlow = vm.computeCreateAddress(address(this), nonce + 3);
        FlowLedgerPropGoalTreasury realGoalTreasury = new FlowLedgerPropGoalTreasury(predictedFlow);
        BudgetStakeLedger realLedger = new BudgetStakeLedger(address(realGoalTreasury));

        strategy.setStakeVault(address(realStakeVault));
        strategy.setGoalTreasury(address(realGoalTreasury));
        strategy.setCanAllocate(parentKey, allocator, true);
        strategy.setCanAccountAllocate(allocator, true);

        GoalFlowAllocationLedgerPipeline realPipeline = new GoalFlowAllocationLedgerPipeline(address(realLedger));
        IAllocationStrategy strategies = IAllocationStrategy(address(strategy));
        address realFlow = address(
            _deployFlowWithConfig(
                owner, address(budgetRegistryManager), managerRewardPool, address(realPipeline), address(0), strategies
            )
        );
        assertEq(realFlow, predictedFlow);

        vm.prank(owner);
        superToken.transfer(realFlow, 500_000e18);

        vm.prank(address(budgetRegistryManager));
        ICustomFlow(realFlow).addRecipient(PARENT_BUDGET_RECIPIENT_ID, PARENT_BUDGET_RECIPIENT, recipientMetadata);

        FlowLedgerPropBudgetFlowRegistrable registrableBudgetFlow =
            new FlowLedgerPropBudgetFlowRegistrable(realFlow, address(strategy));
        FlowLedgerPropPremiumEscrow registrablePremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropBudgetTreasuryRegistrable registrableBudgetTreasury = new FlowLedgerPropBudgetTreasuryRegistrable(
            address(registrableBudgetFlow),
            address(registrablePremiumEscrow),
            uint64(block.timestamp),
            address(budgetRegistryManager)
        );

        budgetRegistryManager.setTopology(
            PARENT_BUDGET_RECIPIENT_ID,
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: address(registrableBudgetFlow),
                budgetTreasury: address(registrableBudgetTreasury),
                premiumEscrow: address(registrablePremiumEscrow),
                strategy: address(strategy),
                allocationMechanism: address(0),
                allocationMechanismArbitrator: address(0)
            }),
            true
        );

        vm.prank(address(budgetRegistryManager));
        realLedger.registerBudget(PARENT_BUDGET_RECIPIENT_ID, address(registrableBudgetTreasury));

        assertEq(realLedger.budgetForRecipient(PARENT_BUDGET_RECIPIENT_ID), address(registrableBudgetTreasury));
        assertEq(realLedger.trackedBudgetCount(), 1);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        uint256 initialWeight = 40 * UNIT_WEIGHT_SCALE;
        realStakeVault.setWeight(allocator, initialWeight);
        strategy.setWeight(parentKey, initialWeight);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), realFlow, recipientIds, scaled);

        assertEq(realLedger.userAllocatedStakeOnBudget(allocator, address(registrableBudgetTreasury)), initialWeight);
        assertEq(realLedger.budgetTotalAllocatedStake(address(registrableBudgetTreasury)), initialWeight);
        IBudgetStakeLedger.UserBudgetCheckpointView memory firstUserCheckpoint =
            realLedger.userBudgetCheckpoint(allocator, address(registrableBudgetTreasury));
        IBudgetStakeLedger.BudgetCheckpointView memory firstBudgetCheckpoint =
            realLedger.budgetCheckpoint(address(registrableBudgetTreasury));
        uint64 firstUserCheckpointAt = firstUserCheckpoint.lastCheckpoint;
        uint64 firstBudgetCheckpointAt = firstBudgetCheckpoint.lastCheckpoint;
        assertGt(firstUserCheckpointAt, 0);
        assertGt(firstBudgetCheckpointAt, 0);

        uint256 reducedWeight = 15 * UNIT_WEIGHT_SCALE;
        vm.warp(block.timestamp + 1);
        realStakeVault.setWeight(allocator, reducedWeight);
        strategy.setWeight(parentKey, reducedWeight);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), realFlow, recipientIds, scaled);

        assertEq(realLedger.userAllocatedStakeOnBudget(allocator, address(registrableBudgetTreasury)), reducedWeight);
        assertEq(realLedger.budgetTotalAllocatedStake(address(registrableBudgetTreasury)), reducedWeight);
        IBudgetStakeLedger.UserBudgetCheckpointView memory secondUserCheckpoint =
            realLedger.userBudgetCheckpoint(allocator, address(registrableBudgetTreasury));
        IBudgetStakeLedger.BudgetCheckpointView memory secondBudgetCheckpoint =
            realLedger.budgetCheckpoint(address(registrableBudgetTreasury));
        uint64 secondUserCheckpointAt = secondUserCheckpoint.lastCheckpoint;
        uint64 secondBudgetCheckpointAt = secondBudgetCheckpoint.lastCheckpoint;
        assertGt(secondUserCheckpointAt, firstUserCheckpointAt);
        assertGt(secondBudgetCheckpointAt, firstBudgetCheckpointAt);
        assertEq(registrablePremiumEscrow.checkpointCallCount(), 2);
        assertEq(registrablePremiumEscrow.lastCheckpointAccount(), allocator);
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

    function test_previewChildSyncRequirements_directPipelineCall_usesExplicitFlowContext() public {
        uint256 initialStake = 80e18;
        uint256 reducedStake = 40e18;
        bytes32 childCommit = keccak256("child-commit");

        _setWeights(initialStake);
        _allocateParentSingleRecipient();
        childFlow.setCommit(childCommit);

        _setWeights(reducedStake);
        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        ICustomFlow.ChildSyncRequirement[] memory reqs = allocationPipeline.previewChildSyncRequirements(
            address(flow), address(strategy), parentKey, initialStake, recipientIds, scaled, recipientIds, scaled
        );

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(budgetTreasury));
        assertEq(reqs[0].childFlow, address(childFlow));
        assertEq(reqs[0].childStrategy, address(childStrategy));
        assertEq(reqs[0].allocationKey, parentKey);
        assertEq(reqs[0].expectedCommit, childCommit);

        FlowLedgerPropBudgetFlowRegistrable wrongFlow =
            new FlowLedgerPropBudgetFlowRegistrable(address(0), address(strategy));
        vm.expectRevert(
            abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER_FLOW.selector, address(wrongFlow), address(flow))
        );
        allocationPipeline.previewChildSyncRequirements(
            address(wrongFlow), address(strategy), parentKey, initialStake, recipientIds, scaled, recipientIds, scaled
        );
    }

    function test_gas_allocate_withLedgerPremiumCheckpoint_overheadUnderTwentyPercent() public {
        uint256 withPremiumCheckpointGas = _measureAllocateGasForPipelineVariant(true);
        uint256 withoutPremiumCheckpointGas = _measureAllocateGasForPipelineVariant(false);

        assertGt(withPremiumCheckpointGas, withoutPremiumCheckpointGas);

        uint256 overhead = withPremiumCheckpointGas - withoutPremiumCheckpointGas;
        uint256 overheadBps = (overhead * FlowProtocolConstants.BPS_SCALE_UINT256) / withPremiumCheckpointGas;

        emit log_named_uint("allocate_gas_with_premium_checkpoint", withPremiumCheckpointGas);
        emit log_named_uint("allocate_gas_without_premium_checkpoint", withoutPremiumCheckpointGas);
        emit log_named_uint("allocate_gas_premium_checkpoint_overhead", overhead);
        emit log_named_uint("allocate_gas_premium_checkpoint_overhead_bps", overheadBps);

        assertLe(overheadBps, 2_000);
    }

    function _measureAllocateGasForPipelineVariant(bool includePremiumCheckpoint) internal returns (uint256 gasUsed) {
        uint256 deploymentNonce = vm.getNonce(address(this));
        address predictedFlow = vm.computeCreateAddress(address(this), deploymentNonce + 5);

        FlowLedgerPropStakeVault benchmarkStakeVault = new FlowLedgerPropStakeVault();
        FlowLedgerPropGoalTreasury benchmarkGoalTreasury = new FlowLedgerPropGoalTreasury(predictedFlow);
        FlowLedgerPropLedger benchmarkLedger = new FlowLedgerPropLedger(address(benchmarkGoalTreasury));
        address benchmarkPipeline = includePremiumCheckpoint
            ? address(new GoalFlowAllocationLedgerPipeline(address(benchmarkLedger)))
            : address(new FlowLedgerPropNoPremiumCheckpointPipeline(address(benchmarkLedger)));

        MockAllocationStrategy benchmarkStrategy = new MockAllocationStrategy();
        benchmarkStrategy.setUseAuxAsKey(true);
        benchmarkStrategy.setStakeVault(address(benchmarkStakeVault));
        benchmarkStrategy.setGoalTreasury(address(benchmarkGoalTreasury));

        uint256 benchmarkKey = benchmarkStrategy.allocationKey(allocator, bytes(""));
        benchmarkStrategy.setCanAllocate(benchmarkKey, allocator, true);
        benchmarkStrategy.setCanAccountAllocate(allocator, true);

        IAllocationStrategy strategies = IAllocationStrategy(address(benchmarkStrategy));

        ICustomFlow benchmarkFlow = ICustomFlow(
            address(_deployFlowWithConfig(owner, manager, managerRewardPool, benchmarkPipeline, address(0), strategies))
        );
        assertEq(address(benchmarkFlow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(benchmarkFlow), 500_000e18);

        FlowLedgerPropChildStrategy benchmarkChildStrategy = new FlowLedgerPropChildStrategy();
        FlowLedgerPropChildFlow benchmarkChildFlow = new FlowLedgerPropChildFlow(address(benchmarkChildStrategy));
        FlowLedgerPropPremiumEscrow benchmarkPremiumEscrow = new FlowLedgerPropPremiumEscrow();
        FlowLedgerPropBudgetTreasury benchmarkBudgetTreasury = new FlowLedgerPropBudgetTreasury(
            address(benchmarkChildFlow), address(benchmarkChildStrategy), address(benchmarkPremiumEscrow)
        );

        vm.prank(manager);
        benchmarkFlow.addRecipient(PARENT_BUDGET_RECIPIENT_ID, PARENT_BUDGET_RECIPIENT, recipientMetadata);
        benchmarkLedger.setBudget(PARENT_BUDGET_RECIPIENT_ID, address(benchmarkBudgetTreasury));

        (bytes32[] memory recipientIds, uint32[] memory scaled) = _singleParentAllocation();

        uint256 initialWeight = 100 * UNIT_WEIGHT_SCALE;
        uint256 reducedWeight = 75 * UNIT_WEIGHT_SCALE;
        benchmarkStakeVault.setWeight(allocator, initialWeight);
        benchmarkStrategy.setWeight(benchmarkKey, initialWeight);

        vm.prank(allocator);
        benchmarkFlow.allocate(recipientIds, scaled);

        benchmarkStakeVault.setWeight(allocator, reducedWeight);
        benchmarkStrategy.setWeight(benchmarkKey, reducedWeight);

        uint256 gasBefore = gasleft();
        vm.prank(allocator);
        benchmarkFlow.allocate(recipientIds, scaled);
        gasUsed = gasBefore - gasleft();

        if (includePremiumCheckpoint) {
            assertEq(benchmarkPremiumEscrow.checkpointCallCount(), 2);
        } else {
            assertEq(benchmarkPremiumEscrow.checkpointCallCount(), 0);
        }
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

    function _singleAllocation(bytes32 recipientId)
        internal
        pure
        returns (bytes32[] memory recipientIds, uint32[] memory scaled)
    {
        recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;

        scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;
    }

    function _singleParentAllocation() internal pure returns (bytes32[] memory recipientIds, uint32[] memory scaled) {
        return _singleAllocation(PARENT_BUDGET_RECIPIENT_ID);
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

contract FlowLedgerPropNoPremiumCheckpointPipeline is IAllocationPipeline {
    address public immutable allocationLedger;

    error INVALID_ALLOCATION_PIPELINE_KEY_ACCOUNT(address strategy, uint256 allocationKey);

    constructor(address allocationLedger_) {
        allocationLedger = allocationLedger_;
    }

    function validateForFlow(address) external pure {}

    function onAllocationCommitted(
        address strategy,
        uint256 allocationKey,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationsPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationsPpm,
        IAllocationPipeline.CommitKind
    ) external {
        address ledger = allocationLedger;
        if (ledger == address(0)) return;

        address account = IAllocationKeyAccountResolver(strategy).accountForAllocationKey(allocationKey);
        if (account == address(0)) revert INVALID_ALLOCATION_PIPELINE_KEY_ACCOUNT(strategy, allocationKey);

        address[] memory changedBudgetTreasuries = IBudgetStakeLedger(ledger)
            .checkpointAllocation(
                account, prevWeight, prevRecipientIds, prevAllocationsPpm, newWeight, newRecipientIds, newAllocationsPpm
            );
        if (changedBudgetTreasuries.length == 0) return;

        GoalFlowLedgerMode.ChildSyncAction[] memory actions =
            GoalFlowLedgerMode.buildChildSyncActions(account, changedBudgetTreasuries);
        GoalFlowLedgerMode.executeChildSyncBestEffort(actions);
    }

    function previewChildSyncRequirements(
        address,
        address,
        uint256,
        uint256,
        bytes32[] calldata,
        uint32[] calldata,
        bytes32[] calldata,
        uint32[] calldata
    ) external pure returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        reqs = new ICustomFlow.ChildSyncRequirement[](0);
    }
}

contract FlowLedgerPropGoalTreasury {
    address public flow;
    bool public resolved;

    constructor(address flow_) {
        flow = flow_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}

contract FlowLedgerPropLedger {
    error NOT_SORTED_OR_DUPLICATE();

    uint256 private constant _PPM_SCALE = FlowProtocolConstants.PPM_SCALE_UINT256;
    uint256 private constant _UNIT_WEIGHT_SCALE = 1e15;

    struct DeltaBuckets {
        address[] decreases;
        address[] increases;
        uint256 decreaseCount;
        uint256 increaseCount;
    }

    struct MergeOrderState {
        bytes32 lastRecipientId;
        bool hasLastRecipientId;
    }

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
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external returns (address[] memory changedBudgetTreasuries) {
        checkpointCallCount += 1;
        return
            _changedBudgets(
                prevWeight, prevRecipientIds, prevAllocationPpm, newWeight, newRecipientIds, newAllocationPpm
            );
    }

    function previewChangedBudgetTreasuries(
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external view returns (address[] memory changedBudgetTreasuries) {
        return _changedBudgets(
            prevWeight, prevRecipientIds, prevAllocationPpm, newWeight, newRecipientIds, newAllocationPpm
        );
    }

    function _changedBudgets(
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) internal view returns (address[] memory changedBudgetTreasuries) {
        if (prevRecipientIds.length == 0 && newRecipientIds.length == 0) {
            return new address[](0);
        }

        DeltaBuckets memory buckets = _initBuckets(prevRecipientIds.length + newRecipientIds.length);
        MergeOrderState memory orderState;
        (SortedRecipientMerge.Cursor memory mergeCursor,) =
            SortedRecipientMerge.init(prevRecipientIds, newRecipientIds, SortedRecipientMerge.Precondition.AssumeSorted);

        while (SortedRecipientMerge.hasNext(mergeCursor, prevRecipientIds.length, newRecipientIds.length)) {
            (SortedRecipientMerge.Step memory step, SortedRecipientMerge.Cursor memory nextCursor) =
                SortedRecipientMerge.next(prevRecipientIds, newRecipientIds, mergeCursor);
            mergeCursor = nextCursor;
            _assertStrictMergedOrder(step.recipientId, orderState);
            orderState.lastRecipientId = step.recipientId;
            orderState.hasLastRecipientId = true;

            uint256 oldAllocated =
                step.hasOld ? _effectiveAllocatedStake(prevWeight, prevAllocationPpm[step.oldIndex]) : 0;
            uint256 newAllocated =
                step.hasNew ? _effectiveAllocatedStake(newWeight, newAllocationPpm[step.newIndex]) : 0;
            if (oldAllocated == newAllocated) continue;

            address budget = _budgetByRecipient[step.recipientId];
            if (budget == address(0)) continue;
            _recordDelta(buckets, budget, oldAllocated, newAllocated);
        }

        return _mergeBuckets(buckets);
    }

    function _initBuckets(uint256 maxCount) private pure returns (DeltaBuckets memory buckets) {
        buckets.decreases = new address[](maxCount);
        buckets.increases = new address[](maxCount);
    }

    function _assertStrictMergedOrder(bytes32 recipientId, MergeOrderState memory orderState) private pure {
        if (orderState.hasLastRecipientId && recipientId <= orderState.lastRecipientId) {
            revert NOT_SORTED_OR_DUPLICATE();
        }
    }

    function _recordDelta(DeltaBuckets memory buckets, address budget, uint256 oldAllocated, uint256 newAllocated)
        private
        pure
    {
        if (newAllocated < oldAllocated) {
            buckets.decreases[buckets.decreaseCount] = budget;
            unchecked {
                ++buckets.decreaseCount;
            }
        } else {
            buckets.increases[buckets.increaseCount] = budget;
            unchecked {
                ++buckets.increaseCount;
            }
        }
    }

    function _mergeBuckets(DeltaBuckets memory buckets)
        private
        pure
        returns (address[] memory changedBudgetTreasuries)
    {
        uint256 totalCount =
            buckets.decreaseCount + buckets.increaseCount;
        changedBudgetTreasuries = new address[](totalCount);
        for (uint256 i = 0; i < buckets.decreaseCount;) {
            changedBudgetTreasuries[i] = buckets.decreases[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < buckets.increaseCount;) {
            changedBudgetTreasuries[buckets.decreaseCount + i] = buckets.increases[i];
            unchecked {
                ++i;
            }
        }
    }

    function _effectiveAllocatedStake(uint256 weight, uint32 allocationPpm) internal pure returns (uint256) {
        return (weight * allocationPpm / _PPM_SCALE) / _UNIT_WEIGHT_SCALE * _UNIT_WEIGHT_SCALE;
    }
}

contract FlowLedgerPropBudgetRegistryManager {
    mapping(bytes32 => IBudgetStackTopologyReader.BudgetStackTopology) internal _topologyByItemId;
    mapping(bytes32 => bool) internal _activeByItemId;
    mapping(address => bytes32) internal _itemIdByBudgetTreasury;
    mapping(address => bytes32) internal _itemIdByChildFlow;

    function setTopology(bytes32 itemId, IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active)
        external
    {
        _topologyByItemId[itemId] = topology;
        _activeByItemId[itemId] = active;
        _itemIdByBudgetTreasury[topology.budgetTreasury] = itemId;
        _itemIdByChildFlow[topology.childFlow] = itemId;
    }

    function budgetStackTopology(bytes32 itemId)
        external
        view
        returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active)
    {
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function budgetStackTopologyForBudgetTreasury(address budgetTreasury)
        external
        view
        returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active)
    {
        bytes32 itemId = _itemIdByBudgetTreasury[budgetTreasury];
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function budgetStackTopologyForChildFlow(address childFlow)
        external
        view
        returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active)
    {
        bytes32 itemId = _itemIdByChildFlow[childFlow];
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function itemIdForBudgetTreasury(address budgetTreasury) external view returns (bytes32 itemId) {
        itemId = _itemIdByBudgetTreasury[budgetTreasury];
    }

    function itemIdForChildFlow(address childFlow) external view returns (bytes32 itemId) {
        itemId = _itemIdByChildFlow[childFlow];
    }
}

abstract contract FlowLedgerPropTopologyBudgetTreasuryBase {
    address public flow;
    address public topologyStrategy;
    bool internal _topologyActive = true;
    bool internal _revertAuthority;
    bool internal _revertTopologyLookup;

    constructor(address flow_, address topologyStrategy_) {
        flow = flow_;
        topologyStrategy = topologyStrategy_;
    }

    function setTopologyStrategy(address topologyStrategy_) external {
        topologyStrategy = topologyStrategy_;
    }

    function setTopologyActive(bool active_) external {
        _topologyActive = active_;
    }

    function setRevertAuthority(bool shouldRevert) external {
        _revertAuthority = shouldRevert;
    }

    function setRevertTopologyLookup(bool shouldRevert) external {
        _revertTopologyLookup = shouldRevert;
    }

    function authority() external view returns (address) {
        if (_revertAuthority) revert("authority");
        return address(this);
    }

    function budgetStackTopologyForBudgetTreasury(address budgetTreasury)
        external
        view
        returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active)
    {
        if (_revertTopologyLookup) revert("topology");
        if (budgetTreasury != address(this)) return (topology, false);

        topology = IBudgetStackTopologyReader.BudgetStackTopology({
            childFlow: flow,
            budgetTreasury: address(this),
            premiumEscrow: _topologyPremiumEscrow(),
            strategy: topologyStrategy,
            allocationMechanism: address(0),
            allocationMechanismArbitrator: address(0)
        });
        active = _topologyActive;
    }

    function _setFlow(address flow_) internal {
        flow = flow_;
    }

    function _topologyPremiumEscrow() internal view virtual returns (address);
}

contract FlowLedgerPropBudgetTreasury is FlowLedgerPropTopologyBudgetTreasuryBase {
    address public premiumEscrow;

    constructor(address flow_, address topologyStrategy_, address premiumEscrow_)
        FlowLedgerPropTopologyBudgetTreasuryBase(flow_, topologyStrategy_)
    {
        premiumEscrow = premiumEscrow_;
    }

    function _topologyPremiumEscrow() internal view override returns (address) {
        return premiumEscrow;
    }
}

contract FlowLedgerPropMutableBudgetTreasury is FlowLedgerPropBudgetTreasury {
    constructor(address flow_, address topologyStrategy_, address premiumEscrow_)
        FlowLedgerPropBudgetTreasury(flow_, topologyStrategy_, premiumEscrow_)
    {}

    function setFlow(address flow_) external {
        _setFlow(flow_);
    }
}

contract FlowLedgerPropBudgetTreasuryPremiumEscrowReverting is FlowLedgerPropTopologyBudgetTreasuryBase {
    error PREMIUM_ESCROW_LOOKUP_REVERT();

    constructor(address flow_, address topologyStrategy_)
        FlowLedgerPropTopologyBudgetTreasuryBase(flow_, topologyStrategy_)
    {}

    function premiumEscrow() external pure returns (address) {
        revert PREMIUM_ESCROW_LOOKUP_REVERT();
    }

    function _topologyPremiumEscrow() internal pure override returns (address) {
        return address(0);
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

    function currentWeight(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function canAllocate(address, uint256, address) external pure returns (bool) {
        return false;
    }

    function strategyKey() external pure returns (string memory) {
        return "FlowLedgerPropChild";
    }
}

contract FlowLedgerPropChildFlow {
    IAllocationStrategy internal _strategy;

    error SYNC_REVERT();

    bytes32 internal _commit;
    bool internal _revertSync;
    uint256 public syncCallCount;
    address public lastStrategy;
    uint256 public lastAllocationKey;

    constructor(address strategy_) {
        _strategy = IAllocationStrategy(strategy_);
    }

    function setCommit(bytes32 commit_) external {
        _commit = commit_;
    }

    function setRevertSync(bool shouldRevert) external {
        _revertSync = shouldRevert;
    }

    function strategy() external view returns (IAllocationStrategy) {
        return _strategy;
    }

    function getAllocationCommitment(address, uint256) external view returns (bytes32) {
        return _commit;
    }

    function syncAllocation(uint256 allocationKey) external {
        if (_revertSync) revert SYNC_REVERT();
        syncCallCount += 1;
        lastStrategy = address(_strategy);
        lastAllocationKey = allocationKey;
    }
}

contract FlowLedgerPropBudgetFlowRegistrable {
    address public parent;
    address internal _strategy;

    constructor(address parent_, address strategy_) {
        parent = parent_;
        _strategy = strategy_;
    }

    function strategy() external view returns (IAllocationStrategy) {
        return IAllocationStrategy(_strategy);
    }
}

contract FlowLedgerPropBudgetTreasuryRegistrable {
    address public flow;
    address public authority;
    address public premiumEscrow;
    uint64 public resolvedAt;
    uint64 public activatedAt;
    uint64 public executionDuration = 1 days;
    uint64 public fundingDeadline = type(uint64).max;
    uint8 public state;

    constructor(address flow_, address premiumEscrow_, uint64 activatedAt_, address authority_) {
        flow = flow_;
        authority = authority_;
        premiumEscrow = premiumEscrow_;
        activatedAt = activatedAt_;
    }
}

contract FlowLedgerPropManagedController {}
