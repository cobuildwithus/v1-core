// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IPremiumEscrow } from "../interfaces/IPremiumEscrow.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IUnderwriterSlasherRouter } from "../interfaces/IUnderwriterSlasherRouter.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract PremiumEscrow is IPremiumEscrow, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using SuperTokenV1Library for ISuperToken;

    uint256 private constant _INDEX_SCALE = 1e27;

    error ADDRESS_ZERO();
    error INVALID_SLASH_PPM(uint32 value);
    error ONLY_BUDGET_TREASURY();
    error ONLY_BUDGET_CONTROL();
    error INVALID_MANAGER_REWARD_POOL(address pool);
    error MANAGER_REWARD_POOL_ALREADY_SET(address currentPool);
    error MANAGER_REWARD_POOL_NOT_CONNECTED();
    error POOL_CONNECT_FAILED();
    error INVALID_CLOSE_STATE(IBudgetTreasury.BudgetState state);
    error INVALID_CLOSE_WINDOW(uint64 activatedAt, uint64 closedAt);
    error INVALID_CLOSE_TIMESTAMP(uint64 closedAt);
    error SUPER_TOKEN_MISMATCH(address goalFlowSuperToken, address budgetTreasurySuperToken);
    error ALREADY_CLOSED();
    error NOT_CLOSED();
    error NOT_SLASHABLE();
    error UNRESOLVED_CREDIT_SLASH_PARAMS(uint256 coverageLambda);
    error GOAL_TREASURY_UNAVAILABLE();
    error GOAL_NOT_SUCCEEDED(IGoalTreasury.GoalState state);
    error GOAL_NOT_EXPIRED(IGoalTreasury.GoalState state);
    error BUDGET_NOT_SUCCEEDED(IBudgetTreasury.BudgetState state);

    event PremiumIndexed(
        uint256 indexed distributedPremium,
        uint256 indexed totalCoverage,
        uint256 indexDelta,
        uint256 newPremiumIndex
    );
    event CreditIndexed(
        uint256 indexed distributedCredit,
        uint256 indexed totalCoverage,
        uint256 indexDelta,
        uint256 newCreditIndex
    );
    event ManagerRewardPoolConnected(address indexed pool, uint256 baselineReceived);
    event OrphanPremiumRecycled(address indexed destination, uint256 amount);
    event AccountCheckpointed(
        address indexed account,
        uint256 previousCoverage,
        uint256 currentCoverage,
        uint256 claimableAmount,
        uint256 exposureIntegral,
        uint256 totalCoverage
    );
    event Claimed(address indexed account, address indexed to, uint256 amount);
    event UnclaimablePremiumSwept(address indexed goalFlow, uint256 amount);
    event Closed(IBudgetTreasury.BudgetState indexed finalState, uint64 activatedAt, uint64 closedAt);
    event UnderwriterSlashed(
        address indexed underwriter,
        uint256 exposureIntegral,
        uint256 slashWeight,
        uint256 duration
    );

    /// @notice Emitted with the inputs used to compute slashing for an underwriter.
    /// @dev `usedCreditFormula == false` only on zero-duration/zero-slash-ppm early return paths.
    event UnderwriterSlashCalculated(
        address indexed underwriter,
        bool usedCreditFormula,
        uint256 creditDrawn,
        uint256 premiumEarned,
        uint256 coverageLambda,
        uint256 duration,
        uint256 rawSlashWeight,
        uint256 capWeight,
        uint256 finalSlashWeight
    );

    struct AccountState {
        uint256 userIndex;
        uint256 userCreditIndex;
        uint256 claimable;
        uint256 premiumEarned;
        uint256 creditDrawn;
        uint256 userCov;
        uint256 peakCov;
        uint256 exposureIntegral;
        uint64 lastExposureTs;
        bool slashed;
    }

    address public budgetTreasury;
    address public budgetStakeLedger;
    IERC20 public premiumToken;
    address public goalFlow;
    /// @notice The child budget flow contract (recipient of goal flow distributions).
    address public budgetFlow;
    address public underwriterSlasherRouter;
    uint32 public budgetSlashPpm;

    uint256 public premiumIndex;
    /// @notice Cumulative goal-flow credit (receipts by the budget flow) indexed per unit coverage.
    uint256 public creditIndex;
    /// @notice Cumulative goal-flow receipts already accounted for credit indexing.
    uint256 public accountedGoalReceived;
    /// @notice Manager reward distribution pool used as canonical premium inflow source.
    ISuperfluidPool public managerRewardPool;
    /// @notice Cumulative manager-reward receipts already accounted for indexing/recycling.
    uint256 public accountedManagerRewardReceived;
    uint256 public totalCoverage;

    bool public closed;
    IBudgetTreasury.BudgetState public finalState;
    uint64 public activatedAt;
    uint64 public closedAt;

    mapping(address => AccountState) private _accountStates;

    constructor() {
        _disableInitializers();
    }

    modifier onlyBudgetTreasury() {
        if (msg.sender != budgetTreasury) revert ONLY_BUDGET_TREASURY();
        _;
    }

    function initialize(
        address budgetTreasury_,
        address budgetStakeLedger_,
        address goalFlow_,
        address underwriterSlasherRouter_,
        uint32 budgetSlashPpm_
    ) external override initializer {
        __ReentrancyGuard_init();

        if (budgetTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (budgetStakeLedger_ == address(0)) revert ADDRESS_ZERO();
        if (goalFlow_ == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouter_ == address(0)) revert ADDRESS_ZERO();
        if (budgetSlashPpm_ > FlowProtocolConstants.PPM_SCALE) revert INVALID_SLASH_PPM(budgetSlashPpm_);

        address premiumTokenAddress = address(IFlow(goalFlow_).superToken());
        if (premiumTokenAddress == address(0)) revert ADDRESS_ZERO();
        address budgetTreasurySuperToken = address(IBudgetTreasury(budgetTreasury_).superToken());
        if (budgetTreasurySuperToken == address(0)) revert ADDRESS_ZERO();
        if (premiumTokenAddress != budgetTreasurySuperToken) {
            revert SUPER_TOKEN_MISMATCH(premiumTokenAddress, budgetTreasurySuperToken);
        }

        budgetTreasury = budgetTreasury_;
        budgetStakeLedger = budgetStakeLedger_;
        premiumToken = IERC20(premiumTokenAddress);
        goalFlow = goalFlow_;
        budgetFlow = IBudgetTreasury(budgetTreasury_).flow();
        underwriterSlasherRouter = underwriterSlasherRouter_;
        budgetSlashPpm = budgetSlashPpm_;

        // Establish a baseline so future goal-flow receipt deltas are well-defined.
        try IFlow(goalFlow_).getTotalReceivedByMember(budgetFlow) returns (uint256 totalReceived) {
            accountedGoalReceived = totalReceived;
        } catch {
            accountedGoalReceived = 0;
        }
    }

    /// @notice Connects this escrow as a member of the manager reward distribution pool.
    /// @dev Callable by budget treasury or its controller. One-time configuration (idempotent for same pool).
    function connectManagerRewardPool(address managerRewardPool_) external override {
        address budgetTreasury_ = budgetTreasury;
        address controller = budgetTreasury_ == address(0) ? address(0) : IBudgetTreasury(budgetTreasury_).controller();
        if (msg.sender != budgetTreasury_ && msg.sender != controller) revert ONLY_BUDGET_CONTROL();
        if (managerRewardPool_ == address(0) || managerRewardPool_.code.length == 0) {
            revert INVALID_MANAGER_REWARD_POOL(managerRewardPool_);
        }
        address currentManagerRewardPool = address(managerRewardPool);
        if (currentManagerRewardPool != address(0)) {
            if (currentManagerRewardPool == managerRewardPool_) return;
            revert MANAGER_REWARD_POOL_ALREADY_SET(currentManagerRewardPool);
        }

        ISuperfluidPool managerRewardDistributionPool = ISuperfluidPool(managerRewardPool_);
        managerRewardPool = managerRewardDistributionPool;
        bool success = ISuperToken(address(premiumToken)).connectPool(managerRewardDistributionPool);
        if (!success) revert POOL_CONNECT_FAILED();

        // Establish a baseline so future deltas are well-defined.
        accountedManagerRewardReceived = managerRewardDistributionPool.getTotalAmountReceivedByMember(address(this));
        emit ManagerRewardPoolConnected(managerRewardPool_, accountedManagerRewardReceived);
    }

    function userIndex(address account) external view returns (uint256) {
        return _accountStates[account].userIndex;
    }

    function claimable(address account) external view returns (uint256) {
        return _accountStates[account].claimable;
    }

    function premiumEarned(address account) external view returns (uint256) {
        return _accountStates[account].premiumEarned;
    }

    function userCov(address account) external view override returns (uint256) {
        return _accountStates[account].userCov;
    }

    function peakCov(address account) external view returns (uint256) {
        return _accountStates[account].peakCov;
    }

    function exposureIntegral(address account) external view override returns (uint256) {
        return _accountStates[account].exposureIntegral;
    }

    function creditDrawn(address account) external view override returns (uint256) {
        return _accountStates[account].creditDrawn;
    }

    function lastExposureTs(address account) external view returns (uint64) {
        return _accountStates[account].lastExposureTs;
    }

    function slashed(address account) external view returns (bool) {
        return _accountStates[account].slashed;
    }

    function isSlashable() public view returns (bool) {
        if (!closed) return false;
        if (activatedAt == 0) return false;
        return finalState == IBudgetTreasury.BudgetState.Failed || finalState == IBudgetTreasury.BudgetState.Expired;
    }

    function checkpoint(address account) external override {
        _checkpoint(account, !closed);
    }

    function claim(address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ADDRESS_ZERO();

        // Premium is a success fee and only claimable after budget terminalization as succeeded.
        if (!closed) revert NOT_CLOSED();
        IBudgetTreasury.BudgetState budgetFinalState = finalState;
        if (budgetFinalState != IBudgetTreasury.BudgetState.Succeeded) {
            revert BUDGET_NOT_SUCCEEDED(budgetFinalState);
        }

        _requireGoalSucceeded();

        // Coverage is frozen on close, so do not re-sync post-close.
        _checkpoint(msg.sender, false);

        AccountState storage accountState = _accountStates[msg.sender];
        uint256 claimableAmount = accountState.claimable;
        if (claimableAmount == 0) return 0;

        uint256 available = premiumToken.balanceOf(address(this));
        amount = Math.min(claimableAmount, available);
        if (amount == 0) return 0;

        accountState.claimable = claimableAmount - amount;
        premiumToken.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    /// @notice Sweeps unclaimable premium to the goal flow once the goal has expired.
    /// @dev Premiums are escrowed for underwriters and only become claimable on goal success and
    ///      budget success.
    ///      On goal expiry, these premiums are intentionally made unclaimable and should be burned.
    ///      This function forwards the SuperToken to the goal flow; anyone can then call
    ///      `GoalTreasury.settleLateResidual()` to sweep/downgrade/burn. We attempt this burn
    ///      best-effort here, but do not fail closed if it reverts.
    function burnOnGoalFailure() external override nonReentrant returns (uint256 amount) {
        (address goalTreasury, IGoalTreasury.GoalState state) = _goalTreasuryStateOrRevert();
        if (state != IGoalTreasury.GoalState.Expired) revert GOAL_NOT_EXPIRED(state);

        // Ensure any newly received premium is accounted for before sweeping.
        _checkpointGlobal();

        amount = _sweepEscrowedPremiumToGoalFlow();

        // Best-effort burn: this will sweep the goal flow balance (including the swept premium)
        // and burn the underlying via the goal's revnet controller.
        try IGoalTreasury(goalTreasury).settleLateResidual() {} catch {}
    }

    function close(
        IBudgetTreasury.BudgetState state_,
        uint64 activatedAt_,
        uint64 closedAt_
    ) external override onlyBudgetTreasury {
        if (closed) {
            if (state_ == finalState && activatedAt_ == activatedAt && closedAt_ == closedAt) return;
            revert ALREADY_CLOSED();
        }
        if (state_ == IBudgetTreasury.BudgetState.Funding || state_ == IBudgetTreasury.BudgetState.Active) {
            revert INVALID_CLOSE_STATE(state_);
        }
        if (closedAt_ == 0 || closedAt_ > block.timestamp) revert INVALID_CLOSE_TIMESTAMP(closedAt_);
        if (activatedAt_ > closedAt_) revert INVALID_CLOSE_WINDOW(activatedAt_, closedAt_);

        _checkpointGlobal();

        closed = true;
        finalState = state_;
        activatedAt = activatedAt_;
        closedAt = closedAt_;
        // Freeze coverage to prevent post-close premium accrual; late inflows recycle to goal flow.
        totalCoverage = 0;

        // Pattern B: premium is only payable if the budget succeeds.
        // If failed/expired, recycle escrowed premium to the goal flow.
        if (state_ != IBudgetTreasury.BudgetState.Succeeded) {
            _sweepEscrowedPremiumToGoalFlow();
        }

        emit Closed(state_, activatedAt_, closedAt_);
    }

    function _sweepEscrowedPremiumToGoalFlow() internal returns (uint256 amount) {
        amount = premiumToken.balanceOf(address(this));
        if (amount != 0) {
            premiumToken.safeTransfer(goalFlow, amount);
            emit UnclaimablePremiumSwept(goalFlow, amount);
        }

        // Rebaseline receipt accounting so future checkpoints do not attempt to recycle already-swept dust.
        accountedManagerRewardReceived = _managerRewardPoolOrRevert().getTotalAmountReceivedByMember(address(this));
    }

    function slash(address underwriter) external override nonReentrant returns (uint256 slashWeight) {
        if (underwriter == address(0)) revert ADDRESS_ZERO();
        if (!closed) revert NOT_CLOSED();
        if (!isSlashable()) revert NOT_SLASHABLE();

        _checkpointGlobal();
        _checkpointAccount(underwriter, false);

        AccountState storage accountState = _accountStates[underwriter];
        if (accountState.slashed) return 0;
        accountState.slashed = true;

        uint256 duration = uint256(IBudgetTreasury(budgetTreasury).executionDuration());
        if (duration == 0 || budgetSlashPpm == 0) {
            uint256 earlyCapWeight = Math.mulDiv(
                accountState.peakCov,
                uint256(budgetSlashPpm),
                FlowProtocolConstants.PPM_SCALE_UINT256
            );
            emit UnderwriterSlashCalculated(
                underwriter,
                false,
                accountState.creditDrawn,
                accountState.premiumEarned,
                0,
                duration,
                0,
                earlyCapWeight,
                0
            );
            emit UnderwriterSlashed(underwriter, accountState.exposureIntegral, 0, duration);
            return 0;
        }

        // Credit-drawn-proportional slashing formula (normalized by configured execution duration):
        //   avgCoverageEq = creditDrawn * coverageLambda / duration
        //   rawSlashWeight = avgCoverageEq * budgetSlashPpm
        //   slashWeight = min(rawSlashWeight, peakCoverage * budgetSlashPpm / 1e6)

        uint256 coverageLambda = _resolveCoverageLambda();
        if (coverageLambda == 0) revert UNRESOLVED_CREDIT_SLASH_PARAMS(coverageLambda);

        uint256 rawSlashWeight;
        uint256 capWeight = Math.mulDiv(
            accountState.peakCov,
            uint256(budgetSlashPpm),
            FlowProtocolConstants.PPM_SCALE_UINT256
        );
        // avgCoverageEq = creditDrawn * coverageLambda / duration
        uint256 avgCoverageEq = Math.mulDiv(accountState.creditDrawn, coverageLambda, duration);
        // rawSlashWeight = avgCoverageEq * budgetSlashPpm / 1e6
        rawSlashWeight = Math.mulDiv(
            avgCoverageEq,
            uint256(budgetSlashPpm),
            FlowProtocolConstants.PPM_SCALE_UINT256
        );
        slashWeight = rawSlashWeight > capWeight ? capWeight : rawSlashWeight;

        if (slashWeight != 0) {
            IUnderwriterSlasherRouter(underwriterSlasherRouter).slashUnderwriter(underwriter, slashWeight);
        }

        emit UnderwriterSlashCalculated(
            underwriter,
            true,
            accountState.creditDrawn,
            accountState.premiumEarned,
            coverageLambda,
            duration,
            rawSlashWeight,
            capWeight,
            slashWeight
        );
        emit UnderwriterSlashed(underwriter, accountState.exposureIntegral, slashWeight, duration);
    }

    function _checkpoint(address account, bool syncCoverage) internal {
        if (account == address(0)) revert ADDRESS_ZERO();
        _checkpointGlobal();
        _checkpointAccount(account, syncCoverage);
    }

    function _checkpointAccount(address account, bool syncCoverage) internal {
        AccountState storage accountState = _accountStates[account];
        uint256 previousCoverage = accountState.userCov;

        _accruePremium(accountState);
        _accrueCredit(accountState);
        _accrueExposure(accountState);

        if (syncCoverage) {
            uint256 currentCoverage = IBudgetStakeLedger(budgetStakeLedger).userAllocatedStakeOnBudget(
                account,
                budgetTreasury
            );
            if (currentCoverage != previousCoverage) {
                if (currentCoverage > previousCoverage) {
                    totalCoverage += currentCoverage - previousCoverage;
                } else {
                    totalCoverage -= previousCoverage - currentCoverage;
                }
                accountState.userCov = currentCoverage;
            }

            // Track peak coverage for bounded slashing.
            if (accountState.userCov > accountState.peakCov) {
                accountState.peakCov = accountState.userCov;
            }
        }

        emit AccountCheckpointed(
            account,
            previousCoverage,
            accountState.userCov,
            accountState.claimable,
            accountState.exposureIntegral,
            totalCoverage
        );
    }

    function _accruePremium(AccountState storage accountState) internal {
        uint256 indexDelta = premiumIndex - accountState.userIndex;
        if (indexDelta != 0 && accountState.userCov != 0) {
            uint256 accrued = Math.mulDiv(accountState.userCov, indexDelta, _INDEX_SCALE);
            if (accrued != 0) {
                accountState.claimable += accrued;
                // Track total earned premium (independent of claiming) for analytics.
                accountState.premiumEarned += accrued;
            }
        }
        accountState.userIndex = premiumIndex;
    }

    function _accrueCredit(AccountState storage accountState) internal {
        uint256 indexDelta = creditIndex - accountState.userCreditIndex;
        if (indexDelta != 0 && accountState.userCov != 0) {
            uint256 accrued = Math.mulDiv(accountState.userCov, indexDelta, _INDEX_SCALE);
            if (accrued != 0) {
                accountState.creditDrawn += accrued;
            }
        }
        accountState.userCreditIndex = creditIndex;
    }

    function _resolveCoverageLambda() internal view returns (uint256 lambda) {
        address resolvedGoalTreasury;
        try IFlow(goalFlow).flowOperator() returns (address goalTreasury_) {
            resolvedGoalTreasury = goalTreasury_;
        } catch {
            return 0;
        }
        if (resolvedGoalTreasury == address(0) || resolvedGoalTreasury.code.length == 0) return 0;
        try IGoalTreasury(resolvedGoalTreasury).coverageLambda() returns (uint256 lambda_) {
            lambda = lambda_;
        } catch {
            lambda = 0;
        }
    }

    function _goalTreasuryOrRevert() internal view returns (address goalTreasury) {
        if (goalFlow == address(0) || goalFlow.code.length == 0) revert GOAL_TREASURY_UNAVAILABLE();
        goalTreasury = IFlow(goalFlow).flowOperator();
        if (goalTreasury == address(0) || goalTreasury.code.length == 0) revert GOAL_TREASURY_UNAVAILABLE();
    }

    function _requireGoalSucceeded() internal view {
        (, IGoalTreasury.GoalState state) = _goalTreasuryStateOrRevert();
        if (state != IGoalTreasury.GoalState.Succeeded) revert GOAL_NOT_SUCCEEDED(state);
    }

    function _goalTreasuryStateOrRevert() internal view returns (address goalTreasury, IGoalTreasury.GoalState state) {
        goalTreasury = _goalTreasuryOrRevert();
        state = IGoalTreasury(goalTreasury).state();
    }

    function _accrueExposure(AccountState storage accountState) internal {
        uint64 startTs = _executionStart();
        uint64 exposureTs = _exposureTimestamp();

        if (startTs == 0) {
            accountState.lastExposureTs = exposureTs;
            return;
        }

        uint64 fromTs = accountState.lastExposureTs;
        if (fromTs < startTs) fromTs = startTs;

        if (exposureTs > fromTs && accountState.userCov != 0) {
            accountState.exposureIntegral += accountState.userCov * uint256(exposureTs - fromTs);
        }

        accountState.lastExposureTs = exposureTs;
    }

    function _checkpointGlobal() internal {
        _checkpointGlobalGoalFlowReceipts();
        _checkpointGlobalFromManagerRewardPool();
    }

    function _checkpointGlobalGoalFlowReceipts() internal {
        address budgetFlow_ = budgetFlow;
        if (budgetFlow_ == address(0)) return;

        uint256 totalReceived;
        try IFlow(goalFlow).getTotalReceivedByMember(budgetFlow_) returns (uint256 received_) {
            totalReceived = received_;
        } catch {
            return;
        }

        uint256 previousAccounted = accountedGoalReceived;
        // Defensive clamp in case cumulative receipt accounting ever moves backwards.
        if (totalReceived < previousAccounted) {
            accountedGoalReceived = totalReceived;
            previousAccounted = totalReceived;
        }
        if (totalReceived == previousAccounted) return;

        uint256 incoming = totalReceived - previousAccounted;
        uint256 oldTotalCoverage = totalCoverage;

        // If there is no active coverage snapshot, do not attribute receipts to underwriters.
        // (This is consistent with credit-line logic: zero coverage implies no insured credit.)
        if (oldTotalCoverage == 0) {
            accountedGoalReceived = totalReceived;
            return;
        }

        uint256 indexDelta = Math.mulDiv(incoming, _INDEX_SCALE, oldTotalCoverage);
        if (indexDelta == 0) return;

        uint256 distributed = Math.mulDiv(indexDelta, oldTotalCoverage, _INDEX_SCALE);
        creditIndex += indexDelta;
        accountedGoalReceived = previousAccounted + distributed;

        emit CreditIndexed(distributed, oldTotalCoverage, indexDelta, creditIndex);
    }

    function _checkpointGlobalFromManagerRewardPool() internal {
        uint256 totalReceived = _managerRewardPoolOrRevert().getTotalAmountReceivedByMember(address(this));
        uint256 previousAccounted = accountedManagerRewardReceived;

        // Defensive clamp in case cumulative receipt accounting ever moves backwards.
        if (totalReceived < previousAccounted) {
            accountedManagerRewardReceived = totalReceived;
            previousAccounted = totalReceived;
        }
        if (totalReceived == previousAccounted) return;

        uint256 incoming = totalReceived - previousAccounted;
        uint256 oldTotalCoverage = totalCoverage;

        if (oldTotalCoverage == 0) {
            // Write the cumulative receipt baseline before external transfer to avoid
            // reentrant callbacks observing stale receipt accounting.
            accountedManagerRewardReceived = totalReceived;
            premiumToken.safeTransfer(goalFlow, incoming);
            emit OrphanPremiumRecycled(goalFlow, incoming);
            return;
        }

        uint256 indexDelta = Math.mulDiv(incoming, _INDEX_SCALE, oldTotalCoverage);
        if (indexDelta == 0) return;

        uint256 distributed = Math.mulDiv(indexDelta, oldTotalCoverage, _INDEX_SCALE);
        premiumIndex += indexDelta;
        accountedManagerRewardReceived = previousAccounted + distributed;

        emit PremiumIndexed(distributed, oldTotalCoverage, indexDelta, premiumIndex);
    }

    function _managerRewardPoolOrRevert() internal view returns (ISuperfluidPool pool) {
        pool = managerRewardPool;
        if (address(pool) == address(0)) revert MANAGER_REWARD_POOL_NOT_CONNECTED();
    }

    function _executionStart() internal view returns (uint64) {
        if (closed) return activatedAt;
        return IBudgetTreasury(budgetTreasury).activatedAt();
    }

    function _exposureTimestamp() internal view returns (uint64) {
        if (closed) return closedAt;
        return uint64(block.timestamp);
    }
}
