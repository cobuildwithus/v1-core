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

/// @notice Immutable terminal that routes ETH -> COBUILD -> goal payments.
/// @dev Direct COBUILD payments are forwarded to the goal project's COBUILD terminal.
contract CobuildTerminal is IJBTerminal, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IJBDirectory public immutable DIRECTORY;
    address public immutable COBUILD_TOKEN;
    uint256 public immutable COBUILD_REVNET_ID;

    error ADDRESS_ZERO();
    error NO_VALUE();
    error INCORRECT_VALUE();
    error UNSUPPORTED_TOKEN(address token);
    error UNSUPPORTED_CALL();
    error NO_COBUILD_ETH_TERMINAL();
    error NO_DEST_TERMINAL();
    error DEST_TERMINAL_IS_SELF();
    error ZERO_COBUILD_OUT();

    constructor(IJBDirectory directory, address cobuildToken, uint256 cobuildRevnetId) {
        if (address(directory) == address(0)) revert ADDRESS_ZERO();
        if (cobuildToken == address(0)) revert ADDRESS_ZERO();
        if (cobuildRevnetId == 0) revert ADDRESS_ZERO();

        DIRECTORY = directory;
        COBUILD_TOKEN = cobuildToken;
        COBUILD_REVNET_ID = cobuildRevnetId;
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
        if (token == JBConstants.NATIVE_TOKEN) {
            return _payWithEth(projectId, amount, beneficiary, minReturnedTokens, memo, metadata);
        }

        if (token == COBUILD_TOKEN) {
            if (msg.value != 0) revert INCORRECT_VALUE();
            return _payWithCobuild(projectId, amount, beneficiary, minReturnedTokens, memo, metadata);
        }

        revert UNSUPPORTED_TOKEN(token);
    }

    function accountingContextForTokenOf(uint256, address token)
        external
        pure
        override
        returns (JBAccountingContext memory)
    {
        if (token == JBConstants.NATIVE_TOKEN) {
            return _nativeAccountingContext();
        }

        return JBAccountingContext({ token: address(0), decimals: 0, currency: 0 });
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = _nativeAccountingContext();
    }

    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256, uint256)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override { }

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable override {
        revert UNSUPPORTED_CALL();
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256 balance) {
        return 0;
    }

    function _payWithEth(
        uint256 projectId,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        if (msg.value == 0) revert NO_VALUE();
        if (msg.value != amount) revert INCORRECT_VALUE();

        IJBTerminal cobuildEthTerminal = DIRECTORY.primaryTerminalOf(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN);
        if (address(cobuildEthTerminal) == address(0)) revert NO_COBUILD_ETH_TERMINAL();

        IERC20 cobuildToken = IERC20(COBUILD_TOKEN);
        uint256 cobuildBalanceBefore = cobuildToken.balanceOf(address(this));

        // Buy COBUILD from the COBUILD revnet using ETH.
        cobuildEthTerminal.pay{ value: msg.value }(
            COBUILD_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            msg.value,
            address(this),
            1,
            memo,
            metadata
        );

        uint256 cobuildReceived = cobuildToken.balanceOf(address(this)) - cobuildBalanceBefore;
        if (cobuildReceived == 0) revert ZERO_COBUILD_OUT();
        IJBTerminal destinationTerminal = _destinationTerminalOf(projectId);

        beneficiaryTokenCount = _forwardCobuild(
            destinationTerminal, cobuildToken, cobuildReceived, projectId, beneficiary, minReturnedTokens, memo, metadata
        );
    }

    function _payWithCobuild(
        uint256 projectId,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        IJBTerminal destinationTerminal = _destinationTerminalOf(projectId);
        IERC20 cobuildToken = IERC20(COBUILD_TOKEN);

        uint256 cobuildBalanceBefore = cobuildToken.balanceOf(address(this));
        cobuildToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 cobuildReceived = cobuildToken.balanceOf(address(this)) - cobuildBalanceBefore;
        if (cobuildReceived == 0) revert ZERO_COBUILD_OUT();

        beneficiaryTokenCount = _forwardCobuild(
            destinationTerminal, cobuildToken, cobuildReceived, projectId, beneficiary, minReturnedTokens, memo, metadata
        );
    }

    function _destinationTerminalOf(uint256 projectId) internal view returns (IJBTerminal destinationTerminal) {
        destinationTerminal = DIRECTORY.primaryTerminalOf(projectId, COBUILD_TOKEN);
        if (address(destinationTerminal) == address(0)) revert NO_DEST_TERMINAL();
        if (address(destinationTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();
    }

    function _nativeAccountingContext() internal pure returns (JBAccountingContext memory) {
        return JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    function _forwardCobuild(
        IJBTerminal destinationTerminal,
        IERC20 cobuildToken,
        uint256 cobuildAmount,
        uint256 projectId,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        cobuildToken.forceApprove(address(destinationTerminal), 0);
        cobuildToken.forceApprove(address(destinationTerminal), cobuildAmount);

        beneficiaryTokenCount = destinationTerminal.pay(
            projectId,
            COBUILD_TOKEN,
            cobuildAmount,
            beneficiary,
            minReturnedTokens,
            memo,
            metadata
        );

        cobuildToken.forceApprove(address(destinationTerminal), 0);
    }
}
