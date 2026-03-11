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

import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

/// @notice Shared terminal that routes native ETH into a goal's parent/community token before funding the goal.
/// @dev The goal's payment denomination is resolved from its registered treasury on each pay call.
contract CobuildGoalTerminal is IJBTerminal, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IJBDirectory public immutable DIRECTORY;
    IGoalDeploymentRegistry public immutable GOAL_DEPLOYMENT_REGISTRY;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error NO_VALUE();
    error INCORRECT_VALUE();
    error UNSUPPORTED_TOKEN(address token);
    error UNSUPPORTED_CALL();
    error GOAL_NOT_REGISTERED(uint256 goalId);
    error NO_PAYMENT_ETH_TERMINAL(uint256 paymentRevnetId);
    error NO_DEST_TERMINAL(uint256 projectId, address token);
    error DEST_TERMINAL_IS_SELF();
    error ZERO_PAYMENT_TOKEN_OUT();

    constructor(IJBDirectory directory, IGoalDeploymentRegistry goalDeploymentRegistry) {
        if (address(directory) == address(0)) revert ADDRESS_ZERO();
        if (address(goalDeploymentRegistry) == address(0)) revert ADDRESS_ZERO();
        if (address(directory).code.length == 0) revert NOT_A_CONTRACT(address(directory));
        if (address(goalDeploymentRegistry).code.length == 0) {
            revert NOT_A_CONTRACT(address(goalDeploymentRegistry));
        }

        DIRECTORY = directory;
        GOAL_DEPLOYMENT_REGISTRY = goalDeploymentRegistry;
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
        (address paymentToken, uint256 paymentRevnetId) = _fundingContextOf(projectId);

        if (token == JBConstants.NATIVE_TOKEN) {
            return
                _payWithEth(
                    projectId,
                    paymentToken,
                    paymentRevnetId,
                    amount,
                    beneficiary,
                    minReturnedTokens,
                    memo,
                    metadata
                );
        }

        if (token == paymentToken) {
            if (msg.value != 0) revert INCORRECT_VALUE();
            return
                _payWithPaymentToken(projectId, paymentToken, amount, beneficiary, minReturnedTokens, memo, metadata);
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
        uint256 projectId,
        address paymentToken,
        uint256 paymentRevnetId,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        if (msg.value == 0) revert NO_VALUE();
        if (msg.value != amount) revert INCORRECT_VALUE();

        IJBTerminal paymentEthTerminal = DIRECTORY.primaryTerminalOf(paymentRevnetId, JBConstants.NATIVE_TOKEN);
        if (address(paymentEthTerminal) == address(0)) revert NO_PAYMENT_ETH_TERMINAL(paymentRevnetId);

        IERC20 paymentTokenRef = IERC20(paymentToken);
        uint256 paymentBalanceBefore = paymentTokenRef.balanceOf(address(this));

        paymentEthTerminal.pay{ value: msg.value }(
            paymentRevnetId,
            JBConstants.NATIVE_TOKEN,
            msg.value,
            address(this),
            1,
            memo,
            bytes("")
        );

        uint256 paymentReceived = paymentTokenRef.balanceOf(address(this)) - paymentBalanceBefore;
        if (paymentReceived == 0) revert ZERO_PAYMENT_TOKEN_OUT();

        IJBTerminal destinationTerminal = _destinationTerminalOf(projectId, paymentToken);
        beneficiaryTokenCount = _forwardPaymentToken(
            destinationTerminal,
            paymentTokenRef,
            paymentToken,
            paymentReceived,
            projectId,
            beneficiary,
            minReturnedTokens,
            memo,
            metadata
        );
    }

    function _payWithPaymentToken(
        uint256 projectId,
        address paymentToken,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        IJBTerminal destinationTerminal = _destinationTerminalOf(projectId, paymentToken);
        IERC20 paymentTokenRef = IERC20(paymentToken);

        uint256 paymentBalanceBefore = paymentTokenRef.balanceOf(address(this));
        paymentTokenRef.safeTransferFrom(msg.sender, address(this), amount);
        uint256 paymentReceived = paymentTokenRef.balanceOf(address(this)) - paymentBalanceBefore;
        if (paymentReceived == 0) revert ZERO_PAYMENT_TOKEN_OUT();

        beneficiaryTokenCount = _forwardPaymentToken(
            destinationTerminal,
            paymentTokenRef,
            paymentToken,
            paymentReceived,
            projectId,
            beneficiary,
            minReturnedTokens,
            memo,
            metadata
        );
    }

    function _fundingContextOf(uint256 goalId) internal view returns (address paymentToken, uint256 paymentRevnetId) {
        address goalTreasury = GOAL_DEPLOYMENT_REGISTRY.goalTreasuryOf(goalId);
        if (goalTreasury == address(0)) revert GOAL_NOT_REGISTERED(goalId);
        if (goalTreasury.code.length == 0) revert NOT_A_CONTRACT(goalTreasury);

        IGoalTreasury treasury = IGoalTreasury(goalTreasury);
        paymentRevnetId = treasury.cobuildRevnetId();

        address stakeVault = treasury.stakeVault();
        if (stakeVault == address(0)) revert ADDRESS_ZERO();
        if (stakeVault.code.length == 0) revert NOT_A_CONTRACT(stakeVault);

        paymentToken = address(IStakeVault(stakeVault).cobuildToken());
        if (paymentToken == address(0)) revert ADDRESS_ZERO();
        if (paymentToken.code.length == 0) revert NOT_A_CONTRACT(paymentToken);
    }

    function _destinationTerminalOf(
        uint256 projectId,
        address paymentToken
    ) internal view returns (IJBTerminal destinationTerminal) {
        destinationTerminal = DIRECTORY.primaryTerminalOf(projectId, paymentToken);
        if (address(destinationTerminal) == address(0)) revert NO_DEST_TERMINAL(projectId, paymentToken);
        if (address(destinationTerminal) == address(this)) revert DEST_TERMINAL_IS_SELF();
    }

    function _nativeAccountingContext() internal pure returns (JBAccountingContext memory) {
        return
            JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });
    }

    function _forwardPaymentToken(
        IJBTerminal destinationTerminal,
        IERC20 paymentTokenRef,
        address paymentToken,
        uint256 paymentAmount,
        uint256 projectId,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        paymentTokenRef.forceApprove(address(destinationTerminal), 0);
        paymentTokenRef.forceApprove(address(destinationTerminal), paymentAmount);

        beneficiaryTokenCount = destinationTerminal.pay(
            projectId,
            paymentToken,
            paymentAmount,
            beneficiary,
            minReturnedTokens,
            memo,
            metadata
        );

        paymentTokenRef.forceApprove(address(destinationTerminal), 0);
    }
}
