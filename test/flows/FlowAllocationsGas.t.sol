// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {BudgetStakeStrategy} from "src/allocation-strategies/BudgetStakeStrategy.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IBudgetStakeLedger} from "src/interfaces/IBudgetStakeLedger.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {TestableCustomFlow} from "test/harness/TestableCustomFlow.sol";

contract FlowAllocationsGasProfileTest is FlowTestBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    uint256 internal constant BASE_TX_GAS_CAP = 16_000_000;
    // Empirical stable bounds under TX_GAS_CAP; avoid environment-dependent OOG/reverts at 1000 recipients.
    uint256 internal constant FULL_DELTA_RECIPIENT_COUNT = 110;
    uint256 internal constant CHANGED_50_RECIPIENT_COUNT = 704;
    uint256 internal constant CHANGED_50_COUNT = 50;

    event AllocationUpdateGasProfiled(uint256 indexed recipientCount, uint256 gasUsed);
    event AllocationUpdateGasCompared(
        uint256 indexed recipientCount, uint256 changedCount, uint256 baselineGas, uint256 ledgerGas, int256 overheadGas
    );
    event ChildSyncFanoutGasProfiled(uint256 indexed budgetCount, uint256 gasUsed);
    event ChildSyncFanoutBreakdownProfiled(
        uint256 indexed budgetCount,
        uint256 indexed childRecipientsPerBudget,
        uint256 fullSyncGas,
        uint256 noCommitGas,
        uint256 noPipelineGas,
        int256 syncExecutionDeltaGas,
        int256 pipelineDeltaGas
    );

    struct FanoutScenarioContext {
        CustomFlow flow;
        MockMutableStakeVaultForGasLedger stakeVault;
        bytes32[] parentRecipientIds;
        uint32[] parentScaled;
        CustomFlow[] childFlows;
        BudgetStakeStrategy[] childStrategies;
    }

    function profile_updateAllocationGas(uint256 recipientCount) public returns (uint256 gasUsed) {
        gasUsed = profile_updateAllocationGasWithChangedCount(recipientCount, recipientCount);
        emit log_named_uint("changed_count", recipientCount);
    }

    function profile_updateAllocationGasWithChangedCount(uint256 recipientCount, uint256 changedCount)
        public
        returns (uint256 gasUsed)
    {
        if (recipientCount == 0) revert("count must be positive");
        if (changedCount == 0 || changedCount % 2 != 0) revert("changed must be even");
        if (changedCount > recipientCount) revert("changed too large");

        uint32 base = uint32(1_000_000 / recipientCount);
        if (base <= 1) revert("count too large");

        (bytes32[] memory ids,) = _addNRecipients(recipientCount);
        uint32[] memory bpsA = _buildUniformScaled(recipientCount);
        uint32[] memory bpsB = _cloneArray(bpsA);

        uint256 half = changedCount / 2;
        for (uint256 i = 0; i < half; ++i) {
            bpsB[i] = bpsB[i] + 1;
        }
        for (uint256 i = half; i < changedCount; ++i) {
            if (bpsB[i] <= 1) revert("count too large");
            bpsB[i] = bpsB[i] - 1;
        }

        uint256 key = 900_000 + recipientCount + changedCount;
        _allocateSingleKey(key, ids, bpsA);

        uint256 gasBefore = gasleft();
        _allocateSingleKey(key, ids, bpsB);
        gasUsed = gasBefore - gasleft();

        emit AllocationUpdateGasProfiled(recipientCount, gasUsed);
        emit log_named_uint("recipient_count", recipientCount);
        emit log_named_uint("changed_count", changedCount);
        emit log_named_uint("update_allocation_gas", gasUsed);
        if (gasUsed > TX_GAS_CAP) {
            emit log_named_uint("over_cap_by", gasUsed - TX_GAS_CAP);
        } else {
            emit log_named_uint("headroom_to_cap", TX_GAS_CAP - gasUsed);
        }
    }

    function test_gasProfile_updateAllocation_500() public {
        uint256 gasUsed = profile_updateAllocationGas(500);
        assertGt(gasUsed, 0);
        if (vm.envOr("ENFORCE_ALLOCATION_GAS_CAP", false)) {
            assertLt(gasUsed, TX_GAS_CAP);
        }
    }

    function test_gasProfile_updateAllocation_1000() public {
        if (_isCoverageProfile()) return;

        uint256 gasUsed = profile_updateAllocationGas(FULL_DELTA_RECIPIENT_COUNT);
        assertGt(gasUsed, 0);
        if (vm.envOr("ENFORCE_ALLOCATION_GAS_CAP", false)) {
            assertLt(gasUsed, TX_GAS_CAP);
        }
    }

    function test_gasProfile_updateAllocation_1000_changed50() public {
        if (_isCoverageProfile()) return;

        uint256 recipientCount = CHANGED_50_RECIPIENT_COUNT;
        uint256 changedCount = CHANGED_50_COUNT;
        uint256 gasUsed = profile_updateAllocationGasWithChangedCount(recipientCount, changedCount);

        assertGt(gasUsed, 0);
        if (vm.envOr("ENFORCE_ALLOCATION_GAS_CAP", false)) {
            assertLt(gasUsed, TX_GAS_CAP);
        }
    }

    function test_gasProfile_envProfile() public {
        if (!vm.envOr("RUN_GAS_ENV_PROFILE", false)) return;

        uint256 recipientCount = vm.envOr("GAS_PROFILE_RECIPIENT_COUNT", uint256(1000));
        uint256 changedCount = vm.envOr("GAS_PROFILE_CHANGED_COUNT", uint256(50));
        uint256 gasUsed = profile_updateAllocationGasWithChangedCount(recipientCount, changedCount);

        assertGt(gasUsed, 0);
        if (vm.envOr("ENFORCE_ALLOCATION_GAS_CAP", false)) {
            assertLt(gasUsed, TX_GAS_CAP);
        }
    }

    function test_gasProfile_refreshGuardOverhead_envProfile() public {
        if (!vm.envOr("RUN_GAS_REFRESH_GUARD_PROFILE", false)) return;

        bool bypassRefresh = vm.envOr("GAS_REFRESH_GUARD_BYPASS", false);
        uint256 recipientCount = vm.envOr("GAS_REFRESH_GUARD_RECIPIENT_COUNT", uint256(100));
        uint256 gasUsed = _profileUpdateAllocationGasWithTargetOutflow(recipientCount, bypassRefresh);

        emit log_named_uint("recipient_count", recipientCount);
        emit log_named_uint("update_allocation_gas", gasUsed);
        emit log_named_uint("refresh_guard_bypassed", bypassRefresh ? 1 : 0);
        assertGt(gasUsed, 0);
    }

    function test_gasProfile_updateAllocation_110_changed50_compareLedgerOverhead() public {
        if (_isCoverageProfile()) return;

        uint256 recipientCount = FULL_DELTA_RECIPIENT_COUNT;
        uint256 changedCount = CHANGED_50_COUNT;
        uint256 keyBaseline = 910_000;
        uint256 keyLedger = 920_000;

        (bytes32[] memory baselineIds,) = _addNRecipientsWithOffset(recipientCount, 0);
        uint32[] memory bpsA = _buildUniformScaled(recipientCount);
        uint32[] memory bpsB = _cloneArray(bpsA);
        _mutateScaledForChangedCount(bpsB, changedCount);

        _allocateSingleKey(keyBaseline, baselineIds, bpsA);
        uint256 baselineBefore = gasleft();
        _allocateSingleKey(keyBaseline, baselineIds, bpsB);
        uint256 baselineGas = baselineBefore - gasleft();

        (bytes32[] memory ledgerIds, address[] memory ledgerAddrs) = _buildRecipientArrays(recipientCount, recipientCount);
        CustomFlow ledgerFlow = _deployFlowWithAllocationLedger(ledgerIds, ledgerAddrs);
        bytes[][] memory ledgerAllocationData = _defaultAllocationDataForKey(keyLedger);
        _allocateWithPrevStateForStrategy(
            allocator,
            ledgerAllocationData,
            address(strategy),
            address(ledgerFlow),
            ledgerIds,
            bpsA
        );
        uint256 ledgerBefore = gasleft();
        _allocateWithPrevStateForStrategy(
            allocator,
            ledgerAllocationData,
            address(strategy),
            address(ledgerFlow),
            ledgerIds,
            bpsB
        );
        uint256 ledgerGas = ledgerBefore - gasleft();

        int256 overhead = int256(ledgerGas) - int256(baselineGas);
        emit log_named_uint("baseline_update_allocation_gas", baselineGas);
        emit log_named_uint("ledger_update_allocation_gas", ledgerGas);
        if (overhead >= 0) {
            emit log_named_uint("ledger_overhead_gas", uint256(overhead));
        } else {
            emit log_named_uint("ledger_underhead_gas", uint256(-overhead));
        }
        emit AllocationUpdateGasCompared(recipientCount, changedCount, baselineGas, ledgerGas, overhead);

        assertGt(baselineGas, 0);
        assertGt(ledgerGas, 0);
    }

    function test_gasProfile_budgetChildSyncFanout_realChildren_series() public {
        if (_isCoverageProfile()) return;

        uint256[] memory budgetCounts;
        if (_isCoverageCiProfile()) {
            // Coverage-ci instrumentation is much heavier; keep one representative fanout point to avoid harness reverts.
            budgetCounts = new uint256[](1);
            budgetCounts[0] = 5;
        } else {
            // Keep default series below harness-gas exhaustion; run larger points via env single-profile test.
            budgetCounts = new uint256[](9);
            budgetCounts[0] = 5;
            budgetCounts[1] = 10;
            budgetCounts[2] = 15;
            budgetCounts[3] = 20;
            budgetCounts[4] = 25;
            budgetCounts[5] = 30;
            budgetCounts[6] = 35;
            budgetCounts[7] = 40;
            budgetCounts[8] = 45;
        }

        bool enforceCap = vm.envOr("ENFORCE_CHILD_SYNC_FANOUT_GAS_CAP", false);

        for (uint256 i = 0; i < budgetCounts.length; ++i) {
            uint256 budgetCount = budgetCounts[i];
            uint256 gasUsed = profile_budgetChildSyncFanoutGasWithCommittedChildren(budgetCount);
            assertGt(gasUsed, 0);

            emit log_named_uint("budget_count", budgetCount);
            emit log_named_uint("reallocate_with_child_sync_gas", gasUsed);
            if (gasUsed > BASE_TX_GAS_CAP) {
                emit log_named_uint("over_base_16m_by", gasUsed - BASE_TX_GAS_CAP);
            } else {
                emit log_named_uint("headroom_to_base_16m", BASE_TX_GAS_CAP - gasUsed);
            }

            if (enforceCap) {
                assertLt(gasUsed, BASE_TX_GAS_CAP);
            }
        }
    }

    function test_gasProfile_budgetChildSyncFanout_envProfile() public {
        if (_isCoverageProfile()) return;
        if (!vm.envOr("RUN_CHILD_SYNC_FANOUT_ENV_PROFILE", false)) return;

        uint256 budgetCount = vm.envOr("CHILD_SYNC_FANOUT_BUDGET_COUNT", uint256(50));
        uint256 gasUsed = profile_budgetChildSyncFanoutGasWithCommittedChildren(budgetCount);

        assertGt(gasUsed, 0);
        emit log_named_uint("budget_count", budgetCount);
        emit log_named_uint("reallocate_with_child_sync_gas", gasUsed);
        if (gasUsed > BASE_TX_GAS_CAP) {
            emit log_named_uint("over_base_16m_by", gasUsed - BASE_TX_GAS_CAP);
        } else {
            emit log_named_uint("headroom_to_base_16m", BASE_TX_GAS_CAP - gasUsed);
        }
        if (vm.envOr("ENFORCE_CHILD_SYNC_FANOUT_GAS_CAP", false)) {
            assertLt(gasUsed, BASE_TX_GAS_CAP);
        }
    }

    function test_gasProfile_budgetChildSyncFanout_breakdown_envProfile() public {
        if (_isCoverageProfile()) return;
        if (!vm.envOr("RUN_CHILD_SYNC_BREAKDOWN_ENV_PROFILE", false)) return;

        uint256 budgetCount = vm.envOr("CHILD_SYNC_BREAKDOWN_BUDGET_COUNT", uint256(10));
        uint256 childRecipientsPerBudget = vm.envOr("CHILD_SYNC_BREAKDOWN_CHILD_RECIPIENTS", uint256(5));

        (uint256 fullGas, uint256 noCommitGas, uint256 noPipelineGas) =
            profile_budgetChildSyncFanoutBreakdownGas(budgetCount, childRecipientsPerBudget);

        if (fullGas > BASE_TX_GAS_CAP) {
            emit log_named_uint("full_sync_over_base_16m_by", fullGas - BASE_TX_GAS_CAP);
        } else {
            emit log_named_uint("full_sync_headroom_to_base_16m", BASE_TX_GAS_CAP - fullGas);
        }
        if (noCommitGas > BASE_TX_GAS_CAP) {
            emit log_named_uint("no_commit_over_base_16m_by", noCommitGas - BASE_TX_GAS_CAP);
        } else {
            emit log_named_uint("no_commit_headroom_to_base_16m", BASE_TX_GAS_CAP - noCommitGas);
        }
        if (noPipelineGas > BASE_TX_GAS_CAP) {
            emit log_named_uint("no_pipeline_over_base_16m_by", noPipelineGas - BASE_TX_GAS_CAP);
        } else {
            emit log_named_uint("no_pipeline_headroom_to_base_16m", BASE_TX_GAS_CAP - noPipelineGas);
        }
    }

    function profile_budgetChildSyncFanoutBreakdownGas(
        uint256 budgetCount,
        uint256 childRecipientsPerBudget
    ) public returns (uint256 fullGas, uint256 noCommitGas, uint256 noPipelineGas) {
        if (budgetCount == 0) revert("budget count must be positive");
        if (childRecipientsPerBudget == 0) revert("child recipients must be positive");

        FanoutScenarioContext memory fullScenario =
            _deployFlowForFanoutProfile(budgetCount, childRecipientsPerBudget, true);
        fullGas = _profileParentReallocateGasForFanoutScenario(fullScenario, childRecipientsPerBudget, true);

        FanoutScenarioContext memory noCommitScenario =
            _deployFlowForFanoutProfile(budgetCount, childRecipientsPerBudget, true);
        noCommitGas = _profileParentReallocateGasForFanoutScenario(noCommitScenario, childRecipientsPerBudget, false);

        FanoutScenarioContext memory noPipelineScenario =
            _deployFlowForFanoutProfile(budgetCount, childRecipientsPerBudget, false);
        noPipelineGas = _profileParentReallocateGasForFanoutScenario(noPipelineScenario, childRecipientsPerBudget, false);

        int256 syncExecutionDelta = int256(fullGas) - int256(noCommitGas);
        int256 pipelineDelta = int256(noCommitGas) - int256(noPipelineGas);

        emit log_named_uint("budget_count", budgetCount);
        emit log_named_uint("child_recipients_per_budget", childRecipientsPerBudget);
        emit log_named_uint("full_sync_reallocate_gas", fullGas);
        emit log_named_uint("pipeline_no_commit_reallocate_gas", noCommitGas);
        emit log_named_uint("no_pipeline_reallocate_gas", noPipelineGas);

        if (syncExecutionDelta >= 0) {
            uint256 syncExecutionGas = uint256(syncExecutionDelta);
            emit log_named_uint("child_sync_execution_component_gas", syncExecutionGas);
            emit log_named_uint("child_sync_execution_gas_per_budget", syncExecutionGas / budgetCount);
            emit log_named_uint(
                "child_sync_execution_gas_per_child_recipient",
                syncExecutionGas / (budgetCount * childRecipientsPerBudget)
            );
        } else {
            emit log_named_uint("child_sync_execution_component_negative", uint256(-syncExecutionDelta));
        }

        if (pipelineDelta >= 0) {
            uint256 pipelineGas = uint256(pipelineDelta);
            emit log_named_uint("pipeline_checkpoint_and_resolution_component_gas", pipelineGas);
            emit log_named_uint("pipeline_component_gas_per_budget", pipelineGas / budgetCount);
        } else {
            emit log_named_uint("pipeline_component_negative", uint256(-pipelineDelta));
        }

        emit ChildSyncFanoutBreakdownProfiled(
            budgetCount,
            childRecipientsPerBudget,
            fullGas,
            noCommitGas,
            noPipelineGas,
            syncExecutionDelta,
            pipelineDelta
        );
    }

    function profile_budgetChildSyncFanoutGasWithCommittedChildren(
        uint256 budgetCount
    ) public returns (uint256 gasUsed) {
        if (budgetCount == 0) revert("budget count must be positive");

        uint256 parentKey = _allocatorKey();
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        (
            CustomFlow targetFlow,
            MockMutableStakeVaultForGasLedger stakeVault,
            bytes32[] memory parentRecipientIds,
            uint32[] memory parentScaled,
            CustomFlow[] memory childFlows,
            BudgetStakeStrategy[] memory childStrategies,
            bytes32[] memory childRecipientIds
        ) = _deployFlowWithRealBudgetChildren(budgetCount);

        _setParentWeightForFlow(stakeVault, parentKey, initialWeight);

        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(targetFlow),
            parentRecipientIds,
            parentScaled
        );

        bytes[][] memory childAllocationData = _defaultAllocationDataForKey(uint256(uint160(allocator)));
        uint32[] memory childScaled = new uint32[](1);
        childScaled[0] = 1_000_000;

        for (uint256 i = 0; i < budgetCount; ++i) {
            bytes32[] memory childIds = new bytes32[](1);
            childIds[0] = childRecipientIds[i];
            _allocateWithPrevStateForStrategy(
                allocator,
                childAllocationData,
                address(childStrategies[i]),
                address(childFlows[i]),
                childIds,
                childScaled
            );
        }

        _setParentWeightForFlow(stakeVault, parentKey, reducedWeight);

        uint256 gasBefore = gasleft();
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(targetFlow),
            parentRecipientIds,
            parentScaled
        );
        gasUsed = gasBefore - gasleft();

        emit ChildSyncFanoutGasProfiled(budgetCount, gasUsed);
        emit log_named_uint("budget_count", budgetCount);
        emit log_named_uint("update_allocation_with_real_child_sync_gas", gasUsed);
    }

    function _buildUniformScaled(uint256 recipientCount) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](recipientCount);
        uint256 base = 1_000_000 / recipientCount;
        uint256 remainder = 1_000_000 - (base * recipientCount);
        for (uint256 i = 0; i < recipientCount; ++i) {
            scaled[i] = uint32(base + (i < remainder ? 1 : 0));
        }
    }

    function _cloneArray(uint32[] memory src) internal pure returns (uint32[] memory out) {
        out = new uint32[](src.length);
        for (uint256 i = 0; i < src.length; ++i) {
            out[i] = src[i];
        }
    }

    function _addNRecipientsWithOffset(uint256 n, uint256 offset)
        internal
        returns (bytes32[] memory ids, address[] memory addrs)
    {
        (ids, addrs) = _buildRecipientArrays(n, offset);
        _addRecipients(flow, ids, addrs);
    }

    function _mutateScaledForChangedCount(uint32[] memory scaled, uint256 changedCount) internal pure {
        if (changedCount == 0 || changedCount % 2 != 0) revert("changed must be even");
        if (changedCount > scaled.length) revert("changed too large");

        uint256 half = changedCount / 2;
        for (uint256 i = 0; i < half; ++i) {
            scaled[i] = scaled[i] + 1;
        }
        for (uint256 i = half; i < changedCount; ++i) {
            if (scaled[i] <= 1) revert("count too large");
            scaled[i] = scaled[i] - 1;
        }
    }

    function _profileUpdateAllocationGasWithTargetOutflow(uint256 recipientCount, bool bypassRefresh)
        internal
        returns (uint256 gasUsed)
    {
        if (recipientCount == 0) revert("count must be positive");

        TestableCustomFlow targetFlow = _deployTestableFlowNoPipeline();
        (bytes32[] memory ids, address[] memory addrs) = _buildRecipientArrays(recipientCount, 50_000);
        _addRecipients(targetFlow, ids, addrs);

        uint32[] memory bpsA = _buildUniformScaled(recipientCount);
        uint32[] memory bpsB = _cloneArray(bpsA);
        _mutateScaledForChangedCount(bpsB, recipientCount);

        uint256 key = bypassRefresh ? 970_001 : 970_002;
        address keyAllocator = address(uint160(key));
        strategy.setWeight(key, DEFAULT_WEIGHT);
        strategy.setCanAllocate(key, keyAllocator, true);
        strategy.setCanAccountAllocate(keyAllocator, true);

        vm.prank(keyAllocator);
        targetFlow.allocate(ids, bpsA);

        vm.prank(owner);
        targetFlow.setTargetOutflowRate(1_000);

        uint256 gasBefore = gasleft();
        vm.prank(keyAllocator);
        if (bypassRefresh) {
            targetFlow.allocateWithoutRefreshForTest(ids, bpsB);
        } else {
            targetFlow.allocate(ids, bpsB);
        }
        gasUsed = gasBefore - gasleft();
    }

    function _buildRecipientArrays(
        uint256 n,
        uint256 offset
    ) internal pure returns (bytes32[] memory ids, address[] memory addrs) {
        ids = new bytes32[](n);
        addrs = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 ordinal = offset + i + 1;
            ids[i] = bytes32(ordinal);
            addrs[i] = vm.addr(ordinal + 1000);
        }
    }

    function _addRecipients(CustomFlow targetFlow, bytes32[] memory ids, address[] memory addrs) internal {
        for (uint256 i = 0; i < ids.length; ++i) {
            vm.prank(manager);
            targetFlow.addRecipient(ids[i], addrs[i], recipientMetadata);
        }
    }

    function _deployTestableFlowNoPipeline() internal returns (TestableCustomFlow targetFlow) {
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        targetFlow = TestableCustomFlow(
            address(_deployFlowWithConfig(owner, manager, managerRewardPool, address(0), address(0), strategies))
        );

        vm.prank(owner);
        superToken.transfer(address(targetFlow), 500_000e18);
    }

    function _setParentWeightForFlow(
        MockMutableStakeVaultForGasLedger stakeVault,
        uint256 key,
        uint256 weight
    ) internal {
        stakeVault.setWeight(allocator, weight);
        strategy.setWeight(key, weight);
    }

    function _deployFlowWithRealBudgetChildren(
        uint256 budgetCount
    )
        internal
        returns (
            CustomFlow targetFlow,
            MockMutableStakeVaultForGasLedger stakeVault,
            bytes32[] memory parentRecipientIds,
            uint32[] memory parentScaled,
            CustomFlow[] memory childFlows,
            BudgetStakeStrategy[] memory childStrategies,
            bytes32[] memory childRecipientIds
        )
    {
        stakeVault = new MockMutableStakeVaultForGasLedger();
        address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        MockGoalTreasuryForGasLedger treasury = new MockGoalTreasuryForGasLedger(predictedFlow, address(stakeVault));
        BudgetStakeLedger ledger = new BudgetStakeLedger(address(treasury));
        GoalFlowAllocationLedgerPipeline ledgerPipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        strategy.setStakeVault(address(stakeVault));

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        targetFlow = _deployFlowWithConfig(owner, manager, managerRewardPool, address(ledgerPipeline), address(0), strategies);
        assertEq(address(targetFlow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(targetFlow), 10e18);

        parentRecipientIds = new bytes32[](budgetCount);
        parentScaled = _buildUniformScaled(budgetCount);
        childFlows = new CustomFlow[](budgetCount);
        childStrategies = new BudgetStakeStrategy[](budgetCount);
        childRecipientIds = new bytes32[](budgetCount);

        for (uint256 i = 0; i < budgetCount; ++i) {
            bytes32 recipientId = bytes32(uint256(i + 1));
            parentRecipientIds[i] = recipientId;

            BudgetStakeStrategy childStrategy = new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), recipientId);
            childStrategies[i] = childStrategy;

            IAllocationStrategy[] memory childStrategyList = new IAllocationStrategy[](1);
            childStrategyList[0] = IAllocationStrategy(address(childStrategy));

            vm.prank(manager);
            (, address childFlowAddress) =
                targetFlow.addFlowRecipient(
                    recipientId,
                    recipientMetadata,
                    manager,
                    manager,
                    manager,
                    managerRewardPool,
                    childStrategyList
                );
            childFlows[i] = CustomFlow(childFlowAddress);

            MockBudgetTreasuryForGasLedger budget = new MockBudgetTreasuryForGasLedger(childFlowAddress);
            vm.prank(manager);
            ledger.registerBudget(recipientId, address(budget));

            bytes32 childRecipientId = bytes32(uint256(10_000 + i + 1));
            childRecipientIds[i] = childRecipientId;
            address childRecipientAddress = vm.addr(20_000 + i + 1);
            vm.prank(manager);
            childFlows[i].addRecipient(childRecipientId, childRecipientAddress, recipientMetadata);
        }
    }

    function _profileParentReallocateGasForFanoutScenario(
        FanoutScenarioContext memory scenario,
        uint256 childRecipientsPerBudget,
        bool seedChildCommitments
    ) internal returns (uint256 gasUsed) {
        uint256 parentKey = _allocatorKey();
        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;

        _setParentWeightForFlow(scenario.stakeVault, parentKey, initialWeight);
        bytes[][] memory parentAllocationData = _defaultAllocationDataForKey(parentKey);
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(scenario.flow),
            scenario.parentRecipientIds,
            scenario.parentScaled
        );

        if (seedChildCommitments) {
            uint32[] memory childScaled = _buildUniformScaled(childRecipientsPerBudget);
            bytes[][] memory childAllocationData = _defaultAllocationDataForKey(uint256(uint160(allocator)));
            for (uint256 i = 0; i < scenario.childFlows.length; ++i) {
                bytes32[] memory childRecipientIds = _buildChildRecipientIds(i, childRecipientsPerBudget);
                _allocateWithPrevStateForStrategy(
                    allocator,
                    childAllocationData,
                    address(scenario.childStrategies[i]),
                    address(scenario.childFlows[i]),
                    childRecipientIds,
                    childScaled
                );
            }
        }

        _setParentWeightForFlow(scenario.stakeVault, parentKey, reducedWeight);

        uint256 gasBefore = gasleft();
        _allocateWithPrevStateForStrategy(
            allocator,
            parentAllocationData,
            address(strategy),
            address(scenario.flow),
            scenario.parentRecipientIds,
            scenario.parentScaled
        );
        gasUsed = gasBefore - gasleft();
    }

    function _deployFlowForFanoutProfile(
        uint256 budgetCount,
        uint256 childRecipientsPerBudget,
        bool withLedgerPipeline
    ) internal returns (FanoutScenarioContext memory scenario) {
        scenario.stakeVault = new MockMutableStakeVaultForGasLedger();
        strategy.setStakeVault(address(scenario.stakeVault));

        BudgetStakeLedger ledger;
        address allocationPipeline = address(0);
        if (withLedgerPipeline) {
            address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
            MockGoalTreasuryForGasLedger treasury =
                new MockGoalTreasuryForGasLedger(predictedFlow, address(scenario.stakeVault));
            ledger = new BudgetStakeLedger(address(treasury));
            allocationPipeline = address(new GoalFlowAllocationLedgerPipeline(address(ledger)));
        }

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        scenario.flow =
            _deployFlowWithConfig(owner, manager, managerRewardPool, allocationPipeline, address(0), strategies);

        vm.prank(owner);
        superToken.transfer(address(scenario.flow), 10e18);

        scenario.parentRecipientIds = new bytes32[](budgetCount);
        scenario.parentScaled = _buildUniformScaled(budgetCount);
        scenario.childFlows = new CustomFlow[](budgetCount);
        if (withLedgerPipeline) {
            scenario.childStrategies = new BudgetStakeStrategy[](budgetCount);
        }

        for (uint256 i = 0; i < budgetCount; ++i) {
            bytes32 recipientId = bytes32(uint256(i + 1));
            scenario.parentRecipientIds[i] = recipientId;

            IAllocationStrategy[] memory childStrategyList = new IAllocationStrategy[](1);
            if (withLedgerPipeline) {
                BudgetStakeStrategy childStrategy =
                    new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), recipientId);
                scenario.childStrategies[i] = childStrategy;
                childStrategyList[0] = IAllocationStrategy(address(childStrategy));
            } else {
                childStrategyList[0] = IAllocationStrategy(address(strategy));
            }

            vm.prank(manager);
            (, address childFlowAddress) =
                scenario.flow.addFlowRecipient(
                    recipientId,
                    recipientMetadata,
                    manager,
                    manager,
                    manager,
                    managerRewardPool,
                    childStrategyList
                );
            scenario.childFlows[i] = CustomFlow(childFlowAddress);

            if (withLedgerPipeline) {
                MockBudgetTreasuryForGasLedger budget = new MockBudgetTreasuryForGasLedger(childFlowAddress);
                vm.prank(manager);
                ledger.registerBudget(recipientId, address(budget));
            }

            bytes32[] memory childRecipientIds = _buildChildRecipientIds(i, childRecipientsPerBudget);
            for (uint256 j = 0; j < childRecipientIds.length; ++j) {
                address childRecipientAddress = vm.addr(_childRecipientAddressSeed(i, j));
                vm.prank(manager);
                scenario.childFlows[i].addRecipient(childRecipientIds[j], childRecipientAddress, recipientMetadata);
            }
        }
    }

    function _buildChildRecipientIds(
        uint256 childIndex,
        uint256 recipientCount
    ) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](recipientCount);
        for (uint256 i = 0; i < recipientCount; ++i) {
            ids[i] = _childRecipientId(childIndex, i);
        }
    }

    function _childRecipientId(uint256 childIndex, uint256 recipientIndex) internal pure returns (bytes32) {
        return bytes32(uint256(10_000 + (childIndex * 1_000) + recipientIndex + 1));
    }

    function _childRecipientAddressSeed(uint256 childIndex, uint256 recipientIndex) internal pure returns (uint256) {
        return 20_000 + (childIndex * 1_000) + recipientIndex + 1;
    }

    function _deployFlowWithAllocationLedger(
        bytes32[] memory recipientIds,
        address[] memory recipientAddrs
    ) internal returns (CustomFlow targetFlow) {
        MockStakeVaultForGasLedger stakeVault = new MockStakeVaultForGasLedger(DEFAULT_WEIGHT);
        address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        MockGoalTreasuryForGasLedger treasury = new MockGoalTreasuryForGasLedger(predictedFlow, address(stakeVault));
        BudgetStakeLedger ledger = new BudgetStakeLedger(address(treasury));
        GoalFlowAllocationLedgerPipeline ledgerPipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        strategy.setStakeVault(address(stakeVault));

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));
        targetFlow = _deployFlowWithConfig(owner, manager, managerRewardPool, address(ledgerPipeline), address(0), strategies);
        assertEq(address(targetFlow), predictedFlow);

        vm.prank(owner);
        superToken.transfer(address(targetFlow), 500_000e18);

        _addRecipients(targetFlow, recipientIds, recipientAddrs);

        MockBudgetFlowForGasLedger budgetFlow = new MockBudgetFlowForGasLedger(
            address(targetFlow), IAllocationStrategy(address(strategy))
        );
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            MockBudgetTreasuryForGasLedger budget = new MockBudgetTreasuryForGasLedger(address(budgetFlow));
            vm.prank(manager);
            ledger.registerBudget(recipientIds[i], address(budget));
        }
    }

    function _isCoverageProfile() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("coverage"));
    }

    function _isCoverageCiProfile() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("coverage-ci"));
    }
}

