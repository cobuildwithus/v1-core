// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IStakeVault } from "../interfaces/IStakeVault.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IRewardEscrow } from "../interfaces/IRewardEscrow.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { RewardEscrowMath } from "./library/RewardEscrowMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract RewardEscrow is IRewardEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 private constant _GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint8 private constant _GOAL_EXPIRED = uint8(IGoalTreasury.GoalState.Expired);

    uint256 private constant _DEFAULT_FINALIZE_STEP = 32;

    IERC20 public immutable override rewardToken;
    IERC20 public immutable override cobuildToken;
    ISuperToken public immutable override rewardSuperToken;
    IStakeVault public immutable override stakeVault;
    address public immutable override goalTreasury;
    IBudgetStakeLedger private immutable _budgetStakeLedger;

    bool public override finalized;
    bool public override finalizationInProgress;
    uint8 public override finalState;
    uint64 public override goalFinalizedAt;

    uint256 public override rewardPoolSnapshot;
    uint256 public override cobuildPoolSnapshot;
    uint256 public override totalClaimed;
    uint256 public override totalCobuildClaimed;

    mapping(address => bool) public override claimed;
    mapping(address => uint256) private _cachedSuccessfulPointsPlusOne;

    constructor(
        address goalTreasury_,
        IERC20 rewardToken_,
        IStakeVault stakeVault_,
        ISuperToken rewardSuperToken_,
        IBudgetStakeLedger budgetStakeLedger_
    ) {
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (address(rewardToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(stakeVault_) == address(0)) revert ADDRESS_ZERO();
        if (address(budgetStakeLedger_) == address(0)) revert ADDRESS_ZERO();

        goalTreasury = goalTreasury_;
        rewardToken = rewardToken_;
        stakeVault = stakeVault_;
        rewardSuperToken = rewardSuperToken_;
        _budgetStakeLedger = budgetStakeLedger_;

        if (budgetStakeLedger_.goalTreasury() != goalTreasury_) {
            revert INVALID_BUDGET_STAKE_LEDGER();
        }

        if (address(stakeVault_.goalToken()) != address(rewardToken_)) revert INVALID_REWARD_TOKEN();

        IERC20 localCobuildToken;
        try stakeVault_.cobuildToken() returns (IERC20 cobuildToken_) {
            localCobuildToken = cobuildToken_;
        } catch {
            localCobuildToken = IERC20(address(0));
        }
        cobuildToken = localCobuildToken;

        if (address(rewardSuperToken_) != address(0)) {
            address underlying;
            try rewardSuperToken_.getUnderlyingToken() returns (address underlying_) {
                underlying = underlying_;
            } catch {
                revert INVALID_GOAL_SUPER_TOKEN();
            }
            if (underlying != address(rewardToken_)) revert INVALID_GOAL_SUPER_TOKEN();
        }
    }

    modifier onlyGoalTreasury() {
        if (msg.sender != goalTreasury) revert ONLY_GOAL_TREASURY();
        _;
    }

    function budgetStakeLedger() external view override returns (address) {
        return address(_budgetStakeLedger);
    }

    function totalPointsSnapshot() public view override returns (uint256) {
        return _budgetStakeLedger.totalPointsSnapshot();
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view override returns (uint256) {
        return _budgetStakeLedger.userAllocatedStakeOnBudget(account, budget);
    }

    function budgetTotalAllocatedStake(address budget) external view override returns (uint256) {
        return _budgetStakeLedger.budgetTotalAllocatedStake(budget);
    }

    function trackedBudgetCount() external view override returns (uint256) {
        return _budgetStakeLedger.trackedBudgetCount();
    }

    function trackedBudgetAt(uint256 index) external view override returns (address) {
        return _budgetStakeLedger.trackedBudgetAt(index);
    }

    function allTrackedBudgetsResolved() external view override returns (bool) {
        return _budgetStakeLedger.allTrackedBudgetsResolved();
    }

    function budgetPoints(address budget) external view override returns (uint256) {
        return _budgetStakeLedger.budgetPoints(budget);
    }

    function userPointsOnBudget(address account, address budget) external view override returns (uint256) {
        return _budgetStakeLedger.userPointsOnBudget(account, budget);
    }

    function userSuccessfulPoints(address account) external view override returns (uint256) {
        return _budgetStakeLedger.userSuccessfulPoints(account);
    }

    function budgetSucceededAtFinalize(address budget) external view override returns (bool) {
        return _budgetStakeLedger.budgetSucceededAtFinalize(budget);
    }

    function budgetResolvedAtFinalize(address budget) external view override returns (uint64) {
        return _budgetStakeLedger.budgetResolvedAtFinalize(budget);
    }

    function previewClaim(address account) external view override returns (ClaimPreview memory preview) {
        preview.snapshotClaimed = claimed[account];
        if (!finalized || finalState != _GOAL_SUCCEEDED) return preview;

        uint256 snapshotPoints = _budgetStakeLedger.totalPointsSnapshot();
        if (snapshotPoints == 0) return preview;
        IERC20 localCobuildToken = cobuildToken;
        bool hasCobuildToken = address(localCobuildToken) != address(0);

        uint256 cachedPointsPlusOne = _cachedSuccessfulPointsPlusOne[account];
        uint256 userPoints = _decodeCachedSuccessfulPoints(cachedPointsPlusOne);
        if (cachedPointsPlusOne == 0) {
            userPoints = _resolveSuccessfulPoints(account);
        }
        preview.userPoints = userPoints;
        if (userPoints == 0) return preview;

        if (!preview.snapshotClaimed) {
            preview.snapshotGoalAmount = RewardEscrowMath.computeSnapshotClaim(
                rewardPoolSnapshot,
                totalClaimed,
                userPoints,
                snapshotPoints
            );

            if (hasCobuildToken) {
                preview.snapshotCobuildAmount = RewardEscrowMath.computeSnapshotClaim(
                    cobuildPoolSnapshot,
                    totalCobuildClaimed,
                    userPoints,
                    snapshotPoints
                );
            }
        }

        preview.totalGoalAmount = preview.snapshotGoalAmount;
        preview.totalCobuildAmount = preview.snapshotCobuildAmount;
    }

    function claimCursor(address account) external view override returns (ClaimCursor memory cursor) {
        uint256 cachedPointsPlusOne = _cachedSuccessfulPointsPlusOne[account];
        cursor.snapshotClaimed = claimed[account];
        cursor.successfulPointsCached = cachedPointsPlusOne != 0;
        cursor.cachedSuccessfulPoints = _decodeCachedSuccessfulPoints(cachedPointsPlusOne);
    }

    function unwrapGoalSuperToken(uint256 amount) external override nonReentrant returns (uint256 rewardAmount) {
        return _unwrapGoalSuperToken(amount);
    }

    function unwrapAllGoalSuperTokens() external override nonReentrant returns (uint256 rewardAmount) {
        return _unwrapGoalSuperToken(type(uint256).max);
    }

    // slither-disable-next-line reentrancy-no-eth
    function finalize(uint8 finalState_, uint64 goalFinalizedAt_) external override onlyGoalTreasury nonReentrant {
        if (finalized) revert ALREADY_FINALIZED();
        if (finalizationInProgress) {
            if (finalState_ != finalState || goalFinalizedAt_ != goalFinalizedAt) revert ALREADY_FINALIZED();
            _continueFinalization(_DEFAULT_FINALIZE_STEP);
            return;
        }
        if (finalState_ < _GOAL_SUCCEEDED || finalState_ > _GOAL_EXPIRED) revert INVALID_FINAL_STATE();
        if (goalFinalizedAt_ == 0 || goalFinalizedAt_ > block.timestamp) {
            revert INVALID_FINALIZATION_TIMESTAMP(goalFinalizedAt_);
        }

        finalState = finalState_;
        goalFinalizedAt = goalFinalizedAt_;

        _unwrapGoalSuperToken(type(uint256).max);
        rewardPoolSnapshot = rewardToken.balanceOf(address(this));

        if (address(cobuildToken) != address(0)) {
            cobuildPoolSnapshot = cobuildToken.balanceOf(address(this));
        }

        _budgetStakeLedger.finalize(finalState_, goalFinalizedAt_);
        if (_budgetStakeLedger.finalized()) {
            _completeFinalization();
            return;
        }

        finalizationInProgress = true;
    }

    function finalizeStep(uint256 maxBudgets) external override nonReentrant returns (bool done, uint256 processed) {
        if (!finalizationInProgress) revert FINALIZATION_NOT_IN_PROGRESS();
        if (maxBudgets == 0) revert INVALID_STEP_SIZE();
        (done, processed) = _budgetStakeLedger.finalizeStep(maxBudgets);
        if (done) {
            _completeFinalization();
        }
    }

    function prepareClaim(
        address account,
        uint256 maxBudgets
    ) external override nonReentrant returns (uint256 points, bool done, uint256 nextCursor) {
        if (!finalized) revert NOT_FINALIZED();
        if (account == address(0)) revert ADDRESS_ZERO();
        if (finalState != _GOAL_SUCCEEDED) {
            return (0, true, 0);
        }
        if (maxBudgets == 0) revert INVALID_STEP_SIZE();

        (points, done, nextCursor) = _budgetStakeLedger.prepareUserSuccessfulPoints(account, maxBudgets);
        if (done) {
            _cachedSuccessfulPointsPlusOne[account] = points + 1;
        }
    }

    function claim(address to) external override nonReentrant returns (uint256 goalAmount, uint256 cobuildAmount) {
        if (!finalized) revert NOT_FINALIZED();
        if (to == address(0)) revert ADDRESS_ZERO();

        _unwrapGoalSuperToken(type(uint256).max);

        if (finalState != _GOAL_SUCCEEDED) {
            _markClaimed(msg.sender);
            return _emitZeroClaim(msg.sender, to);
        }

        uint256 snapshotPoints = _budgetStakeLedger.totalPointsSnapshot();
        if (snapshotPoints == 0) {
            _markClaimed(msg.sender);
            return _emitZeroClaim(msg.sender, to);
        }

        uint256 userPoints = _successfulPointsFor(msg.sender);
        if (userPoints == 0) {
            _markClaimed(msg.sender);
            return _emitZeroClaim(msg.sender, to);
        }

        uint256 rewardAmount;
        uint256 baseCobuildAmount;
        IERC20 localCobuildToken = cobuildToken;

        if (!claimed[msg.sender]) {
            claimed[msg.sender] = true;

            if (rewardPoolSnapshot != 0) {
                rewardAmount = RewardEscrowMath.computeSnapshotClaim(
                    rewardPoolSnapshot,
                    totalClaimed,
                    userPoints,
                    snapshotPoints
                );

                if (rewardAmount > 0) {
                    totalClaimed += rewardAmount;
                    rewardToken.safeTransfer(to, rewardAmount);
                }
            }

            if (cobuildPoolSnapshot != 0 && address(localCobuildToken) != address(0)) {
                baseCobuildAmount = RewardEscrowMath.computeSnapshotClaim(
                    cobuildPoolSnapshot,
                    totalCobuildClaimed,
                    userPoints,
                    snapshotPoints
                );

                if (baseCobuildAmount > 0) {
                    totalCobuildClaimed += baseCobuildAmount;
                    localCobuildToken.safeTransfer(to, baseCobuildAmount);
                }
            }
        }

        goalAmount = rewardAmount;
        cobuildAmount = baseCobuildAmount;
        emit Claimed(msg.sender, to, rewardAmount, baseCobuildAmount);
    }

    function releaseFailedAssetsToTreasury() external override nonReentrant onlyGoalTreasury returns (uint256 amount) {
        if (!finalized) revert NOT_FINALIZED();
        if (finalState == _GOAL_SUCCEEDED && _budgetStakeLedger.totalPointsSnapshot() != 0) {
            revert INVALID_FINAL_STATE();
        }
        _unwrapGoalSuperToken(type(uint256).max);

        amount = rewardToken.balanceOf(address(this));
        address to = goalTreasury;
        if (amount > 0) {
            rewardToken.safeTransfer(to, amount);
        }
        emit FailedRewardsSwept(to, amount);

        IERC20 localCobuildToken = cobuildToken;
        if (address(localCobuildToken) != address(0)) {
            uint256 cobuildAmount = localCobuildToken.balanceOf(address(this));
            if (cobuildAmount > 0) {
                localCobuildToken.safeTransfer(to, cobuildAmount);
            }
            emit FailedCobuildRewardsSwept(to, cobuildAmount);
        }
    }

    function _unwrapGoalSuperToken(uint256 amount) internal returns (uint256 rewardAmount) {
        ISuperToken localRewardSuperToken = rewardSuperToken;
        if (address(localRewardSuperToken) == address(0)) return 0;

        IERC20 superTokenAsErc20 = IERC20(address(localRewardSuperToken));
        uint256 available = superTokenAsErc20.balanceOf(address(this));
        if (available == 0) return 0;

        uint256 amountToDowngrade = amount;
        if (amountToDowngrade > available) amountToDowngrade = available;
        if (amountToDowngrade == 0) return 0;

        uint256 rewardBefore = rewardToken.balanceOf(address(this));
        localRewardSuperToken.downgrade(amountToDowngrade);
        rewardAmount = rewardToken.balanceOf(address(this)) - rewardBefore;

        emit GoalSuperTokenUnwrapped(msg.sender, amountToDowngrade, rewardAmount);
    }

    function _continueFinalization(uint256 maxBudgets) internal {
        if (_budgetStakeLedger.finalized()) {
            _completeFinalization();
            return;
        }
        (bool done, ) = _budgetStakeLedger.finalizeStep(maxBudgets);
        if (done) {
            _completeFinalization();
        }
    }

    function _completeFinalization() internal {
        finalizationInProgress = false;
        finalized = true;
        emit RewardEscrowFinalized(
            finalState,
            rewardPoolSnapshot,
            cobuildPoolSnapshot,
            _budgetStakeLedger.totalPointsSnapshot(),
            goalFinalizedAt
        );
    }

    function _decodeCachedSuccessfulPoints(uint256 cachedPointsPlusOne) internal pure returns (uint256) {
        return cachedPointsPlusOne == 0 ? 0 : cachedPointsPlusOne - 1;
    }

    function _resolveSuccessfulPoints(address account) internal view returns (uint256 userPoints) {
        (bool prepared, uint256 preparedPoints, ) = _budgetStakeLedger.preparedUserSuccessfulPoints(account);
        userPoints = prepared ? preparedPoints : _budgetStakeLedger.userSuccessfulPoints(account);
    }

    function _successfulPointsFor(address account) internal returns (uint256 userPoints) {
        uint256 cachedPointsPlusOne = _cachedSuccessfulPointsPlusOne[account];
        userPoints = _decodeCachedSuccessfulPoints(cachedPointsPlusOne);
        if (cachedPointsPlusOne != 0) return userPoints;

        userPoints = _resolveSuccessfulPoints(account);
        _cachedSuccessfulPointsPlusOne[account] = userPoints + 1;
    }

    function _markClaimed(address account) internal {
        if (!claimed[account]) claimed[account] = true;
    }

    function _emitZeroClaim(address account, address to) internal returns (uint256, uint256) {
        emit Claimed(account, to, 0, 0);
        return (0, 0);
    }
}
