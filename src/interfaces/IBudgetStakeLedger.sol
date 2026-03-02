// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface IBudgetStakeLedger {
    struct BudgetInfoView {
        bool isTracked;
        uint64 removedAt;
        uint64 activatedAt;
        uint64 resolvedOrRemovedAt;
    }

    struct UserBudgetCheckpointView {
        uint256 allocatedStake;
        uint64 lastCheckpoint;
    }

    struct BudgetCheckpointView {
        uint256 totalAllocatedStake;
        uint64 lastCheckpoint;
    }

    struct TrackedBudgetSummary {
        address budget;
        uint64 resolvedOrRemovedAt;
        uint256 totalAllocatedStake;
    }

    error ADDRESS_ZERO();
    error ONLY_GOAL_FLOW_OR_PIPELINE();
    error ONLY_BUDGET_REGISTRY_MANAGER();
    error INVALID_CHECKPOINT_DATA();
    error INVALID_BUDGET_NOT_CONTRACT(address budget);
    error INVALID_BUDGET_FLOW_READ(address budget);
    error INVALID_BUDGET_FLOW(address budget, address budgetFlow);
    error INVALID_BUDGET_PARENT_READ(address budgetFlow);
    error INVALID_BUDGET_PARENT_MISMATCH(address budgetFlow, address expectedParent, address actualParent);
    error INVALID_BUDGET_EXECUTION_DURATION(address budget);
    error INVALID_BUDGET_FUNDING_DEADLINE(address budget);
    error INVALID_BUDGET_ACTIVATED_AT(address budget);
    error INVALID_BUDGET_RESOLVED_AT(address budget);
    error INVALID_BUDGET_STATE(address budget);
    error INVALID_GOAL_FLOW(address goalFlow);
    error BUDGET_ALREADY_REGISTERED();
    error ALLOCATION_DRIFT(address account, address budget, uint256 storedAllocated, uint256 expectedAllocated);
    error TOTAL_ALLOCATED_UNDERFLOW(address budget, uint256 totalAllocated, uint256 attemptedDecrease);
    error BLOCK_NOT_YET_MINED();

    event AllocationCheckpointed(
        address indexed account,
        address indexed budget,
        uint256 allocatedStake,
        uint64 checkpointTime
    );
    event BudgetRegistered(bytes32 indexed recipientId, address indexed budget);
    event BudgetRemoved(bytes32 indexed recipientId, address indexed budget);

    function goalTreasury() external view returns (address);

    function checkpointAllocation(
        address account,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external;

    function registerBudget(bytes32 recipientId, address budget) external;
    function removeBudget(bytes32 recipientId) external;
    function budgetForRecipient(bytes32 recipientId) external view returns (address);

    function trackedBudgetCount() external view returns (uint256);
    function trackedBudgetAt(uint256 index) external view returns (address);
    function allTrackedBudgetsResolved() external view returns (bool);
    function registeredBudgetCount() external view returns (uint256);
    function registeredBudgetAt(uint256 index) external view returns (address);

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256);
    function budgetTotalAllocatedStake(address budget) external view returns (uint256);

    function getPastUserAllocatedStakeOnBudget(
        address account,
        address budget,
        uint256 blockNumber
    ) external view returns (uint256);

    function getPastUserAllocationWeight(address account, uint256 blockNumber) external view returns (uint256);

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
