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

/// @notice Community-level split hook that routes reserved community tokens into pre-approved child goals.
/// @dev A trusted wrapper can set a one-shot pending route before calling the community revnet terminal.
/// The revnet controller then calls `processSplitWith`, which consumes the route and forwards the reserved
/// community tokens into the selected child goals in the same transaction.
contract CobuildSplitHook is ICobuildSplitHook, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant RESERVED_TOKENS_GROUP_ID = 1;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error UNAUTHORIZED();
    error INVALID_COMMUNITY_REVNET_ID();
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_SOURCE_TOKEN(address expectedToken, address actualToken);
    error INVALID_SPLIT_GROUP(uint256 expectedGroupId, uint256 actualGroupId);
    error INVALID_GOAL_ID();
    error INVALID_ROUTE_LENGTHS(uint256 goalIdsLength, uint256 weightsLength);
    error INVALID_ROUTE_WEIGHT(uint256 index);
    error DUPLICATE_GOAL(uint256 goalId);
    error GOAL_NOT_APPROVED(uint256 goalId);
    error NO_ROUTE_AVAILABLE();
    error NO_ROUTE_SETTER();
    error PENDING_ROUTE_EXISTS();
    error NO_PENDING_ROUTE();
    error NO_GOAL_TERMINAL(uint256 goalId);
    error NATIVE_VALUE_MISMATCH(uint256 expected, uint256 actual);
    error INSUFFICIENT_HOOK_BALANCE(address token, uint256 expected, uint256 available);

    event RouteSetterSet(address indexed routeSetter);
    event DefaultBeneficiarySet(address indexed beneficiary);
    event GoalApprovalSet(uint256 indexed goalId, bool approved);
    event DefaultRouteSet(uint256[] goalIds, uint32[] weights);
    event PendingRouteStarted(address indexed payer, address indexed beneficiary, uint256[] goalIds, uint32[] weights);
    event PendingRouteConsumed(
        address indexed payer,
        address indexed beneficiary,
        uint256 sourceAmount,
        uint256[] goalIds,
        uint32[] weights
    );
    event ReservedTokensEscrowed(address indexed token, uint256 amount);
    event GoalRouted(
        address indexed beneficiary,
        uint256 indexed goalId,
        address indexed token,
        uint256 amount,
        bool fromPendingRoute
    );
    event EscrowSwept(address indexed beneficiary, uint256 totalAmount, uint256[] goalIds, uint32[] weights);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    struct PendingRoute {
        address payer;
        address beneficiary;
        uint64 createdAt;
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

    IJBDirectory public directory;
    uint256 public communityRevnetId;
    address public communityToken;
    address public owner;
    address public routeSetter;
    address public defaultBeneficiary;

    PendingRoute private _pendingRoute;
    uint256[] private _approvedGoals;
    mapping(uint256 => uint256) private _approvedGoalIndexPlusOne;
    uint256[] private _defaultGoalIds;
    uint32[] private _defaultWeights;

    constructor() {
        _disableInitializers();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UNAUTHORIZED();
        _;
    }

    modifier onlyRouteSetter() {
        address setter = routeSetter;
        if (setter == address(0)) revert NO_ROUTE_SETTER();
        if (msg.sender != setter) revert UNAUTHORIZED();
        _;
    }

    function initialize(
        IJBDirectory directory_,
        uint256 communityRevnetId_,
        address communityToken_,
        address owner_
    ) external initializer {
        __ReentrancyGuard_init();

        address directoryAddress = address(directory_);
        if (directoryAddress == address(0) || communityToken_ == address(0) || owner_ == address(0)) {
            revert ADDRESS_ZERO();
        }
        if (directoryAddress.code.length == 0) revert NOT_A_CONTRACT(directoryAddress);
        if (communityToken_.code.length == 0) revert NOT_A_CONTRACT(communityToken_);
        if (communityRevnetId_ == 0) revert INVALID_COMMUNITY_REVNET_ID();

        directory = directory_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
        owner = owner_;
        routeSetter = owner_;

        emit OwnershipTransferred(address(0), owner_);
        emit RouteSetterSet(owner_);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(ICobuildSplitHook).interfaceId ||
            interfaceId == type(IJBSplitHook).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function approvedGoals() external view override returns (uint256[] memory goals) {
        goals = _approvedGoals;
    }

    function defaultRoute() external view override returns (uint256[] memory goalIds, uint32[] memory weights) {
        goalIds = _copyUint256Array(_defaultGoalIds);
        weights = _copyUint32Array(_defaultWeights);
    }

    function pendingRoute() external view override returns (PendingRouteView memory out) {
        PendingRoute storage route = _pendingRoute;
        out = PendingRouteView({
            payer: route.payer,
            beneficiary: route.beneficiary,
            createdAt: route.createdAt,
            goalIds: _copyUint256Array(route.goalIds),
            weights: _copyUint32Array(route.weights)
        });
    }

    function hasPendingRoute() public view override returns (bool) {
        return _pendingRoute.active;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ADDRESS_ZERO();

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);

        if (routeSetter == previousOwner) {
            routeSetter = newOwner;
            emit RouteSetterSet(newOwner);
        }
    }

    function setRouteSetter(address routeSetter_) external override onlyOwner {
        if (routeSetter_ == address(0)) revert ADDRESS_ZERO();
        routeSetter = routeSetter_;
        emit RouteSetterSet(routeSetter_);
    }

    function setDefaultBeneficiary(address beneficiary) external override onlyOwner {
        defaultBeneficiary = beneficiary;
        emit DefaultBeneficiarySet(beneficiary);
    }

    function setApprovedGoal(uint256 goalId, bool approved) external override onlyOwner {
        if (goalId == 0) revert INVALID_GOAL_ID();

        uint256 indexPlusOne = _approvedGoalIndexPlusOne[goalId];
        bool isApproved = indexPlusOne != 0;
        if (approved == isApproved) {
            emit GoalApprovalSet(goalId, approved);
            return;
        }

        if (approved) {
            _approvedGoalIndexPlusOne[goalId] = _approvedGoals.length + 1;
            _approvedGoals.push(goalId);
        } else {
            uint256 removeIndex = indexPlusOne - 1;
            uint256 lastIndex = _approvedGoals.length - 1;
            if (removeIndex != lastIndex) {
                uint256 movedGoalId = _approvedGoals[lastIndex];
                _approvedGoals[removeIndex] = movedGoalId;
                _approvedGoalIndexPlusOne[movedGoalId] = removeIndex + 1;
            }
            _approvedGoals.pop();
            delete _approvedGoalIndexPlusOne[goalId];
        }

        emit GoalApprovalSet(goalId, approved);
    }

    function setDefaultRoute(uint256[] calldata goalIds, uint32[] calldata weights) external override onlyOwner {
        if (goalIds.length == 0) {
            delete _defaultGoalIds;
            delete _defaultWeights;
            emit DefaultRouteSet(new uint256[](0), new uint32[](0));
            return;
        }

        _validateRoute(goalIds, weights);
        _replaceStorageRoute(_defaultGoalIds, _defaultWeights, goalIds, weights);
        emit DefaultRouteSet(goalIds, weights);
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
        _replaceStorageRoute(route.goalIds, route.weights, goalIds, weights);

        emit PendingRouteStarted(payer, beneficiary, goalIds, weights);
    }

    function sweepEscrowed(
        address beneficiary,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) external override onlyOwner nonReentrant returns (uint256 sweptAmount) {
        if (beneficiary == address(0)) revert ADDRESS_ZERO();

        sweptAmount = IERC20(communityToken).balanceOf(address(this));
        if (sweptAmount == 0) return 0;

        if (goalIds.length == 0) {
            if (_defaultGoalIds.length == 0) revert NO_ROUTE_AVAILABLE();

            uint256[] memory defaultGoalIds_ = _copyUint256Array(_defaultGoalIds);
            uint32[] memory defaultWeights_ = _copyUint32Array(_defaultWeights);
            _routeToGoals(
                RouteRuntime({
                    token: IERC20(communityToken),
                    sourceAmount: sweptAmount,
                    beneficiary: beneficiary,
                    goalIds: defaultGoalIds_,
                    weights: defaultWeights_,
                    fromPendingRoute: false
                })
            );
            emit EscrowSwept(beneficiary, sweptAmount, defaultGoalIds_, defaultWeights_);
            return sweptAmount;
        }

        _validateRoute(goalIds, weights);
        uint256[] memory explicitGoalIds = _copyUint256Calldata(goalIds);
        uint32[] memory explicitWeights = _copyUint32Calldata(weights);
        _routeToGoals(
            RouteRuntime({
                token: IERC20(communityToken),
                sourceAmount: sweptAmount,
                beneficiary: beneficiary,
                goalIds: explicitGoalIds,
                weights: explicitWeights,
                fromPendingRoute: false
            })
        );
        emit EscrowSwept(beneficiary, sweptAmount, explicitGoalIds, explicitWeights);
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

            emit PendingRouteConsumed(payer, beneficiary, amount, goalIds, weights);
            return;
        }

        if (_defaultGoalIds.length != 0 && defaultBeneficiary != address(0)) {
            uint256[] memory defaultGoalIds_ = _copyUint256Array(_defaultGoalIds);
            uint32[] memory defaultWeights_ = _copyUint32Array(_defaultWeights);
            _routeToGoals(
                RouteRuntime({
                    token: token,
                    sourceAmount: amount,
                    beneficiary: defaultBeneficiary,
                    goalIds: defaultGoalIds_,
                    weights: defaultWeights_,
                    fromPendingRoute: false
                })
            );
            return;
        }

        emit ReservedTokensEscrowed(context.token, amount);
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
            address terminalAddress = address(directory.primaryTerminalOf(goalId, communityToken));
            if (terminalAddress == address(0)) revert NO_GOAL_TERMINAL(goalId);

            route.token.forceApprove(terminalAddress, amountForGoal);
            IJBTerminal(terminalAddress).pay(
                goalId,
                communityToken,
                amountForGoal,
                route.beneficiary,
                0,
                "",
                bytes("")
            );
            route.token.forceApprove(terminalAddress, 0);

            emit GoalRouted(route.beneficiary, goalId, communityToken, amountForGoal, route.fromPendingRoute);
        }
    }

    function _validateRoute(uint256[] calldata goalIds, uint32[] calldata weights) internal view {
        if (goalIds.length == 0 || goalIds.length != weights.length) {
            revert INVALID_ROUTE_LENGTHS(goalIds.length, weights.length);
        }

        uint256 totalWeight;
        for (uint256 i = 0; i < goalIds.length; i++) {
            uint256 goalId = goalIds[i];
            if (_approvedGoalIndexPlusOne[goalId] == 0) revert GOAL_NOT_APPROVED(goalId);
            if (weights[i] == 0) revert INVALID_ROUTE_WEIGHT(i);
            totalWeight += weights[i];

            for (uint256 j = i + 1; j < goalIds.length; j++) {
                if (goalIds[j] == goalId) revert DUPLICATE_GOAL(goalId);
            }
        }

        if (totalWeight == 0) revert NO_ROUTE_AVAILABLE();
    }

    function _sumWeights(uint32[] memory weights) internal pure returns (uint256 totalWeight) {
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        if (totalWeight == 0) revert NO_ROUTE_AVAILABLE();
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
        delete _pendingRoute.goalIds;
        delete _pendingRoute.weights;
        delete _pendingRoute;
    }

    function _copyUint256Calldata(uint256[] calldata values) internal pure returns (uint256[] memory copied) {
        copied = new uint256[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }

    function _copyUint32Calldata(uint32[] calldata values) internal pure returns (uint32[] memory copied) {
        copied = new uint32[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
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
