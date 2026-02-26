// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { BudgetStakeLedgerMath } from "./library/BudgetStakeLedgerMath.sol";
import { FlowUnitMath } from "../library/FlowUnitMath.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";
import { SortedRecipientMerge } from "../library/SortedRecipientMerge.sol";

contract BudgetStakeLedger is IBudgetStakeLedger {
    struct UserBudgetCheckpoint {
        uint256 allocatedStake;
        uint256 unmaturedStake;
        uint256 accruedPoints;
        uint64 lastCheckpoint;
    }

    struct BudgetCheckpoint {
        uint256 totalAllocatedStake;
        uint256 totalUnmaturedStake;
        uint256 accruedPoints;
        uint64 lastCheckpoint;
    }

    struct BudgetInfo {
        bool isTracked;
        bool wasSuccessfulAtFinalization;
        uint64 resolvedAtFinalization;
        uint64 removedAt;
        uint64 scoringEndsAt;
        uint64 maturationPeriodSeconds;
    }

    uint8 private constant _GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint8 private constant _GOAL_EXPIRED = uint8(IGoalTreasury.GoalState.Expired);

    uint8 private constant _BUDGET_SUCCEEDED = uint8(IBudgetTreasury.BudgetState.Succeeded);

    uint256 private constant _INLINE_FINALIZE_BUDGETS = 32;
    uint64 private constant _MIN_MATURATION_SECONDS = 1;
    uint64 private constant _MATURATION_DIVISOR = 10;

    address public immutable override goalTreasury;

    bool public override finalized;
    bool public override finalizationInProgress;
    uint8 public override finalState;
    uint64 public override goalFinalizedAt;
    uint256 public override finalizeCursor;

    uint256 public override totalPointsSnapshot;
    uint256 private _finalizingPointsSnapshot;

    mapping(address => mapping(address => UserBudgetCheckpoint)) private _userBudgetCheckpoints;
    mapping(address => BudgetCheckpoint) private _budgetCheckpoints;
    mapping(address => BudgetInfo) private _budgetInfo;
    mapping(bytes32 => address) private _budgetByRecipientId;
    mapping(address => uint256) private _preparedSuccessfulPointsPlusOne;
    mapping(address => uint256) private _preparedSuccessfulPointsCursor;

    address[] private _trackedBudgets;

    constructor(address goalTreasury_) {
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        goalTreasury = goalTreasury_;
    }

    modifier onlyGoalSettlementAuthority() {
        if (msg.sender == goalTreasury) {
            _;
            return;
        }

        address rewardEscrow = IGoalTreasury(goalTreasury).rewardEscrow();

        if (msg.sender != rewardEscrow || rewardEscrow == address(0)) revert ONLY_GOAL_TREASURY();
        _;
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
        if (finalized || finalizationInProgress) return;
        if (account == address(0)) revert ADDRESS_ZERO();
        if (prevRecipientIds.length != prevScaled.length) revert INVALID_CHECKPOINT_DATA();
        if (newRecipientIds.length != newScaled.length) revert INVALID_CHECKPOINT_DATA();
        (SortedRecipientMerge.Cursor memory mergeCursor, bool validMergeInput) = SortedRecipientMerge.init(
            prevRecipientIds,
            newRecipientIds,
            SortedRecipientMerge.Precondition.RequireSorted
        );
        if (!validMergeInput) revert INVALID_CHECKPOINT_DATA();

        uint64 nowTs = uint64(block.timestamp);
        uint256 oldLen = prevRecipientIds.length;
        uint256 newLen = newRecipientIds.length;

        while (SortedRecipientMerge.hasNext(mergeCursor, oldLen, newLen)) {
            (
                SortedRecipientMerge.Step memory step,
                SortedRecipientMerge.Cursor memory nextCursor
            ) = SortedRecipientMerge.next(prevRecipientIds, newRecipientIds, mergeCursor);
            mergeCursor = nextCursor;

            address budget = _budgetByRecipientId[step.recipientId];
            if (budget == address(0)) continue;

            if (step.hasOld && step.hasNew) {
                uint256 oldAllocated = _effectiveAllocatedStake(prevWeight, prevScaled[step.oldIndex]);
                uint256 pairedNewAllocated = _effectiveAllocatedStake(newWeight, newScaled[step.newIndex]);
                _checkpointBudgetAllocation(account, budget, oldAllocated, pairedNewAllocated, nowTs);
                continue;
            }

            if (step.hasOld) {
                uint256 oldAllocated = _effectiveAllocatedStake(prevWeight, prevScaled[step.oldIndex]);
                _checkpointBudgetAllocation(account, budget, oldAllocated, 0, nowTs);
                continue;
            }

            uint256 addedNewAllocated = _effectiveAllocatedStake(newWeight, newScaled[step.newIndex]);
            _checkpointBudgetAllocation(account, budget, 0, addedNewAllocated, nowTs);
        }
    }

    function registerBudget(bytes32 recipientId, address budget) external override onlyBudgetRegistryManager {
        if (finalized || finalizationInProgress) revert REGISTRATION_CLOSED();
        if (budget == address(0)) revert ADDRESS_ZERO();
        (uint64 scoringEndsAt, uint64 maturationPeriodSeconds) = _validateBudgetForRegistration(budget);

        address existing = _budgetByRecipientId[recipientId];
        if (existing != address(0) && existing != budget) revert BUDGET_ALREADY_REGISTERED();
        if (existing == budget) return;
        BudgetInfo storage info = _budgetInfo[budget];
        if (info.isTracked) revert BUDGET_ALREADY_REGISTERED();

        _budgetByRecipientId[recipientId] = budget;
        info.isTracked = true;
        _trackedBudgets.push(budget);
        info.scoringEndsAt = scoringEndsAt;
        info.maturationPeriodSeconds = maturationPeriodSeconds;

        emit BudgetRegistered(recipientId, budget);
    }

    function removeBudget(bytes32 recipientId) external override onlyBudgetRegistryManager {
        if (finalized || finalizationInProgress) revert REGISTRATION_CLOSED();
        address budget = _budgetByRecipientId[recipientId];
        if (budget == address(0)) return;

        delete _budgetByRecipientId[recipientId];
        BudgetInfo storage info = _budgetInfo[budget];
        if (info.removedAt == 0) {
            info.removedAt = uint64(block.timestamp);
        }
        emit BudgetRemoved(recipientId, budget);
    }

    function budgetForRecipient(bytes32 recipientId) external view override returns (address) {
        return _budgetByRecipientId[recipientId];
    }

    function finalize(uint8 finalState_, uint64 goalFinalizedAt_) external override onlyGoalSettlementAuthority {
        if (finalizationInProgress) revert FINALIZATION_ALREADY_IN_PROGRESS();
        if (finalized) revert ALREADY_FINALIZED();
        if (finalState_ < _GOAL_SUCCEEDED || finalState_ > _GOAL_EXPIRED) revert INVALID_FINAL_STATE();
        if (goalFinalizedAt_ == 0 || goalFinalizedAt_ > block.timestamp) {
            revert INVALID_FINALIZATION_TIMESTAMP(goalFinalizedAt_);
        }

        finalState = finalState_;
        goalFinalizedAt = goalFinalizedAt_;
        finalizeCursor = 0;
        _finalizingPointsSnapshot = 0;

        if (finalState_ != _GOAL_SUCCEEDED) {
            _completeFinalization(0);
            return;
        }

        finalizationInProgress = true;
        _advanceSuccessFinalization(_INLINE_FINALIZE_BUDGETS);
    }

    function finalizeStep(uint256 maxBudgets) external override returns (bool done, uint256 processed) {
        if (!finalizationInProgress) revert FINALIZATION_NOT_IN_PROGRESS();
        if (maxBudgets == 0) revert INVALID_STEP_SIZE();
        return _advanceSuccessFinalization(maxBudgets);
    }

    function trackedBudgetCount() external view override returns (uint256) {
        return _trackedBudgets.length;
    }

    function allTrackedBudgetsResolved() external view override returns (bool) {
        uint256 trackedCount = _trackedBudgets.length;
        for (uint256 i = 0; i < trackedCount; ) {
            if (_effectiveBudgetResolvedOrRemovedAt(_trackedBudgets[i]) == 0) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function trackedBudgetAt(uint256 index) external view override returns (address) {
        return _trackedBudgets[index];
    }

    function budgetPoints(address budget) external view override returns (uint256) {
        return _budgetCheckpoints[budget].accruedPoints;
    }

    function userPointsOnBudget(address account, address budget) external view override returns (uint256) {
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];
        uint64 cutoff = _effectiveUserCutoff(budget);
        return _previewUserPoints(userCheckpoint, budget, cutoff);
    }

    function userSuccessfulPoints(address account) external view override returns (uint256 totalPoints) {
        (bool prepared, uint256 preparedPoints, ) = preparedUserSuccessfulPoints(account);
        if (prepared) return preparedPoints;

        uint256 trackedCount = _trackedBudgets.length;

        for (uint256 i = 0; i < trackedCount; ) {
            address budget = _trackedBudgets[i];
            if (_budgetInfo[budget].wasSuccessfulAtFinalization) {
                UserBudgetCheckpoint storage checkpoint = _userBudgetCheckpoints[account][budget];
                uint64 cutoff = _effectiveUserCutoff(budget);
                totalPoints += _previewUserPoints(checkpoint, budget, cutoff);
            }
            unchecked {
                ++i;
            }
        }
    }

    function prepareUserSuccessfulPoints(
        address account,
        uint256 maxBudgets
    ) external override returns (uint256 points, bool done, uint256 nextCursor) {
        if (account == address(0)) revert ADDRESS_ZERO();
        if (!finalized || finalState != _GOAL_SUCCEEDED) {
            return (0, true, 0);
        }
        if (maxBudgets == 0) revert INVALID_STEP_SIZE();

        uint256 trackedCount = _trackedBudgets.length;
        uint256 cursor = _clampCursorToTrackedCount(_preparedSuccessfulPointsCursor[account], trackedCount);
        uint256 cachedPointsPlusOne = _preparedSuccessfulPointsPlusOne[account];
        points = _decodeCachedSuccessfulPoints(cachedPointsPlusOne);

        if (cursor == trackedCount) {
            if (cachedPointsPlusOne == 0) {
                _preparedSuccessfulPointsPlusOne[account] = points + 1;
            }
            return (points, true, cursor);
        }

        uint256 endExclusive = _boundedEndExclusive(cursor, maxBudgets, trackedCount);

        for (uint256 i = cursor; i < endExclusive; ) {
            address budget = _trackedBudgets[i];
            if (_budgetInfo[budget].wasSuccessfulAtFinalization) {
                UserBudgetCheckpoint storage checkpoint = _userBudgetCheckpoints[account][budget];
                uint64 cutoff = _effectiveUserCutoff(budget);
                points += _previewUserPoints(checkpoint, budget, cutoff);
            }
            unchecked {
                ++i;
            }
        }

        _preparedSuccessfulPointsCursor[account] = endExclusive;
        _preparedSuccessfulPointsPlusOne[account] = points + 1;
        done = endExclusive == trackedCount;
        nextCursor = endExclusive;
    }

    function preparedUserSuccessfulPoints(
        address account
    ) public view override returns (bool prepared, uint256 points, uint256 nextCursor) {
        if (!finalized || finalState != _GOAL_SUCCEEDED) {
            return (true, 0, 0);
        }

        uint256 trackedCount = _trackedBudgets.length;
        uint256 cursor = _clampCursorToTrackedCount(_preparedSuccessfulPointsCursor[account], trackedCount);
        points = _decodeCachedSuccessfulPoints(_preparedSuccessfulPointsPlusOne[account]);
        nextCursor = cursor;
        prepared = cursor == trackedCount;
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view override returns (uint256) {
        return _userBudgetCheckpoints[account][budget].allocatedStake;
    }

    function budgetTotalAllocatedStake(address budget) external view override returns (uint256) {
        return _budgetCheckpoints[budget].totalAllocatedStake;
    }

    function budgetSucceededAtFinalize(address budget) external view override returns (bool) {
        return _budgetInfo[budget].wasSuccessfulAtFinalization;
    }

    function budgetResolvedAtFinalize(address budget) external view override returns (uint64) {
        return _budgetInfo[budget].resolvedAtFinalization;
    }

    function budgetInfo(address budget) external view override returns (BudgetInfoView memory info) {
        BudgetInfo storage budgetInfo_ = _budgetInfo[budget];
        info.isTracked = budgetInfo_.isTracked;
        info.wasSuccessfulAtFinalization = budgetInfo_.wasSuccessfulAtFinalization;
        info.resolvedAtFinalization = budgetInfo_.resolvedAtFinalization;
        info.removedAt = budgetInfo_.removedAt;
        info.scoringEndsAt = budgetInfo_.scoringEndsAt;
        info.maturationPeriodSeconds = budgetInfo_.maturationPeriodSeconds;
        info.resolvedOrRemovedAt = _effectiveBudgetResolvedOrRemovedAt(budget);
    }

    function userBudgetCheckpoint(
        address account,
        address budget
    ) external view override returns (UserBudgetCheckpointView memory checkpoint) {
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];
        checkpoint.allocatedStake = userCheckpoint.allocatedStake;
        checkpoint.unmaturedStake = userCheckpoint.unmaturedStake;
        checkpoint.accruedPoints = userCheckpoint.accruedPoints;
        checkpoint.lastCheckpoint = userCheckpoint.lastCheckpoint;
        checkpoint.effectiveCutoff = _effectiveUserCutoff(budget);
    }

    function budgetCheckpoint(address budget) external view override returns (BudgetCheckpointView memory checkpoint) {
        BudgetCheckpoint storage budgetCheckpoint_ = _budgetCheckpoints[budget];
        checkpoint.totalAllocatedStake = budgetCheckpoint_.totalAllocatedStake;
        checkpoint.totalUnmaturedStake = budgetCheckpoint_.totalUnmaturedStake;
        checkpoint.accruedPoints = budgetCheckpoint_.accruedPoints;
        checkpoint.lastCheckpoint = budgetCheckpoint_.lastCheckpoint;
        checkpoint.effectiveCutoff = _effectiveUserCutoff(budget);
    }

    function trackedBudgetSlice(
        uint256 start,
        uint256 count
    ) external view override returns (TrackedBudgetSummary[] memory summaries) {
        uint256 total = _trackedBudgets.length;
        if (start >= total || count == 0) return new TrackedBudgetSummary[](0);

        uint256 endExclusive = _boundedEndExclusive(start, count, total);

        uint256 length = endExclusive - start;
        summaries = new TrackedBudgetSummary[](length);

        for (uint256 i = 0; i < length; ) {
            address budget = _trackedBudgets[start + i];
            BudgetInfo storage info = _budgetInfo[budget];
            summaries[i] = TrackedBudgetSummary({
                budget: budget,
                wasSuccessfulAtFinalization: info.wasSuccessfulAtFinalization,
                resolvedAtFinalization: info.resolvedAtFinalization,
                points: _budgetCheckpoints[budget].accruedPoints
            });
            unchecked {
                ++i;
            }
        }
    }

    function _advanceSuccessFinalization(uint256 maxBudgets) internal returns (bool done, uint256 processed) {
        uint256 trackedCount = _trackedBudgets.length;
        uint256 cursor = finalizeCursor;
        if (cursor >= trackedCount) {
            _completeFinalization(_finalizingPointsSnapshot);
            return (true, 0);
        }

        uint256 endExclusive = _boundedEndExclusive(cursor, maxBudgets, trackedCount);

        uint256 pointsSnapshot = _finalizingPointsSnapshot;
        uint64 finalizationTs = goalFinalizedAt;
        uint256 nextCursor = cursor;

        for (; nextCursor < endExclusive; ) {
            address budget = _trackedBudgets[nextCursor];
            BudgetInfo storage info = _budgetInfo[budget];
            uint64 resolvedAt = IBudgetTreasury(budget).resolvedAt();
            if (info.removedAt == 0 && resolvedAt == 0) break;

            BudgetCheckpoint storage budgetCheckpointData = _budgetCheckpoints[budget];
            uint64 cutoff = _clampCutoffToBudgetInfo(finalizationTs, info);

            _accrueBudgetPoints(budgetCheckpointData, cutoff, _maturationSecondsForBudget(budget));

            bool succeeded = _isBudgetSucceededAtFinalization(budget, info.removedAt, resolvedAt);
            info.wasSuccessfulAtFinalization = succeeded;
            info.resolvedAtFinalization = resolvedAt;

            if (succeeded) {
                pointsSnapshot += budgetCheckpointData.accruedPoints;
            }

            unchecked {
                ++nextCursor;
            }
        }

        processed = nextCursor - cursor;
        finalizeCursor = nextCursor;
        _finalizingPointsSnapshot = pointsSnapshot;

        if (nextCursor == trackedCount) {
            _completeFinalization(pointsSnapshot);
            done = true;
        }
    }

    function _completeFinalization(uint256 pointsSnapshot) internal {
        finalizationInProgress = false;
        finalized = true;
        totalPointsSnapshot = pointsSnapshot;
        emit StakeLedgerFinalized(finalState, pointsSnapshot, goalFinalizedAt);
    }

    function _checkpointBudgetAllocation(
        address account,
        address budget,
        uint256 oldAllocated,
        uint256 newAllocated,
        uint64 nowTs
    ) internal {
        BudgetCheckpoint storage budgetCheckpointData = _budgetCheckpoints[budget];
        BudgetInfo storage budgetInfoData = _budgetInfo[budget];
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];
        uint64 checkpointTime = _clampCutoffToBudgetInfo(nowTs, budgetInfoData);
        uint64 maturationSeconds = _maturationSecondsForBudget(budget);

        uint256 userStoredAllocated = userCheckpoint.allocatedStake;
        if (userStoredAllocated != oldAllocated) {
            revert ALLOCATION_DRIFT(account, budget, userStoredAllocated, oldAllocated);
        }

        _accrueBudgetPoints(budgetCheckpointData, checkpointTime, maturationSeconds);
        _accrueUserPoints(userCheckpoint, checkpointTime, maturationSeconds);

        uint256 unmaturedBefore = userCheckpoint.unmaturedStake;
        uint256 unmaturedAfter = BudgetStakeLedgerMath.applyStakeChangeToUnmatured(
            unmaturedBefore,
            oldAllocated,
            newAllocated
        );
        if (unmaturedAfter > newAllocated) unmaturedAfter = newAllocated;
        if (unmaturedAfter > unmaturedBefore) {
            budgetCheckpointData.totalUnmaturedStake += unmaturedAfter - unmaturedBefore;
        } else if (unmaturedAfter < unmaturedBefore) {
            uint256 unmaturedDecrease = unmaturedBefore - unmaturedAfter;
            uint256 totalUnmatured = budgetCheckpointData.totalUnmaturedStake;
            if (unmaturedDecrease > totalUnmatured) {
                revert TOTAL_UNMATURED_UNDERFLOW(budget, totalUnmatured, unmaturedDecrease);
            }
            budgetCheckpointData.totalUnmaturedStake = totalUnmatured - unmaturedDecrease;
        }

        if (newAllocated > oldAllocated) {
            budgetCheckpointData.totalAllocatedStake += newAllocated - oldAllocated;
        } else if (newAllocated < oldAllocated) {
            uint256 allocatedDecrease = oldAllocated - newAllocated;
            uint256 totalAllocated = budgetCheckpointData.totalAllocatedStake;
            if (allocatedDecrease > totalAllocated) {
                revert TOTAL_ALLOCATED_UNDERFLOW(budget, totalAllocated, allocatedDecrease);
            }
            budgetCheckpointData.totalAllocatedStake = totalAllocated - allocatedDecrease;
        }
        if (userCheckpoint.allocatedStake != newAllocated) {
            userCheckpoint.allocatedStake = newAllocated;
        }
        if (userCheckpoint.unmaturedStake != unmaturedAfter) {
            userCheckpoint.unmaturedStake = unmaturedAfter;
        }

        emit AllocationCheckpointed(account, budget, newAllocated, checkpointTime);
    }

    function _accrueBudgetPoints(
        BudgetCheckpoint storage checkpoint,
        uint64 checkpointTime,
        uint64 maturationSeconds
    ) internal {
        uint256 totalAllocatedStake = checkpoint.totalAllocatedStake;
        uint256 totalUnmaturedStake = checkpoint.totalUnmaturedStake;
        uint256 accruedPoints = checkpoint.accruedPoints;
        uint64 lastCheckpoint = checkpoint.lastCheckpoint;

        (uint256 newTotalUnmaturedStake, uint256 newAccruedPoints, uint64 newLastCheckpoint) = BudgetStakeLedgerMath
            .accruePoints(
                totalAllocatedStake,
                totalUnmaturedStake,
                accruedPoints,
                lastCheckpoint,
                checkpointTime,
                maturationSeconds
            );

        if (newTotalUnmaturedStake != totalUnmaturedStake) {
            checkpoint.totalUnmaturedStake = newTotalUnmaturedStake;
        }
        if (newAccruedPoints != accruedPoints) {
            checkpoint.accruedPoints = newAccruedPoints;
        }
        if (newLastCheckpoint != lastCheckpoint) {
            checkpoint.lastCheckpoint = newLastCheckpoint;
        }
    }

    function _accrueUserPoints(
        UserBudgetCheckpoint storage checkpoint,
        uint64 checkpointTime,
        uint64 maturationSeconds
    ) internal {
        uint256 allocatedStake = checkpoint.allocatedStake;
        uint256 unmaturedStake = checkpoint.unmaturedStake;
        uint256 accruedPoints = checkpoint.accruedPoints;
        uint64 lastCheckpoint = checkpoint.lastCheckpoint;

        (uint256 newUnmaturedStake, uint256 newAccruedPoints, uint64 newLastCheckpoint) = BudgetStakeLedgerMath
            .accruePoints(
                allocatedStake,
                unmaturedStake,
                accruedPoints,
                lastCheckpoint,
                checkpointTime,
                maturationSeconds
            );

        if (newUnmaturedStake != unmaturedStake) {
            checkpoint.unmaturedStake = newUnmaturedStake;
        }
        if (newAccruedPoints != accruedPoints) {
            checkpoint.accruedPoints = newAccruedPoints;
        }
        if (newLastCheckpoint != lastCheckpoint) {
            checkpoint.lastCheckpoint = newLastCheckpoint;
        }
    }

    function _previewUserPoints(
        UserBudgetCheckpoint storage checkpoint,
        address budget,
        uint64 cutoff
    ) internal view returns (uint256 points) {
        points = BudgetStakeLedgerMath.previewPoints(
            checkpoint.allocatedStake,
            checkpoint.unmaturedStake,
            checkpoint.accruedPoints,
            checkpoint.lastCheckpoint,
            cutoff,
            _maturationSecondsForBudget(budget)
        );
    }

    function _decodeCachedSuccessfulPoints(uint256 cachedPointsPlusOne) internal pure returns (uint256) {
        return cachedPointsPlusOne == 0 ? 0 : cachedPointsPlusOne - 1;
    }

    function _clampCursorToTrackedCount(uint256 cursor, uint256 trackedCount) internal pure returns (uint256) {
        return cursor > trackedCount ? trackedCount : cursor;
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

    function _computeMaturationSeconds(uint64 executionDuration) internal pure returns (uint64 maturationSeconds) {
        if (executionDuration == 0) revert INVALID_BUDGET();

        maturationSeconds = executionDuration / _MATURATION_DIVISOR;
        if (maturationSeconds == 0) maturationSeconds = _MIN_MATURATION_SECONDS;
    }

    function _validateBudgetForRegistration(
        address budget
    ) internal view returns (uint64 fundingDeadline, uint64 maturationSeconds) {
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
            maturationSeconds = _computeMaturationSeconds(executionDuration_);
        } catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.fundingDeadline() returns (uint64 fundingDeadline_) {
            fundingDeadline = fundingDeadline_;
        } catch {
            revert INVALID_BUDGET();
        }
        if (fundingDeadline == 0) revert INVALID_BUDGET();

        try budgetTreasury.resolvedAt() returns (uint64) {} catch {
            revert INVALID_BUDGET();
        }

        try budgetTreasury.state() returns (IBudgetTreasury.BudgetState) {} catch {
            revert INVALID_BUDGET();
        }
    }

    function _maturationSecondsForBudget(address budget) internal view returns (uint64 maturationSeconds) {
        maturationSeconds = _budgetInfo[budget].maturationPeriodSeconds;
        if (maturationSeconds == 0) revert INVALID_BUDGET();
    }

    function _effectiveUserCutoff(address budget) internal view returns (uint64 cutoff) {
        cutoff = goalFinalizedAt;
        if (cutoff == 0) {
            cutoff = uint64(block.timestamp);
        }

        BudgetInfo storage info = _budgetInfo[budget];
        cutoff = _clampCutoffToBudgetInfo(cutoff, info);
    }

    function _clampCutoffToBudgetInfo(uint64 cutoff, BudgetInfo storage info) internal view returns (uint64) {
        uint64 removedAt = info.removedAt;
        if (removedAt != 0 && removedAt < cutoff) {
            cutoff = removedAt;
        }

        uint64 scoringEndsAt = info.scoringEndsAt;
        if (scoringEndsAt != 0 && scoringEndsAt < cutoff) {
            cutoff = scoringEndsAt;
        }
        return cutoff;
    }

    function _goalFlow() internal view returns (address goalFlow) {
        goalFlow = IGoalTreasury(goalTreasury).flow();
    }

    function _requireGoalFlow() internal view returns (address goalFlow) {
        goalFlow = _goalFlow();
        if (goalFlow == address(0) || goalFlow.code.length == 0) revert INVALID_GOAL_FLOW(goalFlow);
    }

    function _isBudgetSucceededAtFinalization(
        address budget,
        uint64 removedAt,
        uint64 resolvedAt
    ) internal view returns (bool) {
        if (removedAt != 0 || resolvedAt == 0) return false;

        return uint8(IBudgetTreasury(budget).state()) == _BUDGET_SUCCEEDED;
    }

    function _effectiveBudgetResolvedOrRemovedAt(address budget) internal view returns (uint64 resolvedOrRemovedAt) {
        uint64 removedAt = _budgetInfo[budget].removedAt;
        uint64 resolvedAt = IBudgetTreasury(budget).resolvedAt();
        if (removedAt == 0) return resolvedAt;
        if (resolvedAt == 0 || removedAt < resolvedAt) return removedAt;
        return resolvedAt;
    }
}
