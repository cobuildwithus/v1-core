// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

import {
    CobuildSplitHookMockDirectory,
    CobuildSplitHookMockGoalRegistry,
    CobuildSplitHookMockGoalTerminal,
    CobuildSplitHookRouteSetterStub,
    CobuildSplitHookMockGoalTreasury,
    CobuildSplitHookMockToken
} from "test/hooks/CobuildSplitHook.t.sol";

contract CobuildSplitHookGasProfileTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 77;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;
    uint256 internal constant DEFAULT_MAX_GOAL_COUNT = 512;
    uint256 internal constant GAS_TARGET_16M = 16_000_000;
    uint256 internal constant GOAL_ID_BASE = 10_000;
    uint256 internal constant TOKENS_PER_GOAL = 1e18;
    // Keep these aligned with the current CobuildSplitHook storage layout.
    uint256 internal constant OBSERVED_VOLUME_MAPPING_SLOT = 6;

    bytes32 internal constant SCENARIO_DIRECT_HISTORICAL = keccak256("direct_historical_goal_treasuries");
    bytes32 internal constant SCENARIO_PENDING_HISTORICAL = keccak256("pending_historical_beneficiary");

    event HistoricalRoutingGasMeasured(bytes32 indexed scenario, uint256 indexed goalCount, uint256 gasUsed);
    event HistoricalRoutingThresholdFound(
        bytes32 indexed scenario,
        uint256 targetGas,
        uint256 thresholdGoalCount,
        uint256 thresholdGasUsed,
        uint256 lastSafeGoalCount,
        uint256 lastSafeGasUsed
    );

    struct Scenario {
        CobuildSplitHook hook;
        CobuildSplitHookMockToken token;
        address controller;
        address routeSetter;
        address beneficiary;
    }

    struct ThresholdResult {
        uint256 thresholdGoalCount;
        uint256 thresholdGasUsed;
        uint256 lastSafeGoalCount;
        uint256 lastSafeGasUsed;
    }

    function test_gasProfile_directHistoricalRoute_firstGoalCountOver16m() public {
        ThresholdResult memory result =
            profile_findFirstHistoricalRouteGoalCountOverTarget(false, DEFAULT_MAX_GOAL_COUNT, GAS_TARGET_16M);

        if (result.thresholdGoalCount == 0) {
            emit log_named_uint("direct_historical_route_threshold_not_found_within_goal_count", DEFAULT_MAX_GOAL_COUNT);
            return;
        }

        assertGt(result.thresholdGasUsed, GAS_TARGET_16M, "direct threshold gas");
        assertLe(result.lastSafeGasUsed, GAS_TARGET_16M, "direct last safe gas");

        emit log_named_uint("direct_historical_route_first_goal_count_over_16m", result.thresholdGoalCount);
        emit log_named_uint("direct_historical_route_gas_at_threshold", result.thresholdGasUsed);
        emit log_named_uint("direct_historical_route_last_safe_goal_count", result.lastSafeGoalCount);
        emit log_named_uint("direct_historical_route_gas_at_last_safe_count", result.lastSafeGasUsed);
    }

    function test_gasProfile_pendingHistoricalRoute_firstGoalCountOver16m() public {
        ThresholdResult memory result =
            profile_findFirstHistoricalRouteGoalCountOverTarget(true, DEFAULT_MAX_GOAL_COUNT, GAS_TARGET_16M);

        if (result.thresholdGoalCount == 0) {
            emit log_named_uint(
                "pending_historical_route_threshold_not_found_within_goal_count", DEFAULT_MAX_GOAL_COUNT
            );
            return;
        }

        assertGt(result.thresholdGasUsed, GAS_TARGET_16M, "pending threshold gas");
        assertLe(result.lastSafeGasUsed, GAS_TARGET_16M, "pending last safe gas");

        emit log_named_uint("pending_historical_route_first_goal_count_over_16m", result.thresholdGoalCount);
        emit log_named_uint("pending_historical_route_gas_at_threshold", result.thresholdGasUsed);
        emit log_named_uint("pending_historical_route_last_safe_goal_count", result.lastSafeGoalCount);
        emit log_named_uint("pending_historical_route_gas_at_last_safe_count", result.lastSafeGasUsed);
    }

    function profile_findFirstHistoricalRouteGoalCountOverTarget(
        bool usesPendingHistoricalRoute,
        uint256 maxGoalCount,
        uint256 targetGas
    ) public returns (ThresholdResult memory result) {
        if (maxGoalCount == 0) revert("max goal count must be positive");

        bytes32 scenario = usesPendingHistoricalRoute ? SCENARIO_PENDING_HISTORICAL : SCENARIO_DIRECT_HISTORICAL;

        uint256 lowGoalCount;
        uint256 lowGasUsed;
        uint256 highGoalCount = 1;

        while (true) {
            uint256 gasUsed = _measureHistoricalRouteGas(highGoalCount, usesPendingHistoricalRoute);
            _emitGasMeasurement(scenario, highGoalCount, gasUsed);

            if (gasUsed > targetGas) {
                result = ThresholdResult({
                    thresholdGoalCount: highGoalCount,
                    thresholdGasUsed: gasUsed,
                    lastSafeGoalCount: lowGoalCount,
                    lastSafeGasUsed: lowGasUsed
                });
                break;
            }

            lowGoalCount = highGoalCount;
            lowGasUsed = gasUsed;

            if (highGoalCount == maxGoalCount) {
                emit HistoricalRoutingThresholdFound(scenario, targetGas, 0, 0, lowGoalCount, lowGasUsed);
                return result;
            }

            uint256 nextGoalCount = highGoalCount * 2;
            if (nextGoalCount > maxGoalCount || nextGoalCount <= highGoalCount) {
                nextGoalCount = maxGoalCount;
            }
            highGoalCount = nextGoalCount;
        }

        while (result.lastSafeGoalCount + 1 < result.thresholdGoalCount) {
            uint256 midGoalCount =
                result.lastSafeGoalCount + ((result.thresholdGoalCount - result.lastSafeGoalCount) / 2);
            uint256 gasUsed = _measureHistoricalRouteGas(midGoalCount, usesPendingHistoricalRoute);
            _emitGasMeasurement(scenario, midGoalCount, gasUsed);

            if (gasUsed > targetGas) {
                result.thresholdGoalCount = midGoalCount;
                result.thresholdGasUsed = gasUsed;
            } else {
                result.lastSafeGoalCount = midGoalCount;
                result.lastSafeGasUsed = gasUsed;
            }
        }

        emit HistoricalRoutingThresholdFound(
            scenario,
            targetGas,
            result.thresholdGoalCount,
            result.thresholdGasUsed,
            result.lastSafeGoalCount,
            result.lastSafeGasUsed
        );
    }

    function _measureHistoricalRouteGas(uint256 goalCount, bool usesPendingHistoricalRoute)
        internal
        returns (uint256 gasUsed)
    {
        if (goalCount == 0) revert("goal count must be positive");

        Scenario memory scenario = _deployHistoricalRoutingScenario(goalCount);
        uint256 sourceAmount = goalCount * TOKENS_PER_GOAL;

        if (usesPendingHistoricalRoute) {
            vm.prank(scenario.routeSetter);
            scenario.hook.beginPendingHistoricalRoute(scenario.beneficiary, scenario.beneficiary);
        }

        scenario.token.mint(address(scenario.hook), sourceAmount);

        // This is a lower-bound gas profile: setup and the measured call share one test transaction, so some storage
        // and account accesses are warmer here than they would be on a fresh user-originated call.
        vm.prank(scenario.controller);
        uint256 gasBefore = gasleft();
        scenario.hook.processSplitWith(_context(address(scenario.token), sourceAmount));
        gasUsed = gasBefore - gasleft();
    }

    function _deployHistoricalRoutingScenario(uint256 goalCount) internal returns (Scenario memory scenario) {
        address controller = vm.addr(goalCount + 1);
        address routeSetter = address(new CobuildSplitHookRouteSetterStub());
        address beneficiary = vm.addr(goalCount + 20_000);

        CobuildSplitHookMockToken token = new CobuildSplitHookMockToken("Community", "COMM");
        CobuildSplitHookMockDirectory directory = new CobuildSplitHookMockDirectory();
        GoalDeploymentRegistry goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        CobuildSplitHookMockGoalRegistry goalRegistry = new CobuildSplitHookMockGoalRegistry(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(token)
        );

        CobuildSplitHook hook = _deployHook(directory, token, routeSetter, goalRegistry);
        directory.setController(COMMUNITY_REVNET_ID, controller);

        for (uint256 i = 0; i < goalCount; i++) {
            uint256 goalId = GOAL_ID_BASE + i + 1;
            CobuildSplitHookMockGoalTerminal terminal = new CobuildSplitHookMockGoalTerminal(token);
            CobuildSplitHookMockGoalTreasury treasury = new CobuildSplitHookMockGoalTreasury(goalId);
            goalDeploymentRegistry.registerGoal(goalId, address(treasury));
            directory.setPrimaryTerminal(goalId, address(token), IJBTerminal(address(terminal)));
            goalRegistry.setGoalSelectable(goalId, true);
        }

        _seedHistoricalVolumes(hook, goalCount);
        assertEq(hook.observedVolumeOf(GOAL_ID_BASE + 1), TOKENS_PER_GOAL);

        scenario = Scenario({
            hook: hook, token: token, controller: controller, routeSetter: routeSetter, beneficiary: beneficiary
        });
    }

    function _deployHook(
        CobuildSplitHookMockDirectory directory,
        CobuildSplitHookMockToken token,
        address routeSetter,
        CobuildSplitHookMockGoalRegistry goalRegistry
    ) internal returns (CobuildSplitHook deployedHook) {
        CobuildSplitHook implementation = new CobuildSplitHook();
        deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));
        deployedHook.initialize(
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(token),
            routeSetter,
            ICommunityGoalRegistry(address(goalRegistry))
        );
    }

    function _seedHistoricalVolumes(CobuildSplitHook hook, uint256 goalCount) internal {
        for (uint256 i = 0; i < goalCount; i++) {
            uint256 goalId = GOAL_ID_BASE + i + 1;
            vm.store(
                address(hook),
                keccak256(abi.encode(goalId, uint256(OBSERVED_VOLUME_MAPPING_SLOT))),
                bytes32(TOKENS_PER_GOAL)
            );
        }
    }

    function _context(address token, uint256 amount) internal pure returns (JBSplitHookContext memory context) {
        context = JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: COMMUNITY_REVNET_ID,
            groupId: RESERVED_TOKENS_GROUP_ID,
            split: JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            })
        });
    }

    function _emitGasMeasurement(bytes32 scenario, uint256 goalCount, uint256 gasUsed) internal {
        emit HistoricalRoutingGasMeasured(scenario, goalCount, gasUsed);
        emit log_named_uint("historical_route_goal_count", goalCount);
        emit log_named_uint("historical_route_gas_used", gasUsed);
    }
}
