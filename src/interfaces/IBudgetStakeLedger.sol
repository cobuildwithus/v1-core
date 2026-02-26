// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface IBudgetStakeLedger {
    struct BudgetInfoView {
        bool isTracked;
        bool wasSuccessfulAtFinalization;
        uint64 resolvedAtFinalization;
        uint64 removedAt;
        uint64 scoringEndsAt;
        uint64 maturationPeriodSeconds;
        uint64 resolvedOrRemovedAt;
    }

    struct UserBudgetCheckpointView {
        uint256 allocatedStake;
        uint256 unmaturedStake;
        uint256 accruedPoints;
        uint64 lastCheckpoint;
        uint64 effectiveCutoff;
    }

    struct BudgetCheckpointView {
        uint256 totalAllocatedStake;
        uint256 totalUnmaturedStake;
        uint256 accruedPoints;
        uint64 lastCheckpoint;
        uint64 effectiveCutoff;
    }

    struct TrackedBudgetSummary {
        address budget;
        bool wasSuccessfulAtFinalization;
        uint64 resolvedAtFinalization;
        uint256 points;
    }

    error ADDRESS_ZERO();
    error ONLY_GOAL_FLOW();
    error ONLY_GOAL_TREASURY();
    error ONLY_BUDGET_REGISTRY_MANAGER();
    error ALREADY_FINALIZED();
    error INVALID_FINAL_STATE();
    error INVALID_FINALIZATION_TIMESTAMP(uint64 goalFinalizedAt);
    error INVALID_CHECKPOINT_DATA();
    error INVALID_BUDGET();
    error INVALID_GOAL_FLOW(address goalFlow);
    error BUDGET_ALREADY_REGISTERED();
    error FINALIZATION_ALREADY_IN_PROGRESS();
    error FINALIZATION_NOT_IN_PROGRESS();
    error INVALID_STEP_SIZE();
    error REGISTRATION_CLOSED();
    error ALLOCATION_DRIFT(address account, address budget, uint256 storedAllocated, uint256 expectedAllocated);
    error TOTAL_ALLOCATED_UNDERFLOW(address budget, uint256 totalAllocated, uint256 attemptedDecrease);
    error TOTAL_UNMATURED_UNDERFLOW(address budget, uint256 totalUnmatured, uint256 attemptedDecrease);

    event StakeLedgerFinalized(uint8 indexed finalState, uint256 totalPointsSnapshot, uint64 goalFinalizedAt);
    event AllocationCheckpointed(
        address indexed account,
        address indexed budget,
        uint256 allocatedStake,
        uint64 effectiveCheckpointTime
    );
    event BudgetRegistered(bytes32 indexed recipientId, address indexed budget);
    event BudgetRemoved(bytes32 indexed recipientId, address indexed budget);

    function goalTreasury() external view returns (address);
    function finalized() external view returns (bool);
    function finalizationInProgress() external view returns (bool);
    function finalState() external view returns (uint8);
    function goalFinalizedAt() external view returns (uint64);
    function finalizeCursor() external view returns (uint256);
    function totalPointsSnapshot() external view returns (uint256);

    function checkpointAllocation(
        address account,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevScaled,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newScaled
    ) external;
    function registerBudget(bytes32 recipientId, address budget) external;
    function removeBudget(bytes32 recipientId) external;
    function budgetForRecipient(bytes32 recipientId) external view returns (address);

    function finalize(uint8 finalState_, uint64 goalFinalizedAt_) external;
    function finalizeStep(uint256 maxBudgets) external returns (bool done, uint256 processed);

    function trackedBudgetCount() external view returns (uint256);
    function trackedBudgetAt(uint256 index) external view returns (address);
    function allTrackedBudgetsResolved() external view returns (bool);

    function budgetPoints(address budget) external view returns (uint256);
    function userPointsOnBudget(address account, address budget) external view returns (uint256);
    function userSuccessfulPoints(address account) external view returns (uint256);
    function prepareUserSuccessfulPoints(
        address account,
        uint256 maxBudgets
    ) external returns (uint256 points, bool done, uint256 nextCursor);
    function preparedUserSuccessfulPoints(
        address account
    ) external view returns (bool prepared, uint256 points, uint256 nextCursor);

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256);
    function budgetTotalAllocatedStake(address budget) external view returns (uint256);

    function budgetSucceededAtFinalize(address budget) external view returns (bool);
    function budgetResolvedAtFinalize(address budget) external view returns (uint64);
    function budgetInfo(address budget) external view returns (BudgetInfoView memory info);
    function userBudgetCheckpoint(
        address account,
        address budget
    ) external view returns (UserBudgetCheckpointView memory checkpoint);
    function budgetCheckpoint(address budget) external view returns (BudgetCheckpointView memory checkpoint);
    function trackedBudgetSlice(
        uint256 start,
        uint256 count
    ) external view returns (TrackedBudgetSummary[] memory summaries);
}
