// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { JBAccountingContext } from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";

/// @notice Terminal wrapper that lets a payer route the community revnet's reserved-token split into selected child goals.
/// @dev The wrapper seeds either an explicit route or a historical-default route on `CobuildSplitHook` immediately
/// before calling the community revnet's primary terminal.
contract CobuildPaymentTerminal is IJBTerminal, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IJBDirectory public immutable DIRECTORY;
    ICobuildSplitHook public immutable SPLIT_HOOK;
    address public immutable COBUILD_TOKEN;
    uint256 public immutable COBUILD_REVNET_ID;
    uint256 public immutable COMMUNITY_REVNET_ID;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error NO_VALUE();
    error INCORRECT_VALUE();
    error UNSUPPORTED_TOKEN(address token);
    error UNSUPPORTED_CALL();
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_COMMUNITY_TOKEN(address expectedToken, address actualToken);
    error INVALID_ROUTE_SETTER(address expectedRouteSetter, address actualRouteSetter);
    error NO_COBUILD_ETH_TERMINAL();
    error NO_DEST_TERMINAL();
    error DEST_TERMINAL_IS_SELF();
    error ZERO_COBUILD_OUT();
    error ROUTE_NOT_CONSUMED();

    constructor(
        IJBDirectory directory,
        ICobuildSplitHook splitHook,
        address cobuildToken,
        uint256 cobuildRevnetId,
        uint256 communityRevnetId
    ) {
        if (
            address(directory) == address(0) ||
            address(splitHook) == address(0) ||
            cobuildToken == address(0) ||
            cobuildRevnetId == 0 ||
            communityRevnetId == 0
        ) {
            revert ADDRESS_ZERO();
        }
        if (address(directory).code.length == 0) revert NOT_A_CONTRACT(address(directory));
        if (address(splitHook).code.length == 0) revert NOT_A_CONTRACT(address(splitHook));
        if (cobuildToken.code.length == 0) revert NOT_A_CONTRACT(cobuildToken);

        DIRECTORY = directory;
        SPLIT_HOOK = splitHook;
        COBUILD_TOKEN = cobuildToken;
        COBUILD_REVNET_ID = cobuildRevnetId;
        COMMUNITY_REVNET_ID = communityRevnetId;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IERC165).interfaceId;
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
        if (projectId != COMMUNITY_REVNET_ID) {
            revert INVALID_PROJECT(COMMUNITY_REVNET_ID, projectId);
        }

        (uint256[] memory goalIds, uint32[] memory weights) = _decodeRoutingMetadata(metadata);
        if (token == JBConstants.NATIVE_TOKEN) {
            return _payWithEth(amount, beneficiary, minReturnedTokens, memo, goalIds, weights);
        }

        if (token == COBUILD_TOKEN) {
            if (msg.value != 0) revert INCORRECT_VALUE();
            return _payWithCobuild(amount, beneficiary, minReturnedTokens, memo, goalIds, weights);
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
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (uint256 beneficiaryTokenCount) {
        if (msg.value == 0) revert NO_VALUE();
        if (msg.value != amount) revert INCORRECT_VALUE();

        IJBTerminal cobuildEthTerminal = DIRECTORY.primaryTerminalOf(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN);
        if (address(cobuildEthTerminal) == address(0)) revert NO_COBUILD_ETH_TERMINAL();

        IERC20 cobuildToken = IERC20(COBUILD_TOKEN);
        uint256 cobuildBalanceBefore = cobuildToken.balanceOf(address(this));

        cobuildEthTerminal.pay{ value: msg.value }(
            COBUILD_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            msg.value,
            address(this),
            1,
            memo,
            bytes("")
        );

        uint256 cobuildReceived = cobuildToken.balanceOf(address(this)) - cobuildBalanceBefore;
        if (cobuildReceived == 0) revert ZERO_COBUILD_OUT();

        beneficiaryTokenCount = _forwardCobuild(
            cobuildToken,
            cobuildReceived,
            beneficiary,
            minReturnedTokens,
            memo,
            goalIds,
            weights
        );
    }

    function _payWithCobuild(
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (uint256 beneficiaryTokenCount) {
        IERC20 cobuildToken = IERC20(COBUILD_TOKEN);
        uint256 cobuildBalanceBefore = cobuildToken.balanceOf(address(this));
        cobuildToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 cobuildReceived = cobuildToken.balanceOf(address(this)) - cobuildBalanceBefore;
        if (cobuildReceived == 0) revert ZERO_COBUILD_OUT();

        beneficiaryTokenCount = _forwardCobuild(
            cobuildToken,
            cobuildReceived,
            beneficiary,
            minReturnedTokens,
            memo,
            goalIds,
            weights
        );
    }

    function _forwardCobuild(
        IERC20 cobuildToken,
        uint256 cobuildAmount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        uint256[] memory goalIds,
        uint32[] memory weights
    ) internal returns (uint256 beneficiaryTokenCount) {
        _requireSplitHookConfiguration();

        IJBTerminal destinationTerminal = _destinationTerminalOf();
        bool hasExplicitRoute = goalIds.length != 0;
        if (hasExplicitRoute) {
            SPLIT_HOOK.beginPendingRoute(msg.sender, beneficiary, goalIds, weights);
        } else {
            SPLIT_HOOK.beginPendingHistoricalRoute(msg.sender, beneficiary);
        }

        cobuildToken.forceApprove(address(destinationTerminal), cobuildAmount);

        beneficiaryTokenCount = destinationTerminal.pay(
            COMMUNITY_REVNET_ID,
            COBUILD_TOKEN,
            cobuildAmount,
            beneficiary,
            minReturnedTokens,
            memo,
            bytes("")
        );

        cobuildToken.forceApprove(address(destinationTerminal), 0);

        if (!SPLIT_HOOK.hasPendingRoute()) return beneficiaryTokenCount;
        if (hasExplicitRoute || beneficiaryTokenCount != 0) revert ROUTE_NOT_CONSUMED();

        SPLIT_HOOK.cancelPendingRoute();
    }

    function _destinationTerminalOf() internal view returns (IJBTerminal destinationTerminal) {
        destinationTerminal = DIRECTORY.primaryTerminalOf(COMMUNITY_REVNET_ID, COBUILD_TOKEN);
        if (address(destinationTerminal) == address(0)) revert NO_DEST_TERMINAL();
        if (address(destinationTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();
    }

    function _requireSplitHookConfiguration() internal view {
        uint256 configuredCommunityRevnetId = SPLIT_HOOK.communityRevnetId();
        if (configuredCommunityRevnetId != COMMUNITY_REVNET_ID) {
            revert INVALID_PROJECT(COMMUNITY_REVNET_ID, configuredCommunityRevnetId);
        }

        address configuredCommunityToken = SPLIT_HOOK.communityToken();
        if (configuredCommunityToken != COBUILD_TOKEN) {
            revert INVALID_COMMUNITY_TOKEN(COBUILD_TOKEN, configuredCommunityToken);
        }

        address configuredRouteSetter = SPLIT_HOOK.routeSetter();
        if (configuredRouteSetter != address(this)) {
            revert INVALID_ROUTE_SETTER(address(this), configuredRouteSetter);
        }
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
