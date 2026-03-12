// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

/// @notice Community-level split hook that routes its reserved community-token callback slice into child goals.
/// @dev A fixed init-time canonical community terminal seeds one-shot explicit routes before the community revnet pay
/// executes. Explicit routes are the only source of historical market signal. All non-explicit historical routing is
/// deferred into the paginated backlog flush path.
contract CobuildSplitHook is ICobuildSplitHook, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant RESERVED_TOKENS_GROUP_ID = 1;
    uint256 private constant ROUTING_SCORE_HALF_LIFE = 30 days;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error UNAUTHORIZED();
    error INVALID_COMMUNITY_REVNET_ID();
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_SOURCE_TOKEN(address expectedToken, address actualToken);
    error INVALID_DIRECTORY(address expectedDirectory, address actualDirectory);
    error INVALID_SPLIT_GROUP(uint256 expectedGroupId, uint256 actualGroupId);
    error INVALID_ROUTE_LENGTHS(uint256 goalIdsLength, uint256 weightsLength);
    error INVALID_ROUTE_WEIGHT(uint256 index);
    error DUPLICATE_GOAL(uint256 goalId);
    error GOAL_NOT_APPROVED(uint256 goalId);
    error NO_GOAL_TREASURY(uint256 goalId);
    error NO_ROUTE_AVAILABLE();
    error PENDING_ROUTE_EXISTS();
    error NO_PENDING_ROUTE();
    error INVALID_HISTORICAL_FLUSH_PAGE_SIZE();
    error INVALID_BACKLOG_SNAPSHOT(uint256 backlogTokenCount, uint256 sourceAmount);
    error NO_GOAL_TERMINAL(uint256 goalId);
    error GOAL_PAYMENT_OUTFLOW_MISMATCH(uint256 goalId, uint256 expectedAmount, uint256 actualAmount);
    error NATIVE_VALUE_MISMATCH(uint256 expected, uint256 actual);
    error INSUFFICIENT_HOOK_BALANCE(address token, uint256 expected, uint256 available);
    error INVALID_QUEUED_ROLLOVER_RELEASE_COUNT();

    event RouteSetterConfigured(address indexed routeSetter);
    event GoalRegistryConfigured(address indexed goalRegistry);
    event PendingRouteStarted(
        address indexed payer,
        address indexed beneficiary,
        uint256 backlogTokenCount,
        uint256[] goalIds,
        uint32[] weights
    );
    event PendingRouteConsumed(
        address indexed payer,
        address indexed beneficiary,
        uint256 sourceAmount,
        uint256[] goalIds,
        uint32[] weights
    );
    event HistoricalBacklogDeferred(uint256 amount, uint256 newBacklogAmount);
    event HistoricalBacklogFlushed(uint256 amount, uint256 remainingBacklogAmount);
    event HistoricalBacklogFlushReset(uint256 indexed epoch, uint256 remainingBacklogAmount);
    event QueuedRolloverAdded(
        address indexed sender,
        uint256 amount,
        uint64 releaseAt,
        uint256 newQueuedRolloverAmount
    );
    event QueuedRolloversReleased(uint256 releasedAmount, uint256 newHistoricalBacklogAmount);
    event RoutingScoreRecorded(uint256 indexed goalId, uint256 amount, uint256 newRoutingScore);
    event GoalRouted(
        address indexed beneficiary,
        uint256 indexed goalId,
        address indexed token,
        uint256 amount,
        bool fromPendingRoute
    );

    struct PendingRoute {
        address payer;
        address beneficiary;
        uint64 createdAt;
        uint256 backlogTokenCount;
        bool active;
        uint256[] goalIds;
        uint32[] weights;
    }

    struct RouteRuntime {
        IERC20 token;
        uint256 sourceAmount;
        address beneficiary;
        uint256[] goalIds;
        uint32[] weights;
        bool fromPendingRoute;
    }

    struct HistoricalBacklogProgress {
        bool active;
        uint256 remainingAmount;
        uint256 processedGoalCount;
    }

    struct QueuedRollover {
        uint64 releaseAt;
        uint256 amount;
    }

    struct PendingRouteExecution {
        address payer;
        address beneficiary;
        uint256 backlogTokenCount;
        uint256 routeAmount;
        uint256[] goalIds;
        uint32[] weights;
    }

    IJBDirectory public directory;
    uint256 public communityRevnetId;
    address public communityToken;
    address public routeSetter;
    ICommunityGoalRegistry private _goalRegistry;
    IGoalDeploymentRegistry private _goalDeploymentRegistry;
    // Explicit-route amounts accumulate into a lazily decaying routing score. Selectability gates live historical-route inclusion.
    mapping(uint256 => uint256) private _routingScoreOf;
    mapping(uint256 => uint256) private _routingScoreUpdatedSeason;
    uint256 public override historicalBacklogAmount;
    uint256 public override queuedRolloverAmount;
    uint256 public historicalBacklogRoutingEpoch;

    PendingRoute private _pendingRoute;
    HistoricalBacklogProgress private _historicalBacklogProgress;
    QueuedRollover[] private _queuedRollovers;
    uint256 private _queuedRolloverReleaseCursor;
    mapping(uint256 goalId => uint256 epoch) private _historicalBacklogProcessedAtEpoch;

    constructor() {
        _disableInitializers();
    }

    modifier onlyRouteSetter() {
        if (msg.sender != routeSetter) revert UNAUTHORIZED();
        _;
    }

    function initialize(
        IJBDirectory directory_,
        uint256 communityRevnetId_,
        address communityToken_,
        address routeSetter_,
        ICommunityGoalRegistry goalRegistry_
    ) external initializer {
        __ReentrancyGuard_init();

        address directoryAddress = address(directory_);
        address communityTokenAddress = communityToken_;
        address routeSetterAddress = routeSetter_;
        address goalRegistryAddress = address(goalRegistry_);
        if (
            directoryAddress == address(0) ||
            communityTokenAddress == address(0) ||
            routeSetterAddress == address(0) ||
            goalRegistryAddress == address(0)
        ) revert ADDRESS_ZERO();
        if (directoryAddress.code.length == 0) revert NOT_A_CONTRACT(directoryAddress);
        if (communityTokenAddress.code.length == 0) revert NOT_A_CONTRACT(communityTokenAddress);
        if (routeSetterAddress.code.length == 0) revert NOT_A_CONTRACT(routeSetterAddress);
        if (goalRegistryAddress.code.length == 0) revert NOT_A_CONTRACT(goalRegistryAddress);
        if (communityRevnetId_ == 0) revert INVALID_COMMUNITY_REVNET_ID();
        uint256 goalRegistryRevnetId = goalRegistry_.communityRevnetId();
        if (goalRegistryRevnetId != communityRevnetId_) {
            revert INVALID_PROJECT(communityRevnetId_, goalRegistryRevnetId);
        }
        address goalRegistryToken = goalRegistry_.communityToken();
        if (goalRegistryToken != communityTokenAddress) {
            revert INVALID_SOURCE_TOKEN(communityTokenAddress, goalRegistryToken);
        }
        address goalRegistryDirectory = address(goalRegistry_.directory());
        if (goalRegistryDirectory != directoryAddress) {
            revert INVALID_DIRECTORY(directoryAddress, goalRegistryDirectory);
        }
        IGoalDeploymentRegistry goalDeploymentRegistry_ = goalRegistry_.goalDeploymentRegistry();
        address goalDeploymentRegistryAddress = address(goalDeploymentRegistry_);
        if (goalDeploymentRegistryAddress == address(0)) revert ADDRESS_ZERO();
        if (goalDeploymentRegistryAddress.code.length == 0) revert NOT_A_CONTRACT(goalDeploymentRegistryAddress);

        directory = directory_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityTokenAddress;
        routeSetter = routeSetterAddress;
        _goalRegistry = goalRegistry_;
        _goalDeploymentRegistry = goalDeploymentRegistry_;

        emit RouteSetterConfigured(routeSetterAddress);
        emit GoalRegistryConfigured(goalRegistryAddress);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(ICobuildSplitHook).interfaceId ||
            interfaceId == type(IJBSplitHook).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function goalRegistry() external view override returns (address) {
        return address(_goalRegistry);
    }

    function routingScoreOf(uint256 goalId) public view override returns (uint256) {
        return _currentRoutingScore(goalId);
    }

    function selectableGoalIds() external view override returns (uint256[] memory goalIds) {
        goalIds = _goalRegistry.selectableGoalIds();
    }

    function currentRoutingMass() external view override returns (uint256 totalRoutingMass) {
        totalRoutingMass = _currentRoutingMass();
    }

    function historicalBacklogProgress()
        external
        view
        override
        returns (HistoricalBacklogProgressView memory progress)
    {
        HistoricalBacklogProgress storage stored = _historicalBacklogProgress;
        progress = HistoricalBacklogProgressView({
            active: stored.active,
            epoch: historicalBacklogRoutingEpoch,
            remainingAmount: stored.remainingAmount,
            processedGoalCount: stored.processedGoalCount
        });
    }

    function queuedRolloverEntryCount() external view override returns (uint256 entryCount) {
        entryCount = _queuedRollovers.length;
    }

    function queuedRolloverAt(uint256 index) external view override returns (uint64 releaseAt, uint256 amount) {
        QueuedRollover storage rollover = _queuedRollovers[index];
        return (rollover.releaseAt, rollover.amount);
    }

    function historicalRoute()
        external
        view
        override
        returns (uint256[] memory goalIds, uint256[] memory routingScores)
    {
        return _historicalRoute();
    }

    function pendingRoute() external view override returns (PendingRouteView memory out) {
        PendingRoute storage route = _pendingRoute;
        out = PendingRouteView({
            payer: route.payer,
            beneficiary: route.beneficiary,
            createdAt: route.createdAt,
            backlogTokenCount: route.backlogTokenCount,
            goalIds: _copyUint256Array(route.goalIds),
            weights: _copyUint32Array(route.weights)
        });
    }

    function hasPendingRoute() public view override returns (bool) {
        return _pendingRoute.active;
    }

    function beginPendingRoute(
        address payer,
        address beneficiary,
        uint256 backlogTokenCount,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) external override onlyRouteSetter {
        if (_pendingRoute.active) revert PENDING_ROUTE_EXISTS();
        if (payer == address(0) || beneficiary == address(0)) revert ADDRESS_ZERO();

        _validateRoute(goalIds, weights);

        PendingRoute storage route = _pendingRoute;
        route.payer = payer;
        route.beneficiary = beneficiary;
        route.createdAt = uint64(block.timestamp);
        route.backlogTokenCount = backlogTokenCount;
        route.active = true;
        _replaceStorageRoute(route.goalIds, route.weights, goalIds, weights);

        emit PendingRouteStarted(payer, beneficiary, backlogTokenCount, goalIds, weights);
    }

    function cancelPendingRoute() external override onlyRouteSetter {
        _clearPendingRoute();
    }

    function queueRollover(uint256 amount, uint64 releaseAt) external override nonReentrant {
        if (amount == 0) return;

        IERC20 token = IERC20(communityToken);
        token.safeTransferFrom(msg.sender, address(this), amount);

        _queuedRollovers.push(QueuedRollover({ releaseAt: releaseAt, amount: amount }));
        queuedRolloverAmount += amount;

        emit QueuedRolloverAdded(msg.sender, amount, releaseAt, queuedRolloverAmount);
    }

    function releaseQueuedRollovers(
        uint256 maxEntryCount
    ) external override nonReentrant returns (uint256 releasedAmount) {
        if (maxEntryCount == 0) revert INVALID_QUEUED_ROLLOVER_RELEASE_COUNT();

        uint256 length = _queuedRollovers.length;
        if (length == 0) return 0;

        uint256 cursor = _queuedRolloverReleaseCursor;
        if (cursor >= length) cursor = 0;

        uint256 scanned;
        uint256 index = cursor;
        while (index < length && scanned < maxEntryCount) {
            QueuedRollover storage rollover = _queuedRollovers[index];
            if (rollover.amount != 0 && rollover.releaseAt <= block.timestamp) {
                releasedAmount += rollover.amount;
                queuedRolloverAmount -= rollover.amount;
                delete _queuedRollovers[index];
            }

            index++;
            scanned++;
        }

        _queuedRolloverReleaseCursor = index >= length ? 0 : index;
        _trimTrailingQueuedRollovers();

        if (releasedAmount != 0) {
            _deferHistoricalBacklog(releasedAmount);
            emit QueuedRolloversReleased(releasedAmount, historicalBacklogAmount);
        }
    }

    function flushHistoricalBacklog(
        uint256 maxGoalCount
    ) external override nonReentrant returns (uint256 routedAmount) {
        if (maxGoalCount == 0) revert INVALID_HISTORICAL_FLUSH_PAGE_SIZE();

        routedAmount = historicalBacklogAmount;
        if (routedAmount == 0) return 0;

        IERC20 token = IERC20(communityToken);
        _requireHookBalance(token, routedAmount);
        routedAmount = _routeHistoricalBacklogPage(token, maxGoalCount);
    }

    function processSplitWith(JBSplitHookContext calldata context) external payable override nonReentrant {
        _validateProcessSplitContext(context);
        uint256 amount = context.amount;
        if (amount == 0) return;
        IERC20 token = IERC20(context.token);
        _requireHookBalance(token, amount);

        if (_pendingRoute.active) {
            _processPendingRoute(token, amount);
            return;
        }

        _deferHistoricalBacklog(amount);
    }

    function _validateProcessSplitContext(JBSplitHookContext calldata context) internal view {
        if (context.projectId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, context.projectId);
        }
        if (context.token != communityToken) revert INVALID_SOURCE_TOKEN(communityToken, context.token);
        if (context.groupId != RESERVED_TOKENS_GROUP_ID) {
            revert INVALID_SPLIT_GROUP(RESERVED_TOKENS_GROUP_ID, context.groupId);
        }
        if (msg.value != 0) revert NATIVE_VALUE_MISMATCH(0, msg.value);
        if (msg.sender != address(directory.controllerOf(context.projectId))) revert UNAUTHORIZED();
    }

    function _processPendingRoute(IERC20 token, uint256 amount) internal {
        PendingRouteExecution memory pending = _consumePendingRoute(amount);
        if (pending.backlogTokenCount != 0) _deferHistoricalBacklog(pending.backlogTokenCount);
        if (pending.routeAmount != 0) _routePendingRouteAmount(token, pending);

        emit PendingRouteConsumed(
            pending.payer,
            pending.beneficiary,
            pending.routeAmount,
            pending.goalIds,
            pending.weights
        );
    }

    function _consumePendingRoute(uint256 amount) internal returns (PendingRouteExecution memory execution) {
        PendingRoute storage pending = _pendingRoute;
        execution.payer = pending.payer;
        execution.beneficiary = pending.beneficiary;
        execution.backlogTokenCount = pending.backlogTokenCount;
        if (execution.backlogTokenCount > amount) {
            revert INVALID_BACKLOG_SNAPSHOT(execution.backlogTokenCount, amount);
        }
        execution.routeAmount = amount - execution.backlogTokenCount;
        execution.goalIds = _copyUint256Array(pending.goalIds);
        execution.weights = _copyUint32Array(pending.weights);
        _clearPendingRoute();
    }

    function _routePendingRouteAmount(IERC20 token, PendingRouteExecution memory pending) internal {
        _routeToGoals(
            RouteRuntime({
                token: token,
                sourceAmount: pending.routeAmount,
                beneficiary: pending.beneficiary,
                goalIds: pending.goalIds,
                weights: pending.weights,
                fromPendingRoute: true
            })
        );
        _recordRoutingScores(pending.goalIds, pending.weights, pending.routeAmount);
    }

    function _routeToGoals(RouteRuntime memory route) internal {
        uint256 totalWeight = _sumWeights(route.weights);
        uint256 remaining = route.sourceAmount;

        for (uint256 i = 0; i < route.goalIds.length; i++) {
            (uint256 amountForGoal, uint256 nextRemaining) = _allocatedAmountForShare(
                route.sourceAmount,
                route.weights[i],
                totalWeight,
                remaining,
                i,
                route.goalIds.length
            );
            remaining = nextRemaining;
            if (amountForGoal == 0) continue;

            uint256 goalId = route.goalIds[i];
            _payGoal(route.token, goalId, amountForGoal, route.beneficiary, route.fromPendingRoute);
        }
    }

    function _payGoal(
        IERC20 token,
        uint256 goalId,
        uint256 amount,
        address beneficiary,
        bool fromPendingRoute
    ) internal {
        IJBTerminal terminal = _goalTerminalOf(goalId);
        address terminalAddress = address(terminal);
        uint256 hookBalanceBefore = token.balanceOf(address(this));

        token.forceApprove(terminalAddress, amount);
        terminal.pay(goalId, communityToken, amount, beneficiary, 0, "", bytes(""));
        token.forceApprove(terminalAddress, 0);

        uint256 hookBalanceAfter = token.balanceOf(address(this));
        uint256 actualOutflow = hookBalanceBefore > hookBalanceAfter ? hookBalanceBefore - hookBalanceAfter : 0;
        if (actualOutflow != amount) revert GOAL_PAYMENT_OUTFLOW_MISMATCH(goalId, amount, actualOutflow);

        emit GoalRouted(beneficiary, goalId, communityToken, amount, fromPendingRoute);
    }

    function _recordRoutingScores(uint256[] memory goalIds, uint32[] memory weights, uint256 sourceAmount) internal {
        uint256 totalWeight = _sumWeights(weights);
        uint256 remaining = sourceAmount;
        bool updated;

        for (uint256 i = 0; i < goalIds.length; i++) {
            (uint256 amountForGoal, uint256 nextRemaining) = _allocatedAmountForShare(
                sourceAmount,
                weights[i],
                totalWeight,
                remaining,
                i,
                goalIds.length
            );
            remaining = nextRemaining;
            if (amountForGoal == 0) continue;

            uint256 goalId = goalIds[i];
            uint256 newRoutingScore = _increaseRoutingScore(goalId, amountForGoal);
            updated = true;

            emit RoutingScoreRecorded(goalId, amountForGoal, newRoutingScore);
        }

        if (updated) _resetHistoricalBacklogProgress();
    }

    function _routeHistoricalBacklogPage(IERC20 token, uint256 maxGoalCount) internal returns (uint256 routedAmount) {
        HistoricalBacklogProgress storage progress = _historicalBacklogProgress;
        if (!progress.active) _startHistoricalBacklogProgress();

        uint256 epoch = historicalBacklogRoutingEpoch;
        (
            uint256[] memory selectableIds,
            uint256 remainingRoutingMass,
            uint256 remainingGoalCount
        ) = _remainingHistoricalRouteRuntime(epoch);
        if (remainingGoalCount == 0 || remainingRoutingMass == 0) {
            _resetHistoricalBacklogProgress();
            return 0;
        }

        uint256 remainingAmount = progress.remainingAmount;
        uint256 processedThisCall;
        for (uint256 i = 0; i < selectableIds.length; i++) {
            if (processedThisCall == maxGoalCount) break;

            uint256 goalId = selectableIds[i];
            if (_historicalBacklogProcessedAtEpoch[goalId] == epoch) continue;

            uint256 routingScore = _currentRoutingScore(goalId);
            if (routingScore == 0) continue;

            uint256 amountForGoal = remainingGoalCount == 1
                ? remainingAmount
                : (remainingAmount * routingScore) / remainingRoutingMass;
            remainingGoalCount -= 1;
            remainingRoutingMass -= routingScore;

            _historicalBacklogProcessedAtEpoch[goalId] = epoch;
            progress.processedGoalCount += 1;
            processedThisCall += 1;

            if (amountForGoal == 0) continue;

            address beneficiary = _goalDeploymentRegistry.goalTreasuryOf(goalId);
            if (beneficiary == address(0)) revert NO_GOAL_TREASURY(goalId);

            _payGoal(token, goalId, amountForGoal, beneficiary, false);
            remainingAmount -= amountForGoal;
            routedAmount += amountForGoal;
        }

        progress.remainingAmount = remainingAmount;
        historicalBacklogAmount = remainingAmount;
        if (remainingAmount == 0) {
            _completeHistoricalBacklogProgress();
        }

        emit HistoricalBacklogFlushed(routedAmount, remainingAmount);
    }

    function _validateRoute(uint256[] calldata goalIds, uint32[] calldata weights) internal view {
        if (goalIds.length == 0 || goalIds.length != weights.length) {
            revert INVALID_ROUTE_LENGTHS(goalIds.length, weights.length);
        }

        for (uint256 i = 0; i < goalIds.length; i++) {
            uint256 goalId = goalIds[i];
            if (!_goalRegistry.isSelectable(goalId)) revert GOAL_NOT_APPROVED(goalId);
            if (weights[i] == 0) revert INVALID_ROUTE_WEIGHT(i);

            for (uint256 j = i + 1; j < goalIds.length; j++) {
                if (goalIds[j] == goalId) revert DUPLICATE_GOAL(goalId);
            }
        }
    }

    function _sumWeights(uint32[] memory weights) internal pure returns (uint256 totalWeight) {
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        if (totalWeight == 0) revert NO_ROUTE_AVAILABLE();
    }

    function _historicalRoute() internal view returns (uint256[] memory goalIds, uint256[] memory routingScores) {
        uint256[] memory selectableIds = _goalRegistry.selectableGoalIds();
        uint256 selectableLength = selectableIds.length;
        uint256 count;
        for (uint256 i = 0; i < selectableLength; i++) {
            uint256 goalId = selectableIds[i];
            if (_currentRoutingScore(goalId) == 0) continue;
            count++;
        }

        goalIds = new uint256[](count);
        routingScores = new uint256[](count);
        uint256 cursor;
        for (uint256 i = 0; i < selectableLength; i++) {
            uint256 goalId = selectableIds[i];
            uint256 routingScore = _currentRoutingScore(goalId);
            if (routingScore == 0) continue;

            goalIds[cursor] = goalId;
            routingScores[cursor] = routingScore;
            cursor++;
        }
    }

    function _remainingHistoricalRouteRuntime(
        uint256 epoch
    )
        internal
        view
        returns (uint256[] memory selectableIds, uint256 totalRemainingRoutingMass, uint256 remainingGoalCount)
    {
        selectableIds = _goalRegistry.selectableGoalIds();
        for (uint256 i = 0; i < selectableIds.length; i++) {
            uint256 goalId = selectableIds[i];
            if (_historicalBacklogProcessedAtEpoch[goalId] == epoch) continue;

            uint256 routingScore = _currentRoutingScore(goalId);
            if (routingScore == 0) continue;

            totalRemainingRoutingMass += routingScore;
            remainingGoalCount += 1;
        }
    }

    function _currentRoutingScore(uint256 goalId) internal view returns (uint256 score) {
        score = _routingScoreOf[goalId];
        if (score == 0) return 0;

        return _decayedRoutingScore(score, _routingScoreUpdatedSeason[goalId], _currentRoutingScoreSeason());
    }

    function _currentRoutingMass() internal view returns (uint256 totalRoutingMass) {
        uint256[] memory selectableIds = _goalRegistry.selectableGoalIds();
        for (uint256 i = 0; i < selectableIds.length; i++) {
            totalRoutingMass += _currentRoutingScore(selectableIds[i]);
        }
    }

    function _increaseRoutingScore(uint256 goalId, uint256 amount) internal returns (uint256 newScore) {
        uint256 currentSeason = _currentRoutingScoreSeason();
        uint256 score = _decayedRoutingScore(
            _routingScoreOf[goalId],
            _routingScoreUpdatedSeason[goalId],
            currentSeason
        );

        newScore = score + amount;
        _routingScoreOf[goalId] = newScore;
        _routingScoreUpdatedSeason[goalId] = currentSeason;
    }

    function _decayedRoutingScore(
        uint256 score,
        uint256 lastUpdatedSeason,
        uint256 currentSeason
    ) internal pure returns (uint256) {
        if (score == 0 || currentSeason <= lastUpdatedSeason) return score;

        uint256 seasonsElapsed = currentSeason - lastUpdatedSeason;
        if (seasonsElapsed >= 256) return 0;

        return score >> seasonsElapsed;
    }

    function _currentRoutingScoreSeason() internal view returns (uint256) {
        return block.timestamp / ROUTING_SCORE_HALF_LIFE;
    }

    function _allocatedAmountForShare(
        uint256 sourceAmount,
        uint256 share,
        uint256 totalShare,
        uint256 remaining,
        uint256 index,
        uint256 itemCount
    ) internal pure returns (uint256 amountForGoal, uint256 nextRemaining) {
        if (index + 1 == itemCount) return (remaining, 0);

        amountForGoal = (sourceAmount * share) / totalShare;
        nextRemaining = remaining - amountForGoal;
    }

    function _goalTerminalOf(uint256 goalId) internal view returns (IJBTerminal terminal) {
        address terminalAddress = address(directory.primaryTerminalOf(goalId, communityToken));
        if (terminalAddress == address(0)) revert NO_GOAL_TERMINAL(goalId);
        if (terminalAddress.code.length == 0) revert NOT_A_CONTRACT(terminalAddress);

        terminal = IJBTerminal(terminalAddress);
    }

    function _replaceStorageRoute(
        uint256[] storage storageGoalIds,
        uint32[] storage storageWeights,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) internal {
        while (storageGoalIds.length != 0) {
            storageGoalIds.pop();
        }
        while (storageWeights.length != 0) {
            storageWeights.pop();
        }

        for (uint256 i = 0; i < goalIds.length; i++) {
            storageGoalIds.push(goalIds[i]);
            storageWeights.push(weights[i]);
        }
    }

    function _clearPendingRoute() internal {
        if (!_pendingRoute.active) revert NO_PENDING_ROUTE();
        delete _pendingRoute;
    }

    function _deferHistoricalBacklog(uint256 amount) internal {
        if (amount == 0) return;
        historicalBacklogAmount += amount;
        _resetHistoricalBacklogProgress();
        emit HistoricalBacklogDeferred(amount, historicalBacklogAmount);
    }

    function _startHistoricalBacklogProgress() internal {
        historicalBacklogRoutingEpoch += 1;
        _historicalBacklogProgress.active = true;
        _historicalBacklogProgress.remainingAmount = historicalBacklogAmount;
        _historicalBacklogProgress.processedGoalCount = 0;
    }

    function _completeHistoricalBacklogProgress() internal {
        _historicalBacklogProgress.active = false;
        _historicalBacklogProgress.remainingAmount = 0;
        _historicalBacklogProgress.processedGoalCount = 0;
    }

    function _resetHistoricalBacklogProgress() internal {
        if (!_historicalBacklogProgress.active) return;
        emit HistoricalBacklogFlushReset(historicalBacklogRoutingEpoch, historicalBacklogAmount);
        _completeHistoricalBacklogProgress();
    }

    function _trimTrailingQueuedRollovers() internal {
        while (_queuedRollovers.length != 0) {
            uint256 lastIndex = _queuedRollovers.length - 1;
            if (_queuedRollovers[lastIndex].amount != 0) break;
            _queuedRollovers.pop();
        }

        if (_queuedRolloverReleaseCursor > _queuedRollovers.length) {
            _queuedRolloverReleaseCursor = 0;
        }
    }

    function _copyUint256Array(uint256[] storage values) internal view returns (uint256[] memory copied) {
        copied = new uint256[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }

    function _copyUint32Array(uint32[] storage values) internal view returns (uint32[] memory copied) {
        copied = new uint32[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }

    function _requireHookBalance(IERC20 token, uint256 amount) internal view {
        uint256 hookBalance = token.balanceOf(address(this));
        if (hookBalance < amount) revert INSUFFICIENT_HOOK_BALANCE(address(token), amount, hookBalance);
    }
}
