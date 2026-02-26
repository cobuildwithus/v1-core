// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {ISuperfluidPool} from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract FlowUpdateMemberUnitsGasProfileTest is FlowTestBase {
    uint256 internal constant DEFAULT_ESTIMATE_BUDGET_COUNT = 10;
    uint256 internal constant DEFAULT_ESTIMATE_RECIPIENTS_PER_BUDGET = 5;
    bytes32 internal constant SCENARIO_COLD_ZERO_TO_NONZERO = keccak256("cold_zero_to_nonzero");
    bytes32 internal constant SCENARIO_WARM_NONZERO_TO_NONZERO = keccak256("warm_nonzero_to_nonzero");
    bytes32 internal constant SCENARIO_WARM_NONZERO_TO_ZERO = keccak256("warm_nonzero_to_zero");
    bytes32 internal constant SCENARIO_WARM_NOOP = keccak256("warm_noop");

    event UpdateMemberUnitsGasMeasured(bytes32 indexed scenario, uint256 gasUsed);
    event ChildSyncUpdateMemberUnitsEstimate(
        uint256 indexed budgetCount,
        uint256 indexed recipientsPerBudget,
        uint256 updateMemberUnitsGas,
        uint256 estimatedSyncGas
    );
    event ChildSyncUpdateMemberUnitsConservativeEstimate(
        uint256 indexed budgetCount,
        uint256 indexed recipientsPerBudget,
        uint256 warmUpdateMemberUnitsGas,
        uint256 coldUpdateMemberUnitsGas,
        uint256 warmEstimateGas,
        uint256 conservativeEstimateGas
    );

    function profile_updateMemberUnitsGas_coldZeroToNonZero() public returns (uint256 gasUsed) {
        gasUsed = _measurePoolUpdateMemberUnitsGas(vm.addr(70_001), 10);

        emit UpdateMemberUnitsGasMeasured(SCENARIO_COLD_ZERO_TO_NONZERO, gasUsed);
        emit log_named_uint("update_member_units_gas_cold_0_to_10", gasUsed);
    }

    function profile_updateMemberUnitsGas_warmNonZeroToNonZero() public returns (uint256 gasUsed) {
        address member = vm.addr(70_002);
        _setPoolUnits(member, 10);
        gasUsed = _measurePoolUpdateMemberUnitsGas(member, 20);

        emit UpdateMemberUnitsGasMeasured(SCENARIO_WARM_NONZERO_TO_NONZERO, gasUsed);
        emit log_named_uint("update_member_units_gas_warm_10_to_20", gasUsed);
    }

    function profile_updateMemberUnitsGas_warmNonZeroToZero() public returns (uint256 gasUsed) {
        address member = vm.addr(70_003);
        _setPoolUnits(member, 20);
        gasUsed = _measurePoolUpdateMemberUnitsGas(member, 0);

        emit UpdateMemberUnitsGasMeasured(SCENARIO_WARM_NONZERO_TO_ZERO, gasUsed);
        emit log_named_uint("update_member_units_gas_warm_20_to_0", gasUsed);
    }

    function profile_updateMemberUnitsGas_warmNoOp() public returns (uint256 gasUsed) {
        address member = vm.addr(70_004);
        _setPoolUnits(member, 20);
        gasUsed = _measurePoolUpdateMemberUnitsGas(member, 20);

        emit UpdateMemberUnitsGasMeasured(SCENARIO_WARM_NOOP, gasUsed);
        emit log_named_uint("update_member_units_gas_warm_20_to_20", gasUsed);
    }

    function profile_childSyncEstimateFromUpdateMemberUnitsCost(
        uint256 budgetCount,
        uint256 recipientsPerBudget
    ) public returns (uint256 estimatedSyncGas, uint256 updateMemberUnitsGas) {
        if (budgetCount == 0) revert("budget count must be positive");
        if (recipientsPerBudget == 0) revert("child recipients must be positive");
        if (budgetCount > type(uint256).max / recipientsPerBudget) revert("estimate multiplier overflow");

        uint256 coldUpdateMemberUnitsGas = profile_updateMemberUnitsGas_coldZeroToNonZero();
        updateMemberUnitsGas = profile_updateMemberUnitsGas_warmNonZeroToNonZero();
        uint256 updatesTotal = budgetCount * recipientsPerBudget;
        if (updatesTotal > type(uint256).max / updateMemberUnitsGas) revert("estimate product overflow");
        if (updatesTotal > type(uint256).max / coldUpdateMemberUnitsGas) revert("conservative estimate overflow");
        estimatedSyncGas = budgetCount * recipientsPerBudget * updateMemberUnitsGas;
        uint256 conservativeEstimateGas = updatesTotal * coldUpdateMemberUnitsGas;

        emit ChildSyncUpdateMemberUnitsEstimate(budgetCount, recipientsPerBudget, updateMemberUnitsGas, estimatedSyncGas);
        emit ChildSyncUpdateMemberUnitsConservativeEstimate(
            budgetCount,
            recipientsPerBudget,
            updateMemberUnitsGas,
            coldUpdateMemberUnitsGas,
            estimatedSyncGas,
            conservativeEstimateGas
        );
        emit log_named_uint("budget_count", budgetCount);
        emit log_named_uint("child_recipients_per_budget", recipientsPerBudget);
        emit log_named_uint("update_member_units_gas_warm_representative", updateMemberUnitsGas);
        emit log_named_uint("update_member_units_gas_cold_reference", coldUpdateMemberUnitsGas);
        emit log_named_uint("estimated_child_sync_execution_gas_warm_lower_bound", estimatedSyncGas);
        emit log_named_uint("estimated_child_sync_execution_gas_cold_conservative", conservativeEstimateGas);
    }

    function test_gasProfile_updateMemberUnits_baselineSeries() public {
        ISuperfluidPool pool = flow.distributionPool();

        uint256 cold = profile_updateMemberUnitsGas_coldZeroToNonZero();
        uint256 warm = profile_updateMemberUnitsGas_warmNonZeroToNonZero();
        uint256 clear = profile_updateMemberUnitsGas_warmNonZeroToZero();
        uint256 noOp = profile_updateMemberUnitsGas_warmNoOp();

        assertGt(cold, 0);
        assertGt(warm, 0);
        assertGt(clear, 0);
        assertGt(noOp, 0);

        assertEq(pool.getUnits(vm.addr(70_001)), uint128(10));
        assertEq(pool.getUnits(vm.addr(70_002)), uint128(20));
        assertEq(pool.getUnits(vm.addr(70_003)), uint128(0));
        assertEq(pool.getUnits(vm.addr(70_004)), uint128(20));
    }

    function test_gasProfile_childSyncEstimate_default() public {
        (uint256 estimatedSyncGas, uint256 updateMemberUnitsGas) =
            profile_childSyncEstimateFromUpdateMemberUnitsCost(
                DEFAULT_ESTIMATE_BUDGET_COUNT, DEFAULT_ESTIMATE_RECIPIENTS_PER_BUDGET
            );
        assertGt(updateMemberUnitsGas, 0);
        assertGt(estimatedSyncGas, 0);
        assertEq(
            estimatedSyncGas,
            DEFAULT_ESTIMATE_BUDGET_COUNT * DEFAULT_ESTIMATE_RECIPIENTS_PER_BUDGET * updateMemberUnitsGas
        );
    }

    function test_gasProfile_childSyncEstimate_envProfile() public {
        if (!vm.envOr("RUN_UPDATE_MEMBER_UNITS_ESTIMATE_ENV_PROFILE", false)) return;

        uint256 budgetCount = vm.envOr("UPDATE_MEMBER_UNITS_ESTIMATE_BUDGET_COUNT", DEFAULT_ESTIMATE_BUDGET_COUNT);
        uint256 recipientsPerBudget = vm.envOr(
            "UPDATE_MEMBER_UNITS_ESTIMATE_RECIPIENTS_PER_BUDGET", DEFAULT_ESTIMATE_RECIPIENTS_PER_BUDGET
        );

        (uint256 estimatedSyncGas, uint256 updateMemberUnitsGas) =
            profile_childSyncEstimateFromUpdateMemberUnitsCost(budgetCount, recipientsPerBudget);
        assertGt(updateMemberUnitsGas, 0);
        assertGt(estimatedSyncGas, 0);
        assertEq(estimatedSyncGas, budgetCount * recipientsPerBudget * updateMemberUnitsGas);
    }

    function test_gasProfile_childSyncEstimate_revertWhenBudgetCountZero() public {
        vm.expectRevert(bytes("budget count must be positive"));
        this.profile_childSyncEstimateFromUpdateMemberUnitsCost(0, DEFAULT_ESTIMATE_RECIPIENTS_PER_BUDGET);
    }

    function test_gasProfile_childSyncEstimate_revertWhenRecipientsPerBudgetZero() public {
        vm.expectRevert(bytes("child recipients must be positive"));
        this.profile_childSyncEstimateFromUpdateMemberUnitsCost(DEFAULT_ESTIMATE_BUDGET_COUNT, 0);
    }

    function test_gasProfile_childSyncEstimate_revertWhenMultiplierOverflows() public {
        vm.expectRevert(bytes("estimate multiplier overflow"));
        this.profile_childSyncEstimateFromUpdateMemberUnitsCost(type(uint256).max, 2);
    }

    function test_gasProfile_childSyncEstimate_revertWhenWarmProductOverflows() public {
        vm.expectRevert(bytes("estimate product overflow"));
        this.profile_childSyncEstimateFromUpdateMemberUnitsCost(type(uint256).max, 1);
    }

    function _setPoolUnits(address member, uint128 units) internal {
        ISuperfluidPool pool = flow.distributionPool();
        vm.prank(address(flow));
        bool success = pool.updateMemberUnits(member, units);
        assertTrue(success);
    }

    function _measurePoolUpdateMemberUnitsGas(address member, uint128 units) internal returns (uint256 gasUsed) {
        ISuperfluidPool pool = flow.distributionPool();
        vm.prank(address(flow));
        uint256 gasBefore = gasleft();
        bool success = pool.updateMemberUnits(member, units);
        gasUsed = gasBefore - gasleft();
        assertTrue(success);
    }
}