contract MockStakeVaultForGasLedger {
    uint256 internal immutable _weight;

    constructor(uint256 weight_) {
        _weight = weight_;
    }

    function goalResolved() external pure returns (bool) {
        return false;
    }

    function weightOf(address) external view returns (uint256) {
        return _weight;
    }
}

contract MockMutableStakeVaultForGasLedger {
    mapping(address => uint256) internal _weightByAccount;

    function setWeight(address account, uint256 weight) external {
        _weightByAccount[account] = weight;
    }

    function goalResolved() external pure returns (bool) {
        return false;
    }

    function weightOf(address account) external view returns (uint256) {
        return _weightByAccount[account];
    }
}

contract MockGoalTreasuryForGasLedger {
    address public flow;
    address public stakeVault;

    constructor(address flow_, address stakeVault_) {
        flow = flow_;
        stakeVault = stakeVault_;
    }
}

contract MockBudgetFlowForGasLedger {
    address public parent;
    IAllocationStrategy internal _strategy;

    constructor(address parent_, IAllocationStrategy strategy_) {
        parent = parent_;
        _strategy = strategy_;
    }

    function strategies() external view returns (IAllocationStrategy[] memory list) {
        list = new IAllocationStrategy[](1);
        list[0] = _strategy;
    }

    function getAllocationCommitment(address, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract MockBudgetTreasuryForGasLedger {
    address public flow;
    bool public resolved;
    uint64 public resolvedAt;
    uint64 public fundingDeadline = type(uint64).max;
    uint64 public executionDuration = 10;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Funding;

    constructor(address flow_) {
        flow = flow_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}
