// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

contract BudgetStakeLedgerCoverageCutoverTest is Test {
    bytes32 internal constant RECIPIENT = bytes32(uint256(1));
    bytes32 internal constant SECOND_RECIPIENT = bytes32(uint256(2));
    bytes32 internal constant THIRD_RECIPIENT = bytes32(uint256(3));
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant PIPELINE = address(0xCAFE);
    uint32 internal constant FULL_ALLOCATION_PPM = FlowProtocolConstants.PPM_SCALE;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    BudgetStakeLedgerCoverageManager internal manager;
    BudgetStakeLedgerCoverageGoalFlow internal goalFlow;
    BudgetStakeLedgerCoverageGoalTreasury internal goalTreasury;
    BudgetStakeLedgerCoverageBudgetFlow internal budgetFlow;
    BudgetStakeLedgerCoverageBudgetTreasury internal budget;
    BudgetStakeLedgerCoverageStrategy internal strategy;
    BudgetStakeLedger internal ledger;

    function setUp() public {
        manager = new BudgetStakeLedgerCoverageManager();
        goalFlow = new BudgetStakeLedgerCoverageGoalFlow(address(manager), PIPELINE);
        goalTreasury = new BudgetStakeLedgerCoverageGoalTreasury(address(goalFlow));
        ledger = new BudgetStakeLedger(address(goalTreasury));

        strategy = new BudgetStakeLedgerCoverageStrategy();
        budgetFlow = new BudgetStakeLedgerCoverageBudgetFlow(address(goalFlow));
        address[] memory childStrategies = new address[](1);
        childStrategies[0] = address(strategy);
        budgetFlow.setStrategies(childStrategies);
        budget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(RECIPIENT, address(budget), address(budgetFlow), address(strategy), true);
        vm.prank(address(manager));
        ledger.registerBudget(RECIPIENT, address(budget));
    }

    function test_clone_initialize_setsGoalTreasuryOnce_andRejectsReinitialize() public {
        BudgetStakeLedger implementation = new BudgetStakeLedger(address(goalTreasury));
        BudgetStakeLedger clone = BudgetStakeLedger(Clones.clone(address(implementation)));

        assertEq(clone.goalTreasury(), address(0));
        clone.initialize(address(goalTreasury));
        assertEq(clone.goalTreasury(), address(goalTreasury));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(0xBEEF));
    }

    function test_clone_initialize_zeroAddressRevert_doesNotConsumeInitializerSlot() public {
        BudgetStakeLedger implementation = new BudgetStakeLedger(address(goalTreasury));
        BudgetStakeLedger clone = BudgetStakeLedger(Clones.clone(address(implementation)));

        vm.expectRevert(IBudgetStakeLedger.ADDRESS_ZERO.selector);
        clone.initialize(address(0));

        clone.initialize(address(goalTreasury));
        assertEq(clone.goalTreasury(), address(goalTreasury));
    }

    function test_constructor_revertsWhenGoalTreasuryIsZero() public {
        vm.expectRevert(IBudgetStakeLedger.ADDRESS_ZERO.selector);
        new BudgetStakeLedger(address(0));
    }

    function test_checkpointAllocation_updatesCoverageOnlyStakeAccounting() public {
        _checkpointSingle(ACCOUNT, 0, 12 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 12 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 12 * UNIT_WEIGHT_SCALE);

        _checkpointSingle(ACCOUNT, 12 * UNIT_WEIGHT_SCALE, 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 4 * UNIT_WEIGHT_SCALE);

        IBudgetStakeLedger.TrackedBudgetSummary[] memory summaries = ledger.trackedBudgetSlice(0, 1);
        assertEq(summaries.length, 1);
        assertEq(summaries[0].budget, address(budget));
        assertEq(summaries[0].totalAllocatedStake, 4 * UNIT_WEIGHT_SCALE);
        assertEq(summaries[0].resolvedOrRemovedAt, 0);
    }

    function test_removeBudget_marksTerminalRemovalAndUntracksBudget() public {
        budget.setResolvedAt(80);

        uint64 removedAt = uint64(block.timestamp + 100);
        vm.warp(removedAt);
        vm.prank(address(manager));
        ledger.removeBudget(RECIPIENT);

        assertEq(ledger.trackedBudgetCount(), 0);
        assertEq(ledger.budgetForRecipient(RECIPIENT), address(0));

        IBudgetStakeLedger.BudgetInfoView memory info = ledger.budgetInfo(address(budget));
        assertFalse(info.isTracked);
        assertEq(info.removedAt, removedAt);
        assertEq(info.resolvedOrRemovedAt, 80);
    }

    function test_registerBudget_clearsRemovedAtOnReRegistration() public {
        uint64 removedAt = uint64(block.timestamp + 100);
        vm.warp(removedAt);
        vm.prank(address(manager));
        ledger.removeBudget(RECIPIENT);

        IBudgetStakeLedger.BudgetInfoView memory removedInfo = ledger.budgetInfo(address(budget));
        assertEq(removedInfo.removedAt, removedAt);
        assertEq(removedInfo.resolvedOrRemovedAt, removedAt);

        _registerBudget(SECOND_RECIPIENT, address(budget));

        IBudgetStakeLedger.BudgetInfoView memory reregisteredInfo = ledger.budgetInfo(address(budget));
        assertTrue(reregisteredInfo.isTracked);
        assertEq(reregisteredInfo.removedAt, 0);
        assertEq(reregisteredInfo.resolvedOrRemovedAt, 0);
        assertFalse(ledger.allTrackedBudgetsResolved());
    }

    function test_registeredBudgetEnumeration_retainsRemovedBudgets() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        _registerBudget(SECOND_RECIPIENT, address(secondBudget));

        vm.prank(address(manager));
        ledger.removeBudget(SECOND_RECIPIENT);

        assertEq(ledger.trackedBudgetCount(), 1);
        assertEq(ledger.registeredBudgetCount(), 2);
        assertEq(ledger.registeredBudgetAt(0), address(budget));
        assertEq(ledger.registeredBudgetAt(1), address(secondBudget));
    }

    function test_registeredBudgetEnumeration_duplicateRegistrationDoesNotAppend() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.startPrank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        vm.stopPrank();

        assertEq(ledger.trackedBudgetCount(), 2);
        assertEq(ledger.registeredBudgetCount(), 2);
        assertEq(ledger.registeredBudgetAt(0), address(budget));
        assertEq(ledger.registeredBudgetAt(1), address(secondBudget));
    }

    function test_allTrackedBudgetsResolved_ignoresRemovedBudgetsAndRequiresActiveTrackedResolved() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        _registerBudget(SECOND_RECIPIENT, address(secondBudget));

        assertFalse(ledger.allTrackedBudgetsResolved());

        budget.setResolvedAt(10);
        assertFalse(ledger.allTrackedBudgetsResolved());

        vm.warp(block.timestamp + 20);
        vm.prank(address(manager));
        ledger.removeBudget(SECOND_RECIPIENT);

        assertTrue(ledger.allTrackedBudgetsResolved());
    }

    function test_registerBudget_afterHistoricalUntrackedAllocation_bootstrapPreventsAllocationDriftDeadlock() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        // Simulate historical allocation while recipient is still unregistered in ledger.
        _checkpointSingleForRecipient(ACCOUNT, SECOND_RECIPIENT, 0, 10 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), 0);

        _registerBudget(SECOND_RECIPIENT, address(secondBudget));

        // Bootstrap tracked accounting from zero, then deallocation should remain drift-free.
        _checkpointSingleForRecipient(ACCOUNT, SECOND_RECIPIENT, 0, 10 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget)), 10 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), 10 * UNIT_WEIGHT_SCALE);

        _checkpointSingleForRecipient(ACCOUNT, SECOND_RECIPIENT, 10 * UNIT_WEIGHT_SCALE, 0);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), 0);
    }

    function test_registerBudget_afterHistoricalUntrackedAllocation_withoutBootstrapRevertsAllocationDrift() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        _checkpointSingleForRecipient(ACCOUNT, SECOND_RECIPIENT, 0, 10 * UNIT_WEIGHT_SCALE);

        _registerBudget(SECOND_RECIPIENT, address(secondBudget));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = SECOND_RECIPIENT;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.ALLOCATION_DRIFT.selector,
                ACCOUNT,
                address(secondBudget),
                0,
                10 * UNIT_WEIGHT_SCALE
            )
        );
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            10 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm,
            8 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm
        );

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), 0);
    }

    function test_checkpointAllocation_noopsAfterGoalResolved() public {
        goalTreasury.setResolved(true);

        _checkpointSingle(ACCOUNT, 0, 9 * UNIT_WEIGHT_SCALE);

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);
    }

    function test_registerBudget_revertsWhenGoalTerminal() public {
        assertEq(ledger.trackedBudgetCount(), 1);
        assertEq(ledger.registeredBudgetCount(), 1);

        goalTreasury.setResolved(true);
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(IBudgetStakeLedger.GOAL_TERMINAL.selector);
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));

        assertEq(ledger.trackedBudgetCount(), 1);
        assertEq(ledger.registeredBudgetCount(), 1);
        assertEq(ledger.budgetForRecipient(RECIPIENT), address(budget));
        assertEq(ledger.budgetForRecipient(SECOND_RECIPIENT), address(0));
    }

    function test_checkpointAllocation_sortedMerge_handlesOldSharedAndNewRecipientsDeterministically() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        BudgetStakeLedgerCoverageBudgetTreasury thirdBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        _configureTopology(THIRD_RECIPIENT, address(thirdBudget), address(budgetFlow), address(strategy), true);
        vm.startPrank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        ledger.registerBudget(THIRD_RECIPIENT, address(thirdBudget));
        vm.stopPrank();

        bytes32[] memory oldRecipientIds = new bytes32[](2);
        oldRecipientIds[0] = RECIPIENT;
        oldRecipientIds[1] = SECOND_RECIPIENT;

        uint32[] memory oldAllocationPpm = new uint32[](2);
        oldAllocationPpm[0] = 500_000;
        oldAllocationPpm[1] = 500_000;

        bytes32[] memory newRecipientIds = new bytes32[](2);
        newRecipientIds[0] = SECOND_RECIPIENT;
        newRecipientIds[1] = THIRD_RECIPIENT;

        uint32[] memory newAllocationPpm = new uint32[](2);
        newAllocationPpm[0] = 500_000;
        newAllocationPpm[1] = 500_000;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT, 0, new bytes32[](0), new uint32[](0), 10 * UNIT_WEIGHT_SCALE, oldRecipientIds, oldAllocationPpm
        );

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            10 * UNIT_WEIGHT_SCALE,
            oldRecipientIds,
            oldAllocationPpm,
            8 * UNIT_WEIGHT_SCALE,
            newRecipientIds,
            newAllocationPpm
        );

        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget)), 0);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget)), 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.userAllocatedStakeOnBudget(ACCOUNT, address(thirdBudget)), 4 * UNIT_WEIGHT_SCALE);

        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), 0);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), 4 * UNIT_WEIGHT_SCALE);
        assertEq(ledger.budgetTotalAllocatedStake(address(thirdBudget)), 4 * UNIT_WEIGHT_SCALE);
    }

    function testFuzz_checkpointAllocation_mergePathMatchesReferenceAndDeltaAccounting(
        uint8 oldMaskSeed,
        uint8 newMaskSeed,
        uint96 prevWeightSeed,
        uint96 newWeightSeed,
        uint32 oldSeedA,
        uint32 oldSeedB,
        uint32 oldSeedC,
        uint32 newSeedA,
        uint32 newSeedB,
        uint32 newSeedC
    ) public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        BudgetStakeLedgerCoverageBudgetTreasury thirdBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        _configureTopology(THIRD_RECIPIENT, address(thirdBudget), address(budgetFlow), address(strategy), true);
        vm.startPrank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
        ledger.registerBudget(THIRD_RECIPIENT, address(thirdBudget));
        vm.stopPrank();

        uint8 oldMask = oldMaskSeed & 0x07;
        uint8 newMask = newMaskSeed & 0x07;
        uint256 prevWeight = bound(uint256(prevWeightSeed), 0, 1_000_000 * UNIT_WEIGHT_SCALE);
        uint256 newWeight = bound(uint256(newWeightSeed), 0, 1_000_000 * UNIT_WEIGHT_SCALE);

        (bytes32[] memory oldRecipientIds, uint32[] memory oldAllocationPpm) =
            _buildSortedAllocations(oldMask, oldSeedA, oldSeedB, oldSeedC);
        (bytes32[] memory newRecipientIds, uint32[] memory newAllocationPpm) =
            _buildSortedAllocations(newMask, newSeedA, newSeedB, newSeedC);

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT, 0, new bytes32[](0), new uint32[](0), prevWeight, oldRecipientIds, oldAllocationPpm
        );

        uint256 firstBefore = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget));
        uint256 secondBefore = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget));
        uint256 thirdBefore = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(thirdBudget));

        uint256 oldFirst = _allocatedForRecipient(prevWeight, oldRecipientIds, oldAllocationPpm, RECIPIENT);
        uint256 oldSecond = _allocatedForRecipient(prevWeight, oldRecipientIds, oldAllocationPpm, SECOND_RECIPIENT);
        uint256 oldThird = _allocatedForRecipient(prevWeight, oldRecipientIds, oldAllocationPpm, THIRD_RECIPIENT);

        assertEq(firstBefore, oldFirst);
        assertEq(secondBefore, oldSecond);
        assertEq(thirdBefore, oldThird);

        // If this reverts, SortedRecipientMerge-based traversal introduced a false-positive drift.
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            prevWeight,
            oldRecipientIds,
            oldAllocationPpm,
            newWeight,
            newRecipientIds,
            newAllocationPpm
        );

        uint256 firstAfter = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(budget));
        uint256 secondAfter = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(secondBudget));
        uint256 thirdAfter = ledger.userAllocatedStakeOnBudget(ACCOUNT, address(thirdBudget));

        uint256 newFirst = _allocatedForRecipient(newWeight, newRecipientIds, newAllocationPpm, RECIPIENT);
        uint256 newSecond = _allocatedForRecipient(newWeight, newRecipientIds, newAllocationPpm, SECOND_RECIPIENT);
        uint256 newThird = _allocatedForRecipient(newWeight, newRecipientIds, newAllocationPpm, THIRD_RECIPIENT);

        assertEq(firstAfter, newFirst);
        assertEq(secondAfter, newSecond);
        assertEq(thirdAfter, newThird);

        _assertDeltaMatchesReference(firstBefore, firstAfter, oldFirst, newFirst);
        _assertDeltaMatchesReference(secondBefore, secondAfter, oldSecond, newSecond);
        _assertDeltaMatchesReference(thirdBefore, thirdAfter, oldThird, newThird);

        assertEq(ledger.budgetTotalAllocatedStake(address(budget)), newFirst);
        assertEq(ledger.budgetTotalAllocatedStake(address(secondBudget)), newSecond);
        assertEq(ledger.budgetTotalAllocatedStake(address(thirdBudget)), newThird);
    }

    function test_registerBudget_revertsWhenBudgetIsNotContract() public {
        address noCode = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_NOT_CONTRACT.selector, noCode));
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, noCode);
    }

    function test_registerBudget_revertsWhenTopologyMissing() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenTopologyInactive() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), false);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenTopologyChildFlowHasNoCode() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(0xBEEF), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenTopologyStrategyHasNoCode() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(0xBEEF), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenTopologyStrategyDoesNotMatchChildFlowStrategy() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        BudgetStakeLedgerCoverageStrategy otherStrategy = new BudgetStakeLedgerCoverageStrategy();

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(otherStrategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenChildFlowDoesNotExposeSingleStrategy() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        BudgetStakeLedgerCoverageStrategy otherStrategy = new BudgetStakeLedgerCoverageStrategy();
        address[] memory childStrategies = new address[](2);
        childStrategies[0] = address(strategy);
        childStrategies[1] = address(otherStrategy);
        budgetFlow.setStrategies(childStrategies);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenTopologyChildFlowMismatchesRuntimeBudget() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        BudgetStakeLedgerCoverageBudgetFlow mismatchedFlow = new BudgetStakeLedgerCoverageBudgetFlow(address(goalFlow));
        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(mismatchedFlow), address(strategy), true);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenGoalFlowIsMissing() public {
        goalTreasury.setFlow(address(0));
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(abi.encodeWithSelector(IBudgetStakeLedger.INVALID_GOAL_FLOW.selector, address(0)));
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenBudgetFlowReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setRevertOnFlowRead(true);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_FLOW_READ.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenBudgetFlowIsInvalid() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setFlow(address(0));

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_FLOW.selector, address(secondBudget), address(0))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenBudgetParentReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(
            address(new BudgetStakeLedgerCoverageFlowWithoutParent())
        );

        _configureTopology(
            SECOND_RECIPIENT, address(secondBudget), address(secondBudget.flow()), address(strategy), true
        );
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_PARENT_READ.selector, secondBudget.flow())
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenBudgetParentDoesNotMatchGoalFlow() public {
        BudgetStakeLedgerCoverageBudgetFlow wrongParentFlow = new BudgetStakeLedgerCoverageBudgetFlow(address(0xDEAD));
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(
            address(wrongParentFlow)
        );

        _configureTopology(
            SECOND_RECIPIENT, address(secondBudget), address(wrongParentFlow), address(strategy), true
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.INVALID_BUDGET_PARENT_MISMATCH.selector,
                address(wrongParentFlow),
                address(goalFlow),
                address(0xDEAD)
            )
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenExecutionDurationInvalid() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setExecutionDuration(0);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_EXECUTION_DURATION.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenExecutionDurationReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setRevertOnExecutionDurationRead(true);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_EXECUTION_DURATION.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenFundingDeadlineInvalid() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setFundingDeadline(0);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_FUNDING_DEADLINE.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenFundingDeadlineReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setRevertOnFundingDeadlineRead(true);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_FUNDING_DEADLINE.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenActivatedAtReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setRevertOnActivatedAtRead(true);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_ACTIVATED_AT.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenResolvedAtReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setRevertOnResolvedAtRead(true);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_RESOLVED_AT.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_registerBudget_revertsWhenStateReadFails() public {
        BudgetStakeLedgerCoverageBudgetTreasury secondBudget = new BudgetStakeLedgerCoverageBudgetTreasury(address(budgetFlow));
        secondBudget.setRevertOnStateRead(true);

        _configureTopology(SECOND_RECIPIENT, address(secondBudget), address(budgetFlow), address(strategy), true);
        vm.expectRevert(
            abi.encodeWithSelector(IBudgetStakeLedger.INVALID_BUDGET_STATE.selector, address(secondBudget))
        );
        vm.prank(address(manager));
        ledger.registerBudget(SECOND_RECIPIENT, address(secondBudget));
    }

    function test_checkpointAllocation_revertsOnAllocationDrift() public {
        _checkpointSingle(ACCOUNT, 0, 10 * UNIT_WEIGHT_SCALE);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetStakeLedger.ALLOCATION_DRIFT.selector,
                ACCOUNT,
                address(budget),
                10 * UNIT_WEIGHT_SCALE,
                9 * UNIT_WEIGHT_SCALE
            )
        );
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            ACCOUNT,
            9 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm,
            8 * UNIT_WEIGHT_SCALE,
            ids,
            allocationPpm
        );
    }

    function _checkpointSingle(address account, uint256 prevWeight, uint256 newWeight) internal {
        _checkpointSingleForRecipient(account, RECIPIENT, prevWeight, newWeight);
    }

    function _registerBudget(bytes32 recipientId, address budget_) internal {
        _configureTopology(recipientId, budget_, address(budgetFlow), address(strategy), true);
        vm.prank(address(manager));
        ledger.registerBudget(recipientId, budget_);
    }

    function _configureTopology(
        bytes32 recipientId,
        address budget_,
        address childFlow_,
        address strategy_,
        bool active
    ) internal {
        manager.setTopology(
            recipientId,
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: childFlow_,
                budgetTreasury: budget_,
                premiumEscrow: address(0),
                strategy: strategy_,
                allocationMechanism: address(0),
                allocationMechanismArbitrator: address(0)
            }),
            active
        );
    }

    function _checkpointSingleForRecipient(
        address account,
        bytes32 recipientId,
        uint256 prevWeight,
        uint256 newWeight
    ) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = recipientId;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = FULL_ALLOCATION_PPM;

        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(account, prevWeight, ids, allocationPpm, newWeight, ids, allocationPpm);
    }

    function _buildSortedAllocations(
        uint8 mask,
        uint32 seedA,
        uint32 seedB,
        uint32 seedC
    ) internal pure returns (bytes32[] memory recipientIds, uint32[] memory allocationsPpm) {
        uint256 count;
        if ((mask & 0x01) != 0) ++count;
        if ((mask & 0x02) != 0) ++count;
        if ((mask & 0x04) != 0) ++count;

        recipientIds = new bytes32[](count);
        allocationsPpm = new uint32[](count);
        if (count == 0) return (recipientIds, allocationsPpm);

        uint256[] memory raw = new uint256[](count);
        uint256 cursor;
        uint256 rawSum;

        if ((mask & 0x01) != 0) {
            recipientIds[cursor] = RECIPIENT;
            raw[cursor] = (uint256(seedA) % FULL_ALLOCATION_PPM) + 1;
            rawSum += raw[cursor];
            ++cursor;
        }
        if ((mask & 0x02) != 0) {
            recipientIds[cursor] = SECOND_RECIPIENT;
            raw[cursor] = (uint256(seedB) % FULL_ALLOCATION_PPM) + 1;
            rawSum += raw[cursor];
            ++cursor;
        }
        if ((mask & 0x04) != 0) {
            recipientIds[cursor] = THIRD_RECIPIENT;
            raw[cursor] = (uint256(seedC) % FULL_ALLOCATION_PPM) + 1;
            rawSum += raw[cursor];
            ++cursor;
        }

        uint256 running;
        for (uint256 i = 0; i + 1 < count; ) {
            uint256 ppm = (raw[i] * FULL_ALLOCATION_PPM) / rawSum;
            allocationsPpm[i] = uint32(ppm);
            running += ppm;
            unchecked {
                ++i;
            }
        }
        allocationsPpm[count - 1] = uint32(uint256(FULL_ALLOCATION_PPM) - running);
    }

    function _allocatedForRecipient(
        uint256 weight,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm,
        bytes32 recipientId
    ) internal pure returns (uint256 allocated) {
        for (uint256 i = 0; i < recipientIds.length; ) {
            if (recipientIds[i] == recipientId) {
                uint256 weighted = (weight * allocationsPpm[i]) / FlowProtocolConstants.PPM_SCALE_UINT256;
                return (weighted / FlowProtocolConstants.UNIT_WEIGHT_SCALE) * FlowProtocolConstants.UNIT_WEIGHT_SCALE;
            }
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    function _assertDeltaMatchesReference(
        uint256 beforeAllocated,
        uint256 afterAllocated,
        uint256 oldAllocated,
        uint256 newAllocated
    ) internal pure {
        if (newAllocated >= oldAllocated) {
            assertEq(afterAllocated - beforeAllocated, newAllocated - oldAllocated);
        } else {
            assertEq(beforeAllocated - afterAllocated, oldAllocated - newAllocated);
        }
    }
}

contract BudgetStakeLedgerCoverageGoalTreasury {
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

contract BudgetStakeLedgerCoverageManager {
    mapping(bytes32 => IBudgetStackTopologyReader.BudgetStackTopology) private _topologyByItemId;
    mapping(bytes32 => bool) private _activeByItemId;
    mapping(address => bytes32) private _itemIdByBudgetTreasury;
    mapping(address => bytes32) private _itemIdByChildFlow;

    function setTopology(
        bytes32 itemId,
        IBudgetStackTopologyReader.BudgetStackTopology memory topology,
        bool active
    ) external {
        _topologyByItemId[itemId] = topology;
        _activeByItemId[itemId] = active;
        _itemIdByBudgetTreasury[topology.budgetTreasury] = itemId;
        _itemIdByChildFlow[topology.childFlow] = itemId;
    }

    function budgetStackTopology(
        bytes32 itemId
    ) external view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function budgetStackTopologyForBudgetTreasury(
        address budgetTreasury
    ) external view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
        bytes32 itemId = _itemIdByBudgetTreasury[budgetTreasury];
        topology = _topologyByItemId[itemId];
        active = _activeByItemId[itemId];
    }

    function budgetStackTopologyForChildFlow(
        address childFlow
    ) external view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) {
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

contract BudgetStakeLedgerCoverageGoalFlow {
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

contract BudgetStakeLedgerCoverageBudgetFlow {
    address public parent;
    address[] private _strategyAddresses;

    constructor(address parent_) {
        parent = parent_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory strategies_) {
        uint256 count = _strategyAddresses.length;
        strategies_ = new IAllocationStrategy[](count);
        for (uint256 i = 0; i < count; ) {
            strategies_[i] = IAllocationStrategy(_strategyAddresses[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setStrategies(address[] memory strategyAddresses_) external {
        _strategyAddresses = strategyAddresses_;
    }
}

contract BudgetStakeLedgerCoverageFlowWithoutParent {}

contract BudgetStakeLedgerCoverageStrategy {}

contract BudgetStakeLedgerCoverageBudgetTreasury {
    address private _flow;
    uint64 private _resolvedAt;
    uint64 private _activatedAt;
    uint64 private _executionDuration = 1 days;
    uint64 private _fundingDeadline = type(uint64).max;
    IBudgetTreasury.BudgetState private _state = IBudgetTreasury.BudgetState.Funding;

    bool private _revertOnFlowRead;
    bool private _revertOnExecutionDurationRead;
    bool private _revertOnFundingDeadlineRead;
    bool private _revertOnActivatedAtRead;
    bool private _revertOnResolvedAtRead;
    bool private _revertOnStateRead;

    constructor(address flow_) {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        if (_revertOnFlowRead) revert("FLOW_READ_FAILED");
        return _flow;
    }

    function resolvedAt() external view returns (uint64) {
        if (_revertOnResolvedAtRead) revert("RESOLVED_AT_READ_FAILED");
        return _resolvedAt;
    }

    function activatedAt() external view returns (uint64) {
        if (_revertOnActivatedAtRead) revert("ACTIVATED_AT_READ_FAILED");
        return _activatedAt;
    }

    function executionDuration() external view returns (uint64) {
        if (_revertOnExecutionDurationRead) revert("EXECUTION_DURATION_READ_FAILED");
        return _executionDuration;
    }

    function fundingDeadline() external view returns (uint64) {
        if (_revertOnFundingDeadlineRead) revert("FUNDING_DEADLINE_READ_FAILED");
        return _fundingDeadline;
    }

    function state() external view returns (IBudgetTreasury.BudgetState) {
        if (_revertOnStateRead) revert("STATE_READ_FAILED");
        return _state;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        _resolvedAt = resolvedAt_;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        _activatedAt = activatedAt_;
    }

    function setExecutionDuration(uint64 executionDuration_) external {
        _executionDuration = executionDuration_;
    }

    function setFundingDeadline(uint64 fundingDeadline_) external {
        _fundingDeadline = fundingDeadline_;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        _state = state_;
    }

    function setRevertOnFlowRead(bool enabled) external {
        _revertOnFlowRead = enabled;
    }

    function setRevertOnExecutionDurationRead(bool enabled) external {
        _revertOnExecutionDurationRead = enabled;
    }

    function setRevertOnFundingDeadlineRead(bool enabled) external {
        _revertOnFundingDeadlineRead = enabled;
    }

    function setRevertOnActivatedAtRead(bool enabled) external {
        _revertOnActivatedAtRead = enabled;
    }

    function setRevertOnResolvedAtRead(bool enabled) external {
        _revertOnResolvedAtRead = enabled;
    }

    function setRevertOnStateRead(bool enabled) external {
        _revertOnStateRead = enabled;
    }
}
