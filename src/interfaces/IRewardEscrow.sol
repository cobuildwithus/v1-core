// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IStakeVault } from "./IStakeVault.sol";

interface IRewardEscrow {
    struct ClaimPreview {
        uint256 snapshotGoalAmount;
        uint256 snapshotCobuildAmount;
        uint256 totalGoalAmount;
        uint256 totalCobuildAmount;
        uint256 userPoints;
        bool snapshotClaimed;
    }

    struct ClaimCursor {
        bool snapshotClaimed;
        bool successfulPointsCached;
        uint256 cachedSuccessfulPoints;
    }

    error ADDRESS_ZERO();
    error INVALID_REWARD_TOKEN();
    error INVALID_GOAL_SUPER_TOKEN();
    error INVALID_BUDGET_STAKE_LEDGER();
    error ONLY_GOAL_TREASURY();
    error ALREADY_FINALIZED();
    error FINALIZATION_NOT_IN_PROGRESS();
    error NOT_FINALIZED();
    error INVALID_FINAL_STATE();
    error INVALID_FINALIZATION_TIMESTAMP(uint64 goalFinalizedAt);
    error INVALID_STEP_SIZE();

    event RewardEscrowFinalized(
        uint8 indexed finalState,
        uint256 rewardPoolSnapshot,
        uint256 cobuildPoolSnapshot,
        uint256 totalPointsSnapshot,
        uint64 goalFinalizedAt
    );
    event GoalSuperTokenUnwrapped(address indexed caller, uint256 superTokenAmount, uint256 rewardTokenAmount);
    event Claimed(address indexed account, address indexed to, uint256 rewardAmount, uint256 cobuildAmount);
    event FailedRewardsSwept(address indexed to, uint256 amount);
    event FailedCobuildRewardsSwept(address indexed to, uint256 amount);

    function goalTreasury() external view returns (address);
    function finalized() external view returns (bool);
    function finalizationInProgress() external view returns (bool);
    function finalState() external view returns (uint8);
    function goalFinalizedAt() external view returns (uint64);
    function budgetStakeLedger() external view returns (address);
    function rewardToken() external view returns (IERC20);
    function cobuildToken() external view returns (IERC20);
    function rewardSuperToken() external view returns (ISuperToken);
    function stakeVault() external view returns (IStakeVault);
    function rewardPoolSnapshot() external view returns (uint256);
    function cobuildPoolSnapshot() external view returns (uint256);
    function totalPointsSnapshot() external view returns (uint256);
    function totalClaimed() external view returns (uint256);
    function totalCobuildClaimed() external view returns (uint256);
    function claimed(address account) external view returns (bool);
    function trackedBudgetCount() external view returns (uint256);
    function trackedBudgetAt(uint256 index) external view returns (address);
    function budgetPoints(address budget) external view returns (uint256);
    function userPointsOnBudget(address account, address budget) external view returns (uint256);
    function userSuccessfulPoints(address account) external view returns (uint256);
    function budgetSucceededAtFinalize(address budget) external view returns (bool);
    function budgetResolvedAtFinalize(address budget) external view returns (uint64);
    function previewClaim(address account) external view returns (ClaimPreview memory preview);
    function claimCursor(address account) external view returns (ClaimCursor memory cursor);
    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256);
    function budgetTotalAllocatedStake(address budget) external view returns (uint256);
    function unwrapGoalSuperToken(uint256 amount) external returns (uint256 rewardAmount);
    function unwrapAllGoalSuperTokens() external returns (uint256 rewardAmount);
    function finalize(uint8 finalState_, uint64 goalFinalizedAt_) external;
    function finalizeStep(uint256 maxBudgets) external returns (bool done, uint256 processed);
    function prepareClaim(
        address account,
        uint256 maxBudgets
    ) external returns (uint256 points, bool done, uint256 nextCursor);
    function claim(address to) external returns (uint256 goalAmount, uint256 cobuildAmount);
    function releaseFailedAssetsToTreasury() external returns (uint256 amount);
    function allTrackedBudgetsResolved() external view returns (bool);
}
