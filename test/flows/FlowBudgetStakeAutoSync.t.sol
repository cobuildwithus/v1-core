// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowAllocationsBase } from "test/flows/FlowAllocations.t.sol";
import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { BudgetStakeStrategy } from "src/allocation-strategies/BudgetStakeStrategy.sol";
import { GoalStakeVaultStrategy } from "src/allocation-strategies/GoalStakeVaultStrategy.sol";
import { GoalFlowAllocationLedgerPipeline } from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IGoalStakeVault } from "src/interfaces/IGoalStakeVault.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalFlowLedgerMode } from "src/library/GoalFlowLedgerMode.sol";
import { TestableCustomFlow } from "test/harness/TestableCustomFlow.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FlowBudgetStakeAutoSyncTest is FlowAllocationsBase {
    event ChildAllocationSyncAttempted(
        address indexed budgetTreasury,
        address indexed childFlow,
        address indexed strategy,
        uint256 allocationKey,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bool success
    );
    event ChildAllocationSyncSkipped(
        address indexed budgetTreasury,
        address indexed childFlow,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bytes32 reason
    );
    event BudgetTreasurySyncAttempted(
        address indexed budgetTreasury,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bool success
    );
    event BudgetTreasurySyncFailed(
        address indexed budgetTreasury,
        address parentFlow,
        address parentStrategy,
        uint256 parentAllocationKey,
        bytes4 revertSelector,
        bytes32 revertDataHash,
        uint256 revertDataLength,
        bytes revertDataTruncated
    );

    bytes32 internal constant CHILD_SYNC_SKIP_NO_COMMITMENT = "NO_COMMITMENT";
    bytes32 internal constant CHILD_SYNC_SKIP_TARGET_UNAVAILABLE = "TARGET_UNAVAILABLE";
    bytes32 internal constant CHILD_SYNC_SKIP_GAS_BUDGET = "GAS_BUDGET";

    bytes32 internal constant PARENT_BUDGET_RECIPIENT_ID = bytes32(uint256(9001));
    bytes32 internal constant CHILD_RECIPIENT_ID = bytes32(uint256(9002));
    address internal constant CHILD_RECIPIENT = address(0xF00D);
    bytes32 internal constant DERIVED_PARENT_BUDGET_RECIPIENT_ID = bytes32(uint256(9101));
    bytes32 internal constant DERIVED_CHILD_RECIPIENT_ID = bytes32(uint256(9102));
    address internal constant DERIVED_CHILD_RECIPIENT = address(0xD351);
    bytes32 internal constant GOAL_PARENT_BUDGET_RECIPIENT_ID = bytes32(uint256(9201));
    bytes32 internal constant GOAL_CHILD_RECIPIENT_ID = bytes32(uint256(9202));
    address internal constant GOAL_CHILD_RECIPIENT = address(0x60A1);
    bytes internal constant STALE_SINGLE_RECIPIENT_SNAPSHOT = hex"000100000000000f4240";
    uint256 internal parentKey;

    BudgetStakeLedger internal ledger;
    GoalFlowAllocationLedgerPipeline internal ledgerPipeline;
    BudgetStakeStrategy internal budgetStrategy;
    FlowBudgetAutoSyncStakeVault internal stakeVault;
    FlowBudgetAutoSyncGoalTreasury internal goalTreasury;
    FlowBudgetAutoSyncBudgetTreasury internal budgetTreasury;
    CustomFlow internal childFlow;

    function setUp() public override {
        super.setUp();

        stakeVault = new FlowBudgetAutoSyncStakeVault();
        address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        goalTreasury = new FlowBudgetAutoSyncGoalTreasury(predictedFlow, address(stakeVault));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        strategy.setStakeVault(address(stakeVault));
        parentKey = uint256(uint160(allocator));
        strategy.setCanAllocate(parentKey, allocator, true);

        ledgerPipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        flow = _deployFlowWithConfig(owner, manager, managerRewardPool, address(ledgerPipeline), address(0), strategies);
        assertEq(address(flow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(flow), 500_000e18);

        budgetTreasury = new FlowBudgetAutoSyncBudgetTreasury(address(0));
        budgetStrategy = new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), PARENT_BUDGET_RECIPIENT_ID);
        childFlow = _deployChildFlow(address(flow), address(budgetStrategy));
        budgetTreasury.setFlow(address(childFlow));

        _addRecipient(PARENT_BUDGET_RECIPIENT_ID, address(childFlow));
        vm.prank(manager);
        ledger.registerBudget(PARENT_BUDGET_RECIPIENT_ID, address(budgetTreasury));

        vm.prank(manager);
        childFlow.addRecipient(CHILD_RECIPIENT_ID, CHILD_RECIPIENT, recipientMetadata);
    }

    function test_allocate_withChildSync_autoSyncsBudgetChildUnitsOnParentWeightDecrease() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );

        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialUnits);

        _setParentWeight(reducedWeight);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        _updatePrevStateCacheForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            parentRecipientIds,
            parentBps
        );

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_attemptsBudgetTreasurySync_forChangedBudget() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint256 syncCallsBefore = budgetTreasury.syncCalls();

        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, true);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(budgetTreasury.syncCalls(), syncCallsBefore + 1);
    }

    function test_allocate_withChildSync_continuesWhenBudgetTreasurySyncReverts() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );
        budgetTreasury.setSyncShouldRevert(true);

        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, false);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_emitsBudgetTreasurySyncFailedDiagnostics_forErrorStringRevert() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        budgetTreasury.setSyncShouldRevert(true);
        bytes memory expectedRevertData = abi.encodeWithSelector(bytes4(keccak256("Error(string)")), "SYNC_REVERT");

        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncFailed(
            address(budgetTreasury),
            address(flow),
            address(strategy),
            parentKey,
            bytes4(keccak256("Error(string)")),
            keccak256(expectedRevertData),
            expectedRevertData.length,
            expectedRevertData
        );
        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, false);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_emitsBudgetTreasurySyncFailedDiagnostics_withTruncatedRawRevertData()
        public
    {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        bytes memory longRevertData = _bytesRange(4096);
        budgetTreasury.setSyncRevertData(longRevertData);
        bytes memory truncatedRevertData = _slicePrefix(longRevertData, 160);

        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncFailed(
            address(budgetTreasury),
            address(flow),
            address(strategy),
            parentKey,
            bytes4(0x01020304),
            keccak256(truncatedRevertData),
            longRevertData.length,
            truncatedRevertData
        );
        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, false);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_appliesBudgetTreasurySyncGasStipend() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        budgetTreasury.setMaxSyncGas(550_000);
        uint256 syncCallsBefore = budgetTreasury.syncCalls();
        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, true);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(budgetTreasury.syncCalls(), syncCallsBefore + 1);
    }

    function test_allocate_withChildSync_budgetSyncStipendFailure_doesNotBlockChildSync() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        budgetTreasury.setMaxSyncGas(450_000);
        uint256 budgetKey = uint256(uint160(allocator));
        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, false);
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(childFlow), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, true);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_autoSyncsWithoutManualRequestPayload() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_skipsWhenChildTargetUnavailable_withoutPrevState() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialUnits);

        budgetTreasury.setFlow(address(0xBADC0DE));
        _setParentWeight(reducedWeight);

        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(0), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_TARGET_UNAVAILABLE);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialUnits);
    }

    function test_allocate_withChildSync_skipsWhenChildHasNoCommitment_withoutPrevState() public {
        uint256 initialWeight = 12e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();

        _setParentWeight(initialWeight);

        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(childFlow), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_NO_COMMITMENT);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        _updatePrevStateCacheForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            parentRecipientIds,
            parentBps
        );

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), uint128(0));
    }

    function test_allocate_withChildSync_doesNotRequireManualChildPrevState() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_legacyMalformedPrevStateConceptNoLongerApplies() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_recordsFailedAttemptWhenChildSyncCallFails() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialUnits);

        uint256 budgetKey = uint256(uint160(allocator));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);
        FlowBudgetAutoSyncFailingChildFlow failingChild = new FlowBudgetAutoSyncFailingChildFlow(
            address(budgetStrategy), expectedCommit
        );
        budgetTreasury.setFlow(address(failingChild));

        _setParentWeight(reducedWeight);
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(failingChild), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, false);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialUnits);
    }

    function test_allocate_withChildSync_ignoresManualRequestDuplicationConcept() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_allocate_withChildSync_usesCurrentChildCommitFromStorage() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;
        uint256 secondReducedWeight = 2e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);
        _updatePrevStateCacheForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            parentRecipientIds,
            parentBps
        );

        // Mutate the child commit so the original prevState becomes stale.
        bytes32 secondChildRecipientId = bytes32(uint256(9003));
        vm.prank(manager);
        childFlow.addRecipient(secondChildRecipientId, address(0xBEEF9003), recipientMetadata);

        bytes32[] memory mutatedChildRecipientIds = new bytes32[](2);
        mutatedChildRecipientIds[0] = childRecipientIds[0];
        mutatedChildRecipientIds[1] = secondChildRecipientId;
        uint32[] memory mutatedChildBps = new uint32[](2);
        mutatedChildBps[0] = 500_000;
        mutatedChildBps[1] = 500_000;
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            mutatedChildRecipientIds,
            mutatedChildBps
        );

        _setParentWeight(secondReducedWeight);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(secondReducedWeight, 500_000));
    }

    function test_syncAllocation_autoSyncsWithoutManualRequestPayload() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);
        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_syncAllocation_withChildSync_autoSyncsBudgetChildUnits() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialUnits);

        _setParentWeight(reducedWeight);

        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_syncAllocation_withChildSync_recordsFailedAttemptWhenChildSyncCallFails() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialChildUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        uint256 budgetKey = uint256(uint160(allocator));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);
        FlowBudgetAutoSyncFailingChildFlow failingChild = new FlowBudgetAutoSyncFailingChildFlow(
            address(budgetStrategy), expectedCommit
        );
        budgetTreasury.setFlow(address(failingChild));

        _setParentWeight(reducedWeight);
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(failingChild), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, false);
        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(flow.distributionPool().getUnits(address(childFlow)), _units(reducedWeight, 1_000_000));
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);
    }

    function test_syncAllocation_withChildSync_appliesChildSyncGasStipend() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint256 budgetKey = uint256(uint160(allocator));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);
        FlowBudgetAutoSyncStipendAwareChildFlow stipendAwareChild =
            new FlowBudgetAutoSyncStipendAwareChildFlow(address(budgetStrategy), expectedCommit, 1_100_000);
        budgetTreasury.setFlow(address(stipendAwareChild));

        _setParentWeight(reducedWeight);
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(stipendAwareChild), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, true);
        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(stipendAwareChild.syncCalls(), 1);
    }

    function test_syncAllocation_withChildSync_skipsWhenGasBudgetInsufficient() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialChildUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        uint256 syncCallsBefore = budgetTreasury.syncCalls();
        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, true);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(childFlow), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_GAS_BUDGET);

        vm.prank(other);
        flow.syncAllocation{ gas: 1_500_000 }(address(strategy), parentKey);

        assertEq(budgetTreasury.syncCalls(), syncCallsBefore + 1);
        assertEq(flow.distributionPool().getUnits(address(childFlow)), _units(reducedWeight, 1_000_000));
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);
    }

    function test_syncAllocation_withChildSync_veryLowGas_skipsBudgetSyncAndChildSync() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialChildUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        uint256 syncCallsBefore = budgetTreasury.syncCalls();
        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, false);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(childFlow), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_GAS_BUDGET);

        vm.prank(other);
        flow.syncAllocation{ gas: 1_100_000 }(address(strategy), parentKey);

        assertEq(budgetTreasury.syncCalls(), syncCallsBefore);
        assertEq(flow.distributionPool().getUnits(address(childFlow)), _units(reducedWeight, 1_000_000));
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);
    }

    function test_syncAllocation_withChildSync_lowGasSkip_thenDirectChildSyncReconciles() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialChildUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        _setParentWeight(reducedWeight);

        vm.expectEmit(true, false, false, true, address(ledgerPipeline));
        emit BudgetTreasurySyncAttempted(address(budgetTreasury), address(flow), address(strategy), parentKey, true);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(childFlow), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_GAS_BUDGET);

        vm.prank(other);
        flow.syncAllocation{ gas: 1_500_000 }(address(strategy), parentKey);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        uint256 budgetKey = uint256(uint160(allocator));
        vm.prank(other);
        childFlow.syncAllocation(address(budgetStrategy), budgetKey);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_syncAllocation_withChildSync_childNeedsMoreThanStipend_recordsFailedAttempt() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialChildUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        uint256 budgetKey = uint256(uint160(allocator));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);
        FlowBudgetAutoSyncStipendAwareChildFlow stipendAwareChild =
            new FlowBudgetAutoSyncStipendAwareChildFlow(address(budgetStrategy), expectedCommit, 900_000);
        budgetTreasury.setFlow(address(stipendAwareChild));

        _setParentWeight(reducedWeight);
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(stipendAwareChild), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, false);

        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(flow.distributionPool().getUnits(address(childFlow)), _units(reducedWeight, 1_000_000));
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);
    }

    function test_syncAllocation_withChildSync_twoBudgets_partialProgressWhenGasBudgetTight() public {
        uint256 initialParentWeight = 20e24;
        uint256 updatedParentWeight = 40e24;

        bytes32 secondParentBudgetRecipientId = bytes32(uint256(9003));
        bytes32 secondChildRecipientId = bytes32(uint256(9004));
        address secondChildRecipient = address(0xB002);

        FlowBudgetAutoSyncBudgetTreasury secondBudgetTreasury = new FlowBudgetAutoSyncBudgetTreasury(address(0));
        BudgetStakeStrategy secondBudgetStrategy =
            new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), secondParentBudgetRecipientId);
        CustomFlow secondChildFlow = _deployChildFlow(address(flow), address(secondBudgetStrategy));
        secondBudgetTreasury.setFlow(address(secondChildFlow));

        _addRecipient(secondParentBudgetRecipientId, address(secondChildFlow));
        vm.prank(manager);
        ledger.registerBudget(secondParentBudgetRecipientId, address(secondBudgetTreasury));

        vm.prank(manager);
        secondChildFlow.addRecipient(secondChildRecipientId, secondChildRecipient, recipientMetadata);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        bytes32[] memory parentRecipientIds = new bytes32[](2);
        parentRecipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        parentRecipientIds[1] = secondParentBudgetRecipientId;
        uint32[] memory parentBps = new uint32[](2);
        parentBps[0] = 500_000;
        parentBps[1] = 500_000;

        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();
        (bytes32[] memory secondChildRecipientIds, uint32[] memory secondChildBps) =
            _singleChildAllocationForRecipient(secondChildRecipientId);

        _setParentWeight(initialParentWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(secondBudgetStrategy),
            address(secondChildFlow),
            secondChildRecipientIds,
            secondChildBps
        );

        uint128 initialSecondChildUnits = secondChildFlow.distributionPool().getUnits(secondChildRecipient);

        uint256 firstBudgetKey = uint256(uint160(allocator));
        bytes32 firstExpectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), firstBudgetKey);
        FlowBudgetAutoSyncGasBurningChildFlow gasBurningChild =
            new FlowBudgetAutoSyncGasBurningChildFlow(address(budgetStrategy), firstExpectedCommit, 150_000);
        budgetTreasury.setFlow(address(gasBurningChild));

        _setParentWeight(updatedParentWeight);

        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(gasBurningChild), address(budgetStrategy), firstBudgetKey, address(flow), address(strategy), parentKey, true);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(secondBudgetTreasury), address(secondChildFlow), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_GAS_BUDGET);

        vm.prank(other);
        flow.syncAllocation{ gas: 2_300_000 }(address(strategy), parentKey);

        assertEq(gasBurningChild.syncCalls(), 1);
        assertEq(secondChildFlow.distributionPool().getUnits(secondChildRecipient), initialSecondChildUnits);
    }

    function test_allocateAndSyncAllocation_withChildSync_matchEventAndLedgerState() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);

        uint256 snapshotId = vm.snapshot();
        uint256 childAllocationKey = uint256(uint160(allocator));

        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(childFlow), address(budgetStrategy), childAllocationKey, address(flow), address(strategy), parentKey, true);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        uint256 allocateStake = ledger.userAllocatedStakeOnBudget(allocator, address(budgetTreasury));
        uint256 allocateTotalStake = ledger.budgetTotalAllocatedStake(address(budgetTreasury));
        uint128 allocateUnits = childFlow.distributionPool().getUnits(CHILD_RECIPIENT);
        bytes32 allocateParentCommit = flow.getAllocationCommitment(address(strategy), parentKey);
        bytes32 allocateChildCommit = childFlow.getAllocationCommitment(address(budgetStrategy), childAllocationKey);

        vm.revertTo(snapshotId);

        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(childFlow), address(budgetStrategy), childAllocationKey, address(flow), address(strategy), parentKey, true);
        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(ledger.userAllocatedStakeOnBudget(allocator, address(budgetTreasury)), allocateStake);
        assertEq(ledger.budgetTotalAllocatedStake(address(budgetTreasury)), allocateTotalStake);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), allocateUnits);
        assertEq(flow.getAllocationCommitment(address(strategy), parentKey), allocateParentCommit);
        assertEq(childFlow.getAllocationCommitment(address(budgetStrategy), childAllocationKey), allocateChildCommit);
    }

    function test_clearStaleAllocation_withChildSync_autoSyncsChildWithoutManualRequestPayload() public {
        uint256 initialWeight = 12e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(0);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), parentKey);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), uint128(0));
    }

    function test_clearStaleAllocation_withChildSync_recordsFailedAttemptWhenChildSyncCallFails() public {
        uint256 initialWeight = 12e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialChildUnits = _units(initialWeight, 1_000_000);
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);

        uint256 budgetKey = uint256(uint160(allocator));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);
        FlowBudgetAutoSyncFailingChildFlow failingChild = new FlowBudgetAutoSyncFailingChildFlow(
            address(budgetStrategy), expectedCommit
        );
        budgetTreasury.setFlow(address(failingChild));

        _setParentWeight(0);
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(failingChild), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, false);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), parentKey);

        assertEq(flow.distributionPool().getUnits(address(childFlow)), uint128(0));
        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialChildUnits);
    }

    function test_clearStaleAllocation_withUnresolvedTarget_skips() public {
        uint256 initialWeight = 12e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(flow.distributionPool().getUnits(address(childFlow)), initialUnits);

        FlowBudgetAutoSyncAllocationKeyRevertingStrategy badStrategy = new FlowBudgetAutoSyncAllocationKeyRevertingStrategy();
        CustomFlow badChildFlow = _deployChildFlow(address(flow), address(badStrategy));
        budgetTreasury.setFlow(address(badChildFlow));

        _setParentWeight(0);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(0), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_TARGET_UNAVAILABLE);
        vm.prank(other);
        flow.clearStaleAllocation(address(strategy), parentKey);

        assertEq(flow.distributionPool().getUnits(address(childFlow)), uint128(0));
    }

    function test_allocate_withChildSync_autoSyncsGoalStakeVaultChildUnitsOnParentWeightDecrease() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        GoalStakeVaultStrategy goalStrategy = new GoalStakeVaultStrategy(IGoalStakeVault(address(stakeVault)));
        CustomFlow goalChildFlow = _deployChildFlow(address(flow), address(goalStrategy));
        FlowBudgetAutoSyncBudgetTreasury goalBudgetTreasury =
            new FlowBudgetAutoSyncBudgetTreasury(address(goalChildFlow));

        _addRecipient(GOAL_PARENT_BUDGET_RECIPIENT_ID, address(goalChildFlow));
        vm.prank(manager);
        ledger.registerBudget(GOAL_PARENT_BUDGET_RECIPIENT_ID, address(goalBudgetTreasury));

        vm.prank(manager);
        goalChildFlow.addRecipient(GOAL_CHILD_RECIPIENT_ID, GOAL_CHILD_RECIPIENT, recipientMetadata);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) =
            _singleParentAllocationForRecipient(GOAL_PARENT_BUDGET_RECIPIENT_ID);
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) =
            _singleChildAllocationForRecipient(GOAL_CHILD_RECIPIENT_ID);

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(goalStrategy),
            address(goalChildFlow),
            childRecipientIds,
            childBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(goalChildFlow.distributionPool().getUnits(GOAL_CHILD_RECIPIENT), initialUnits);

        uint256 goalKey = goalStrategy.allocationKey(allocator, bytes(""));
        assertEq(goalKey, uint256(uint160(allocator)));

        _setParentWeight(reducedWeight);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        _updatePrevStateCacheForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            parentRecipientIds,
            parentBps
        );

        assertEq(
            goalChildFlow.distributionPool().getUnits(GOAL_CHILD_RECIPIENT),
            _units(reducedWeight, 1_000_000)
        );
    }

    function test_previewChildSyncRequirements_usesGoalStakeVaultStrategyAllocationKey() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        GoalStakeVaultStrategy goalStrategy = new GoalStakeVaultStrategy(IGoalStakeVault(address(stakeVault)));
        CustomFlow goalChildFlow = _deployChildFlow(address(flow), address(goalStrategy));
        FlowBudgetAutoSyncBudgetTreasury goalBudgetTreasury =
            new FlowBudgetAutoSyncBudgetTreasury(address(goalChildFlow));

        _addRecipient(GOAL_PARENT_BUDGET_RECIPIENT_ID, address(goalChildFlow));
        vm.prank(manager);
        ledger.registerBudget(GOAL_PARENT_BUDGET_RECIPIENT_ID, address(goalBudgetTreasury));

        vm.prank(manager);
        goalChildFlow.addRecipient(GOAL_CHILD_RECIPIENT_ID, GOAL_CHILD_RECIPIENT, recipientMetadata);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) =
            _singleParentAllocationForRecipient(GOAL_PARENT_BUDGET_RECIPIENT_ID);
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) =
            _singleChildAllocationForRecipient(GOAL_CHILD_RECIPIENT_ID);

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(goalStrategy),
            address(goalChildFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);

        ICustomFlow.ChildSyncRequirement[] memory reqs = flow.previewChildSyncRequirements(
            address(strategy),
            parentKey,
            parentRecipientIds,
            parentBps
        );

        uint256 goalKey = goalStrategy.allocationKey(allocator, bytes(""));
        bytes32 expectedCommit = goalChildFlow.getAllocationCommitment(address(goalStrategy), goalKey);

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(goalBudgetTreasury));
        assertEq(reqs[0].childFlow, address(goalChildFlow));
        assertEq(reqs[0].childStrategy, address(goalStrategy));
        assertEq(reqs[0].allocationKey, goalKey);
        assertEq(reqs[0].expectedCommit, expectedCommit);
    }

    function test_allocate_withChildSync_usesStrategyDerivedAllocationKey() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        FlowBudgetAutoSyncDerivedKeyStrategy derivedStrategy = new FlowBudgetAutoSyncDerivedKeyStrategy();
        CustomFlow derivedChildFlow = _deployChildFlow(address(flow), address(derivedStrategy));
        FlowBudgetAutoSyncBudgetTreasury derivedBudgetTreasury =
            new FlowBudgetAutoSyncBudgetTreasury(address(derivedChildFlow));

        _addRecipient(DERIVED_PARENT_BUDGET_RECIPIENT_ID, address(derivedChildFlow));
        vm.prank(manager);
        ledger.registerBudget(DERIVED_PARENT_BUDGET_RECIPIENT_ID, address(derivedBudgetTreasury));

        vm.prank(manager);
        derivedChildFlow.addRecipient(DERIVED_CHILD_RECIPIENT_ID, DERIVED_CHILD_RECIPIENT, recipientMetadata);

        derivedStrategy.setWeightForAccount(allocator, initialWeight);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) =
            _singleParentAllocationForRecipient(DERIVED_PARENT_BUDGET_RECIPIENT_ID);
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) =
            _singleChildAllocationForRecipient(DERIVED_CHILD_RECIPIENT_ID);

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(derivedStrategy),
            address(derivedChildFlow),
            childRecipientIds,
            childBps
        );

        uint256 derivedKey = derivedStrategy.allocationKey(allocator, bytes(""));
        assertTrue(derivedKey != uint256(uint160(allocator)));
        assertTrue(derivedChildFlow.getAllocationCommitment(address(derivedStrategy), derivedKey) != bytes32(0));
        assertEq(derivedChildFlow.getAllocationCommitment(address(derivedStrategy), uint256(uint160(allocator))), bytes32(0));

        derivedStrategy.setWeightForAccount(allocator, reducedWeight);
        _setParentWeight(reducedWeight);

        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(
            derivedChildFlow.distributionPool().getUnits(DERIVED_CHILD_RECIPIENT),
            _units(reducedWeight, 1_000_000)
        );
    }

    function test_previewChildSyncRequirements_returnsRequiredBudgetTarget() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);

        ICustomFlow.ChildSyncRequirement[] memory reqs = flow.previewChildSyncRequirements(
            address(strategy),
            parentKey,
            parentRecipientIds,
            parentBps
        );

        uint256 budgetKey = budgetStrategy.allocationKey(allocator, bytes(""));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(budgetTreasury));
        assertEq(reqs[0].childFlow, address(childFlow));
        assertEq(reqs[0].childStrategy, address(budgetStrategy));
        assertEq(reqs[0].allocationKey, budgetKey);
        assertEq(reqs[0].expectedCommit, expectedCommit);
    }

    function test_previewChildSyncRequirements_returnsEmptyWhenChildCommitMissing() public {
        uint256 initialWeight = 12e24;

        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();

        _setParentWeight(initialWeight);

        ICustomFlow.ChildSyncRequirement[] memory reqs = flow.previewChildSyncRequirements(
            address(strategy),
            parentKey,
            parentRecipientIds,
            parentBps
        );

        assertEq(reqs.length, 0);
    }

    function test_previewChildSyncRequirements_noCommit_withStoredSnapshot_revertsInvalidPrevAllocation() public {
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        _setParentWeight(12e24);

        TestableCustomFlow(address(flow)).setAllocSnapshotPackedForTest(
            address(strategy), parentKey, STALE_SINGLE_RECIPIENT_SNAPSHOT
        );
        assertEq(flow.getAllocationCommitment(address(strategy), parentKey), bytes32(0));

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        flow.previewChildSyncRequirements(address(strategy), parentKey, parentRecipientIds, parentBps);
    }

    function test_previewChildSyncRequirements_revertsWhenChildTargetUnavailable() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        budgetTreasury.setFlow(address(0xBADC0DE));
        _setParentWeight(reducedWeight);

        vm.expectRevert(
            abi.encodeWithSelector(GoalFlowLedgerMode.CHILD_SYNC_TARGET_UNAVAILABLE.selector, address(budgetTreasury))
        );
        flow.previewChildSyncRequirements(address(strategy), parentKey, parentRecipientIds, parentBps);
    }

    function test_previewChildSyncRequirements_usesCanonicalPrevStateWhenCommitExists() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );

        _setParentWeight(reducedWeight);

        ICustomFlow.ChildSyncRequirement[] memory reqs = flow.previewChildSyncRequirements(
            address(strategy),
            parentKey,
            parentRecipientIds,
            parentBps
        );
        uint256 budgetKey = budgetStrategy.allocationKey(allocator, bytes(""));
        bytes32 expectedCommit = childFlow.getAllocationCommitment(address(budgetStrategy), budgetKey);

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(budgetTreasury));
        assertEq(reqs[0].childFlow, address(childFlow));
        assertEq(reqs[0].childStrategy, address(budgetStrategy));
        assertEq(reqs[0].allocationKey, budgetKey);
        assertEq(reqs[0].expectedCommit, expectedCommit);
    }

    function test_previewChildSyncRequirements_usesStrategyDerivedAllocationKey() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        FlowBudgetAutoSyncDerivedKeyStrategy derivedStrategy = new FlowBudgetAutoSyncDerivedKeyStrategy();
        CustomFlow derivedChildFlow = _deployChildFlow(address(flow), address(derivedStrategy));
        FlowBudgetAutoSyncBudgetTreasury derivedBudgetTreasury =
            new FlowBudgetAutoSyncBudgetTreasury(address(derivedChildFlow));

        _addRecipient(DERIVED_PARENT_BUDGET_RECIPIENT_ID, address(derivedChildFlow));
        vm.prank(manager);
        ledger.registerBudget(DERIVED_PARENT_BUDGET_RECIPIENT_ID, address(derivedBudgetTreasury));

        vm.prank(manager);
        derivedChildFlow.addRecipient(DERIVED_CHILD_RECIPIENT_ID, DERIVED_CHILD_RECIPIENT, recipientMetadata);

        derivedStrategy.setWeightForAccount(allocator, initialWeight);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) =
            _singleParentAllocationForRecipient(DERIVED_PARENT_BUDGET_RECIPIENT_ID);
        (bytes32[] memory childRecipientIds, uint32[] memory childBps) =
            _singleChildAllocationForRecipient(DERIVED_CHILD_RECIPIENT_ID);

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(derivedStrategy),
            address(derivedChildFlow),
            childRecipientIds,
            childBps
        );

        uint256 derivedKey = derivedStrategy.allocationKey(allocator, bytes(""));
        bytes32 expectedCommit = derivedChildFlow.getAllocationCommitment(address(derivedStrategy), derivedKey);

        derivedStrategy.setWeightForAccount(allocator, reducedWeight);
        _setParentWeight(reducedWeight);

        ICustomFlow.ChildSyncRequirement[] memory reqs = flow.previewChildSyncRequirements(
            address(strategy),
            parentKey,
            parentRecipientIds,
            parentBps
        );

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(derivedBudgetTreasury));
        assertEq(reqs[0].childFlow, address(derivedChildFlow));
        assertEq(reqs[0].childStrategy, address(derivedStrategy));
        assertEq(reqs[0].allocationKey, derivedKey);
        assertEq(reqs[0].expectedCommit, expectedCommit);
    }

    function test_allocate_withChildSync_skipsWhenChildStrategyAllocationKeyReverts_withoutPrevState() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );

        uint128 initialUnits = _units(initialWeight, 1_000_000);
        assertEq(flow.distributionPool().getUnits(address(childFlow)), initialUnits);

        FlowBudgetAutoSyncAllocationKeyRevertingStrategy badStrategy = new FlowBudgetAutoSyncAllocationKeyRevertingStrategy();
        CustomFlow badChildFlow = _deployChildFlow(address(flow), address(badStrategy));
        budgetTreasury.setFlow(address(badChildFlow));

        _setParentWeight(reducedWeight);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(0), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_TARGET_UNAVAILABLE);
        vm.prank(allocator);
        flow.allocate(parentRecipientIds, parentBps);

        assertEq(flow.distributionPool().getUnits(address(childFlow)), _units(reducedWeight, 1_000_000));
    }

    function test_syncAllocation_withUnresolvedTarget_skips() public {
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        (bytes32[] memory parentRecipientIds, uint32[] memory parentBps) = _singleParentAllocation();

        _setParentWeight(initialWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );

        FlowBudgetAutoSyncAllocationKeyRevertingStrategy badStrategy = new FlowBudgetAutoSyncAllocationKeyRevertingStrategy();
        CustomFlow badChildFlow = _deployChildFlow(address(flow), address(badStrategy));
        budgetTreasury.setFlow(address(badChildFlow));

        _setParentWeight(reducedWeight);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(budgetTreasury), address(0), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_TARGET_UNAVAILABLE);
        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(flow.distributionPool().getUnits(address(childFlow)), _units(reducedWeight, 1_000_000));
    }

    function test_syncAllocation_withMixedChangedBudgets_skipsUnavailableTargetAndContinues() public {
        uint256 initialParentWeight = 20e24;
        uint256 updatedParentWeight = 40e24;

        bytes32 secondParentBudgetRecipientId = bytes32(uint256(9003));
        bytes32 secondChildRecipientId = bytes32(uint256(9004));
        address secondChildRecipient = address(0xB002);

        FlowBudgetAutoSyncBudgetTreasury secondBudgetTreasury = new FlowBudgetAutoSyncBudgetTreasury(address(0));
        BudgetStakeStrategy secondBudgetStrategy =
            new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), secondParentBudgetRecipientId);
        CustomFlow secondChildFlow = _deployChildFlow(address(flow), address(secondBudgetStrategy));
        secondBudgetTreasury.setFlow(address(secondChildFlow));

        _addRecipient(secondParentBudgetRecipientId, address(secondChildFlow));
        vm.prank(manager);
        ledger.registerBudget(secondParentBudgetRecipientId, address(secondBudgetTreasury));

        vm.prank(manager);
        secondChildFlow.addRecipient(secondChildRecipientId, secondChildRecipient, recipientMetadata);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        bytes32[] memory parentRecipientIds = new bytes32[](2);
        parentRecipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        parentRecipientIds[1] = secondParentBudgetRecipientId;
        uint32[] memory parentBps = new uint32[](2);
        parentBps[0] = 500_000;
        parentBps[1] = 500_000;

        (bytes32[] memory childRecipientIds, uint32[] memory childBps) = _singleChildAllocation();
        (bytes32[] memory secondChildRecipientIds, uint32[] memory secondChildBps) =
            _singleChildAllocationForRecipient(secondChildRecipientId);

        _setParentWeight(initialParentWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            parentRecipientIds,
            parentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            childRecipientIds,
            childBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(secondBudgetStrategy),
            address(secondChildFlow),
            secondChildRecipientIds,
            secondChildBps
        );

        uint128 initialSecondaryChildUnits = secondChildFlow.distributionPool().getUnits(secondChildRecipient);

        FlowBudgetAutoSyncAllocationKeyRevertingStrategy badStrategy = new FlowBudgetAutoSyncAllocationKeyRevertingStrategy();
        CustomFlow badChildFlow = _deployChildFlow(address(flow), address(badStrategy));
        secondBudgetTreasury.setFlow(address(badChildFlow));

        _setParentWeight(updatedParentWeight);
        uint256 budgetKey = uint256(uint160(allocator));
        vm.expectEmit(true, true, true, true, address(ledgerPipeline));
        emit ChildAllocationSyncAttempted(address(budgetTreasury), address(childFlow), address(budgetStrategy), budgetKey, address(flow), address(strategy), parentKey, true);
        vm.expectEmit(true, true, false, true, address(ledgerPipeline));
        emit ChildAllocationSyncSkipped(address(secondBudgetTreasury), address(0), address(flow), address(strategy), parentKey, CHILD_SYNC_SKIP_TARGET_UNAVAILABLE);
        vm.prank(other);
        flow.syncAllocation(address(strategy), parentKey);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), _units(updatedParentWeight, 500_000));
        assertEq(secondChildFlow.distributionPool().getUnits(secondChildRecipient), initialSecondaryChildUnits);
    }

    function test_previewChildSyncRequirements_roundTripWithTwoBudgetChildren_usesActualPrevStateAndSyncsChangedBudgetOnly()
        public
    {
        uint256 initialParentWeight = 20e24;
        uint256 updatedParentWeight = 40e24;
        uint256 unchangedAllocatedStake = 10e24;
        uint256 changedAllocatedStake = 30e24;

        bytes32 secondParentBudgetRecipientId = bytes32(uint256(9003));
        bytes32 secondChildRecipientId = bytes32(uint256(9004));
        address secondChildRecipient = address(0xB002);

        FlowBudgetAutoSyncBudgetTreasury secondBudgetTreasury = new FlowBudgetAutoSyncBudgetTreasury(address(0));
        BudgetStakeStrategy secondBudgetStrategy =
            new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), secondParentBudgetRecipientId);
        CustomFlow secondChildFlow = _deployChildFlow(address(flow), address(secondBudgetStrategy));
        secondBudgetTreasury.setFlow(address(secondChildFlow));

        _addRecipient(secondParentBudgetRecipientId, address(secondChildFlow));
        vm.prank(manager);
        ledger.registerBudget(secondParentBudgetRecipientId, address(secondBudgetTreasury));

        vm.prank(manager);
        secondChildFlow.addRecipient(secondChildRecipientId, secondChildRecipient, recipientMetadata);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);

        bytes32[] memory initialParentRecipientIds = new bytes32[](2);
        initialParentRecipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        initialParentRecipientIds[1] = secondParentBudgetRecipientId;
        uint32[] memory initialParentBps = new uint32[](2);
        initialParentBps[0] = 500_000;
        initialParentBps[1] = 500_000;

        bytes32[] memory updatedParentRecipientIds = new bytes32[](2);
        updatedParentRecipientIds[0] = PARENT_BUDGET_RECIPIENT_ID;
        updatedParentRecipientIds[1] = secondParentBudgetRecipientId;
        uint32[] memory updatedParentBps = new uint32[](2);
        updatedParentBps[0] = 250_000;
        updatedParentBps[1] = 750_000;

        (bytes32[] memory firstChildRecipientIds, uint32[] memory firstChildBps) = _singleChildAllocation();
        (bytes32[] memory secondChildRecipientIds, uint32[] memory secondChildBps) =
            _singleChildAllocationForRecipient(secondChildRecipientId);

        _setParentWeight(initialParentWeight);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(flow),
            initialParentRecipientIds,
            initialParentBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(budgetStrategy),
            address(childFlow),
            firstChildRecipientIds,
            firstChildBps
        );
        _allocateWithPrevStateForStrategy(
            allocator,
            _emptyAllocationData(),
            address(secondBudgetStrategy),
            address(secondChildFlow),
            secondChildRecipientIds,
            secondChildBps
        );

        uint256 secondBudgetKey = secondBudgetStrategy.allocationKey(allocator, bytes(""));
        bytes32 firstExpectedCommit = childFlow.getAllocationCommitment(
            address(budgetStrategy), budgetStrategy.allocationKey(allocator, bytes(""))
        );
        bytes32 secondExpectedCommit =
            secondChildFlow.getAllocationCommitment(address(secondBudgetStrategy), secondBudgetKey);
        assertTrue(firstExpectedCommit != bytes32(0));
        assertTrue(secondExpectedCommit != bytes32(0));

        uint128 initialFirstUnits = childFlow.distributionPool().getUnits(CHILD_RECIPIENT);
        uint128 initialSecondUnits = secondChildFlow.distributionPool().getUnits(secondChildRecipient);
        assertEq(initialFirstUnits, _units(unchangedAllocatedStake, 1_000_000));
        assertEq(initialSecondUnits, _units(unchangedAllocatedStake, 1_000_000));

        _setParentWeight(updatedParentWeight);

        ICustomFlow.ChildSyncRequirement[] memory reqs = flow.previewChildSyncRequirements(
            address(strategy),
            parentKey,
            updatedParentRecipientIds,
            updatedParentBps
        );

        assertEq(reqs.length, 1);
        assertEq(reqs[0].budgetTreasury, address(secondBudgetTreasury));
        assertEq(reqs[0].childFlow, address(secondChildFlow));
        assertEq(reqs[0].childStrategy, address(secondBudgetStrategy));
        assertEq(reqs[0].allocationKey, secondBudgetKey);
        assertEq(reqs[0].expectedCommit, secondExpectedCommit);
        assertTrue(reqs[0].expectedCommit != bytes32(0));

        vm.prank(allocator);
        flow.allocate(updatedParentRecipientIds, updatedParentBps);

        assertEq(childFlow.distributionPool().getUnits(CHILD_RECIPIENT), initialFirstUnits);
        assertEq(
            secondChildFlow.distributionPool().getUnits(secondChildRecipient),
            _units(changedAllocatedStake, 1_000_000)
        );
    }

    function _setParentWeight(uint256 weight) internal {
        stakeVault.setWeight(allocator, weight);
        strategy.setWeight(parentKey, weight);
    }

    function _singleParentAllocation() internal pure returns (bytes32[] memory recipientIds, uint32[] memory scaled) {
        return _singleParentAllocationForRecipient(PARENT_BUDGET_RECIPIENT_ID);
    }

    function _singleChildAllocation() internal pure returns (bytes32[] memory recipientIds, uint32[] memory scaled) {
        return _singleChildAllocationForRecipient(CHILD_RECIPIENT_ID);
    }

    function _singleParentAllocationForRecipient(
        bytes32 recipientId
    ) internal pure returns (bytes32[] memory recipientIds, uint32[] memory scaled) {
        recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        scaled = new uint32[](1);
        scaled[0] = 1_000_000;
    }

    function _singleChildAllocationForRecipient(
        bytes32 recipientId
    ) internal pure returns (bytes32[] memory recipientIds, uint32[] memory scaled) {
        recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        scaled = new uint32[](1);
        scaled[0] = 1_000_000;
    }

    function _emptyAllocationData() internal pure returns (bytes[][] memory data) {
        data = new bytes[][](1);
        data[0] = new bytes[](1);
        data[0][0] = "";
    }

    function _bytesRange(uint256 length) internal pure returns (bytes memory data) {
        data = new bytes(length);
        for (uint256 i = 0; i < length; ) {
            data[i] = bytes1(uint8(i + 1));
            unchecked {
                ++i;
            }
        }
    }

    function _slicePrefix(bytes memory data, uint256 length) internal pure returns (bytes memory prefix) {
        prefix = new bytes(length);
        for (uint256 i = 0; i < length; ) {
            prefix[i] = data[i];
            unchecked {
                ++i;
            }
        }
    }

    function _deployChildFlow(address parentFlow, address childStrategy) internal returns (CustomFlow deployed) {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(childStrategy);

        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            parentFlow,
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        deployed = CustomFlow(proxy);
        vm.prank(owner);
        superToken.transfer(address(deployed), 500_000e18);
    }
}

