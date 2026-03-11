// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "../interfaces/IAllocationKeyAccountResolver.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetStackTopologyReader } from "../interfaces/IBudgetStackTopologyReader.sol";
import { ICustomFlow, IFlow } from "../interfaces/IFlow.sol";
import { IGoalLedgerStrategy } from "../interfaces/IGoalLedgerStrategy.sol";
import { IStakeVault } from "../interfaces/IStakeVault.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { ITreasuryAuthority } from "../interfaces/ITreasuryAuthority.sol";
import { FlowProtocolConstants } from "./FlowProtocolConstants.sol";

library GoalFlowLedgerMode {
    uint256 private constant _SYNC_GAS_HEADROOM_BPS = 1_000; // Keep 10% of entry gas as headroom.
    uint256 private constant _SYNC_MIN_FINALIZATION_GAS = 400_000;

    struct ValidationCache {
        address validatedLedger;
        address validatedGoalTreasury;
        address validatedStakeVault;
    }

    struct ChildSyncTarget {
        address childFlow;
        address childStrategy;
        uint256 allocationKey;
        bytes32 expectedCommit;
    }

    struct ChildSyncAction {
        address budgetTreasury;
        ChildSyncTarget target;
        bytes32 skipReason;
    }

    struct ChildSyncExecution {
        address budgetTreasury;
        address childFlow;
        address childStrategy;
        uint256 allocationKey;
        bytes32 skipReason;
        bool attempted;
        bool success;
        bytes failureReason;
    }

    struct GoalTreasuryWiring {
        address goalTreasury;
        address configuredFlow;
        address stakeVault;
    }

    struct LedgerValidationResult {
        address goalTreasury;
        address stakeVault;
        bool cacheHit;
    }

    struct InitLedgerValidationResult {
        address goalTreasury;
        address stakeVault;
        bool bootstrapAllowed;
    }

    error INVALID_ALLOCATION_LEDGER_STRATEGY(
        address strategy,
        address expectedStakeVault,
        address configuredStakeVault
    );
    error INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER(address strategy);
    error CHILD_SYNC_TARGET_UNAVAILABLE(address budgetTreasury);

    bytes32 internal constant CHILD_SYNC_SKIP_NO_COMMITMENT = "NO_COMMITMENT";
    bytes32 internal constant CHILD_SYNC_SKIP_TARGET_UNAVAILABLE = "TARGET_UNAVAILABLE";
    bytes32 internal constant CHILD_SYNC_SKIP_GAS_BUDGET = "GAS_BUDGET";

    function syncMinGasReserve(uint256 gasAtStart) internal pure returns (uint256) {
        return
            (gasAtStart * _SYNC_GAS_HEADROOM_BPS) /
            FlowProtocolConstants.BPS_SCALE_UINT256 +
            _SYNC_MIN_FINALIZATION_GAS;
    }

    function childSyncGasStipend() internal pure returns (uint256) {
        return FlowProtocolConstants.GOAL_LEDGER_CHILD_SYNC_GAS_STIPEND;
    }

    function validateOrRevert(
        IAllocationStrategy strategy,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) internal returns (address goalTreasury, address stakeVault) {
        LedgerValidationResult memory result = _validatedLedger(strategy, cache, ledger, expectedFlow);
        goalTreasury = result.goalTreasury;
        stakeVault = result.stakeVault;
        if (result.cacheHit) return (goalTreasury, stakeVault);

        cache.validatedLedger = ledger;
        cache.validatedGoalTreasury = goalTreasury;
        cache.validatedStakeVault = stakeVault;
    }

    function validateOrRevertView(
        IAllocationStrategy strategy,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) internal view returns (address goalTreasury, address stakeVault) {
        LedgerValidationResult memory result = _validatedLedger(strategy, cache, ledger, expectedFlow);
        return (result.goalTreasury, result.stakeVault);
    }

    function validateForInitializeOrRevertView(
        IAllocationStrategy strategy,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) internal view returns (address goalTreasury, address stakeVault) {
        if (cache.validatedLedger == ledger) {
            return (cache.validatedGoalTreasury, cache.validatedStakeVault);
        }

        InitLedgerValidationResult memory result = _validateLedgerInitWiring(ledger, expectedFlow);
        goalTreasury = result.goalTreasury;
        if (result.bootstrapAllowed) {
            return (goalTreasury, address(0));
        }

        stakeVault = result.stakeVault;
        _verifyBudgetStakeLedgerStrategy(strategy, stakeVault);
    }

    function prepareCheckpointContextView(
        IAllocationStrategy strategy,
        ValidationCache storage cache,
        address ledger,
        address account,
        address expectedFlow
    ) internal view returns (uint256 newWeight, bool shouldCheckpoint) {
        if (ledger == address(0)) return (0, false);

        (address treasury, address stakeVault) = validateOrRevertView(strategy, cache, ledger, expectedFlow);
        if (!_shouldCheckpointWithValidatedContext(ledger, treasury, stakeVault)) return (0, false);

        try IStakeVault(stakeVault).weightOf(account) returns (uint256 weight_) {
            newWeight = weight_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(treasury, stakeVault);
        }

        return (newWeight, true);
    }

    function prepareCheckpointContextFromCommittedWeight(
        IAllocationStrategy strategy,
        ValidationCache storage cache,
        address ledger,
        uint256 committedWeight,
        address expectedFlow
    ) internal returns (uint256 resolvedWeight, bool shouldCheckpoint) {
        if (ledger == address(0)) return (0, false);

        (address treasury, address stakeVault) = validateOrRevert(strategy, cache, ledger, expectedFlow);
        if (!_shouldCheckpointWithValidatedContext(ledger, treasury, stakeVault)) return (0, false);

        resolvedWeight = committedWeight;
        shouldCheckpoint = true;
    }

    function buildChildSyncActions(
        address account,
        address[] memory budgetTreasuries
    ) internal view returns (ChildSyncAction[] memory actions) {
        uint256 budgetCount = budgetTreasuries.length;
        actions = new ChildSyncAction[](budgetCount);

        for (uint256 i = 0; i < budgetCount; ) {
            address budgetTreasury = budgetTreasuries[i];
            ChildSyncAction memory action;
            action.budgetTreasury = budgetTreasury;

            bool resolved;
            (action.target, resolved) = _resolveChildSyncTarget(account, budgetTreasury);
            if (!resolved) {
                action.skipReason = CHILD_SYNC_SKIP_TARGET_UNAVAILABLE;
            } else if (action.target.expectedCommit == bytes32(0)) {
                action.skipReason = CHILD_SYNC_SKIP_NO_COMMITMENT;
            }

            actions[i] = action;

            unchecked {
                ++i;
            }
        }
    }

    function executeChildSyncBestEffort(
        ChildSyncAction[] memory actions
    ) internal returns (ChildSyncExecution[] memory executions) {
        uint256 actionCount = actions.length;
        executions = new ChildSyncExecution[](actionCount);
        uint256 gasAtStart = gasleft();
        uint256 childSyncStipend = childSyncGasStipend();
        uint256 minGasReserve = syncMinGasReserve(gasAtStart);
        uint256 minGasForChildSyncAttempt = minGasReserve + childSyncStipend;

        for (uint256 i = 0; i < actionCount; ) {
            ChildSyncAction memory action = actions[i];
            ChildSyncExecution memory execution;
            execution.budgetTreasury = action.budgetTreasury;
            execution.childFlow = action.target.childFlow;
            execution.childStrategy = action.target.childStrategy;
            execution.allocationKey = action.target.allocationKey;
            execution.skipReason = action.skipReason;

            if (action.skipReason == bytes32(0)) {
                if (gasleft() <= minGasForChildSyncAttempt) {
                    execution.skipReason = CHILD_SYNC_SKIP_GAS_BUDGET;
                } else {
                    execution.attempted = true;
                    try
                        ICustomFlow(action.target.childFlow).syncAllocation{ gas: childSyncStipend }(
                            action.target.allocationKey
                        )
                    {
                        execution.success = true;
                    } catch (bytes memory reason) {
                        execution.success = false;
                        execution.failureReason = reason;
                    }
                }
            }

            executions[i] = execution;
            unchecked {
                ++i;
            }
        }
    }

    function requiredChildSyncRequirements(
        address account,
        address[] memory budgetTreasuries
    ) internal view returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        uint256 budgetCount = budgetTreasuries.length;
        if (budgetCount == 0) return new ICustomFlow.ChildSyncRequirement[](0);

        ICustomFlow.ChildSyncRequirement[] memory tmp = new ICustomFlow.ChildSyncRequirement[](budgetCount);
        uint256 count;

        for (uint256 i = 0; i < budgetCount; ) {
            address budgetTreasury = budgetTreasuries[i];
            (ChildSyncTarget memory target, bool resolved) = _resolveChildSyncTarget(account, budgetTreasury);

            if (!resolved) revert CHILD_SYNC_TARGET_UNAVAILABLE(budgetTreasury);

            if (target.expectedCommit != bytes32(0)) {
                tmp[count] = ICustomFlow.ChildSyncRequirement({
                    budgetTreasury: budgetTreasury,
                    childFlow: target.childFlow,
                    childStrategy: target.childStrategy,
                    allocationKey: target.allocationKey,
                    expectedCommit: target.expectedCommit
                });
                unchecked {
                    ++count;
                }
            }

            unchecked {
                ++i;
            }
        }

        reqs = new ICustomFlow.ChildSyncRequirement[](count);
        for (uint256 i = 0; i < count; ) {
            reqs[i] = tmp[i];
            unchecked {
                ++i;
            }
        }
    }

    function _goalTreasuryResolvedOrRevert(address ledger, address treasury) private view returns (bool goalResolved) {
        try IGoalTreasury(treasury).resolved() returns (bool resolved_) {
            goalResolved = resolved_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledger, treasury);
        }
    }

    function _validatedLedger(
        IAllocationStrategy strategy,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) private view returns (LedgerValidationResult memory result) {
        if (cache.validatedLedger == ledger) {
            result.goalTreasury = cache.validatedGoalTreasury;
            result.stakeVault = cache.validatedStakeVault;
            result.cacheHit = true;
            return result;
        }

        (result.goalTreasury, result.stakeVault) = _validateLedgerWiringAndStrategy(strategy, ledger, expectedFlow);
    }

    function _shouldCheckpointWithValidatedContext(
        address ledger,
        address treasury,
        address stakeVault
    ) private view returns (bool shouldCheckpoint) {
        if (_goalTreasuryResolvedOrRevert(ledger, treasury)) return false;

        try IStakeVault(stakeVault).goalResolved() returns (bool goalResolved) {
            return !goalResolved;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(treasury, stakeVault);
        }
    }

    function _resolveChildSyncTarget(
        address account,
        address budgetTreasury
    ) private view returns (ChildSyncTarget memory target, bool resolved) {
        if (budgetTreasury.code.length == 0) return (target, false);

        IBudgetStackTopologyReader.BudgetStackTopology memory topology;
        bool active;
        (topology, active, resolved) = _readBudgetStackTopology(budgetTreasury);
        if (!resolved || !active) return (target, false);

        address childFlow = topology.childFlow;
        if (childFlow.code.length == 0) return (target, false);

        address childStrategy = topology.strategy;
        if (childStrategy.code.length == 0) return (target, false);
        if (!_childFlowUsesExpectedStrategy(childFlow, childStrategy)) return (target, false);

        uint256 allocationKey;
        try IAllocationStrategy(childStrategy).allocationKey(account, bytes("")) returns (uint256 allocationKey_) {
            allocationKey = allocationKey_;
        } catch {
            return (target, false);
        }

        address resolvedAccount;
        try IAllocationKeyAccountResolver(childStrategy).accountForAllocationKey(allocationKey) returns (
            address resolvedAccount_
        ) {
            resolvedAccount = resolvedAccount_;
        } catch {
            return (target, false);
        }
        if (resolvedAccount != account) return (target, false);

        bytes32 commit;
        try IFlow(childFlow).getAllocationCommitment(childStrategy, allocationKey) returns (bytes32 commit_) {
            commit = commit_;
        } catch {
            return (target, false);
        }

        target = ChildSyncTarget({
            childFlow: childFlow,
            childStrategy: childStrategy,
            allocationKey: allocationKey,
            expectedCommit: commit
        });
        return (target, true);
    }

    function _readBudgetStackTopology(
        address budgetTreasury
    ) private view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active, bool ok) {
        address topologyRegistry;
        try ITreasuryAuthority(budgetTreasury).authority() returns (address authority_) {
            topologyRegistry = authority_;
        } catch {
            return (topology, false, false);
        }
        if (topologyRegistry.code.length == 0) return (topology, false, false);

        try IBudgetStackTopologyReader(topologyRegistry).budgetStackTopologyForBudgetTreasury(budgetTreasury) returns (
            IBudgetStackTopologyReader.BudgetStackTopology memory topology_,
            bool active_
        ) {
            topology = topology_;
            active = active_;
        } catch {
            return (topology, false, false);
        }

        ok = topology.budgetTreasury == budgetTreasury;
    }

    function _childFlowUsesExpectedStrategy(
        address childFlow,
        address expectedStrategy
    ) private view returns (bool matches) {
        address configuredStrategy;
        try IFlow(childFlow).strategy() returns (IAllocationStrategy strategy_) {
            configuredStrategy = address(strategy_);
        } catch {
            return false;
        }
        return configuredStrategy == expectedStrategy;
    }

    function _validateLedgerWiringAndStrategy(
        IAllocationStrategy strategy,
        address ledger,
        address expectedFlow
    ) private view returns (address goalTreasury, address stakeVault) {
        GoalTreasuryWiring memory wiring = _readGoalTreasuryWiring(ledger);
        goalTreasury = wiring.goalTreasury;
        stakeVault = _requireRuntimeStakeVault(wiring, expectedFlow);
        _verifyBudgetStakeLedgerStrategy(strategy, stakeVault);
    }

    function _readGoalTreasuryWiring(address ledgerAddress) private view returns (GoalTreasuryWiring memory wiring) {
        if (ledgerAddress.code.length == 0) revert IFlow.INVALID_ALLOCATION_LEDGER(ledgerAddress);

        try IBudgetStakeLedger(ledgerAddress).goalTreasury() returns (address goalTreasury_) {
            wiring.goalTreasury = goalTreasury_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER(ledgerAddress);
        }

        if (wiring.goalTreasury == address(0) || wiring.goalTreasury.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, wiring.goalTreasury);
        }

        address configuredFlow;
        try IGoalTreasury(wiring.goalTreasury).flow() returns (address flow_) {
            configuredFlow = flow_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, wiring.goalTreasury);
        }
        wiring.configuredFlow = configuredFlow;

        address stakeVault;
        try IGoalTreasury(wiring.goalTreasury).stakeVault() returns (address stakeVault_) {
            stakeVault = stakeVault_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, wiring.goalTreasury);
        }
        wiring.stakeVault = stakeVault;
    }

    function _requireRuntimeStakeVault(
        GoalTreasuryWiring memory wiring,
        address expectedFlow
    ) private view returns (address stakeVault) {
        if (wiring.configuredFlow != expectedFlow) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_FLOW(expectedFlow, wiring.configuredFlow);
        }

        stakeVault = wiring.stakeVault;
        if (stakeVault == address(0) || stakeVault.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(wiring.goalTreasury, stakeVault);
        }
    }

    function _validateLedgerInitWiring(
        address ledgerAddress,
        address expectedFlow
    ) private view returns (InitLedgerValidationResult memory result) {
        GoalTreasuryWiring memory wiring = _readGoalTreasuryWiring(ledgerAddress);
        result.goalTreasury = wiring.goalTreasury;

        if (wiring.configuredFlow == address(0) && wiring.stakeVault == address(0)) {
            result.bootstrapAllowed = true;
            return result;
        }

        if (wiring.configuredFlow != expectedFlow) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_FLOW(expectedFlow, wiring.configuredFlow);
        }

        result.stakeVault = wiring.stakeVault;
        if (result.stakeVault == address(0) || result.stakeVault.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(wiring.goalTreasury, result.stakeVault);
        }
    }

    function _verifyBudgetStakeLedgerStrategy(IAllocationStrategy strategy, address expectedStakeVault) private view {
        address strategyAddress = address(strategy);
        if (strategyAddress == address(0) || strategyAddress.code.length == 0) {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategyAddress, expectedStakeVault, address(0));
        }

        IGoalLedgerStrategy strategyReader = IGoalLedgerStrategy(strategyAddress);
        address configuredStakeVault;
        try strategyReader.stakeVault() returns (address stakeVault_) {
            configuredStakeVault = stakeVault_;
        } catch {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategyAddress, expectedStakeVault, address(0));
        }

        if (configuredStakeVault != expectedStakeVault) {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategyAddress, expectedStakeVault, configuredStakeVault);
        }

        try strategyReader.accountForAllocationKey(1) returns (address account_) {
            if (account_ == address(0)) revert INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER(strategyAddress);
        } catch {
            revert INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER(strategyAddress);
        }

        try strategyReader.allocationKey(address(1), bytes("")) returns (uint256) {
            // no-op: successful probe confirms empty aux is accepted
        } catch {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategyAddress, expectedStakeVault, configuredStakeVault);
        }
    }
}
