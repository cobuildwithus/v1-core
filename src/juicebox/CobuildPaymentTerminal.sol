// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { JBAccountingContext } from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

/// @notice Shared terminal wrapper that lets a payer route a community revnet's reserved-token split into selected child goals.
/// @dev Community funding configuration is registered per community revnet. The split hook remains community-scoped.
contract CobuildPaymentTerminal is IJBTerminal, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct CommunityConfig {
        ICobuildSplitHook splitHook;
        address paymentToken;
        uint256 paymentSourceRevnetId;
        bool directNativeAllowed;
        bool exists;
    }

    IJBDirectory public immutable DIRECTORY;

    mapping(uint256 communityRevnetId => CommunityConfig config) private _communityConfigOf;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error UNAUTHORIZED(address expected, address actual);
    error NO_VALUE();
    error INCORRECT_VALUE();
    error UNSUPPORTED_TOKEN(address token);
    error UNSUPPORTED_CALL();
    error COMMUNITY_NOT_REGISTERED(uint256 communityRevnetId);
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_COMMUNITY_TOKEN(address expectedToken, address actualToken);
    error INVALID_ROUTE_SETTER(address expectedRouteSetter, address actualRouteSetter);
    error INVALID_GOAL_REGISTRY(address expectedRegistry, address actualRegistry);
    error INVALID_DIRECTORY(address expectedDirectory, address actualDirectory);
    error INVALID_PAYMENT_SOURCE(uint256 paymentSourceRevnetId, address expectedToken, address actualToken);
    error NO_PAYMENT_ETH_TERMINAL(uint256 paymentSourceRevnetId);
    error NO_DEST_TERMINAL(uint256 communityRevnetId, address token);
    error DEST_TERMINAL_IS_SELF();
    error ZERO_PAYMENT_OUT();
    error ROUTE_NOT_CONSUMED();
    error NO_CONTROLLER(uint256 communityRevnetId);

    event CommunityRegistered(
        uint256 indexed communityRevnetId,
        address indexed splitHook,
        address indexed paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed,
        address goalRegistry,
        address registrant
    );

    constructor(IJBDirectory directory) {
        if (address(directory) == address(0)) revert ADDRESS_ZERO();
        if (address(directory).code.length == 0) revert NOT_A_CONTRACT(address(directory));

        DIRECTORY = directory;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function communityConfigOf(
        uint256 communityRevnetId
    )
        external
        view
        returns (
            ICobuildSplitHook splitHook,
            address paymentToken,
            uint256 paymentSourceRevnetId,
            bool directNativeAllowed,
            bool exists
        )
    {
        CommunityConfig storage config = _communityConfigOf[communityRevnetId];
        return (
            config.splitHook,
            config.paymentToken,
            config.paymentSourceRevnetId,
            config.directNativeAllowed,
            config.exists
        );
    }

    function registerCommunity(
        uint256 communityRevnetId,
        ICobuildSplitHook splitHook,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed
    ) external {
        if (address(splitHook) == address(0)) revert ADDRESS_ZERO();
        if (paymentToken == address(0)) revert ADDRESS_ZERO();
        if (communityRevnetId == 0 || paymentSourceRevnetId == 0) revert ADDRESS_ZERO();
        if (address(splitHook).code.length == 0) revert NOT_A_CONTRACT(address(splitHook));
        if (paymentToken.code.length == 0) revert NOT_A_CONTRACT(paymentToken);

        address goalRegistryAddress = splitHook.goalRegistry();
        if (goalRegistryAddress == address(0)) revert ADDRESS_ZERO();
        if (goalRegistryAddress.code.length == 0) revert NOT_A_CONTRACT(goalRegistryAddress);

        ICommunityGoalRegistry goalRegistry = ICommunityGoalRegistry(goalRegistryAddress);
        address registryOwner = goalRegistry.owner();
        if (msg.sender != registryOwner) revert UNAUTHORIZED(registryOwner, msg.sender);

        uint256 registeredCommunityRevnetId = goalRegistry.communityRevnetId();
        if (registeredCommunityRevnetId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, registeredCommunityRevnetId);
        }

        address registeredCommunityToken = goalRegistry.communityToken();
        if (splitHook.communityToken() != registeredCommunityToken) {
            revert INVALID_COMMUNITY_TOKEN(registeredCommunityToken, splitHook.communityToken());
        }
        if (goalRegistry.directory() != DIRECTORY) {
            revert INVALID_DIRECTORY(address(DIRECTORY), address(goalRegistry.directory()));
        }

        _requireSplitHookConfiguration(splitHook, communityRevnetId, registeredCommunityToken, goalRegistryAddress);
        _requirePaymentSource(paymentSourceRevnetId, paymentToken);

        if (directNativeAllowed) {
            IJBTerminal nativeTerminal = DIRECTORY.primaryTerminalOf(communityRevnetId, JBConstants.NATIVE_TOKEN);
            if (address(nativeTerminal) == address(0)) {
                revert NO_DEST_TERMINAL(communityRevnetId, JBConstants.NATIVE_TOKEN);
            }
            if (address(nativeTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();
        } else {
            IJBTerminal destinationTerminal = DIRECTORY.primaryTerminalOf(communityRevnetId, paymentToken);
            if (address(destinationTerminal) == address(0)) revert NO_DEST_TERMINAL(communityRevnetId, paymentToken);
            if (address(destinationTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();
        }

        _communityConfigOf[communityRevnetId] = CommunityConfig({
            splitHook: splitHook,
            paymentToken: paymentToken,
            paymentSourceRevnetId: paymentSourceRevnetId,
            directNativeAllowed: directNativeAllowed,
            exists: true
        });

        emit CommunityRegistered(
            communityRevnetId,
            address(splitHook),
            paymentToken,
            paymentSourceRevnetId,
            directNativeAllowed,
            goalRegistryAddress,
            msg.sender
        );
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) external payable override nonReentrant returns (uint256 beneficiaryTokenCount) {
        CommunityConfig storage config = _communityConfigOf[projectId];
        if (!config.exists) revert COMMUNITY_NOT_REGISTERED(projectId);

        (uint256[] memory goalIds, uint32[] memory weights) = _decodeRoutingMetadata(metadata);
        if (token == JBConstants.NATIVE_TOKEN) {
            return _payWithEth(config, projectId, amount, beneficiary, minReturnedTokens, memo, goalIds, weights);
        }

        if (token == config.paymentToken) {
            if (msg.value != 0) revert INCORRECT_VALUE();
            return
                _payWithPaymentToken(config, projectId, amount, beneficiary, minReturnedTokens, memo, goalIds, weights);
        }

        revert UNSUPPORTED_TOKEN(token);
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    ) external pure override returns (JBAccountingContext memory) {
        if (token == JBConstants.NATIVE_TOKEN) {
            return _nativeAccountingContext();
        }

        return JBAccountingContext({ token: address(0), decimals: 0, currency: 0 });
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = _nativeAccountingContext();
    }

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    ) external payable override {
        revert UNSUPPORTED_CALL();
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256 balance) {
        return 0;
    }

    function _payWithEth(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (uint256 beneficiaryTokenCount) {
        if (msg.value == 0) revert NO_VALUE();
        if (msg.value != amount) revert INCORRECT_VALUE();

        if (config.directNativeAllowed) {
            (IJBController controller, uint256 backlogTokenCount) = _beginRoute(
                config,
                communityRevnetId,
                beneficiary,
                goalIds,
                weights
            );

            IJBTerminal nativeTerminal = DIRECTORY.primaryTerminalOf(communityRevnetId, JBConstants.NATIVE_TOKEN);
            if (address(nativeTerminal) == address(0)) {
                revert NO_DEST_TERMINAL(communityRevnetId, JBConstants.NATIVE_TOKEN);
            }
            if (address(nativeTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();

            beneficiaryTokenCount = nativeTerminal.pay{ value: msg.value }(
                communityRevnetId,
                JBConstants.NATIVE_TOKEN,
                msg.value,
                beneficiary,
                minReturnedTokens,
                memo,
                bytes("")
            );

            _finishRoute(config.splitHook, controller, communityRevnetId, backlogTokenCount);
            return beneficiaryTokenCount;
        }

        IJBTerminal paymentEthTerminal = DIRECTORY.primaryTerminalOf(
            config.paymentSourceRevnetId,
            JBConstants.NATIVE_TOKEN
        );
        if (address(paymentEthTerminal) == address(0)) revert NO_PAYMENT_ETH_TERMINAL(config.paymentSourceRevnetId);

        IERC20 paymentTokenRef = IERC20(config.paymentToken);
        uint256 paymentBalanceBefore = paymentTokenRef.balanceOf(address(this));

        paymentEthTerminal.pay{ value: msg.value }(
            config.paymentSourceRevnetId,
            JBConstants.NATIVE_TOKEN,
            msg.value,
            address(this),
            1,
            memo,
            bytes("")
        );

        uint256 paymentReceived = paymentTokenRef.balanceOf(address(this)) - paymentBalanceBefore;
        if (paymentReceived == 0) revert ZERO_PAYMENT_OUT();

        beneficiaryTokenCount = _forwardPaymentToken(
            config,
            communityRevnetId,
            paymentTokenRef,
            paymentReceived,
            beneficiary,
            minReturnedTokens,
            memo,
            goalIds,
            weights
        );
    }

    function _payWithPaymentToken(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (uint256 beneficiaryTokenCount) {
        IERC20 paymentTokenRef = IERC20(config.paymentToken);
        uint256 paymentBalanceBefore = paymentTokenRef.balanceOf(address(this));
        paymentTokenRef.safeTransferFrom(msg.sender, address(this), amount);
        uint256 paymentReceived = paymentTokenRef.balanceOf(address(this)) - paymentBalanceBefore;
        if (paymentReceived == 0) revert ZERO_PAYMENT_OUT();

        beneficiaryTokenCount = _forwardPaymentToken(
            config,
            communityRevnetId,
            paymentTokenRef,
            paymentReceived,
            beneficiary,
            minReturnedTokens,
            memo,
            goalIds,
            weights
        );
    }

    function _forwardPaymentToken(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        IERC20 paymentTokenRef,
        uint256 paymentAmount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (uint256 beneficiaryTokenCount) {
        (IJBController controller, uint256 backlogTokenCount) = _beginRoute(
            config,
            communityRevnetId,
            beneficiary,
            goalIds,
            weights
        );

        IJBTerminal destinationTerminal = DIRECTORY.primaryTerminalOf(communityRevnetId, config.paymentToken);
        if (address(destinationTerminal) == address(0)) {
            revert NO_DEST_TERMINAL(communityRevnetId, config.paymentToken);
        }
        if (address(destinationTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();

        paymentTokenRef.forceApprove(address(destinationTerminal), 0);
        paymentTokenRef.forceApprove(address(destinationTerminal), paymentAmount);

        beneficiaryTokenCount = destinationTerminal.pay(
            communityRevnetId,
            config.paymentToken,
            paymentAmount,
            beneficiary,
            minReturnedTokens,
            memo,
            bytes("")
        );

        paymentTokenRef.forceApprove(address(destinationTerminal), 0);

        _finishRoute(config.splitHook, controller, communityRevnetId, backlogTokenCount);
    }

    function _beginRoute(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        address beneficiary,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (IJBController controller, uint256 backlogTokenCount) {
        _requireSplitHookConfiguration(
            config.splitHook,
            communityRevnetId,
            config.splitHook.communityToken(),
            config.splitHook.goalRegistry()
        );

        controller = _controllerOf(communityRevnetId);
        backlogTokenCount = controller.pendingReservedTokenBalanceOf(communityRevnetId);

        bool hasExplicitRoute = goalIds.length != 0;
        if (hasExplicitRoute) {
            config.splitHook.beginPendingRoute(msg.sender, beneficiary, backlogTokenCount, goalIds, weights);
        }
    }

    function _finishRoute(
        ICobuildSplitHook splitHook,
        IJBController controller,
        uint256 communityRevnetId,
        uint256 backlogTokenCount
    ) internal {
        uint256 pendingReservedTokenBalance = controller.pendingReservedTokenBalanceOf(communityRevnetId);
        if (pendingReservedTokenBalance <= backlogTokenCount) {
            if (splitHook.hasPendingRoute()) splitHook.cancelPendingRoute();
            return;
        }

        controller.sendReservedTokensToSplitsOf(communityRevnetId);
        if (splitHook.hasPendingRoute()) revert ROUTE_NOT_CONSUMED();
    }

    function _controllerOf(uint256 communityRevnetId) internal view returns (IJBController controller) {
        address controllerAddress = address(DIRECTORY.controllerOf(communityRevnetId));
        if (controllerAddress == address(0)) revert NO_CONTROLLER(communityRevnetId);
        if (controllerAddress.code.length == 0) revert NOT_A_CONTRACT(controllerAddress);

        controller = IJBController(controllerAddress);
    }

    function _requireSplitHookConfiguration(
        ICobuildSplitHook splitHook,
        uint256 communityRevnetId,
        address communityToken,
        address goalRegistry
    ) internal view {
        uint256 configuredCommunityRevnetId = splitHook.communityRevnetId();
        if (configuredCommunityRevnetId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, configuredCommunityRevnetId);
        }

        address configuredCommunityToken = splitHook.communityToken();
        if (configuredCommunityToken != communityToken) {
            revert INVALID_COMMUNITY_TOKEN(communityToken, configuredCommunityToken);
        }

        address configuredGoalRegistry = splitHook.goalRegistry();
        if (configuredGoalRegistry != goalRegistry) {
            revert INVALID_GOAL_REGISTRY(goalRegistry, configuredGoalRegistry);
        }

        address configuredRouteSetter = splitHook.routeSetter();
        if (configuredRouteSetter != address(this)) {
            revert INVALID_ROUTE_SETTER(address(this), configuredRouteSetter);
        }
    }

    function _requirePaymentSource(uint256 paymentSourceRevnetId, address paymentToken) internal view {
        IJBController controller = _controllerOf(paymentSourceRevnetId);
        address paymentSourceToken = address(controller.TOKENS().tokenOf(paymentSourceRevnetId));
        if (paymentSourceToken != paymentToken) {
            revert INVALID_PAYMENT_SOURCE(paymentSourceRevnetId, paymentToken, paymentSourceToken);
        }

        IJBTerminal paymentEthTerminal = DIRECTORY.primaryTerminalOf(paymentSourceRevnetId, JBConstants.NATIVE_TOKEN);
        if (address(paymentEthTerminal) == address(0)) revert NO_PAYMENT_ETH_TERMINAL(paymentSourceRevnetId);
        if (address(paymentEthTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();
    }

    function _decodeRoutingMetadata(
        bytes calldata metadata
    ) internal pure returns (uint256[] memory goalIds, uint32[] memory weights) {
        if (metadata.length == 0) return (new uint256[](0), new uint32[](0));
        return abi.decode(metadata, (uint256[], uint32[]));
    }

    function _nativeAccountingContext() internal pure returns (JBAccountingContext memory) {
        return
            JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
    }
}