contract FlowBudgetAutoSyncStakeVault {
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

contract FlowBudgetAutoSyncGoalTreasury {
    address public flow;
    address public stakeVault;

    constructor(address flow_, address stakeVault_) {
        flow = flow_;
        stakeVault = stakeVault_;
    }
}

contract FlowBudgetAutoSyncBudgetTreasury {
    address public flow;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Active;
    bool public resolved;
    uint64 public resolvedAt;
    uint64 public fundingDeadline = type(uint64).max;
    uint64 public executionDuration = 10;
    uint256 public syncCalls;
    bool public syncShouldRevert;
    bytes internal _syncRevertData;
    uint256 public maxSyncGas = type(uint256).max;

    constructor(address flow_) {
        flow = flow_;
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setResolved(bool resolved_, uint64 resolvedAt_) external {
        resolved = resolved_;
        resolvedAt = resolvedAt_;
    }

    function setSyncShouldRevert(bool shouldRevert) external {
        syncShouldRevert = shouldRevert;
    }

    function setSyncRevertData(bytes calldata revertData_) external {
        _syncRevertData = revertData_;
    }

    function setMaxSyncGas(uint256 maxSyncGas_) external {
        maxSyncGas = maxSyncGas_;
    }

    function sync() external {
        bytes memory revertData = _syncRevertData;
        if (revertData.length != 0) {
            assembly ("memory-safe") {
                revert(add(revertData, 0x20), mload(revertData))
            }
        }
        if (gasleft() > maxSyncGas) revert("SYNC_GAS_TOO_HIGH");
        if (syncShouldRevert) revert("SYNC_REVERT");
        unchecked {
            ++syncCalls;
        }
    }
}

contract FlowBudgetAutoSyncFailingChildFlow {
    IAllocationStrategy[] internal _strategies;
    bytes32 internal _commit;

    constructor(address strategy, bytes32 commit_) {
        _strategies = new IAllocationStrategy[](1);
        _strategies[0] = IAllocationStrategy(strategy);
        _commit = commit_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory) {
        return _strategies;
    }

    function getAllocationCommitment(address, uint256) external view returns (bytes32) {
        return _commit;
    }

    function syncAllocation(address, uint256) external pure {
        revert("SYNC_FAIL");
    }
}

contract FlowBudgetAutoSyncStipendAwareChildFlow {
    IAllocationStrategy[] internal _strategies;
    bytes32 internal _commit;
    uint256 internal _maxSyncGas;
    uint256 public syncCalls;

    constructor(address strategy, bytes32 commit_, uint256 maxSyncGas_) {
        _strategies = new IAllocationStrategy[](1);
        _strategies[0] = IAllocationStrategy(strategy);
        _commit = commit_;
        _maxSyncGas = maxSyncGas_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory) {
        return _strategies;
    }

    function getAllocationCommitment(address, uint256) external view returns (bytes32) {
        return _commit;
    }

    function syncAllocation(address, uint256) external {
        if (gasleft() > _maxSyncGas) revert("SYNC_GAS_TOO_HIGH");
        unchecked {
            ++syncCalls;
        }
    }
}

contract FlowBudgetAutoSyncGasBurningChildFlow {
    IAllocationStrategy[] internal _strategies;
    bytes32 internal _commit;
    uint256 internal _gasToLeave;
    uint256 public syncCalls;

    constructor(address strategy, bytes32 commit_, uint256 gasToLeave_) {
        _strategies = new IAllocationStrategy[](1);
        _strategies[0] = IAllocationStrategy(strategy);
        _commit = commit_;
        _gasToLeave = gasToLeave_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory) {
        return _strategies;
    }

    function getAllocationCommitment(address, uint256) external view returns (bytes32) {
        return _commit;
    }

    function syncAllocation(address, uint256) external {
        uint256 spins;
        while (gasleft() > _gasToLeave) {
            unchecked {
                ++spins;
            }
        }
        if (spins == 0) revert("NO_GAS_BURN");
        unchecked {
            ++syncCalls;
        }
    }
}

contract FlowBudgetAutoSyncDerivedKeyStrategy is IAllocationStrategy {
    uint256 internal constant KEY_OFFSET = 7;
    mapping(address => uint256) internal _weightByAccount;

    function setWeightForAccount(address account, uint256 weight) external {
        _weightByAccount[account] = weight;
    }

    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller)) + KEY_OFFSET;
    }

    function accountForAllocationKey(uint256 key) external pure returns (address) {
        if (key <= KEY_OFFSET) return address(0);
        return address(uint160(key - KEY_OFFSET));
    }

    function currentWeight(uint256 key) external view returns (uint256) {
        if (key <= KEY_OFFSET) return 0;
        return _weightByAccount[address(uint160(key - KEY_OFFSET))];
    }

    function canAllocate(uint256 key, address caller) external view returns (bool) {
        if (key <= KEY_OFFSET) return false;
        return caller == address(uint160(key - KEY_OFFSET));
    }

    function canAccountAllocate(address account) external view returns (bool) {
        return _weightByAccount[account] > 0;
    }

    function accountAllocationWeight(address account) external view returns (uint256) {
        return _weightByAccount[account];
    }

    function strategyKey() external pure returns (string memory) {
        return "DerivedKey";
    }
}

contract FlowBudgetAutoSyncAllocationKeyRevertingStrategy is IAllocationStrategy {
    function allocationKey(address, bytes calldata) external pure returns (uint256) {
        revert("ALLOCATION_KEY_REVERT");
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
        return "BadKey";
    }
}
