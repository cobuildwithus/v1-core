// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library TreasuryDonations {
    using SafeERC20 for IERC20;

    function donateUnderlyingAndUpgradeToFlow(
        ISuperToken superToken,
        address donor,
        address flow,
        uint256 amount
    ) internal returns (uint256 received, address underlyingTokenAddress) {
        address superTokenAddress = address(superToken);
        underlyingTokenAddress = superToken.getUnderlyingToken();
        IERC20 underlyingToken = IERC20(underlyingTokenAddress);
        IERC20 flowSuperToken = IERC20(superTokenAddress);
        underlyingToken.safeTransferFrom(donor, address(this), amount);

        uint256 superTokenBefore = flowSuperToken.balanceOf(address(this));
        underlyingToken.forceApprove(superTokenAddress, 0);
        underlyingToken.forceApprove(superTokenAddress, amount);
        superToken.upgrade(amount);
        underlyingToken.forceApprove(superTokenAddress, 0);

        received = flowSuperToken.balanceOf(address(this)) - superTokenBefore;
        if (received == 0) return (0, underlyingTokenAddress);

        flowSuperToken.safeTransfer(flow, received);
    }
}
