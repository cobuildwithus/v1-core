// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { ICobuildCommunityTerminal } from "src/interfaces/ICobuildCommunityTerminal.sol";
import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBCashOutTerminal } from "@bananapus/core-v5/interfaces/IJBCashOutTerminal.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library GoalTreasuryTerminalRollover {
    using SafeERC20 for IERC20;

    function terminalRolloverReleaseAt(uint64 resolvedAt, uint64 cooldown) public view returns (uint64 releaseAt) {
        uint256 baseTimestamp = resolvedAt != 0 ? resolvedAt : block.timestamp;
        uint256 releaseAtValue = baseTimestamp + cooldown;
        if (releaseAtValue > type(uint64).max) releaseAtValue = type(uint64).max;
        releaseAt = SafeCast.toUint64(releaseAtValue);
    }

    function queueHeldBalanceIfAny(
        IJBDirectory directory,
        uint256 cobuildRevnetId,
        IERC20 paymentToken,
        uint64 releaseAt
    ) public {
        uint256 heldBalance = paymentToken.balanceOf(address(this));
        if (heldBalance == 0) return;
        _queueRolloverAmount(directory, cobuildRevnetId, paymentToken, heldBalance, releaseAt);
    }

    function cashOutAndQueue(
        IJBDirectory directory,
        uint256 goalRevnetId,
        uint256 cobuildRevnetId,
        IERC20 paymentToken,
        address goalToken,
        uint256 goalTokenAmount,
        uint64 releaseAt
    ) public returns (uint256 rolloverAmount) {
        rolloverAmount = _cashOutGoalResidualToCommunityToken(
            directory,
            goalRevnetId,
            paymentToken,
            goalToken,
            goalTokenAmount
        );
        _queueRolloverAmount(directory, cobuildRevnetId, paymentToken, rolloverAmount, releaseAt);
    }

    function _queueRolloverAmount(
        IJBDirectory directory,
        uint256 cobuildRevnetId,
        IERC20 paymentToken,
        uint256 amount,
        uint64 releaseAt
    ) private {
        ICobuildSplitHook splitHook = _communitySplitHook(directory, cobuildRevnetId, paymentToken);
        paymentToken.forceApprove(address(splitHook), 0);
        paymentToken.forceApprove(address(splitHook), amount);
        splitHook.queueRollover(amount, releaseAt);
        paymentToken.forceApprove(address(splitHook), 0);
    }

    function _cashOutGoalResidualToCommunityToken(
        IJBDirectory directory,
        uint256 goalRevnetId,
        IERC20 paymentToken,
        address goalToken,
        uint256 goalTokenAmount
    ) private returns (uint256 reclaimAmount) {
        address terminalAddress = address(directory.primaryTerminalOf(goalRevnetId, address(paymentToken)));
        if (terminalAddress == address(0)) {
            revert IGoalTreasury.NO_TERMINAL_ROLLOVER_GOAL_CASH_OUT_TERMINAL(goalRevnetId, address(paymentToken));
        }
        if (terminalAddress.code.length == 0) revert IGoalTreasury.NOT_A_CONTRACT(terminalAddress);

        IERC20(goalToken).forceApprove(terminalAddress, 0);
        IERC20(goalToken).forceApprove(terminalAddress, goalTokenAmount);
        reclaimAmount = IJBCashOutTerminal(terminalAddress).cashOutTokensOf(
            address(this),
            goalRevnetId,
            goalTokenAmount,
            address(paymentToken),
            1,
            payable(address(this)),
            bytes("")
        );
        IERC20(goalToken).forceApprove(terminalAddress, 0);
    }

    function _communitySplitHook(
        IJBDirectory directory,
        uint256 cobuildRevnetId,
        IERC20 paymentToken
    ) private view returns (ICobuildSplitHook splitHook) {
        address communityTerminal = address(directory.primaryTerminalOf(cobuildRevnetId, address(paymentToken)));
        if (communityTerminal == address(0) || communityTerminal.code.length == 0) {
            revert IGoalTreasury.INVALID_TERMINAL_ROLLOVER_COMMUNITY_TERMINAL(cobuildRevnetId, communityTerminal);
        }

        bool exists;
        (splitHook, , , , exists) = ICobuildCommunityTerminal(communityTerminal).communityConfigOf(cobuildRevnetId);
        address splitHookAddress = address(splitHook);
        if (!exists || splitHookAddress == address(0) || splitHookAddress.code.length == 0) {
            revert IGoalTreasury.INVALID_TERMINAL_ROLLOVER_SPLIT_HOOK(cobuildRevnetId, splitHookAddress);
        }
        if (splitHook.communityRevnetId() != cobuildRevnetId || splitHook.communityToken() != address(paymentToken)) {
            revert IGoalTreasury.INVALID_TERMINAL_ROLLOVER_SPLIT_HOOK(cobuildRevnetId, splitHookAddress);
        }
    }
}
