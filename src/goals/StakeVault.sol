// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IStakeVault} from "../interfaces/IStakeVault.sol";
import {IGoalTreasury} from "../interfaces/IGoalTreasury.sol";
import {ICustomFlow} from "../interfaces/IFlow.sol";
import {ITreasuryAuthority} from "../interfaces/ITreasuryAuthority.sol";
import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBControlled} from "@bananapus/core-v5/interfaces/IJBControlled.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StakeVaultJurorMath} from "./library/StakeVaultJurorMath.sol";
import {StakeVaultSlashMath} from "./library/StakeVaultSlashMath.sol";

contract StakeVault is IStakeVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    uint64 public constant JUROR_EXIT_DELAY = 7 days;
    string public constant STRATEGY_KEY = "StakeVault";

    IERC20 public immutable override goalToken;
    IERC20 public immutable override cobuildToken;
    address public immutable override goalTreasury;
    uint8 public immutable override paymentTokenDecimals;

    IJBRulesets public immutable goalRulesets;
    uint256 public immutable goalRevnetId;
    uint256 private immutable _goalWeightRatio;

    bool public override goalResolved;
    uint64 public override goalResolvedAt;

    mapping(address => uint256) private _stakedGoal;
    mapping(address => uint256) private _stakedCobuild;
    mapping(address => uint256) private _goalWeight;
    mapping(address => uint256) private _jurorLockedGoal;
    mapping(address => uint256) private _jurorLockedCobuild;
    mapping(address => uint256) private _jurorLockedGoalWeight;
    mapping(address => uint256) private _jurorWeight;
    mapping(address => address) private _jurorDelegate;

    struct JurorExitRequest {
        uint256 goalAmount;
        uint256 cobuildAmount;
        uint64 requestedAt;
    }

    mapping(address => JurorExitRequest) private _jurorExitRequest;
    mapping(address => Checkpoints.Trace224) private _jurorWeightCheckpoints;
    Checkpoints.Trace224 private _totalJurorWeightCheckpoints;

    uint256 public override totalStakedGoal;
    uint256 public override totalStakedCobuild;
    uint256 public override totalJurorWeight;
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
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (address(goalToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(cobuildToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(goalRulesets_) == address(0)) revert ADDRESS_ZERO();
        if (address(goalRulesets_).code.length != 0) {
            _requireGoalTokenRevnetLink(goalToken_, goalRulesets_, goalRevnetId_);
        }

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
        _goalWeightRatio = 10 ** paymentTokenDecimals_;
    }

    function depositGoal(uint256 amount) external override nonReentrant {
        if (goalResolved) revert GOAL_ALREADY_RESOLVED();
        if (amount == 0) revert INVALID_AMOUNT();

        uint256 balanceBefore = goalToken.balanceOf(address(this));
        goalToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = goalToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TRANSFER_AMOUNT_MISMATCH();

        uint112 goalWeight = _requireStakingOpen();
        uint256 weightDelta = Math.mulDiv(received, _goalWeightRatio, goalWeight);
        // slither-disable-next-line incorrect-equality
        if (weightDelta == 0) revert ZERO_WEIGHT_DELTA();

        _stakedGoal[msg.sender] += received;
        totalStakedGoal += received;
        _goalWeight[msg.sender] += weightDelta;

        _totalWeight += weightDelta;

        emit GoalStaked(msg.sender, received, weightDelta);
    }

    function depositCobuild(uint256 amount) external override nonReentrant {
        if (goalResolved) revert GOAL_ALREADY_RESOLVED();
        if (amount == 0) revert INVALID_AMOUNT();
        _requireStakingOpen();

        uint256 balanceBefore = cobuildToken.balanceOf(address(this));
        cobuildToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = cobuildToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TRANSFER_AMOUNT_MISMATCH();

        _stakedCobuild[msg.sender] += received;
        totalStakedCobuild += received;

        _totalWeight += received;

        emit CobuildStaked(msg.sender, received, received);
    }

    function withdrawGoal(uint256 amount, address to) external override nonReentrant {
        if (!goalResolved) revert GOAL_NOT_RESOLVED();
        if (amount == 0) revert INVALID_AMOUNT();
        if (to == address(0)) revert ADDRESS_ZERO();

        uint256 staked = _stakedGoal[msg.sender];
        if (amount > staked) revert INSUFFICIENT_STAKED_BALANCE();
        if (amount > staked - _jurorLockedGoal[msg.sender]) revert JUROR_WITHDRAWAL_LOCKED();

        uint256 goalWeightForUser = _goalWeight[msg.sender];
        uint256 weightReduction = amount == staked ? goalWeightForUser : Math.mulDiv(goalWeightForUser, amount, staked);

        _stakedGoal[msg.sender] = staked - amount;
        _goalWeight[msg.sender] = goalWeightForUser - weightReduction;
        totalStakedGoal -= amount;
        _totalWeight -= weightReduction;

        _clampJurorGoalWeight(msg.sender);
        _setJurorWeight(msg.sender, _jurorLockedGoalWeight[msg.sender] + _jurorLockedCobuild[msg.sender]);
        _safeTransferExact(goalToken, to, amount);
        emit GoalWithdrawn(msg.sender, to, amount);
    }

    function withdrawCobuild(uint256 amount, address to) external override nonReentrant {
        if (!goalResolved) revert GOAL_NOT_RESOLVED();
        if (amount == 0) revert INVALID_AMOUNT();
        if (to == address(0)) revert ADDRESS_ZERO();

        uint256 staked = _stakedCobuild[msg.sender];
        if (amount > staked) revert INSUFFICIENT_STAKED_BALANCE();
        if (amount > staked - _jurorLockedCobuild[msg.sender]) revert JUROR_WITHDRAWAL_LOCKED();

        _stakedCobuild[msg.sender] = staked - amount;
        totalStakedCobuild -= amount;
        _totalWeight -= amount;
        _safeTransferExact(cobuildToken, to, amount);
        emit CobuildWithdrawn(msg.sender, to, amount);
    }

    function _requireGoalTokenRevnetLink(IERC20 goalToken_, IJBRulesets goalRulesets_, uint256 goalRevnetId_)
        internal
        view
    {
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
        if (goalResolved) revert GOAL_ALREADY_RESOLVED();
        if (msg.sender != goalTreasury && !_goalTreasuryReportsResolved()) revert GOAL_NOT_RESOLVED();

        goalResolved = true;
        goalResolvedAt = uint64(block.timestamp);
        emit GoalResolved();
    }

    function optInAsJuror(uint256 goalAmount, uint256 cobuildAmount, address delegate) external override nonReentrant {
        if (goalResolved) revert GOAL_ALREADY_RESOLVED();
        if (goalAmount == 0 && cobuildAmount == 0) revert INVALID_JUROR_LOCK();

        uint256 stakedGoal = _stakedGoal[msg.sender];
        uint256 stakedCobuild = _stakedCobuild[msg.sender];
        uint256 lockedGoal = _jurorLockedGoal[msg.sender];
        uint256 lockedCobuild = _jurorLockedCobuild[msg.sender];

        if (goalAmount > stakedGoal - lockedGoal) revert INSUFFICIENT_STAKED_BALANCE();
        if (cobuildAmount > stakedCobuild - lockedCobuild) revert INSUFFICIENT_STAKED_BALANCE();

        uint256 goalWeightDelta = 0;
        if (goalAmount != 0) {
            uint256 goalWeight = _goalWeight[msg.sender];
            uint256 lockedGoalWeight = _jurorLockedGoalWeight[msg.sender];
            goalWeightDelta = StakeVaultJurorMath.computeOptInGoalWeightDelta(
                goalAmount, stakedGoal, lockedGoal, goalWeight, lockedGoalWeight
            );
            // slither-disable-next-line incorrect-equality
            if (goalWeightDelta == 0) revert ZERO_WEIGHT_DELTA();
            _jurorLockedGoalWeight[msg.sender] = lockedGoalWeight + goalWeightDelta;
            _jurorLockedGoal[msg.sender] = lockedGoal + goalAmount;
        }

        if (cobuildAmount != 0) {
            _jurorLockedCobuild[msg.sender] = lockedCobuild + cobuildAmount;
        }

        uint256 oldWeight = _jurorWeight[msg.sender];
        uint256 weightDelta = goalWeightDelta + cobuildAmount;
        uint256 newWeight = oldWeight + weightDelta;
        _setJurorWeight(msg.sender, newWeight);

        _jurorDelegate[msg.sender] = delegate;
        emit JurorOptedIn(msg.sender, goalAmount, cobuildAmount, weightDelta, delegate);
    }

    function requestJurorExit(uint256 goalAmount, uint256 cobuildAmount) external override nonReentrant {
        if (goalAmount == 0 && cobuildAmount == 0) revert INVALID_JUROR_LOCK();

        uint256 lockedGoal = _jurorLockedGoal[msg.sender];
        uint256 lockedCobuild = _jurorLockedCobuild[msg.sender];
        if (goalAmount > lockedGoal) revert INSUFFICIENT_STAKED_BALANCE();
        if (cobuildAmount > lockedCobuild) revert INSUFFICIENT_STAKED_BALANCE();

        uint64 nowTs = uint64(block.timestamp);
        _jurorExitRequest[msg.sender] =
            JurorExitRequest({goalAmount: goalAmount, cobuildAmount: cobuildAmount, requestedAt: nowTs});

        emit JurorExitRequested(msg.sender, goalAmount, cobuildAmount, nowTs, nowTs + JUROR_EXIT_DELAY);
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
        uint256 lockedCobuild = _jurorLockedCobuild[msg.sender];

        uint256 goalAmount = StakeVaultJurorMath.clampToAvailable(request.goalAmount, lockedGoal);
        uint256 cobuildAmount = StakeVaultJurorMath.clampToAvailable(request.cobuildAmount, lockedCobuild);

        uint256 goalWeightReduction = 0;
        if (goalAmount != 0) {
            goalWeightReduction =
                StakeVaultJurorMath.computeFinalizeGoalWeightReduction(goalAmount, lockedGoal, lockedGoalWeight);
            _jurorLockedGoal[msg.sender] = lockedGoal - goalAmount;
            _jurorLockedGoalWeight[msg.sender] = lockedGoalWeight - goalWeightReduction;
        }

        if (cobuildAmount != 0) {
            _jurorLockedCobuild[msg.sender] = lockedCobuild - cobuildAmount;
        }

        delete _jurorExitRequest[msg.sender];

        uint256 oldWeight = _jurorWeight[msg.sender];
        uint256 weightReduction = goalWeightReduction + cobuildAmount;
        uint256 newWeight = oldWeight - weightReduction;
        _setJurorWeight(msg.sender, newWeight);

        emit JurorExitFinalized(msg.sender, goalAmount, cobuildAmount, weightReduction);
    }

    function setJurorDelegate(address delegate) external override {
        _jurorDelegate[msg.sender] = delegate;
        emit JurorDelegateSet(msg.sender, delegate);
    }

    function setJurorSlasher(address slasher) external override {
        if (slasher == address(0)) revert ADDRESS_ZERO();
        if (jurorSlasher != address(0)) revert JUROR_SLASHER_ALREADY_SET();

        if (msg.sender != goalTreasury) {
            address treasuryAuthority = _goalTreasuryAuthority();
            if (msg.sender != treasuryAuthority) revert UNAUTHORIZED();
        }
        if (slasher.code.length == 0) revert INVALID_JUROR_SLASHER();

        jurorSlasher = slasher;
        emit JurorSlasherSet(slasher);
    }

    function setUnderwriterSlasher(address slasher) external override {
        if (slasher == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasher != address(0)) revert UNDERWRITER_SLASHER_ALREADY_SET();

        if (msg.sender != goalTreasury) {
            address treasuryAuthority = _goalTreasuryAuthority();
            if (msg.sender != treasuryAuthority) revert UNAUTHORIZED();
        }
        if (slasher.code.length == 0) revert INVALID_UNDERWRITER_SLASHER();

        underwriterSlasher = slasher;
        emit UnderwriterSlasherSet(slasher);
    }

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external override nonReentrant {
        if (msg.sender != jurorSlasher) revert ONLY_JUROR_SLASHER();
        if (recipient == address(0)) revert ADDRESS_ZERO();
        if (weightAmount == 0) return;

        uint256 currentStakeWeight = _stakeWeightOf(juror);
        if (currentStakeWeight == 0) return;

        uint256 requestedWeight = Math.min(weightAmount, currentStakeWeight);

        StakeVaultSlashMath.StakeSlashSnapshot memory snapshot = _loadStakeSlashSnapshot(juror);
        StakeVaultSlashMath.SlashAmounts memory slash =
            StakeVaultSlashMath.computeStakeSlashBreakdown(snapshot, requestedWeight, currentStakeWeight);
        if (slash.goalAmount == 0 && slash.cobuildAmount == 0) return;

        snapshot = _loadLockedStakeSlashSnapshot(juror, snapshot);
        StakeVaultSlashMath.SlashAmounts memory lockedSlash =
            StakeVaultSlashMath.computeLockedSlashBreakdown(snapshot, slash);

        if (slash.goalAmount != 0) {
            _stakedGoal[juror] = snapshot.stakedGoal - slash.goalAmount;
            totalStakedGoal -= slash.goalAmount;
            _goalWeight[juror] = snapshot.goalWeight - slash.goalWeight;
        }

        if (slash.cobuildAmount != 0) {
            _stakedCobuild[juror] = snapshot.stakedCobuild - slash.cobuildAmount;
            totalStakedCobuild -= slash.cobuildAmount;
        }

        if (lockedSlash.goalAmount != 0) {
            _jurorLockedGoal[juror] = snapshot.lockedGoal - lockedSlash.goalAmount;
            _jurorLockedGoalWeight[juror] = snapshot.lockedGoalWeight - lockedSlash.goalWeight;
        }

        if (lockedSlash.cobuildAmount != 0) {
            _jurorLockedCobuild[juror] = snapshot.lockedCobuild - lockedSlash.cobuildAmount;
        }

        _syncJurorExitRequest(juror);

        uint256 totalWeightReduction = slash.goalWeight + slash.cobuildAmount;
        _totalWeight -= totalWeightReduction;

        _clampJurorGoalWeight(juror);

        uint256 newJurorWeight = _jurorLockedGoalWeight[juror] + _jurorLockedCobuild[juror];
        _setJurorWeight(juror, newJurorWeight);
        _trySyncGoalFlowAllocation(juror);

        if (slash.goalAmount != 0) {
            _safeTransferExact(goalToken, recipient, slash.goalAmount);
        }
        if (slash.cobuildAmount != 0) {
            _safeTransferExact(cobuildToken, recipient, slash.cobuildAmount);
        }

        emit JurorSlashed(juror, weightAmount, totalWeightReduction, slash.goalAmount, slash.cobuildAmount, recipient);
    }

    function slashUnderwriterStake(address underwriter, uint256 weightAmount, address recipient)
        external
        override
        nonReentrant
    {
        if (msg.sender != underwriterSlasher) revert ONLY_UNDERWRITER_SLASHER();
        if (recipient == address(0)) revert ADDRESS_ZERO();
        if (weightAmount == 0) return;

        uint256 currentStakeWeight = _stakeWeightOf(underwriter);
        if (currentStakeWeight == 0) return;

        uint256 requestedWeight = Math.min(weightAmount, currentStakeWeight);

        StakeVaultSlashMath.StakeSlashSnapshot memory snapshot = _loadStakeSlashSnapshot(underwriter);
        StakeVaultSlashMath.SlashAmounts memory slash =
            StakeVaultSlashMath.computeStakeSlashBreakdown(snapshot, requestedWeight, currentStakeWeight);
        if (slash.goalAmount == 0 && slash.cobuildAmount == 0) return;

        snapshot = _loadLockedStakeSlashSnapshot(underwriter, snapshot);
        StakeVaultSlashMath.SlashAmounts memory lockedSlash =
            StakeVaultSlashMath.computeLockedSlashBreakdown(snapshot, slash);

        if (slash.goalAmount != 0) {
            _stakedGoal[underwriter] = snapshot.stakedGoal - slash.goalAmount;
            totalStakedGoal -= slash.goalAmount;
            _goalWeight[underwriter] = snapshot.goalWeight - slash.goalWeight;
        }

        if (slash.cobuildAmount != 0) {
            _stakedCobuild[underwriter] = snapshot.stakedCobuild - slash.cobuildAmount;
            totalStakedCobuild -= slash.cobuildAmount;
        }

        if (lockedSlash.goalAmount != 0) {
            _jurorLockedGoal[underwriter] = snapshot.lockedGoal - lockedSlash.goalAmount;
            _jurorLockedGoalWeight[underwriter] = snapshot.lockedGoalWeight - lockedSlash.goalWeight;
        }

        if (lockedSlash.cobuildAmount != 0) {
            _jurorLockedCobuild[underwriter] = snapshot.lockedCobuild - lockedSlash.cobuildAmount;
        }

        _syncJurorExitRequest(underwriter);

        uint256 totalWeightReduction = slash.goalWeight + slash.cobuildAmount;
        _totalWeight -= totalWeightReduction;

        _clampJurorGoalWeight(underwriter);

        uint256 newJurorWeight = _jurorLockedGoalWeight[underwriter] + _jurorLockedCobuild[underwriter];
        _setJurorWeight(underwriter, newJurorWeight);
        _trySyncGoalFlowAllocation(underwriter);

        if (slash.goalAmount != 0) {
            _safeTransferExact(goalToken, recipient, slash.goalAmount);
        }
        if (slash.cobuildAmount != 0) {
            _safeTransferExact(cobuildToken, recipient, slash.cobuildAmount);
        }

        emit UnderwriterSlashed(
            underwriter, weightAmount, totalWeightReduction, slash.goalAmount, slash.cobuildAmount, recipient
        );
    }

    function _loadStakeSlashSnapshot(address juror)
        internal
        view
        returns (StakeVaultSlashMath.StakeSlashSnapshot memory snapshot)
    {
        snapshot.stakedGoal = _stakedGoal[juror];
        snapshot.goalWeight = _goalWeight[juror];
        snapshot.stakedCobuild = _stakedCobuild[juror];
    }

    function _loadLockedStakeSlashSnapshot(address juror, StakeVaultSlashMath.StakeSlashSnapshot memory snapshot)
        internal
        view
        returns (StakeVaultSlashMath.StakeSlashSnapshot memory)
    {
        snapshot.lockedGoal = _jurorLockedGoal[juror];
        snapshot.lockedGoalWeight = _jurorLockedGoalWeight[juror];
        snapshot.lockedCobuild = _jurorLockedCobuild[juror];
        return snapshot;
    }

    function _trySyncGoalFlowAllocation(address account) internal {
        try IGoalTreasury(goalTreasury).flow() returns (address flow) {
            if (flow == address(0)) return;
            try ICustomFlow(flow).syncAllocationForAccount(account) {}
            catch (bytes memory reason) {
                emit AllocationSyncFailed(account, flow, ICustomFlow.syncAllocationForAccount.selector, reason);
            }
        } catch (bytes memory reason) {
            emit AllocationSyncFailed(account, goalTreasury, IGoalTreasury.flow.selector, reason);
        }
    }

    function stakeVault() external view override returns (address) {
        return address(this);
    }

    function allocationKey(address caller, bytes calldata) external pure override returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(uint256 allocationKey) external pure override returns (address) {
        return _accountForKey(allocationKey);
    }

    function currentWeight(uint256 key) external view override returns (uint256) {
        if (goalResolved) return 0;
        return _stakeWeightOf(_accountForKey(key));
    }

    function canAllocate(uint256 key, address caller) external view override returns (bool) {
        if (goalResolved) return false;
        address allocator = _accountForKey(key);
        return caller == allocator && _stakeWeightOf(allocator) > 0;
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        if (goalResolved) return false;
        return _stakeWeightOf(account) > 0;
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        if (goalResolved) return 0;
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

    function stakedGoalOf(address user) external view override returns (uint256) {
        return _stakedGoal[user];
    }

    function stakedCobuildOf(address user) external view override returns (uint256) {
        return _stakedCobuild[user];
    }

    function jurorLockedGoalOf(address user) external view override returns (uint256) {
        return _jurorLockedGoal[user];
    }

    function jurorLockedCobuildOf(address user) external view override returns (uint256) {
        return _jurorLockedCobuild[user];
    }

    function jurorWeightOf(address user) external view override returns (uint256) {
        return _jurorWeight[user];
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

    function quoteGoalToCobuildWeightRatio(uint256 goalAmount)
        public
        view
        override
        returns (uint256 weightOut, uint112 goalWeight, uint256 weightRatio)
    {
        if (goalAmount == 0) return (0, 0, 0);

        goalWeight = _requireStakingOpen();
        weightRatio = _goalWeightRatio;

        // Mirror the inverse of JBX/Nana mint math:
        // tokenCount = amount * weight / weightRatio  =>  amount = tokenCount * weightRatio / weight.
        weightOut = Math.mulDiv(goalAmount, weightRatio, goalWeight);
    }

    function _readCurrentWeight(IJBRulesets rulesets, uint256 projectId) internal view returns (uint112) {
        try rulesets.currentOf(projectId) returns (JBRuleset memory ruleset) {
            return ruleset.weight;
        } catch {
            return 0;
        }
    }

    function _requireStakingOpen() internal view returns (uint112 goalWeight) {
        goalWeight = _readCurrentWeight(goalRulesets, goalRevnetId);
        if (goalWeight == 0) revert GOAL_STAKING_CLOSED();
    }

    function _goalTreasuryReportsResolved() private view returns (bool) {
        if (goalTreasury.code.length == 0) return false;

        try IGoalTreasury(goalTreasury).resolved() returns (bool resolved_) {
            return resolved_;
        } catch {
            return false;
        }
    }

    function _goalTreasuryAuthority() internal view returns (address) {
        if (goalTreasury.code.length == 0) return address(0);

        try ITreasuryAuthority(goalTreasury).authority() returns (address authority_) {
            return authority_;
        } catch {
            revert INVALID_TREASURY_AUTHORITY_SURFACE(goalTreasury);
        }
    }

    function _setJurorWeight(address juror, uint256 newWeight) internal {
        uint256 oldWeight = _jurorWeight[juror];
        if (oldWeight == newWeight) return;

        _jurorWeight[juror] = newWeight;
        if (newWeight > oldWeight) {
            totalJurorWeight += newWeight - oldWeight;
        } else {
            totalJurorWeight -= oldWeight - newWeight;
        }

        _jurorWeightCheckpoints[juror].push(SafeCast.toUint32(block.number), SafeCast.toUint224(newWeight));
        _totalJurorWeightCheckpoints.push(SafeCast.toUint32(block.number), SafeCast.toUint224(totalJurorWeight));
    }

    function _clampJurorGoalWeight(address juror) internal {
        uint256 lockedGoalWeight = _jurorLockedGoalWeight[juror];
        uint256 currentGoalWeight = _goalWeight[juror];

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
        uint256 lockedCobuild = _jurorLockedCobuild[juror];

        request.goalAmount = StakeVaultJurorMath.clampToAvailable(request.goalAmount, lockedGoal);
        request.cobuildAmount = StakeVaultJurorMath.clampToAvailable(request.cobuildAmount, lockedCobuild);
    }

    function _stakeWeightOf(address user) internal view returns (uint256) {
        return _goalWeight[user] + _stakedCobuild[user];
    }

    function _accountForKey(uint256 key) internal pure returns (address) {
        return address(uint160(key));
    }

    function _safeTransferExact(IERC20 token, address to, uint256 amount) internal {
        uint256 vaultBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 spent = vaultBalanceBefore - token.balanceOf(address(this));
        if (spent != amount) revert TRANSFER_AMOUNT_MISMATCH();
        uint256 received = token.balanceOf(to) - recipientBalanceBefore;
        if (received != amount) revert TRANSFER_AMOUNT_MISMATCH();
    }
}
