// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "../interfaces/IAllocationKeyAccountResolver.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "../interfaces/IFlow.sol";
import { IGoalLedgerStrategy } from "../interfaces/IGoalLedgerStrategy.sol";
import { IGoalStakeVault } from "../interfaces/IGoalStakeVault.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { FlowProtocolConstants } from "./FlowProtocolConstants.sol";
import { FlowUnitMath } from "./FlowUnitMath.sol";
import { SortedRecipientMerge } from "./SortedRecipientMerge.sol";

library GoalFlowLedgerMode {
    uint256 private constant _BPS_SCALE = 10_000;
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
        return (gasAtStart * _SYNC_GAS_HEADROOM_BPS) / _BPS_SCALE + _SYNC_MIN_FINALIZATION_GAS;
    }

    function childSyncGasStipend() internal pure returns (uint256) {
        return FlowProtocolConstants.GOAL_LEDGER_CHILD_SYNC_GAS_STIPEND;
    }

    function budgetTreasurySyncGasStipend() internal pure returns (uint256) {
        return FlowProtocolConstants.GOAL_LEDGER_BUDGET_TREASURY_SYNC_GAS_STIPEND;
    }

    function validateOrRevert(
        IAllocationStrategy[] memory strategies,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) internal returns (address goalTreasury, address stakeVault) {
        if (cache.validatedLedger == ledger) {
            return (cache.validatedGoalTreasury, cache.validatedStakeVault);
        }

        (goalTreasury, stakeVault) = _validateLedgerWiringAndStrategy(strategies, ledger, expectedFlow);

        cache.validatedLedger = ledger;
        cache.validatedGoalTreasury = goalTreasury;
        cache.validatedStakeVault = stakeVault;
    }

    function validateOrRevertView(
        IAllocationStrategy[] memory strategies,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) internal view returns (address goalTreasury, address stakeVault) {
        if (cache.validatedLedger == ledger) {
            return (cache.validatedGoalTreasury, cache.validatedStakeVault);
        }

        (goalTreasury, stakeVault) = _validateLedgerWiringAndStrategy(strategies, ledger, expectedFlow);
    }

    function validateForInitializeOrRevertView(
        IAllocationStrategy[] memory strategies,
        ValidationCache storage cache,
        address ledger,
        address expectedFlow
    ) internal view returns (address goalTreasury, address stakeVault) {
        if (cache.validatedLedger == ledger) {
            return (cache.validatedGoalTreasury, cache.validatedStakeVault);
        }

        goalTreasury = _requireAllocationLedgerGoalTreasury(ledger);
        (bool bootstrapAllowed, address resolvedStakeVault) = _validateLedgerInitWiring(
            ledger,
            goalTreasury,
            expectedFlow
        );
        if (bootstrapAllowed) {
            return (goalTreasury, address(0));
        }

        stakeVault = resolvedStakeVault;
        _verifyBudgetStakeLedgerStrategy(strategies, stakeVault);
    }

    function detectBudgetDeltasCalldata(
        uint256 percentageScale,
        address ledger,
        uint256 prevWeight,
        bytes32[] calldata prevIds,
        uint32[] calldata prevAllocationScaled,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationScaled
    ) internal view returns (address[] memory budgetTreasuries) {
        if (ledger == address(0)) return new address[](0);
        return
            _detectBudgetDeltaTreasuriesCalldata(
                percentageScale,
                IBudgetStakeLedger(ledger),
                prevWeight,
                prevIds,
                prevAllocationScaled,
                newWeight,
                newRecipientIds,
                newAllocationScaled
            );
    }

    function prepareCheckpointContextView(
        IAllocationStrategy[] memory strategies,
        ValidationCache storage cache,
        address ledger,
        address account,
        address expectedFlow
    ) internal view returns (uint256 newWeight, bool shouldCheckpoint) {
        if (ledger == address(0)) return (0, false);

        (address treasury, address stakeVault) = validateOrRevertView(strategies, cache, ledger, expectedFlow);

        bool goalResolved;
        try IGoalStakeVault(stakeVault).goalResolved() returns (bool goalResolved_) {
            goalResolved = goalResolved_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(treasury, stakeVault);
        }
        if (goalResolved) {
            return (0, false);
        }

        try IGoalStakeVault(stakeVault).weightOf(account) returns (uint256 weight_) {
            newWeight = weight_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(treasury, stakeVault);
        }

        return (newWeight, true);
    }

    function prepareCheckpointContextFromCommittedWeight(
        IAllocationStrategy[] memory strategies,
        ValidationCache storage cache,
        address ledger,
        uint256 committedWeight,
        address expectedFlow
    ) internal returns (uint256 resolvedWeight, bool shouldCheckpoint) {
        if (ledger == address(0)) return (0, false);

        (address treasury, address stakeVault) = validateOrRevert(strategies, cache, ledger, expectedFlow);

        bool goalResolved;
        try IGoalStakeVault(stakeVault).goalResolved() returns (bool goalResolved_) {
            goalResolved = goalResolved_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(treasury, stakeVault);
        }
        if (goalResolved) {
            return (0, false);
        }

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
                            action.target.childStrategy,
                            action.target.allocationKey
                        )
                    {
                        execution.success = true;
                    } catch {
                        execution.success = false;
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

    function _detectBudgetDeltaTreasuriesCalldata(
        uint256 percentageScale,
        IBudgetStakeLedger ledgerReader,
        uint256 prevWeight,
        bytes32[] calldata prevIds,
        uint32[] calldata prevAllocationScaled,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationScaled
    ) private view returns (address[] memory budgetTreasuries) {
        uint256 oldLen = prevIds.length;
        uint256 newLen = newRecipientIds.length;
        if (oldLen == 0 && newLen == 0) return new address[](0);

        address[] memory tmp = new address[](oldLen + newLen);
        uint256 count;
        (SortedRecipientMerge.Cursor memory mergeCursor, ) = SortedRecipientMerge.init(
            prevIds,
            newRecipientIds,
            SortedRecipientMerge.Precondition.AssumeSorted
        );

        while (SortedRecipientMerge.hasNext(mergeCursor, oldLen, newLen)) {
            (
                SortedRecipientMerge.Step memory step,
                SortedRecipientMerge.Cursor memory nextCursor
            ) = SortedRecipientMerge.next(prevIds, newRecipientIds, mergeCursor);
            mergeCursor = nextCursor;

            bytes32 recipientId = step.recipientId;
            uint256 oldAllocated;
            uint256 newAllocated;

            if (step.hasOld) {
                oldAllocated = FlowUnitMath.effectiveAllocatedStake(
                    prevWeight,
                    prevAllocationScaled[step.oldIndex],
                    percentageScale
                );
            }

            if (step.hasNew) {
                newAllocated = FlowUnitMath.effectiveAllocatedStake(
                    newWeight,
                    newAllocationScaled[step.newIndex],
                    percentageScale
                );
            }

            if (oldAllocated == newAllocated) continue;

            address budgetTreasury = ledgerReader.budgetForRecipient(recipientId);
            if (budgetTreasury == address(0)) continue;

            tmp[count] = budgetTreasury;
            unchecked {
                ++count;
            }
        }

        budgetTreasuries = new address[](count);
        for (uint256 i = 0; i < count; ) {
            budgetTreasuries[i] = tmp[i];
            unchecked {
                ++i;
            }
        }
    }

    function _resolveChildSyncTarget(
        address account,
        address budgetTreasury
    ) private view returns (ChildSyncTarget memory target, bool resolved) {
        if (budgetTreasury.code.length == 0) return (target, false);

        address childFlow;
        try IBudgetTreasury(budgetTreasury).flow() returns (address flow_) {
            childFlow = flow_;
        } catch {
            return (target, false);
        }
        if (childFlow.code.length == 0) return (target, false);

        IAllocationStrategy[] memory childStrategies;
        try IFlow(childFlow).strategies() returns (IAllocationStrategy[] memory strategies_) {
            childStrategies = strategies_;
        } catch {
            return (target, false);
        }
        if (childStrategies.length != 1) return (target, false);

        address childStrategy = address(childStrategies[0]);
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

    function _validateLedgerWiringAndStrategy(
        IAllocationStrategy[] memory strategies,
        address ledger,
        address expectedFlow
    ) private view returns (address goalTreasury, address stakeVault) {
        goalTreasury = _requireAllocationLedgerGoalTreasury(ledger);
        stakeVault = _requireAllocationLedgerWiring(ledger, goalTreasury, expectedFlow);
        _verifyBudgetStakeLedgerStrategy(strategies, stakeVault);
    }

    function _requireAllocationLedgerGoalTreasury(address ledgerAddress) private view returns (address goalTreasury) {
        if (ledgerAddress.code.length == 0) revert IFlow.INVALID_ALLOCATION_LEDGER(ledgerAddress);

        try IBudgetStakeLedger(ledgerAddress).goalTreasury() returns (address goalTreasury_) {
            goalTreasury = goalTreasury_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER(ledgerAddress);
        }

        if (goalTreasury == address(0)) revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, address(0));
    }

    function _requireAllocationLedgerWiring(
        address ledgerAddress,
        address goalTreasury,
        address expectedFlow
    ) private view returns (address stakeVault) {
        if (goalTreasury.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, goalTreasury);
        }

        address configuredFlow;
        try IGoalTreasury(goalTreasury).flow() returns (address flow_) {
            configuredFlow = flow_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, goalTreasury);
        }
        if (configuredFlow != expectedFlow) revert IFlow.INVALID_ALLOCATION_LEDGER_FLOW(expectedFlow, configuredFlow);

        try IGoalTreasury(goalTreasury).stakeVault() returns (address stakeVault_) {
            stakeVault = stakeVault_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, goalTreasury);
        }

        if (stakeVault == address(0) || stakeVault.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(goalTreasury, stakeVault);
        }
    }

    function _validateLedgerInitWiring(
        address ledgerAddress,
        address goalTreasury,
        address expectedFlow
    ) private view returns (bool bootstrapAllowed, address stakeVault) {
        if (goalTreasury.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, goalTreasury);
        }

        address configuredFlow;
        try IGoalTreasury(goalTreasury).flow() returns (address flow_) {
            configuredFlow = flow_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, goalTreasury);
        }

        try IGoalTreasury(goalTreasury).stakeVault() returns (address stakeVault_) {
            stakeVault = stakeVault_;
        } catch {
            revert IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY(ledgerAddress, goalTreasury);
        }

        if (configuredFlow == address(0) && stakeVault == address(0)) {
            return (true, address(0));
        }

        if (configuredFlow != expectedFlow) revert IFlow.INVALID_ALLOCATION_LEDGER_FLOW(expectedFlow, configuredFlow);

        if (stakeVault == address(0) || stakeVault.code.length == 0) {
            revert IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT(goalTreasury, stakeVault);
        }
    }

    function _verifyBudgetStakeLedgerStrategy(
        IAllocationStrategy[] memory strategies,
        address expectedStakeVault
    ) private view {
        uint256 strategyCount = strategies.length;
        if (strategyCount != 1) revert IFlow.ALLOCATION_LEDGER_REQUIRES_SINGLE_STRATEGY(strategyCount);

        address strategy = address(strategies[0]);
        IGoalLedgerStrategy strategyReader = IGoalLedgerStrategy(strategy);
        address configuredStakeVault;
        try strategyReader.stakeVault() returns (address stakeVault_) {
            configuredStakeVault = stakeVault_;
        } catch {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategy, expectedStakeVault, address(0));
        }

        if (configuredStakeVault != expectedStakeVault) {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategy, expectedStakeVault, configuredStakeVault);
        }

        try strategyReader.accountForAllocationKey(1) returns (address account_) {
            if (account_ == address(0)) revert INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER(strategy);
        } catch {
            revert INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER(strategy);
        }

        try strategyReader.allocationKey(address(1), bytes("")) returns (uint256) {
            // no-op: successful probe confirms empty aux is accepted
        } catch {
            revert INVALID_ALLOCATION_LEDGER_STRATEGY(strategy, expectedStakeVault, configuredStakeVault);
        }
    }
}
