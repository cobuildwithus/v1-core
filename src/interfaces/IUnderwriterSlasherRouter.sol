// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IStakeVault} from "./IStakeVault.sol";

interface IUnderwriterSlasherRouter {
    function authority() external view returns (address);
    function stakeVault() external view returns (IStakeVault);
    function isAuthorizedPremiumEscrow(address escrow) external view returns (bool);

    function setAuthorizedPremiumEscrow(address premiumEscrow, bool authorized) external;
    function slashUnderwriter(address underwriter, uint256 weight) external;
}
