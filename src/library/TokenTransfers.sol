// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

library TokenTransfers {
    using SafeERC20 for IERC20;

    error NATIVE_TRANSFER_FAILED(address to, uint256 amount);
    error BALANCE_DECREASED_UNEXPECTEDLY(address token, address account, uint256 beforeBalance, uint256 afterBalance);
    error BALANCE_INCREASED_UNEXPECTEDLY(address token, address account, uint256 beforeBalance, uint256 afterBalance);

    function balanceOf(address token, address account) internal view returns (uint256 balance) {
        if (token == JBConstants.NATIVE_TOKEN) return account.balance;
        return IERC20(token).balanceOf(account);
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;

        if (token == JBConstants.NATIVE_TOKEN) {
            (bool success, ) = payable(to).call{ value: amount }("");
            if (!success) revert NATIVE_TRANSFER_FAILED(to, amount);
            return;
        }

        IERC20(token).safeTransfer(to, amount);
    }

    function safeTransferFromReceived(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        received = _checkedIncreaseDelta(address(token), to, balanceBefore, token.balanceOf(to));
    }

    function safeTransferSpentAndReceived(
        IERC20 token,
        address to,
        uint256 amount
    ) internal returns (uint256 spent, uint256 received) {
        uint256 senderBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(to);

        token.safeTransfer(to, amount);

        spent = _checkedDecreaseDelta(
            address(token),
            address(this),
            senderBalanceBefore,
            token.balanceOf(address(this))
        );
        received = _checkedIncreaseDelta(address(token), to, recipientBalanceBefore, token.balanceOf(to));
    }

    function safeTransferReceived(IERC20 token, address to, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        received = _checkedIncreaseDelta(address(token), to, balanceBefore, token.balanceOf(to));
    }

    function _checkedIncreaseDelta(
        address token,
        address account,
        uint256 beforeBalance,
        uint256 afterBalance
    ) private pure returns (uint256 delta) {
        if (afterBalance < beforeBalance) {
            revert BALANCE_DECREASED_UNEXPECTEDLY(token, account, beforeBalance, afterBalance);
        }
        delta = afterBalance - beforeBalance;
    }

    function _checkedDecreaseDelta(
        address token,
        address account,
        uint256 beforeBalance,
        uint256 afterBalance
    ) private pure returns (uint256 delta) {
        if (afterBalance > beforeBalance) {
            revert BALANCE_INCREASED_UNEXPECTEDLY(token, account, beforeBalance, afterBalance);
        }
        delta = beforeBalance - afterBalance;
    }
}
