// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IStakeVault} from "./IStakeVault.sol";

interface IUnderwriterSlasherRouter {
    error ADDRESS_ZERO();
    error ONLY_AUTHORITY();
    error ONLY_AUTHORIZED_PREMIUM_ESCROW();
    error INVALID_PREMIUM_ESCROW(address premiumEscrow);
    error INVALID_GOAL_TOKEN(address expected, address actual);
    error INVALID_COBUILD_TOKEN(address expected, address actual);
    error GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH(address expected, address actual);
    error INVALID_GOAL_TERMINAL(address terminal);

    event PremiumEscrowAuthorizationSet(address indexed premiumEscrow, bool authorized);
    event CobuildConversionFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 cobuildAmount, bytes reason
    );
    event UnderwriterSlashRouted(
        address indexed premiumEscrow,
        address indexed underwriter,
        uint256 requestedWeight,
        uint256 goalSlashedAmount,
        uint256 cobuildSlashedAmount,
        uint256 convertedGoalAmount,
        uint256 forwardedSuperTokenAmount
    );

    function authority() external view returns (address);
    function stakeVault() external view returns (IStakeVault);
    function isAuthorizedPremiumEscrow(address escrow) external view returns (bool);

    function setAuthorizedPremiumEscrow(address premiumEscrow, bool authorized) external;
    function slashUnderwriter(address underwriter, uint256 weight) external;
}
