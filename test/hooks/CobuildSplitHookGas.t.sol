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
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
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
    uint256 internal constant PAGINATED_FLUSH_GOAL_COUNT = 16;
    uint256 internal constant TOKENS_PER_GOAL = 1e18;
    uint256 internal constant OBSERVED_VOLUME_MAPPING_SLOT = 6;

    event HistoricalRoutingGasMeasured(bytes32 indexed scenario, uint256 indexed goalCount, uint256 gasUsed);

    struct Scenario {
        CobuildSplitHook hook;
        CobuildSplitHookMockToken token;
        address controller;
    }

    function test_gasProfile_directReservedCallbackDefersBacklog_staysBelow16mAt512Goals() public {
        Scenario memory scenario = _deployHistoricalRoutingScenario(DEFAULT_MAX_GOAL_COUNT);
        uint256 sourceAmount = DEFAULT_MAX_GOAL_COUNT * TOKENS_PER_GOAL;

        scenario.token.mint(address(scenario.hook), sourceAmount);

        vm.prank(scenario.controller);
        uint256 gasBefore = gasleft();
        scenario.hook.processSplitWith(_context(address(scenario.token), sourceAmount));
        uint256 gasUsed = gasBefore - gasleft();

        emit HistoricalRoutingGasMeasured(keccak256("direct_reserved_callback_defers_backlog"), DEFAULT_MAX_GOAL_COUNT, gasUsed);

        assertEq(scenario.hook.historicalBacklogAmount(), sourceAmount);
        assertLt(gasUsed, GAS_TARGET_16M, "direct defer gas");
    }

    function test_gasProfile_paginatedHistoricalBacklogFlush_staysBelow16mAt512Goals() public {
        Scenario memory scenario = _deployHistoricalRoutingScenario(DEFAULT_MAX_GOAL_COUNT);
        uint256 sourceAmount = DEFAULT_MAX_GOAL_COUNT * TOKENS_PER_GOAL;

        scenario.token.mint(address(scenario.hook), sourceAmount);

        vm.prank(scenario.controller);
        scenario.hook.processSplitWith(_context(address(scenario.token), sourceAmount));

        assertEq(scenario.hook.historicalBacklogAmount(), sourceAmount);

        uint256 gasBefore = gasleft();
        uint256 routedAmount = scenario.hook.flushHistoricalBacklog(PAGINATED_FLUSH_GOAL_COUNT);
        uint256 gasUsed = gasBefore - gasleft();

        emit HistoricalRoutingGasMeasured(keccak256("paginated_historical_backlog_treasuries"), DEFAULT_MAX_GOAL_COUNT, gasUsed);

        assertEq(routedAmount, PAGINATED_FLUSH_GOAL_COUNT * TOKENS_PER_GOAL);
        assertEq(
            scenario.hook.historicalBacklogAmount(),
            (DEFAULT_MAX_GOAL_COUNT - PAGINATED_FLUSH_GOAL_COUNT) * TOKENS_PER_GOAL
        );
        assertLt(gasUsed, GAS_TARGET_16M, "paginated backlog gas");
    }

    function _deployHistoricalRoutingScenario(uint256 goalCount) internal returns (Scenario memory scenario) {
        address controller = vm.addr(goalCount + 1);
        address routeSetter = address(new CobuildSplitHookRouteSetterStub());

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

        scenario = Scenario({hook: hook, token: token, controller: controller});
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
                percent: JBConstants.SPLITS_TOTAL_PERCENT,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            })
        });
    }
}
