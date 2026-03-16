// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IStakeVault } from "../interfaces/IStakeVault.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { ITreasuryRuntimeViews } from "../interfaces/ITreasuryRuntimeViews.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IPremiumEscrowSlashAccounting } from "../interfaces/IPremiumEscrow.sol";
import { ICustomFlow } from "../interfaces/IFlow.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBControlled } from "@bananapus/core-v5/interfaces/IJBControlled.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AddressKeyAllocation } from "../library/AddressKeyAllocation.sol";
import { TokenTransfers } from "../library/TokenTransfers.sol";
import { StakeVaultJurorMath } from "./library/StakeVaultJurorMath.sol";
import { StakeVaultSlashMath } from "./library/StakeVaultSlashMath.sol";

contract StakeVault is IStakeVault, Initializable, ReentrancyGuard {
    using Checkpoints for Checkpoints.Trace224;
    using TokenTransfers for IERC20;

    uint64 public constant JUROR_EXIT_DELAY = 7 days;
    string public constant STRATEGY_KEY = "StakeVault";
    uint16 private constant BPS_SCALE = 10_000;
    uint8 private constant RULESET_RESERVED_PERCENT_OFFSET = 4;

    IERC20 public override goalToken;
    IERC20 public override cobuildToken;
    address public override goalTreasury;
    uint8 public override paymentTokenDecimals;

    IJBRulesets public goalRulesets;
    uint256 public goalRevnetId;
    uint256 private _goalWeightScale;
    uint112 public goalWeightSnapshot;
    uint16 public reservedPercentSnapshot;

    uint64 public override goalResolvedAt;

    mapping(address => uint256) private _stakedGoal;
    mapping(address => uint256) private _stakedCobuild;
    mapping(address => uint256) private _accountGoalStakeWeight;
    mapping(address => uint256) private _jurorLockedGoal;
    mapping(address => uint256) private _jurorLockedGoalWeight;
    mapping(address => address) private _jurorDelegate;

    struct JurorExitRequest {
        uint256 goalAmount;
        uint64 requestedAt;
    }

    mapping(address => JurorExitRequest) private _jurorExitRequest;
    mapping(address => Checkpoints.Trace224) private _jurorWeightCheckpoints;
    Checkpoints.Trace224 private _totalJurorWeightCheckpoints;
    mapping(address => uint256) private _underwriterWithdrawalPrepareCursor;
    mapping(address => uint64) private _underwriterWithdrawalPreparedForResolvedAt;
    mapping(address => uint256) private _underwriterWithdrawalPreparedBudgetCount;

    uint256 public override totalStakedGoal;
    uint256 public override totalStakedCobuild;
    uint256 private _totalWeight;

    address public override jurorSlasher;
    address public override underwriterSlasher;

    constructor(
        address goalTreasury_,
        IERC20 goalToken_,
        IERC20 cobuildToken_,
        IJBRulesets goalRulesets_,
        uint256 goalRevnetId_,
        uint8 paymentTokenDecimals_
    ) {
        if (
            !_isImplementationConstructorSentinelConfig(
                goalTreasury_,
                goalToken_,
                cobuildToken_,
                goalRulesets_,
                goalRevnetId_,
                paymentTokenDecimals_
            )
        ) {
            _initialize(goalTreasury_, goalToken_, cobuildToken_, goalRulesets_, goalRevnetId_, paymentTokenDecimals_);
        }
        _disableInitializers();
    }

    function _isImplementationConstructorSentinelConfig(
        address goalTreasury_,
        IERC20 goalToken_,
        IERC20 cobuildToken_,
        IJBRulesets goalRulesets_,
        uint256 goalRevnetId_,
        uint8 paymentTokenDecimals_
    ) internal pure returns (bool) {
        return
            goalTreasury_ == address(0) &&
            address(goalToken_) == address(0) &&
            address(cobuildToken_) == address(0) &&
            address(goalRulesets_) == address(0) &&
            goalRevnetId_ == 0 &&
            paymentTokenDecimals_ == 0;
    }

    function initialize(
        address goalTreasury_,
        IERC20 goalToken_,
        IERC20 cobuildToken_,
        IJBRulesets goalRulesets_,
        uint256 goalRevnetId_,
        uint8 paymentTokenDecimals_
    ) external initializer {
        _initialize(goalTreasury_, goalToken_, cobuildToken_, goalRulesets_, goalRevnetId_, paymentTokenDecimals_);
    }

    function _initialize(
        address goalTreasury_,
        IERC20 goalToken_,
        IERC20 cobuildToken_,
        IJBRulesets goalRulesets_,
        uint256 goalRevnetId_,
        uint8 paymentTokenDecimals_
    ) internal {
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (address(goalToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(cobuildToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(goalRulesets_) == address(0)) revert ADDRESS_ZERO();
        if (address(goalRulesets_).code.length == 0) revert NOT_A_CONTRACT(address(goalRulesets_));
        _requireGoalTokenRevnetLink(goalToken_, goalRulesets_, goalRevnetId_);

        uint8 goalDecimals = IERC20Metadata(address(goalToken_)).decimals();
        uint8 cobuildDecimals = IERC20Metadata(address(cobuildToken_)).decimals();
        if (goalDecimals != cobuildDecimals) revert DECIMALS_MISMATCH(goalDecimals, cobuildDecimals);
        if (paymentTokenDecimals_ > 77) revert INVALID_PAYMENT_TOKEN_DECIMALS(paymentTokenDecimals_);
        if (goalDecimals != paymentTokenDecimals_) {
            revert PAYMENT_TOKEN_DECIMALS_MISMATCH(goalDecimals, paymentTokenDecimals_);
        }

        goalTreasury = goalTreasury_;
        goalToken = goalToken_;
        cobuildToken = cobuildToken_;
        goalRulesets = goalRulesets_;
        goalRevnetId = goalRevnetId_;
        paymentTokenDecimals = paymentTokenDecimals_;
        _goalWeightScale = 10 ** paymentTokenDecimals_;

        JBRuleset memory currentRuleset = _requireCurrentRuleset(goalRulesets_, goalRevnetId_);
        goalWeightSnapshot = currentRuleset.weight;

        uint16 reservedPercent = uint16(currentRuleset.metadata >> RULESET_RESERVED_PERCENT_OFFSET);
        if (reservedPercent >= BPS_SCALE) revert INVALID_RESERVED_PERCENT(reservedPercent);
        reservedPercentSnapshot = reservedPercent;
    }

    function goalResolved() public view override returns (bool) {
        return goalResolvedAt != 0;
    }

    function depositGoal(uint256 amount) external override nonReentrant {
        if (goalResolvedAt != 0) revert GOAL_ALREADY_RESOLVED();
        if (amount == 0) revert INVALID_AMOUNT();

        _safeTransferFromExact(goalToken, msg.sender, amount);

        _requireStakingOpen();
        uint256 weightDelta = _computeGoalStakeWeightDelta(amount);
        // slither-disable-next-line incorrect-equality
        if (weightDelta == 0) revert ZERO_WEIGHT_DELTA();

        _stakedGoal[msg.sender] += amount;
        totalStakedGoal += amount;
        _accountGoalStakeWeight[msg.sender] += weightDelta;

        _totalWeight += weightDelta;

        emit GoalStaked(msg.sender, amount, weightDelta);
    }

    function depositCobuild(uint256 amount) external override nonReentrant {
        if (goalResolvedAt != 0) revert GOAL_ALREADY_RESOLVED();
        if (amount == 0) revert INVALID_AMOUNT();
        _requireStakingOpen();

        _safeTransferFromExact(cobuildToken, msg.sender, amount);

        _stakedCobuild[msg.sender] += amount;
        totalStakedCobuild += amount;

        _totalWeight += amount;

        emit CobuildStaked(msg.sender, amount, amount);
    }

    function withdrawGoal(uint256 amount, address to) external override nonReentrant {
        if (goalResolvedAt == 0) revert GOAL_NOT_RESOLVED();
        _requireUnderwriterWithdrawalPrepared(msg.sender);
        if (amount == 0) revert INVALID_AMOUNT();
        if (to == address(0)) revert ADDRESS_ZERO();

        uint256 staked = _stakedGoal[msg.sender];
        if (amount > staked) revert INSUFFICIENT_STAKED_BALANCE();
        if (amount > staked - _jurorLockedGoal[msg.sender]) revert JUROR_WITHDRAWAL_LOCKED();

        uint256 accountGoalStakeWeight = _accountGoalStakeWeight[msg.sender];
        uint256 weightReduction = amount == staked
            ? accountGoalStakeWeight
            : Math.mulDiv(accountGoalStakeWeight, amount, staked);

        _stakedGoal[msg.sender] = staked - amount;
        _accountGoalStakeWeight[msg.sender] = accountGoalStakeWeight - weightReduction;
        totalStakedGoal -= amount;
        _totalWeight -= weightReduction;

        _clampJurorGoalWeight(msg.sender);
        _setJurorWeight(msg.sender, _jurorLockedGoalWeight[msg.sender]);
        _safeTransferExact(goalToken, to, amount);
        emit GoalWithdrawn(msg.sender, to, amount);
    }

    function withdrawCobuild(uint256 amount, address to) external override nonReentrant {
        if (goalResolvedAt == 0) revert GOAL_NOT_RESOLVED();
        _requireUnderwriterWithdrawalPrepared(msg.sender);
        if (amount == 0) revert INVALID_AMOUNT();
        if (to == address(0)) revert ADDRESS_ZERO();

        uint256 staked = _stakedCobuild[msg.sender];
        if (amount > staked) revert INSUFFICIENT_STAKED_BALANCE();

        _stakedCobuild[msg.sender] = staked - amount;
        totalStakedCobuild -= amount;
        _totalWeight -= amount;
        _safeTransferExact(cobuildToken, to, amount);
        emit CobuildWithdrawn(msg.sender, to, amount);
    }

    function _requireGoalTokenRevnetLink(
        IERC20 goalToken_,
        IJBRulesets goalRulesets_,
        uint256 goalRevnetId_
    ) internal view {
        IJBDirectory directory;
        try IJBControlled(address(goalRulesets_)).DIRECTORY() returns (IJBDirectory resolvedDirectory) {
            directory = resolvedDirectory;
        } catch {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(goalToken_));
        }

        if (address(directory) == address(0) || address(directory).code.length == 0) {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(goalToken_));
        }

        address controller = address(directory.controllerOf(goalRevnetId_));
        if (controller == address(0)) revert INVALID_REVNET_CONTROLLER(controller);

        IJBTokens tokens;
        try IJBController(controller).TOKENS() returns (IJBTokens resolvedTokens) {
            tokens = resolvedTokens;
        } catch {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(goalToken_));
        }

        if (address(tokens) == address(0)) revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(goalToken_));

        uint256 derivedRevnetId;
        try tokens.projectIdOf(IJBToken(address(goalToken_))) returns (uint256 resolvedRevnetId) {
            derivedRevnetId = resolvedRevnetId;
        } catch {
            revert GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(goalToken_));
        }

        if (derivedRevnetId != goalRevnetId_) {
            revert GOAL_TOKEN_REVNET_MISMATCH(address(goalToken_), goalRevnetId_, derivedRevnetId);
        }
    }

    function markGoalResolved() external override {
        if (goalResolvedAt != 0) revert GOAL_ALREADY_RESOLVED();
        if (msg.sender != goalTreasury && !_goalTreasuryReportsResolved()) revert GOAL_NOT_RESOLVED();

        uint64 resolvedAt = uint64(block.timestamp);
        if (resolvedAt == 0) resolvedAt = 1;
        goalResolvedAt = resolvedAt;
        emit GoalResolved();
    }

    // Intentionally not `nonReentrant`: this path may call `premiumEscrow.slash(...)`,
    // which can route back into `slashUnderwriterStake(...)` (guarded by `nonReentrant`).
    function prepareUnderwriterWithdrawal(
        uint256 maxBudgets
    ) external override returns (uint256 nextBudgetIndex, uint256 budgetCount, bool complete) {
        uint64 resolvedAt = goalResolvedAt;
        if (resolvedAt == 0) revert GOAL_NOT_RESOLVED();
        if (maxBudgets == 0) revert INVALID_AMOUNT();

        address underwriter = msg.sender;
        IBudgetStakeLedger budgetStakeLedger = IBudgetStakeLedger(_requireBudgetStakeLedger());

        uint256 cursor = _underwriterWithdrawalPrepareCursor[underwriter];
        if (_underwriterWithdrawalPreparedForResolvedAt[underwriter] != resolvedAt) {
            cursor = 0;
            _underwriterWithdrawalPreparedBudgetCount[underwriter] = 0;
            _underwriterWithdrawalPreparedForResolvedAt[underwriter] = resolvedAt;
        }

        budgetCount = budgetStakeLedger.registeredBudgetCount();
        if (cursor > budgetCount) cursor = budgetCount;

        uint256 endExclusive = cursor + Math.min(maxBudgets, budgetCount - cursor);

        for (uint256 i = cursor; i < endExclusive; ) {
            address budget = budgetStakeLedger.registeredBudgetAt(i);
            _prepareUnderwriterForBudget(underwriter, budgetStakeLedger, budget);
            unchecked {
                ++i;
            }
        }

        nextBudgetIndex = endExclusive;
        _underwriterWithdrawalPrepareCursor[underwriter] = nextBudgetIndex;

        complete = nextBudgetIndex == budgetCount;
        if (complete) {
            _underwriterWithdrawalPreparedBudgetCount[underwriter] = budgetCount;
        }

        emit UnderwriterWithdrawalPrepared(underwriter, nextBudgetIndex, budgetCount, complete);
    }

    function optInAsJuror(uint256 goalAmount, address delegate) external override nonReentrant {
        if (goalResolvedAt != 0) revert GOAL_ALREADY_RESOLVED();
        if (goalAmount == 0) revert INVALID_JUROR_LOCK();

        uint256 stakedGoal = _stakedGoal[msg.sender];
        uint256 lockedGoal = _jurorLockedGoal[msg.sender];

        if (goalAmount > stakedGoal - lockedGoal) revert INSUFFICIENT_STAKED_BALANCE();

        uint256 accountGoalStakeWeight = _accountGoalStakeWeight[msg.sender];
        uint256 lockedGoalWeight = _jurorLockedGoalWeight[msg.sender];
        uint256 goalWeightDelta = StakeVaultJurorMath.computeOptInGoalWeightDelta(
            goalAmount,
            stakedGoal,
            lockedGoal,
            accountGoalStakeWeight,
            lockedGoalWeight
        );
        // slither-disable-next-line incorrect-equality
        if (goalWeightDelta == 0) revert ZERO_WEIGHT_DELTA();
        _jurorLockedGoalWeight[msg.sender] = lockedGoalWeight + goalWeightDelta;
        _jurorLockedGoal[msg.sender] = lockedGoal + goalAmount;
        _setJurorWeight(msg.sender, _currentJurorWeight(msg.sender) + goalWeightDelta);

        _jurorDelegate[msg.sender] = delegate;
        emit JurorOptedIn(msg.sender, goalAmount, goalWeightDelta, delegate);
    }

    function requestJurorExit(uint256 goalAmount) external override nonReentrant {
        if (goalAmount == 0) revert INVALID_JUROR_LOCK();

        uint256 lockedGoal = _jurorLockedGoal[msg.sender];
        if (goalAmount > lockedGoal) revert INSUFFICIENT_STAKED_BALANCE();

        uint64 nowTs = uint64(block.timestamp);
        _jurorExitRequest[msg.sender] = JurorExitRequest({ goalAmount: goalAmount, requestedAt: nowTs });

        emit JurorExitRequested(msg.sender, goalAmount, nowTs, nowTs + JUROR_EXIT_DELAY);
    }

    function finalizeJurorExit() external override nonReentrant {
        JurorExitRequest memory request = _jurorExitRequest[msg.sender];
        if (request.requestedAt == 0) revert EXIT_NOT_READY();

        uint64 exitDelayStart = request.requestedAt;
        uint64 resolvedAt = goalResolvedAt;
        if (resolvedAt > exitDelayStart) {
            exitDelayStart = resolvedAt;
        }
        if (block.timestamp < uint256(exitDelayStart) + JUROR_EXIT_DELAY) revert EXIT_NOT_READY();

        uint256 lockedGoal = _jurorLockedGoal[msg.sender];
        uint256 lockedGoalWeight = _jurorLockedGoalWeight[msg.sender];

        uint256 goalAmount = StakeVaultJurorMath.clampToAvailable(request.goalAmount, lockedGoal);

        uint256 goalWeightReduction = 0;
        if (goalAmount != 0) {
            goalWeightReduction = StakeVaultJurorMath.computeFinalizeGoalWeightReduction(
                goalAmount,
                lockedGoal,
                lockedGoalWeight
            );
            _jurorLockedGoal[msg.sender] = lockedGoal - goalAmount;
            _jurorLockedGoalWeight[msg.sender] = lockedGoalWeight - goalWeightReduction;
        }

        delete _jurorExitRequest[msg.sender];

        _setJurorWeight(msg.sender, _currentJurorWeight(msg.sender) - goalWeightReduction);

        emit JurorExitFinalized(msg.sender, goalAmount, goalWeightReduction);
    }

    function setJurorDelegate(address delegate) external override {
        _jurorDelegate[msg.sender] = delegate;
        emit JurorDelegateSet(msg.sender, delegate);
    }

    function setJurorSlasher(address slasher) external override {
        if (slasher == address(0)) revert ADDRESS_ZERO();
        if (jurorSlasher != address(0)) revert JUROR_SLASHER_ALREADY_SET();
        if (msg.sender != goalTreasury) revert UNAUTHORIZED();
        if (slasher.code.length == 0) revert INVALID_JUROR_SLASHER();

        jurorSlasher = slasher;
        emit JurorSlasherSet(slasher);
    }

    function setUnderwriterSlasher(address slasher) external override {
        if (slasher == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasher != address(0)) revert UNDERWRITER_SLASHER_ALREADY_SET();
        if (msg.sender != goalTreasury) revert UNAUTHORIZED();
        if (slasher.code.length == 0) revert INVALID_UNDERWRITER_SLASHER();

        underwriterSlasher = slasher;
        emit UnderwriterSlasherSet(slasher);
    }

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external override nonReentrant {
        if (msg.sender != jurorSlasher) revert ONLY_JUROR_SLASHER();
        StakeVaultSlashMath.SlashAmounts memory slash = _slashJurorGoalOnly(juror, weightAmount, recipient);
        if (slash.goalAmount == 0) return;

        emit JurorSlashed(juror, weightAmount, slash.goalWeight, slash.goalAmount, recipient);
    }

    function slashUnderwriterStake(
        address underwriter,
        uint256 weightAmount,
        address recipient
    ) external override nonReentrant {
        if (msg.sender != underwriterSlasher) revert ONLY_UNDERWRITER_SLASHER();
        StakeVaultSlashMath.SlashAmounts memory slash = _slashStake(underwriter, weightAmount, recipient);
        if (slash.goalAmount == 0 && slash.cobuildAmount == 0) return;

        uint256 totalWeightReduction = slash.goalWeight + slash.cobuildAmount;

        emit UnderwriterSlashed(
            underwriter,
            weightAmount,
            totalWeightReduction,
            slash.goalAmount,
            slash.cobuildAmount,
            recipient
        );
    }

    /// @dev Slash juror stake using goal-token weight only. Cobuild stake is never slashed for juror behavior.
    function _slashJurorGoalOnly(
        address juror,
        uint256 weightAmount,
        address recipient
    ) internal returns (StakeVaultSlashMath.SlashAmounts memory slash) {
        if (recipient == address(0)) revert ADDRESS_ZERO();
        if (weightAmount == 0) return slash;

        uint256 currentGoalWeight = _accountGoalStakeWeight[juror];
        if (currentGoalWeight == 0) return slash;

        uint256 requestedWeight = Math.min(weightAmount, currentGoalWeight);

        StakeVaultSlashMath.StakeSlashSnapshot memory snapshot = StakeVaultSlashMath.StakeSlashSnapshot({
            stakedGoal: _stakedGoal[juror],
            goalWeight: currentGoalWeight,
            stakedCobuild: 0,
            lockedGoal: _jurorLockedGoal[juror],
            lockedGoalWeight: _jurorLockedGoalWeight[juror],
            lockedCobuild: 0
        });

        slash = StakeVaultSlashMath.computeStakeSlashBreakdown(snapshot, requestedWeight, currentGoalWeight);
        // `stakedCobuild` is 0 in the snapshot, so only goal stake can be slashed.
        if (slash.goalAmount == 0) return slash;

        StakeVaultSlashMath.SlashAmounts memory lockedSlash = StakeVaultSlashMath.computeLockedSlashBreakdown(
            snapshot,
            slash
        );

        _stakedGoal[juror] = snapshot.stakedGoal - slash.goalAmount;
        totalStakedGoal -= slash.goalAmount;
        _accountGoalStakeWeight[juror] = snapshot.goalWeight - slash.goalWeight;

        if (lockedSlash.goalAmount != 0) {
            _jurorLockedGoal[juror] = snapshot.lockedGoal - lockedSlash.goalAmount;
            _jurorLockedGoalWeight[juror] = snapshot.lockedGoalWeight - lockedSlash.goalWeight;
        }

        _syncJurorExitRequest(juror);

        _totalWeight -= slash.goalWeight;

        _clampJurorGoalWeight(juror);
        _setJurorWeight(juror, _jurorLockedGoalWeight[juror]);
        _trySyncGoalFlowAllocation(juror);

        _safeTransferExact(goalToken, recipient, slash.goalAmount);
    }

    function _slashStake(
        address account,
        uint256 weightAmount,
        address recipient
    ) internal returns (StakeVaultSlashMath.SlashAmounts memory slash) {
        if (recipient == address(0)) revert ADDRESS_ZERO();
        if (weightAmount == 0) return slash;

        uint256 currentStakeWeight = _stakeWeightOf(account);
        if (currentStakeWeight == 0) return slash;

        uint256 requestedWeight = Math.min(weightAmount, currentStakeWeight);

        StakeVaultSlashMath.StakeSlashSnapshot memory snapshot = StakeVaultSlashMath.StakeSlashSnapshot({
            stakedGoal: _stakedGoal[account],
            goalWeight: _accountGoalStakeWeight[account],
            stakedCobuild: _stakedCobuild[account],
            lockedGoal: _jurorLockedGoal[account],
            lockedGoalWeight: _jurorLockedGoalWeight[account],
            lockedCobuild: 0
        });
        slash = StakeVaultSlashMath.computeStakeSlashBreakdown(snapshot, requestedWeight, currentStakeWeight);
        if (slash.goalAmount == 0 && slash.cobuildAmount == 0) return slash;

        StakeVaultSlashMath.SlashAmounts memory lockedSlash = StakeVaultSlashMath.computeLockedSlashBreakdown(
            snapshot,
            slash
        );

        if (slash.goalAmount != 0) {
            _stakedGoal[account] = snapshot.stakedGoal - slash.goalAmount;
            totalStakedGoal -= slash.goalAmount;
            _accountGoalStakeWeight[account] = snapshot.goalWeight - slash.goalWeight;
        }

        if (slash.cobuildAmount != 0) {
            _stakedCobuild[account] = snapshot.stakedCobuild - slash.cobuildAmount;
            totalStakedCobuild -= slash.cobuildAmount;
        }

        if (lockedSlash.goalAmount != 0) {
            _jurorLockedGoal[account] = snapshot.lockedGoal - lockedSlash.goalAmount;
            _jurorLockedGoalWeight[account] = snapshot.lockedGoalWeight - lockedSlash.goalWeight;
        }

        _syncJurorExitRequest(account);

        uint256 totalWeightReduction = slash.goalWeight + slash.cobuildAmount;
        _totalWeight -= totalWeightReduction;

        _clampJurorGoalWeight(account);

        _setJurorWeight(account, _jurorLockedGoalWeight[account]);
        _trySyncGoalFlowAllocation(account);

        if (slash.goalAmount != 0) {
            _safeTransferExact(goalToken, recipient, slash.goalAmount);
        }
        if (slash.cobuildAmount != 0) {
            _safeTransferExact(cobuildToken, recipient, slash.cobuildAmount);
        }

        return slash;
    }

    function _trySyncGoalFlowAllocation(address account) internal {
        try IGoalTreasury(goalTreasury).flow() returns (address flow) {
            if (flow == address(0)) return;
            try ICustomFlow(flow).syncAllocationForAccount(account) {} catch (bytes memory reason) {
                emit AllocationSyncFailed(account, flow, ICustomFlow.syncAllocationForAccount.selector, reason);
            }
        } catch (bytes memory reason) {
            emit AllocationSyncFailed(account, goalTreasury, ITreasuryRuntimeViews.flow.selector, reason);
        }
    }

    function stakeVault() external view override returns (address) {
        return address(this);
    }

    function allocationKey(address caller, bytes calldata) external pure override returns (uint256) {
        return AddressKeyAllocation.keyFor(caller);
    }

    function accountForAllocationKey(uint256 key) external pure override returns (address) {
        return AddressKeyAllocation.accountForKey(key);
    }

    function currentWeight(address, uint256 key) external view override returns (uint256) {
        if (_allocationFrozen()) return 0;
        return _stakeWeightOf(_accountForKey(key));
    }

    function canAllocate(address, uint256 key, address caller) external view override returns (bool) {
        if (_allocationFrozen()) return false;
        address allocator = _accountForKey(key);
        return caller == allocator && _stakeWeightOf(allocator) > 0;
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        if (_allocationFrozen()) return false;
        return _stakeWeightOf(account) > 0;
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        if (_allocationFrozen()) return 0;
        return _stakeWeightOf(account);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function weightOf(address user) external view override returns (uint256) {
        return _stakeWeightOf(user);
    }

    function totalWeight() external view override returns (uint256) {
        return _totalWeight;
    }

    function totalJurorWeight() external view override returns (uint256) {
        return _currentTotalJurorWeight();
    }

    function underwriterWithdrawalPrepareCursor(address underwriter) external view override returns (uint256) {
        return _underwriterWithdrawalPrepareCursor[underwriter];
    }

    function underwriterWithdrawalPreparedForResolvedAt(address underwriter) external view override returns (uint64) {
        return _underwriterWithdrawalPreparedForResolvedAt[underwriter];
    }

    function underwriterWithdrawalPreparedBudgetCount(address underwriter) external view override returns (uint256) {
        return _underwriterWithdrawalPreparedBudgetCount[underwriter];
    }

    function stakedGoalOf(address user) external view override returns (uint256) {
        return _stakedGoal[user];
    }

    function stakedCobuildOf(address user) external view override returns (uint256) {
        return _stakedCobuild[user];
    }

    function jurorLockedGoalOf(address user) external view override returns (uint256) {
        return _jurorLockedGoal[user];
    }

    function jurorWeightOf(address user) external view override returns (uint256) {
        return _currentJurorWeight(user);
    }

    function jurorDelegateOf(address user) external view override returns (address) {
        return _jurorDelegate[user];
    }

    function isAuthorizedJurorOperator(address juror, address operator) external view override returns (bool) {
        return operator == juror || operator == _jurorDelegate[juror];
    }

    function getPastJurorWeight(address user, uint256 blockNumber) external view override returns (uint256) {
        if (blockNumber >= block.number) revert BLOCK_NOT_YET_MINED();
        return _jurorWeightCheckpoints[user].upperLookupRecent(SafeCast.toUint32(blockNumber));
    }

    function getPastTotalJurorWeight(uint256 blockNumber) external view override returns (uint256) {
        if (blockNumber >= block.number) revert BLOCK_NOT_YET_MINED();
        return _totalJurorWeightCheckpoints.upperLookupRecent(SafeCast.toUint32(blockNumber));
    }

    function quoteGoalToCobuildWeightRatio(
        uint256 goalAmount
    ) public view override returns (uint256 weightOut, uint112 snapshotGoalWeight, uint256 weightScale) {
        if (goalAmount == 0) return (0, 0, 0);

        _requireStakingOpen();
        snapshotGoalWeight = goalWeightSnapshot;
        weightScale = _goalWeightScale;

        // Mirrors `depositGoal(...)` weight accounting.
        //
        // Base issuance weight is the inverse of JBX/Nana mint math:
        // tokenCount = amount * weight / weightScale  =>  amount = tokenCount * weightScale / weight.
        //
        // We snapshot `weight` and `reservedPercent` once at init:
        // - issuance pricing from snapped `weight` is always included,
        // - the reserved-percent premium linearly decays from activation -> deadline.
        weightOut = _computeGoalStakeWeightDelta(goalAmount);
    }

    /// @dev Compute the stake-weight delta for a goal-token deposit.
    ///
    /// Behavior:
    /// - Issuance pricing is always applied using the snapshotted ruleset weight.
    /// - Reserve premium is fully applied pre-activation, then decays linearly to zero by deadline.
    ///
    /// This is intentionally applied *at deposit time* to avoid requiring continuous weight syncs
    /// across Flow allocations.
    function _computeGoalStakeWeightDelta(uint256 goalAmount) internal view returns (uint256 weightOut) {
        // Issuance-priced base weight from snapshotted ruleset weight.
        uint256 issuanceBase = Math.mulDiv(goalAmount, _goalWeightScale, goalWeightSnapshot);
        uint16 reserveBps = reservedPercentSnapshot;
        if (reserveBps == 0) return issuanceBase;

        // Full reserve premium applied at activation/pre-activation.
        // fullBoost = BPS/(BPS-reserveBps), so boosted = issuanceBase * fullBoost.
        uint256 boosted = Math.mulDiv(issuanceBase, BPS_SCALE, BPS_SCALE - reserveBps);
        uint256 reservePremium = boosted - issuanceBase;
        if (reservePremium == 0) return issuanceBase;

        // Activation/pre-activation still receives the full reserve premium, but the metadata reads that
        // determine decay are required for this accounting path and must fail closed if unavailable.
        if (goalTreasury.code.length == 0) revert GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE();

        uint64 activated;
        uint64 end;
        IGoalTreasury treasury = IGoalTreasury(goalTreasury);
        try treasury.activatedAt() returns (uint64 activatedAt_) {
            activated = activatedAt_;
        } catch {
            revert GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE();
        }
        try treasury.deadline() returns (uint64 deadline_) {
            end = deadline_;
        } catch {
            revert GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE();
        }

        if (end == 0) revert GOAL_TREASURY_WEIGHT_METADATA_UNAVAILABLE();

        // Not yet activated => no decay.
        if (activated == 0) return boosted;

        // If the activation/deadline window is degenerate, treat as fully decayed reserve premium.
        if (end <= activated) return issuanceBase;

        uint256 nowTs = block.timestamp;
        uint256 activatedTs = uint256(activated);
        uint256 endTs = uint256(end);
        if (nowTs <= activatedTs) return boosted;
        if (nowTs >= endTs) return issuanceBase;

        uint256 remaining = endTs - nowTs;
        uint256 duration = endTs - activatedTs;

        // Linear interpolation for reserve premium only:
        // - boosted (at remaining == duration)
        // - issuanceBase (at remaining == 0)
        return issuanceBase + Math.mulDiv(reservePremium, remaining, duration);
    }

    function _requireCurrentRuleset(IJBRulesets rulesets, uint256 projectId) internal view returns (JBRuleset memory) {
        try rulesets.currentOf(projectId) returns (JBRuleset memory ruleset) {
            if (ruleset.weight == 0) revert GOAL_STAKING_CLOSED();
            return ruleset;
        } catch {
            revert GOAL_STAKING_CLOSED();
        }
    }

    function _requireStakingOpen() internal view {
        _requireCurrentRuleset(goalRulesets, goalRevnetId);
    }

    function _allocationFrozen() private view returns (bool) {
        return goalResolvedAt != 0 || _goalTreasuryReportsResolved();
    }

    function _goalTreasuryReportsResolved() private view returns (bool) {
        if (goalTreasury.code.length == 0) return false;

        try IGoalTreasury(goalTreasury).resolved() returns (bool resolved_) {
            return resolved_;
        } catch {
            return false;
        }
    }

    function _requireUnderwriterWithdrawalPrepared(address underwriter) private view {
        if (underwriterSlasher == address(0)) return;
        if (_underwriterWithdrawalPreparedForResolvedAt[underwriter] != goalResolvedAt) {
            revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
        }

        IBudgetStakeLedger budgetStakeLedger = IBudgetStakeLedger(_requireBudgetStakeLedger());
        uint256 budgetCount = budgetStakeLedger.registeredBudgetCount();
        if (_underwriterWithdrawalPrepareCursor[underwriter] != budgetCount) {
            revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
        }
        if (_underwriterWithdrawalPreparedBudgetCount[underwriter] != budgetCount) {
            revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
        }
    }

    function _prepareUnderwriterForBudget(
        address underwriter,
        IBudgetStakeLedger budgetStakeLedger,
        address budget
    ) private {
        if (budget == address(0) || budget.code.length == 0) revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();

        IBudgetTreasury budgetTreasury = IBudgetTreasury(budget);
        address premiumEscrowAddress = budgetTreasury.premiumEscrow();
        // `address(0)` is an explicit optional-premium mode: there is no underwriting side effect to reconcile.
        if (premiumEscrowAddress == address(0)) return;
        if (premiumEscrowAddress.code.length == 0) revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
        IPremiumEscrowSlashAccounting premiumEscrow = IPremiumEscrowSlashAccounting(premiumEscrowAddress);

        uint256 currentCoverage = budgetStakeLedger.userAllocatedStakeOnBudget(underwriter, budget);
        bool hasCurrentCoverage = currentCoverage != 0;
        uint256 userCov = premiumEscrow.userCov(underwriter);
        uint256 exposureIntegral = premiumEscrow.exposureIntegral(underwriter);
        uint256 creditDrawn = premiumEscrow.creditDrawn(underwriter);
        bool hasEscrowExposure = userCov != 0 || exposureIntegral != 0 || creditDrawn != 0;
        uint64 activatedAt = budgetTreasury.activatedAt();

        if (!budgetTreasury.resolved()) {
            // Nuanced unresolved handling:
            // - block unresolved budgets when the caller has activation-window/current exposure signals,
            // - allow unresolved pre-activation budgets with only current allocation to avoid unnecessary lockups.
            if ((activatedAt != 0 && hasCurrentCoverage) || hasEscrowExposure) {
                revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
            }
            return;
        }

        IBudgetTreasury.BudgetState state = budgetTreasury.state();
        bool slashRequired = activatedAt != 0 &&
            (state == IBudgetTreasury.BudgetState.Failed || state == IBudgetTreasury.BudgetState.Expired);
        bool hasSlashableExposure = hasCurrentCoverage || hasEscrowExposure;

        if (!slashRequired || !hasSlashableExposure) return;

        try premiumEscrow.slash(underwriter) {} catch {
            budgetTreasury.retryTerminalSideEffects();
            premiumEscrow.slash(underwriter);
        }
    }

    function _requireBudgetStakeLedger() private view returns (address budgetStakeLedger) {
        if (goalTreasury.code.length == 0) revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();

        try IGoalTreasury(goalTreasury).budgetStakeLedger() returns (address ledger) {
            budgetStakeLedger = ledger;
        } catch {
            revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
        }
        if (budgetStakeLedger == address(0) || budgetStakeLedger.code.length == 0) {
            revert UNDERWRITER_WITHDRAWAL_NOT_PREPARED();
        }
    }

    function _setJurorWeight(address juror, uint256 newWeight) internal {
        uint256 oldWeight = _currentJurorWeight(juror);
        if (oldWeight == newWeight) return;

        uint256 oldTotalWeight = _currentTotalJurorWeight();
        uint256 newTotalWeight;
        if (newWeight > oldWeight) {
            newTotalWeight = oldTotalWeight + (newWeight - oldWeight);
        } else {
            newTotalWeight = oldTotalWeight - (oldWeight - newWeight);
        }

        _jurorWeightCheckpoints[juror].push(SafeCast.toUint32(block.number), SafeCast.toUint224(newWeight));
        _totalJurorWeightCheckpoints.push(SafeCast.toUint32(block.number), SafeCast.toUint224(newTotalWeight));
    }

    function _clampJurorGoalWeight(address juror) internal {
        uint256 lockedGoalWeight = _jurorLockedGoalWeight[juror];
        uint256 currentGoalWeight = _accountGoalStakeWeight[juror];

        if (lockedGoalWeight > currentGoalWeight) {
            _jurorLockedGoalWeight[juror] = currentGoalWeight;
        }

        if (_jurorLockedGoal[juror] == 0) {
            _jurorLockedGoalWeight[juror] = 0;
        }
    }

    function _syncJurorExitRequest(address juror) internal {
        JurorExitRequest storage request = _jurorExitRequest[juror];
        if (request.requestedAt == 0) return;

        uint256 lockedGoal = _jurorLockedGoal[juror];

        request.goalAmount = StakeVaultJurorMath.clampToAvailable(request.goalAmount, lockedGoal);
    }

    function _stakeWeightOf(address user) internal view returns (uint256) {
        return _accountGoalStakeWeight[user] + _stakedCobuild[user];
    }

    function _currentJurorWeight(address juror) internal view returns (uint256) {
        return _jurorWeightCheckpoints[juror].latest();
    }

    function _currentTotalJurorWeight() internal view returns (uint256) {
        return _totalJurorWeightCheckpoints.latest();
    }

    function _accountForKey(uint256 key) internal pure returns (address) {
        return AddressKeyAllocation.accountForKey(key);
    }

    function _safeTransferFromExact(IERC20 token, address from, uint256 amount) internal {
        uint256 received = token.safeTransferFromReceived(from, address(this), amount);
        if (received != amount) revert TRANSFER_AMOUNT_MISMATCH();
    }

    function _safeTransferExact(IERC20 token, address to, uint256 amount) internal {
        (uint256 spent, uint256 received) = token.safeTransferSpentAndReceived(to, amount);
        if (spent != amount) revert TRANSFER_AMOUNT_MISMATCH();
        if (received != amount) revert TRANSFER_AMOUNT_MISMATCH();
    }
}
