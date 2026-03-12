// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBCashOutTerminal } from "@bananapus/core-v5/interfaces/IJBCashOutTerminal.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { ICobuildCommunityTerminal } from "src/interfaces/ICobuildCommunityTerminal.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

/// @notice Atomically exits goal tokens into the goal's upstream community token, COBUILD token, or native ETH.
/// @dev The router infers the lineage from goal-treasury and community-terminal config rather than taking arbitrary hops.
contract CobuildExitRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_COMMUNITY_HOPS = 8;

    enum ExitTarget {
        CommunityToken,
        CobuildToken,
        Native
    }

    struct RouteNode {
        uint256 projectId;
        address token;
        uint256 amount;
    }

    IJBDirectory public immutable DIRECTORY;
    IGoalDeploymentRegistry public immutable GOAL_DEPLOYMENT_REGISTRY;
    ICobuildCommunityTerminal public immutable COMMUNITY_TERMINAL;
    IERC20 public immutable COBUILD_TOKEN;
    uint256 public immutable COBUILD_REVNET_ID;

    error ADDRESS_ZERO();
    error SELF_BENEFICIARY();
    error NOT_A_CONTRACT(address account);
    error DEADLINE_EXPIRED(uint256 deadline, uint256 nowTs);
    error INVALID_AMOUNT();
    error GOAL_NOT_REGISTERED(uint256 goalId);
    error GOAL_TOKEN_NOT_DEPLOYED(uint256 projectId);
    error INVALID_COBUILD_ROOT(address expectedToken, address actualToken, uint256 cobuildRevnetId);
    error NO_COMMUNITY_LAYER(uint256 goalId);
    error INVALID_COMMUNITY_LAYER(uint256 projectId, address token);
    error TERMINAL_NOT_FOUND(uint256 projectId, address token);
    error TERMINAL_NOT_CASH_OUT(address terminal);
    error INVALID_COMMUNITY_TERMINAL(uint256 projectId, address token, address terminal);
    error TRANSFER_AMOUNT_MISMATCH(uint256 requested, uint256 received);
    error UNDER_MIN_OUTPUT(uint256 amountOut, uint256 minOut);
    error COBUILD_ROUTE_UNAVAILABLE(uint256 projectId, address token);
    error ETH_ROUTE_UNAVAILABLE(uint256 projectId, address token);
    error MAX_COMMUNITY_HOPS_EXCEEDED(uint256 maxHops);
    error NATIVE_TRANSFER_FAILED(address to, uint256 amount);

    event GoalExited(
        address indexed holder,
        address indexed beneficiary,
        uint256 indexed goalId,
        ExitTarget target,
        uint256 goalTokenCount,
        address finalToken,
        uint256 finalAmount
    );

    constructor(
        IJBDirectory directory,
        IGoalDeploymentRegistry goalDeploymentRegistry,
        ICobuildCommunityTerminal communityTerminal,
        IERC20 cobuildToken,
        uint256 cobuildRevnetId
    ) {
        if (address(directory) == address(0)) revert ADDRESS_ZERO();
        if (address(goalDeploymentRegistry) == address(0)) revert ADDRESS_ZERO();
        if (address(communityTerminal) == address(0)) revert ADDRESS_ZERO();
        if (address(cobuildToken) == address(0)) revert ADDRESS_ZERO();
        if (cobuildRevnetId == 0) revert ADDRESS_ZERO();
        _requireContract(address(directory));
        _requireContract(address(goalDeploymentRegistry));
        _requireContract(address(communityTerminal));
        _requireContract(address(cobuildToken));

        address configuredCobuildToken = _tokenOfProject(directory, cobuildRevnetId);
        if (configuredCobuildToken != address(cobuildToken)) {
            revert INVALID_COBUILD_ROOT(address(cobuildToken), configuredCobuildToken, cobuildRevnetId);
        }

        DIRECTORY = directory;
        GOAL_DEPLOYMENT_REGISTRY = goalDeploymentRegistry;
        COMMUNITY_TERMINAL = communityTerminal;
        COBUILD_TOKEN = cobuildToken;
        COBUILD_REVNET_ID = cobuildRevnetId;
    }

    receive() external payable {}

    function exitToCommunityToken(
        uint256 goalId,
        uint256 goalTokenCount,
        uint256 minCommunityTokensOut,
        address beneficiary,
        uint256 deadline,
        bytes calldata metadata
    ) external nonReentrant returns (uint256 communityTokensOut) {
        _requireBeneficiary(beneficiary);
        _requireDeadline(deadline);
        RouteNode memory node = _cashOutGoalToImmediateLayer(goalId, goalTokenCount, metadata);

        if (node.token == address(COBUILD_TOKEN) || node.projectId == COBUILD_REVNET_ID) {
            revert NO_COMMUNITY_LAYER(goalId);
        }
        _requireRegisteredCommunityLayer(node);

        communityTokensOut = node.amount;
        if (communityTokensOut < minCommunityTokensOut) {
            revert UNDER_MIN_OUTPUT(communityTokensOut, minCommunityTokensOut);
        }

        _transferOut(node.token, payable(beneficiary), communityTokensOut);

        emit GoalExited(
            msg.sender,
            beneficiary,
            goalId,
            ExitTarget.CommunityToken,
            goalTokenCount,
            node.token,
            communityTokensOut
        );
    }

    function exitToCobuildToken(
        uint256 goalId,
        uint256 goalTokenCount,
        uint256 minCobuildOut,
        address beneficiary,
        uint256 deadline,
        bytes calldata metadata
    ) external nonReentrant returns (uint256 cobuildOut) {
        _requireBeneficiary(beneficiary);
        _requireDeadline(deadline);
        RouteNode memory node = _cashOutGoalToImmediateLayer(goalId, goalTokenCount, metadata);
        node = _ascendToCobuild(node, metadata);

        cobuildOut = node.amount;
        if (cobuildOut < minCobuildOut) revert UNDER_MIN_OUTPUT(cobuildOut, minCobuildOut);

        _transferOut(address(COBUILD_TOKEN), payable(beneficiary), cobuildOut);

        emit GoalExited(
            msg.sender,
            beneficiary,
            goalId,
            ExitTarget.CobuildToken,
            goalTokenCount,
            address(COBUILD_TOKEN),
            cobuildOut
        );
    }

    function exitToEth(
        uint256 goalId,
        uint256 goalTokenCount,
        uint256 minEthOut,
        address payable beneficiary,
        uint256 deadline,
        bytes calldata metadata
    ) external nonReentrant returns (uint256 ethOut) {
        _requireBeneficiary(beneficiary);
        _requireDeadline(deadline);
        RouteNode memory node = _cashOutGoalToImmediateLayer(goalId, goalTokenCount, metadata);
        node = _ascendToNative(node, metadata);

        ethOut = node.amount;
        if (ethOut < minEthOut) revert UNDER_MIN_OUTPUT(ethOut, minEthOut);

        _transferOut(JBConstants.NATIVE_TOKEN, beneficiary, ethOut);

        emit GoalExited(
            msg.sender,
            beneficiary,
            goalId,
            ExitTarget.Native,
            goalTokenCount,
            JBConstants.NATIVE_TOKEN,
            ethOut
        );
    }

    function _cashOutGoalToImmediateLayer(
        uint256 goalId,
        uint256 goalTokenCount,
        bytes calldata metadata
    ) internal returns (RouteNode memory node) {
        if (goalTokenCount == 0) revert INVALID_AMOUNT();

        address goalTreasury = GOAL_DEPLOYMENT_REGISTRY.goalTreasuryOf(goalId);
        if (goalTreasury == address(0)) revert GOAL_NOT_REGISTERED(goalId);
        _requireContract(goalTreasury);

        IGoalTreasury treasury = IGoalTreasury(goalTreasury);
        address stakeVault = treasury.stakeVault();
        if (stakeVault == address(0)) revert ADDRESS_ZERO();
        _requireContract(stakeVault);

        node.projectId = treasury.cobuildRevnetId();
        node.token = address(IStakeVault(stakeVault).cobuildToken());
        if (node.projectId == 0 || node.token == address(0)) revert ADDRESS_ZERO();

        address goalToken = _tokenOfProject(DIRECTORY, goalId);
        IERC20 goalTokenRef = IERC20(goalToken);
        uint256 goalBalanceBefore = goalTokenRef.balanceOf(address(this));
        goalTokenRef.safeTransferFrom(msg.sender, address(this), goalTokenCount);
        uint256 goalTokensReceived = goalTokenRef.balanceOf(address(this)) - goalBalanceBefore;
        if (goalTokensReceived != goalTokenCount) {
            revert TRANSFER_AMOUNT_MISMATCH(goalTokenCount, goalTokensReceived);
        }

        node.amount = _cashOutProject(goalId, node.token, goalTokenCount, metadata);
    }

    function _ascendToCobuild(
        RouteNode memory node,
        bytes calldata metadata
    ) internal returns (RouteNode memory current) {
        current = node;
        if (current.token == address(COBUILD_TOKEN) && current.projectId == COBUILD_REVNET_ID) return current;

        for (uint256 i; i < MAX_COMMUNITY_HOPS; i++) {
            (
                ,
                address paymentToken,
                uint256 paymentSourceRevnetId,
                bool directNativeAllowed,
                bool exists
            ) = COMMUNITY_TERMINAL.communityConfigOf(current.projectId);

            if (!exists) revert COBUILD_ROUTE_UNAVAILABLE(current.projectId, current.token);

            if (paymentToken == address(COBUILD_TOKEN) && paymentSourceRevnetId == COBUILD_REVNET_ID) {
                current.amount = _cashOutCommunityProject(current.projectId, paymentToken, current.amount, metadata);
                current.projectId = COBUILD_REVNET_ID;
                current.token = paymentToken;
                return current;
            }

            if (paymentSourceRevnetId == current.projectId && directNativeAllowed) {
                revert COBUILD_ROUTE_UNAVAILABLE(current.projectId, current.token);
            }

            current.amount = _cashOutCommunityProject(current.projectId, paymentToken, current.amount, metadata);
            current.projectId = paymentSourceRevnetId;
            current.token = paymentToken;
        }

        revert MAX_COMMUNITY_HOPS_EXCEEDED(MAX_COMMUNITY_HOPS);
    }

    function _ascendToNative(
        RouteNode memory node,
        bytes calldata metadata
    ) internal returns (RouteNode memory current) {
        current = node;
        if (current.token == address(COBUILD_TOKEN) && current.projectId == COBUILD_REVNET_ID) {
            current.amount = _cashOutProject(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, current.amount, metadata);
            current.token = JBConstants.NATIVE_TOKEN;
            current.projectId = 0;
            return current;
        }

        for (uint256 i; i < MAX_COMMUNITY_HOPS; i++) {
            (
                ,
                address paymentToken,
                uint256 paymentSourceRevnetId,
                bool directNativeAllowed,
                bool exists
            ) = COMMUNITY_TERMINAL.communityConfigOf(current.projectId);

            if (!exists) revert ETH_ROUTE_UNAVAILABLE(current.projectId, current.token);

            if (paymentSourceRevnetId == current.projectId && directNativeAllowed) {
                current.amount = _cashOutCommunityProject(
                    current.projectId,
                    JBConstants.NATIVE_TOKEN,
                    current.amount,
                    metadata
                );
                current.token = JBConstants.NATIVE_TOKEN;
                current.projectId = 0;
                return current;
            }

            current.amount = _cashOutCommunityProject(current.projectId, paymentToken, current.amount, metadata);
            current.projectId = paymentSourceRevnetId;
            current.token = paymentToken;

            if (current.token == address(COBUILD_TOKEN) && current.projectId == COBUILD_REVNET_ID) {
                current.amount = _cashOutProject(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, current.amount, metadata);
                current.token = JBConstants.NATIVE_TOKEN;
                current.projectId = 0;
                return current;
            }
        }

        revert MAX_COMMUNITY_HOPS_EXCEEDED(MAX_COMMUNITY_HOPS);
    }

    function _cashOutProject(
        uint256 projectId,
        address tokenToReclaim,
        uint256 cashOutCount,
        bytes calldata metadata
    ) internal returns (uint256 amountOut) {
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf(projectId, tokenToReclaim);
        if (address(terminal) == address(0)) revert TERMINAL_NOT_FOUND(projectId, tokenToReclaim);
        return _cashOutProjectThrough(projectId, tokenToReclaim, cashOutCount, metadata, terminal);
    }

    function _cashOutCommunityProject(
        uint256 projectId,
        address tokenToReclaim,
        uint256 cashOutCount,
        bytes calldata metadata
    ) internal returns (uint256 amountOut) {
        IJBTerminal terminal = DIRECTORY.primaryTerminalOf(projectId, tokenToReclaim);
        if (address(terminal) == address(0)) revert TERMINAL_NOT_FOUND(projectId, tokenToReclaim);
        if (address(terminal) != address(COMMUNITY_TERMINAL)) {
            revert INVALID_COMMUNITY_TERMINAL(projectId, tokenToReclaim, address(terminal));
        }
        return _cashOutProjectThrough(projectId, tokenToReclaim, cashOutCount, metadata, terminal);
    }

    function _cashOutProjectThrough(
        uint256 projectId,
        address tokenToReclaim,
        uint256 cashOutCount,
        bytes calldata metadata,
        IJBTerminal terminal
    ) internal returns (uint256 amountOut) {
        _requireCashOutTerminal(address(terminal));

        uint256 balanceBefore = _balanceOfThis(tokenToReclaim);
        IJBCashOutTerminal(address(terminal)).cashOutTokensOf(
            address(this),
            projectId,
            cashOutCount,
            tokenToReclaim,
            0,
            payable(address(this)),
            metadata
        );
        amountOut = _balanceOfThis(tokenToReclaim) - balanceBefore;
    }

    function _requireCashOutTerminal(address terminal) internal view {
        bool supported;
        try IERC165(terminal).supportsInterface(type(IJBCashOutTerminal).interfaceId) returns (bool doesSupport) {
            supported = doesSupport;
        } catch {
            supported = false;
        }

        if (!supported) revert TERMINAL_NOT_CASH_OUT(terminal);
    }

    function _balanceOfThis(address token) internal view returns (uint256) {
        if (token == JBConstants.NATIVE_TOKEN) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function _transferOut(address token, address payable beneficiary, uint256 amount) internal {
        if (amount == 0) return;

        if (token == JBConstants.NATIVE_TOKEN) {
            (bool success, ) = beneficiary.call{ value: amount }("");
            if (!success) revert NATIVE_TRANSFER_FAILED(beneficiary, amount);
            return;
        }

        IERC20(token).safeTransfer(beneficiary, amount);
    }

    function _requireBeneficiary(address beneficiary) internal view {
        if (beneficiary == address(0)) revert ADDRESS_ZERO();
        if (beneficiary == address(this)) revert SELF_BENEFICIARY();
    }

    function _requireRegisteredCommunityLayer(RouteNode memory node) internal view {
        (, , , , bool exists) = COMMUNITY_TERMINAL.communityConfigOf(node.projectId);
        if (!exists) revert INVALID_COMMUNITY_LAYER(node.projectId, node.token);
        if (_tokenOfProject(DIRECTORY, node.projectId) != node.token) {
            revert INVALID_COMMUNITY_LAYER(node.projectId, node.token);
        }
    }

    function _requireDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DEADLINE_EXPIRED(deadline, block.timestamp);
    }

    function _requireContract(address account) internal view {
        if (account.code.length == 0) revert NOT_A_CONTRACT(account);
    }

    function _tokenOfProject(IJBDirectory directory, uint256 projectId) internal view returns (address token) {
        address controllerAddress = address(directory.controllerOf(projectId));
        _requireContract(controllerAddress);

        IJBTokens tokens = IJBController(controllerAddress).TOKENS();
        token = address(tokens.tokenOf(projectId));
        if (token == address(0)) revert GOAL_TOKEN_NOT_DEPLOYED(projectId);
    }
}
