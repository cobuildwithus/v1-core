// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library TokenTransfers {
    using SafeERC20 for IERC20;

    function safeTransferFromReceived(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        received = token.balanceOf(to) - balanceBefore;
    }

    function safeTransferSpentAndReceived(
        IERC20 token,
        address to,
        uint256 amount
    ) internal returns (uint256 spent, uint256 received) {
        uint256 senderBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(to);

        token.safeTransfer(to, amount);

        spent = senderBalanceBefore - token.balanceOf(address(this));
        received = token.balanceOf(to) - recipientBalanceBefore;
    }

    function safeTransferReceived(IERC20 token, address to, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        received = token.balanceOf(to) - balanceBefore;
    }
}
