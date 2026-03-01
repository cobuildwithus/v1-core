// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { FlowUnitMath } from "../library/FlowUnitMath.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract BudgetStakeLedger is IBudgetStakeLedger {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Checkpoints for Checkpoints.Trace224;

    struct UserBudgetCheckpoint {
        uint256 allocatedStake;
        uint64 lastCheckpoint;
    }

    struct BudgetCheckpoint {
        uint256 totalAllocatedStake;
        uint64 lastCheckpoint;
    }

    struct BudgetInfo {
        bool isTracked;
        uint64 removedAt;
        uint64 activatedAt;
    }

    struct AllocationMergeContext {
        address account;
        uint256 prevWeight;
        bytes32[] prevRecipientIds;
        uint32[] prevScaled;
        uint256 newWeight;
        bytes32[] newRecipientIds;
        uint32[] newScaled;
        uint64 nowTs;
    }

    address public immutable override goalTreasury;

    mapping(address => mapping(address => UserBudgetCheckpoint)) private _userBudgetCheckpoints;
    mapping(address => BudgetCheckpoint) private _budgetCheckpoints;
    mapping(address => BudgetInfo) private _budgetInfo;
    mapping(bytes32 => address) private _budgetByRecipientId;

    EnumerableSet.AddressSet private _trackedBudgets;
    mapping(address => mapping(address => Checkpoints.Trace224)) private _userAllocatedStakeCheckpoints;
    mapping(address => Checkpoints.Trace224) private _userAllocationWeightCheckpoints;

    constructor(address goalTreasury_) {
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        goalTreasury = goalTreasury_;
    }

    function getPastUserAllocatedStakeOnBudget(
        address account,
        address budget,
        uint256 blockNumber
    ) external view override returns (uint256) {
        if (blockNumber >= block.number) revert BLOCK_NOT_YET_MINED();
        return _userAllocatedStakeCheckpoints[account][budget].upperLookupRecent(SafeCast.toUint32(blockNumber));
    }

    function getPastUserAllocationWeight(
        address account,
        uint256 blockNumber
    ) external view override returns (uint256) {
        if (blockNumber >= block.number) revert BLOCK_NOT_YET_MINED();
        return _userAllocationWeightCheckpoints[account].upperLookupRecent(SafeCast.toUint32(blockNumber));
    }

    modifier onlyGoalFlow() {
        address goalFlow = _requireGoalFlow();
        if (msg.sender == goalFlow) {
            _;
            return;
        }

        if (msg.sender != IFlow(goalFlow).allocationPipeline()) revert ONLY_GOAL_FLOW();
        _;
    }

    modifier onlyBudgetRegistryManager() {
        if (msg.sender != IFlow(_requireGoalFlow()).recipientAdmin()) revert ONLY_BUDGET_REGISTRY_MANAGER();
        _;
    }

    function checkpointAllocation(
        address account,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevScaled,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newScaled
    ) external override onlyGoalFlow {
        if (IGoalTreasury(goalTreasury).resolved()) return;
        if (account == address(0)) revert ADDRESS_ZERO();
        if (prevRecipientIds.length != prevScaled.length) revert INVALID_CHECKPOINT_DATA();
        if (newRecipientIds.length != newScaled.length) revert INVALID_CHECKPOINT_DATA();

        if (prevWeight != newWeight) {
            _userAllocationWeightCheckpoints[account].push(
                SafeCast.toUint32(block.number),
                SafeCast.toUint224(newWeight)
            );
        }
        AllocationMergeContext memory ctx = AllocationMergeContext({
            account: account,
            prevWeight: prevWeight,
            prevRecipientIds: prevRecipientIds,
            prevScaled: prevScaled,
            newWeight: newWeight,
            newRecipientIds: newRecipientIds,
            newScaled: newScaled,
            nowTs: uint64(block.timestamp)
        });
        _checkpointAllocationMemory(ctx);
    }

    function registerBudget(bytes32 recipientId, address budget) external override onlyBudgetRegistryManager {
        if (budget == address(0)) revert ADDRESS_ZERO();
        uint64 activatedAt = _validateBudgetForRegistration(budget);

        address existing = _budgetByRecipientId[recipientId];
        if (existing != address(0) && existing != budget) revert BUDGET_ALREADY_REGISTERED();
        if (existing == budget) return;
        BudgetInfo storage info = _budgetInfo[budget];
        if (info.isTracked) revert BUDGET_ALREADY_REGISTERED();

        _budgetByRecipientId[recipientId] = budget;
        info.isTracked = true;
        if (activatedAt != 0) info.activatedAt = activatedAt;
        _trackedBudgets.add(budget);

        emit BudgetRegistered(recipientId, budget);
    }

    function removeBudget(bytes32 recipientId) external override onlyBudgetRegistryManager {
        address budget = _budgetByRecipientId[recipientId];
        if (budget == address(0)) return;

        delete _budgetByRecipientId[recipientId];
        BudgetInfo storage info = _budgetInfo[budget];
        if (info.removedAt == 0) {
            info.removedAt = uint64(block.timestamp);
        }
        info.isTracked = false;
        _trackedBudgets.remove(budget);
        emit BudgetRemoved(recipientId, budget);
    }

    function budgetForRecipient(bytes32 recipientId) external view override returns (address) {
        return _budgetByRecipientId[recipientId];
    }

    function trackedBudgetCount() external view override returns (uint256) {
        return _trackedBudgets.length();
    }

    function allTrackedBudgetsResolved() external view override returns (bool) {
        uint256 trackedCount = _trackedBudgets.length();
        for (uint256 i = 0; i < trackedCount; ) {
            if (_effectiveBudgetResolvedOrRemovedAt(_trackedBudgets.at(i)) == 0) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function trackedBudgetAt(uint256 index) external view override returns (address) {
        return _trackedBudgets.at(index);
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view override returns (uint256) {
        return _userBudgetCheckpoints[account][budget].allocatedStake;
    }

    function budgetTotalAllocatedStake(address budget) external view override returns (uint256) {
        return _budgetCheckpoints[budget].totalAllocatedStake;
    }

    function budgetInfo(address budget) external view override returns (BudgetInfoView memory info) {
        BudgetInfo storage budgetInfo_ = _budgetInfo[budget];
        info.isTracked = budgetInfo_.isTracked;
        info.removedAt = budgetInfo_.removedAt;
        info.activatedAt = _activatedAtForBudgetInfo(budget, budgetInfo_);
        info.resolvedOrRemovedAt = _effectiveBudgetResolvedOrRemovedAt(budget);
    }

    function userBudgetCheckpoint(
        address account,
        address budget
    ) external view override returns (UserBudgetCheckpointView memory checkpoint) {
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];
        checkpoint.allocatedStake = userCheckpoint.allocatedStake;
        checkpoint.lastCheckpoint = userCheckpoint.lastCheckpoint;
    }

    function budgetCheckpoint(address budget) external view override returns (BudgetCheckpointView memory checkpoint) {
        BudgetCheckpoint storage budgetCheckpoint_ = _budgetCheckpoints[budget];
        checkpoint.totalAllocatedStake = budgetCheckpoint_.totalAllocatedStake;
        checkpoint.lastCheckpoint = budgetCheckpoint_.lastCheckpoint;
    }

    function trackedBudgetSlice(
        uint256 start,
        uint256 count
    ) external view override returns (TrackedBudgetSummary[] memory summaries) {
        uint256 total = _trackedBudgets.length();
        if (start >= total || count == 0) return new TrackedBudgetSummary[](0);

        uint256 endExclusive = _boundedEndExclusive(start, count, total);
        uint256 length = endExclusive - start;
        summaries = new TrackedBudgetSummary[](length);

        for (uint256 i = 0; i < length; ) {
            address budget = _trackedBudgets.at(start + i);
            summaries[i] = TrackedBudgetSummary({
                budget: budget,
                resolvedOrRemovedAt: _effectiveBudgetResolvedOrRemovedAt(budget),
                totalAllocatedStake: _budgetCheckpoints[budget].totalAllocatedStake
            });
            unchecked {
                ++i;
            }
        }
    }

    function _checkpointBudgetAllocation(
        address account,
        address budget,
        uint256 oldAllocated,
        uint256 newAllocated,
        uint64 nowTs
    ) internal {
        BudgetCheckpoint storage budgetCheckpointData = _budgetCheckpoints[budget];
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];

        uint256 userStoredAllocated = userCheckpoint.allocatedStake;
        if (userStoredAllocated != oldAllocated) {
            revert ALLOCATION_DRIFT(account, budget, userStoredAllocated, oldAllocated);
        }

        if (newAllocated > oldAllocated) {
            budgetCheckpointData.totalAllocatedStake += newAllocated - oldAllocated;
        } else {
            uint256 allocatedDecrease = oldAllocated - newAllocated;
            uint256 totalAllocated = budgetCheckpointData.totalAllocatedStake;
            if (allocatedDecrease > totalAllocated) {
                revert TOTAL_ALLOCATED_UNDERFLOW(budget, totalAllocated, allocatedDecrease);
            }
            budgetCheckpointData.totalAllocatedStake = totalAllocated - allocatedDecrease;
        }

        userCheckpoint.allocatedStake = newAllocated;
        userCheckpoint.lastCheckpoint = nowTs;
        budgetCheckpointData.lastCheckpoint = nowTs;

        if (newAllocated != oldAllocated) {
            _userAllocatedStakeCheckpoints[account][budget].push(
                SafeCast.toUint32(block.number),
                SafeCast.toUint224(newAllocated)
            );
        }

        emit AllocationCheckpointed(account, budget, newAllocated, nowTs);
    }

    function _checkpointAllocationMemory(AllocationMergeContext memory ctx) internal {
        uint256 oldLen = ctx.prevRecipientIds.length;
        uint256 newLen = ctx.newRecipientIds.length;
        uint256 oldIndex;
        uint256 newIndex;

        while (oldIndex < oldLen || newIndex < newLen) {
            bytes32 oldRecipientId =
                oldIndex < oldLen ? ctx.prevRecipientIds[oldIndex] : bytes32(type(uint256).max);
            bytes32 newRecipientId =
                newIndex < newLen ? ctx.newRecipientIds[newIndex] : bytes32(type(uint256).max);

            bytes32 recipientId;
            bool hasOld;
            bool hasNew;
            uint256 oldScaledIndex;
            uint256 newScaledIndex;

            if (oldRecipientId == newRecipientId) {
                recipientId = oldRecipientId;
                hasOld = true;
                hasNew = true;
                oldScaledIndex = oldIndex;
                newScaledIndex = newIndex;
                unchecked {
                    ++oldIndex;
                    ++newIndex;
                }
            } else if (uint256(oldRecipientId) < uint256(newRecipientId)) {
                recipientId = oldRecipientId;
                hasOld = true;
                oldScaledIndex = oldIndex;
                unchecked {
                    ++oldIndex;
                }
            } else {
                recipientId = newRecipientId;
                hasNew = true;
                newScaledIndex = newIndex;
                unchecked {
                    ++newIndex;
                }
            }

            _processMergeStep(
                ctx,
                recipientId,
                hasOld,
                hasNew,
                oldScaledIndex,
                newScaledIndex
            );
        }
    }

    function _processMergeStep(
        AllocationMergeContext memory ctx,
        bytes32 recipientId,
        bool hasOld,
        bool hasNew,
        uint256 oldScaledIndex,
        uint256 newScaledIndex
    ) internal {
        address budget = _budgetByRecipientId[recipientId];
        if (budget == address(0)) return;

        uint256 oldAllocated;
        uint256 newAllocated;
        if (hasOld) {
            oldAllocated = _effectiveAllocatedStake(ctx.prevWeight, ctx.prevScaled[oldScaledIndex]);
        }
        if (hasNew) {
            newAllocated = _effectiveAllocatedStake(ctx.newWeight, ctx.newScaled[newScaledIndex]);
        }
        if (oldAllocated == newAllocated) return;

        _checkpointBudgetAllocation(ctx.account, budget, oldAllocated, newAllocated, ctx.nowTs);
    }

    function _boundedEndExclusive(
        uint256 start,
        uint256 count,
        uint256 total
    ) internal pure returns (uint256 endExclusive) {
        endExclusive = start + count;
        if (endExclusive > total || endExclusive < start) {
            endExclusive = total;
        }
    }

    function _effectiveAllocatedStake(uint256 weight, uint32 scaled) internal pure returns (uint256) {
        return FlowUnitMath.effectiveAllocatedStake(weight, scaled, FlowProtocolConstants.PPM_SCALE_UINT256);
    }

    function _validateBudgetForRegistration(address budget) internal view returns (uint64 activatedAt) {
        if (budget.code.length == 0) revert INVALID_BUDGET();

        address goalFlow = _goalFlow();
        if (goalFlow == address(0)) revert INVALID_BUDGET();

        IBudgetTreasury budgetTreasury = IBudgetTreasury(budget);
        address budgetFlow;
        try budgetTreasury.flow() returns (address budgetFlow_) {
            budgetFlow = budgetFlow_;
        } catch {
            revert INVALID_BUDGET();
        }
        if (budgetFlow == address(0) || budgetFlow.code.length == 0) revert INVALID_BUDGET();

        try IFlow(budgetFlow).parent() returns (address parentFlow) {
            if (parentFlow != goalFlow) revert INVALID_BUDGET();
        } catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.executionDuration() returns (uint64 executionDuration_) {
            if (executionDuration_ == 0) revert INVALID_BUDGET();
        } catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.fundingDeadline() returns (uint64 fundingDeadline_) {
            if (fundingDeadline_ == 0) revert INVALID_BUDGET();
        } catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.activatedAt() returns (uint64 activatedAt_) {
            activatedAt = activatedAt_;
        } catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.resolvedAt() returns (uint64) {} catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.state() returns (IBudgetTreasury.BudgetState) {} catch {
            revert INVALID_BUDGET();
        }
    }

    function _activatedAtForBudgetInfo(
        address budget,
        BudgetInfo storage info
    ) internal view returns (uint64 activatedAt) {
        activatedAt = info.activatedAt;
        if (activatedAt != 0) return activatedAt;
        return IBudgetTreasury(budget).activatedAt();
    }

    function _goalFlow() internal view returns (address goalFlow) {
        goalFlow = IGoalTreasury(goalTreasury).flow();
    }

    function _requireGoalFlow() internal view returns (address goalFlow) {
        goalFlow = _goalFlow();
        if (goalFlow == address(0) || goalFlow.code.length == 0) revert INVALID_GOAL_FLOW(goalFlow);
    }

    function _effectiveBudgetResolvedOrRemovedAt(address budget) internal view returns (uint64 resolvedOrRemovedAt) {
        BudgetInfo storage info = _budgetInfo[budget];
        uint64 removedAt = info.removedAt;
        uint64 resolvedAt = IBudgetTreasury(budget).resolvedAt();
        if (removedAt == 0) return resolvedAt;
        if (resolvedAt == 0) return removedAt;
        return removedAt < resolvedAt ? removedAt : resolvedAt;
    }
}
