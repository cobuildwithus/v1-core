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
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

/// @notice Community-level split hook that routes reserved community tokens into registry-curated child goals.
/// @dev A fixed init-time wrapper seeds one-shot routes before the community revnet pay executes. Explicit routes are
/// the only source of historical market signal; defaulted routes consume that signal without reinforcing it.
contract CobuildSplitHook is ICobuildSplitHook, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant RESERVED_TOKENS_GROUP_ID = 1;

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
    error NO_GOAL_TERMINAL(uint256 goalId);
    error NATIVE_VALUE_MISMATCH(uint256 expected, uint256 actual);
    error INSUFFICIENT_HOOK_BALANCE(address token, uint256 expected, uint256 available);

    event RouteSetterConfigured(address indexed routeSetter);
    event GoalRegistryConfigured(address indexed goalRegistry);
    event PendingRouteStarted(address indexed payer, address indexed beneficiary, uint256[] goalIds, uint32[] weights);
    event PendingHistoricalRouteStarted(address indexed payer, address indexed beneficiary);
    event PendingRouteConsumed(
        address indexed payer,
        address indexed beneficiary,
        uint256 sourceAmount,
        uint256[] goalIds,
        uint32[] weights
    );
    event PendingHistoricalRouteConsumed(address indexed payer, address indexed beneficiary, uint256 sourceAmount);
    event HistoricalVolumeRecorded(
        uint256 indexed goalId,
        uint256 amount,
        uint256 goalObservedTotal,
        uint256 observedTotal
    );
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
        bool active;
        bool usesHistoricalDefault;
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

    IJBDirectory public directory;
    uint256 public communityRevnetId;
    address public communityToken;
    address public routeSetter;
    ICommunityGoalRegistry private _goalRegistry;
    mapping(uint256 => uint256) public override observedVolumeOf;
    uint256 public override observedTotalVolume;

    PendingRoute private _pendingRoute;

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

        directory = directory_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityTokenAddress;
        routeSetter = routeSetterAddress;
        _goalRegistry = goalRegistry_;

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

    function approvedGoals() external view override returns (uint256[] memory goals) {
        goals = _goalRegistry.selectableGoalIds();
    }

    function historicalRoute() external view override returns (uint256[] memory goalIds, uint256[] memory volumes) {
        return _historicalRoute();
    }

    function pendingRoute() external view override returns (PendingRouteView memory out) {
        PendingRoute storage route = _pendingRoute;
        out = PendingRouteView({
            payer: route.payer,
            beneficiary: route.beneficiary,
            createdAt: route.createdAt,
            usesHistoricalDefault: route.usesHistoricalDefault,
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
        route.active = true;
        route.usesHistoricalDefault = false;
        _replaceStorageRoute(route.goalIds, route.weights, goalIds, weights);

        emit PendingRouteStarted(payer, beneficiary, goalIds, weights);
    }

    function beginPendingHistoricalRoute(address payer, address beneficiary) external override onlyRouteSetter {
        if (_pendingRoute.active) revert PENDING_ROUTE_EXISTS();
        if (payer == address(0) || beneficiary == address(0)) revert ADDRESS_ZERO();

        PendingRoute storage route = _pendingRoute;
        route.payer = payer;
        route.beneficiary = beneficiary;
        route.createdAt = uint64(block.timestamp);
        route.active = true;
        route.usesHistoricalDefault = true;

        emit PendingHistoricalRouteStarted(payer, beneficiary);
    }

    function cancelPendingRoute() external override onlyRouteSetter {
        _clearPendingRoute();
    }

    function processSplitWith(JBSplitHookContext calldata context) external payable override nonReentrant {
        if (context.projectId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, context.projectId);
        }
        if (context.token != communityToken) revert INVALID_SOURCE_TOKEN(communityToken, context.token);
        if (context.groupId != RESERVED_TOKENS_GROUP_ID) {
            revert INVALID_SPLIT_GROUP(RESERVED_TOKENS_GROUP_ID, context.groupId);
        }
        if (msg.value != 0) revert NATIVE_VALUE_MISMATCH(0, msg.value);
        if (msg.sender != address(directory.controllerOf(context.projectId))) revert UNAUTHORIZED();

        uint256 amount = context.amount;
        if (amount == 0) return;

        IERC20 token = IERC20(context.token);
        _requireHookBalance(token, amount);

        if (_pendingRoute.active) {
            PendingRoute storage pending = _pendingRoute;
            address payer = pending.payer;
            address beneficiary = pending.beneficiary;
            bool usesHistoricalDefault = pending.usesHistoricalDefault;

            if (usesHistoricalDefault) {
                _clearPendingRoute();
                if (!_routeUsingHistoricalVolumesToBeneficiary(token, amount, beneficiary, true)) {
                    revert NO_ROUTE_AVAILABLE();
                }

                emit PendingHistoricalRouteConsumed(payer, beneficiary, amount);
                return;
            }

            uint256[] memory goalIds = _copyUint256Array(pending.goalIds);
            uint32[] memory weights = _copyUint32Array(pending.weights);
            _clearPendingRoute();

            _routeToGoals(
                RouteRuntime({
                    token: token,
                    sourceAmount: amount,
                    beneficiary: beneficiary,
                    goalIds: goalIds,
                    weights: weights,
                    fromPendingRoute: true
                })
            );
            _recordObservedRoute(goalIds, weights, amount);

            emit PendingRouteConsumed(payer, beneficiary, amount, goalIds, weights);
            return;
        }

        if (!_routeUsingHistoricalVolumesToGoalTreasuries(token, amount)) revert NO_ROUTE_AVAILABLE();
    }

    function _routeToGoals(RouteRuntime memory route) internal {
        uint256 totalWeight = _sumWeights(route.weights);
        uint256 remaining = route.sourceAmount;

        for (uint256 i = 0; i < route.goalIds.length; i++) {
            uint256 amountForGoal;
            if (i + 1 == route.goalIds.length) {
                amountForGoal = remaining;
            } else {
                amountForGoal = (route.sourceAmount * uint256(route.weights[i])) / totalWeight;
                remaining -= amountForGoal;
            }
            if (amountForGoal == 0) continue;

            uint256 goalId = route.goalIds[i];
            _payGoal(route.token, goalId, amountForGoal, route.beneficiary, route.fromPendingRoute);
        }
    }

    function _routeUsingHistoricalVolumesToBeneficiary(
        IERC20 token,
        uint256 sourceAmount,
        address beneficiary,
        bool fromPendingRoute
    ) internal returns (bool didRoute) {
        if (beneficiary == address(0)) return false;

        (
            uint256[] memory goalIds,
            uint256[] memory volumes,
            uint256 totalHistoricalVolume
        ) = _loadHistoricalRouteRuntime();
        if (goalIds.length == 0) return false;

        uint256 remaining = sourceAmount;
        for (uint256 i = 0; i < goalIds.length; i++) {
            uint256 amountForGoal;
            if (i + 1 == goalIds.length) {
                amountForGoal = remaining;
            } else {
                amountForGoal = (sourceAmount * volumes[i]) / totalHistoricalVolume;
                remaining -= amountForGoal;
            }
            if (amountForGoal == 0) continue;

            uint256 goalId = goalIds[i];
            _payGoal(token, goalId, amountForGoal, beneficiary, fromPendingRoute);
        }

        return true;
    }

    function _routeUsingHistoricalVolumesToGoalTreasuries(
        IERC20 token,
        uint256 sourceAmount
    ) internal returns (bool didRoute) {
        (
            uint256[] memory goalIds,
            uint256[] memory volumes,
            uint256 totalHistoricalVolume
        ) = _loadHistoricalRouteRuntime();
        if (goalIds.length == 0) return false;

        uint256 remaining = sourceAmount;
        for (uint256 i = 0; i < goalIds.length; i++) {
            uint256 amountForGoal;
            if (i + 1 == goalIds.length) {
                amountForGoal = remaining;
            } else {
                amountForGoal = (sourceAmount * volumes[i]) / totalHistoricalVolume;
                remaining -= amountForGoal;
            }
            if (amountForGoal == 0) continue;

            uint256 goalId = goalIds[i];
            address beneficiary = _goalRegistry.goalTreasuryOf(goalId);
            if (beneficiary == address(0)) revert NO_GOAL_TREASURY(goalId);

            _payGoal(token, goalId, amountForGoal, beneficiary, false);
        }

        return true;
    }

    function _payGoal(
        IERC20 token,
        uint256 goalId,
        uint256 amount,
        address beneficiary,
        bool fromPendingRoute
    ) internal {
        address terminalAddress = address(directory.primaryTerminalOf(goalId, communityToken));
        if (terminalAddress == address(0)) revert NO_GOAL_TERMINAL(goalId);

        token.forceApprove(terminalAddress, amount);
        IJBTerminal(terminalAddress).pay(goalId, communityToken, amount, beneficiary, 0, "", bytes(""));
        token.forceApprove(terminalAddress, 0);

        emit GoalRouted(beneficiary, goalId, communityToken, amount, fromPendingRoute);
    }

    function _recordObservedRoute(uint256[] memory goalIds, uint32[] memory weights, uint256 sourceAmount) internal {
        uint256 totalWeight = _sumWeights(weights);
        uint256 remaining = sourceAmount;

        for (uint256 i = 0; i < goalIds.length; i++) {
            uint256 amountForGoal;
            if (i + 1 == goalIds.length) {
                amountForGoal = remaining;
            } else {
                amountForGoal = (sourceAmount * uint256(weights[i])) / totalWeight;
                remaining -= amountForGoal;
            }
            if (amountForGoal == 0) continue;

            uint256 goalId = goalIds[i];
            uint256 newGoalObservedTotal = observedVolumeOf[goalId] + amountForGoal;
            observedVolumeOf[goalId] = newGoalObservedTotal;
            observedTotalVolume += amountForGoal;

            emit HistoricalVolumeRecorded(goalId, amountForGoal, newGoalObservedTotal, observedTotalVolume);
        }
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

    function _sumVolumes(uint256[] memory volumes) internal pure returns (uint256 totalVolume) {
        for (uint256 i = 0; i < volumes.length; i++) {
            totalVolume += volumes[i];
        }
    }

    function _historicalRoute() internal view returns (uint256[] memory goalIds, uint256[] memory volumes) {
        uint256[] memory selectableGoalIds = _goalRegistry.selectableGoalIds();
        uint256 selectableLength = selectableGoalIds.length;
        uint256 count;
        for (uint256 i = 0; i < selectableLength; i++) {
            uint256 goalId = selectableGoalIds[i];
            if (observedVolumeOf[goalId] == 0) continue;
            if (address(directory.primaryTerminalOf(goalId, communityToken)) == address(0)) continue;
            count++;
        }

        goalIds = new uint256[](count);
        volumes = new uint256[](count);
        uint256 cursor;
        for (uint256 i = 0; i < selectableLength; i++) {
            uint256 goalId = selectableGoalIds[i];
            uint256 volume = observedVolumeOf[goalId];
            if (volume == 0) continue;
            if (address(directory.primaryTerminalOf(goalId, communityToken)) == address(0)) continue;

            goalIds[cursor] = goalId;
            volumes[cursor] = volume;
            cursor++;
        }
    }

    function _loadHistoricalRouteRuntime()
        internal
        view
        returns (uint256[] memory goalIds, uint256[] memory volumes, uint256 totalHistoricalVolume)
    {
        (goalIds, volumes) = _historicalRoute();
        if (goalIds.length == 0) return (goalIds, volumes, 0);

        totalHistoricalVolume = _sumVolumes(volumes);
        if (totalHistoricalVolume == 0) return (goalIds, volumes, 0);
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
