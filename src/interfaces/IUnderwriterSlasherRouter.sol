// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IStakeVault } from "./IStakeVault.sol";

interface IUnderwriterSlasherRouter {
    error ADDRESS_ZERO();
    error ONLY_AUTHORITY();
    error ONLY_AUTHORIZED_PREMIUM_ESCROW();
    error INVALID_PREMIUM_ESCROW(address premiumEscrow);
    error INVALID_GOAL_TOKEN(address expected, address actual);
    error INVALID_COBUILD_TOKEN(address expected, address actual);
    error GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH(address expected, address actual);
    error INVALID_GOAL_TERMINAL(address terminal);
    error SUPER_TOKEN_TRANSFER_RETURNED_FALSE(address target, uint256 amount);

    event PremiumEscrowAuthorizationSet(address indexed premiumEscrow, bool authorized);
    event CobuildConversionFailed(
        address indexed premiumEscrow,
        address indexed underwriter,
        uint256 cobuildAmount,
        bytes reason
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
    event GoalSuperTokenUpgradeFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 goalAmount, bytes reason
    );
    event GoalSuperTokenForwardingFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 superTokenAmount, bytes reason
    );
    event GoalSuperTokenForwardingRetried(
        address indexed caller,
        uint256 goalBalanceBefore,
        uint256 superTokenBalanceBefore,
        uint256 forwardedSuperTokenAmount
    );

    function authority() external view returns (address);
    function stakeVault() external view returns (IStakeVault);
    function isAuthorizedPremiumEscrow(address escrow) external view returns (bool);

    function setAuthorizedPremiumEscrow(address premiumEscrow, bool authorized) external;
    function slashUnderwriter(address underwriter, uint256 weight) external;
    function retryForwarding() external returns (uint256 forwardedSuperTokenAmount);
    function retryConversionAndForward()
        external
        returns (uint256 convertedGoalAmount, uint256 forwardedSuperTokenAmount);
}
