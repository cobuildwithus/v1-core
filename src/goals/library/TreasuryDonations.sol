// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library TreasuryDonations {
    using SafeERC20 for IERC20;

    function donateSuperTokenToFlow(
        ISuperToken superToken,
        address donor,
        address flow,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 flowBalanceBefore = superToken.balanceOf(flow);
        IERC20(address(superToken)).safeTransferFrom(donor, flow, amount);
        received = superToken.balanceOf(flow) - flowBalanceBefore;
    }

    function donateUnderlyingAndUpgradeToFlow(
        ISuperToken superToken,
        address donor,
        address flow,
        uint256 amount
    ) internal returns (uint256 received, address underlyingTokenAddress) {
        IERC20 underlyingToken = IERC20(superToken.getUnderlyingToken());
        underlyingTokenAddress = address(underlyingToken);
        underlyingToken.safeTransferFrom(donor, address(this), amount);

        uint256 superTokenBefore = IERC20(address(superToken)).balanceOf(address(this));
        underlyingToken.forceApprove(address(superToken), 0);
        underlyingToken.forceApprove(address(superToken), amount);
        superToken.upgrade(amount);
        underlyingToken.forceApprove(address(superToken), 0);

        received = IERC20(address(superToken)).balanceOf(address(this)) - superTokenBefore;
        if (received == 0) return (0, underlyingTokenAddress);

        IERC20(address(superToken)).safeTransfer(flow, received);
    }
}
