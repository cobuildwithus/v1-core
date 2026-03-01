// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Routes underwriter slashing from premium escrows into stake vault and goal funding.
/// @dev Cobuild conversion failures are best-effort and observable; cobuild stays in this contract on failure.
contract UnderwriterSlasherRouter is IUnderwriterSlasherRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string private constant COBUILD_CONVERSION_MEMO = "UNDERWRITER_SLASH_COBUILD_CONVERSION";

    IStakeVault public immutable override stakeVault;
    address public immutable override authority;
    IJBDirectory public immutable directory;
    IERC20 public immutable goalToken;
    IERC20 public immutable cobuildToken;
    ISuperToken public immutable goalSuperToken;
    address public immutable goalFundingTarget;
    uint256 public immutable goalRevnetId;

    mapping(address => bool) public override isAuthorizedPremiumEscrow;

    constructor(
        IStakeVault stakeVault_,
        address authority_,
        IJBDirectory directory_,
        uint256 goalRevnetId_,
        IERC20 goalToken_,
        IERC20 cobuildToken_,
        ISuperToken goalSuperToken_,
        address goalFundingTarget_
    ) {
        if (address(stakeVault_) == address(0)) revert ADDRESS_ZERO();
        if (authority_ == address(0)) revert ADDRESS_ZERO();
        if (address(directory_) == address(0)) revert ADDRESS_ZERO();
        if (address(goalToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(cobuildToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(goalSuperToken_) == address(0)) revert ADDRESS_ZERO();
        if (goalFundingTarget_ == address(0)) revert ADDRESS_ZERO();

        address expectedGoalToken = address(stakeVault_.goalToken());
        if (expectedGoalToken != address(goalToken_)) {
            revert INVALID_GOAL_TOKEN(expectedGoalToken, address(goalToken_));
        }
        address expectedCobuildToken = address(stakeVault_.cobuildToken());
        if (expectedCobuildToken != address(cobuildToken_)) {
            revert INVALID_COBUILD_TOKEN(expectedCobuildToken, address(cobuildToken_));
        }

        if (address(goalSuperToken_).code.length != 0) {
            address superTokenUnderlying = goalSuperToken_.getUnderlyingToken();
            if (superTokenUnderlying != address(goalToken_)) {
                revert GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH(address(goalToken_), superTokenUnderlying);
            }
        }

        stakeVault = stakeVault_;
        authority = authority_;
        directory = directory_;
        goalRevnetId = goalRevnetId_;
        goalToken = goalToken_;
        cobuildToken = cobuildToken_;
        goalSuperToken = goalSuperToken_;
        goalFundingTarget = goalFundingTarget_;
    }

    function setAuthorizedPremiumEscrow(address premiumEscrow, bool authorized) external override {
        if (msg.sender != authority) revert ONLY_AUTHORITY();
        if (premiumEscrow == address(0)) revert ADDRESS_ZERO();

        isAuthorizedPremiumEscrow[premiumEscrow] = authorized;
        emit PremiumEscrowAuthorizationSet(premiumEscrow, authorized);
    }

    function slashUnderwriter(address underwriter, uint256 weightAmount) external override nonReentrant {
        address premiumEscrow = msg.sender;
        if (!isAuthorizedPremiumEscrow[premiumEscrow]) revert ONLY_AUTHORIZED_PREMIUM_ESCROW();
        if (underwriter == address(0)) revert ADDRESS_ZERO();

        uint256 goalBefore = goalToken.balanceOf(address(this));
        uint256 cobuildBefore = cobuildToken.balanceOf(address(this));

        stakeVault.slashUnderwriterStake(underwriter, weightAmount, address(this));

        uint256 goalSlashedAmount = goalToken.balanceOf(address(this)) - goalBefore;
        uint256 cobuildSlashedAmount = cobuildToken.balanceOf(address(this)) - cobuildBefore;

        uint256 convertedGoalAmount = _tryConvertHeldCobuild(premiumEscrow, underwriter);
        uint256 forwardedSuperTokenAmount = _upgradeAndForwardGoalBalance();

        emit UnderwriterSlashRouted(
            premiumEscrow,
            underwriter,
            weightAmount,
            goalSlashedAmount,
            cobuildSlashedAmount,
            convertedGoalAmount,
            forwardedSuperTokenAmount
        );
    }

    function _tryConvertHeldCobuild(
        address premiumEscrow,
        address underwriter
    ) internal returns (uint256 convertedGoal) {
        uint256 cobuildAmount = cobuildToken.balanceOf(address(this));
        if (cobuildAmount == 0) return 0;
        IJBTerminal goalTerminal = _resolveGoalTerminal();
        if (address(goalTerminal) == address(0) || address(goalTerminal).code.length == 0) {
            emit CobuildConversionFailed(
                premiumEscrow,
                underwriter,
                cobuildAmount,
                abi.encodeWithSelector(INVALID_GOAL_TERMINAL.selector, address(goalTerminal))
            );
            return 0;
        }

        uint256 goalBefore = goalToken.balanceOf(address(this));
        cobuildToken.forceApprove(address(goalTerminal), 0);
        cobuildToken.forceApprove(address(goalTerminal), cobuildAmount);

        try
            goalTerminal.pay(
                goalRevnetId,
                address(cobuildToken),
                cobuildAmount,
                address(this),
                0,
                COBUILD_CONVERSION_MEMO,
                bytes("")
            )
        {
            convertedGoal = goalToken.balanceOf(address(this)) - goalBefore;
        } catch (bytes memory reason) {
            emit CobuildConversionFailed(premiumEscrow, underwriter, cobuildAmount, reason);
        }

        cobuildToken.forceApprove(address(goalTerminal), 0);
    }

    function _upgradeAndForwardGoalBalance() internal returns (uint256 forwardedSuperTokenAmount) {
        IERC20 goalSuperTokenErc20 = IERC20(address(goalSuperToken));

        uint256 goalBalance = goalToken.balanceOf(address(this));
        if (goalBalance != 0) {
            goalToken.forceApprove(address(goalSuperToken), 0);
            goalToken.forceApprove(address(goalSuperToken), goalBalance);
            goalSuperToken.upgrade(goalBalance);
            goalToken.forceApprove(address(goalSuperToken), 0);
        }

        forwardedSuperTokenAmount = goalSuperTokenErc20.balanceOf(address(this));
        if (forwardedSuperTokenAmount != 0) {
            goalSuperTokenErc20.safeTransfer(goalFundingTarget, forwardedSuperTokenAmount);
        }
    }

    function _resolveGoalTerminal() internal view returns (IJBTerminal) {
        return directory.primaryTerminalOf(goalRevnetId, address(cobuildToken));
    }
}
