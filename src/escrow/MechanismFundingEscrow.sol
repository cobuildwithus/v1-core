// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken, ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

/// @title MechanismFundingEscrow
/// @notice Holds SuperToken funding for an allocation mechanism.
/// @dev This contract is intentionally minimal and mechanism-agnostic:
///      - It holds only the SuperToken (no underlying token handling).
///      - Only its controller may move funds.
///      - Funds may be released to a preconfigured mechanism recipient, or refunded to a
///        preconfigured refund recipient.
///
///      Typical use:
///      - A budget flow (or similar) streams/distributes funds into this escrow.
///      - A registry/controller enforces policy (min/max/deadline) and then either:
///          - releases escrowed funds to the mechanism's payout contract, or
///          - refunds escrowed funds back to the funding source.
contract MechanismFundingEscrow {
    using SuperTokenV1Library for ISuperToken;

    error ADDRESS_ZERO();
    error ONLY_CONTROLLER();
    error TRANSFER_FAILED();
    error POOL_CONNECTION_FAILED();

    event Released(address indexed recipient, uint256 amount);
    event Refunded(address indexed refundRecipient, uint256 amount);

    ISuperToken public immutable superToken;
    ISuperfluidPool public immutable distributionPool;
    address public immutable controller;
    address public immutable refundRecipient;
    address public immutable recipient;

    constructor(
        ISuperToken superToken_,
        ISuperfluidPool distributionPool_,
        address controller_,
        address refundRecipient_,
        address recipient_
    ) {
        if (address(superToken_) == address(0)) revert ADDRESS_ZERO();
        if (address(distributionPool_) == address(0)) revert ADDRESS_ZERO();
        if (controller_ == address(0)) revert ADDRESS_ZERO();
        if (refundRecipient_ == address(0)) revert ADDRESS_ZERO();
        if (recipient_ == address(0)) revert ADDRESS_ZERO();

        superToken = superToken_;
        distributionPool = distributionPool_;
        controller = controller_;
        refundRecipient = refundRecipient_;
        recipient = recipient_;

        if (!superToken_.connectPool(distributionPool_)) revert POOL_CONNECTION_FAILED();
    }

    modifier onlyController() {
        if (msg.sender != controller) revert ONLY_CONTROLLER();
        _;
    }

    /// @notice Releases SuperToken balance from escrow to the configured recipient.
    /// @param amount Amount to release. Use max uint256 to release all available balance.
    /// @return released Actual amount transferred.
    function release(uint256 amount) external onlyController returns (uint256 released) {
        released = _transferOut(recipient, amount);
        if (released != 0) emit Released(recipient, released);
    }

    /// @notice Refunds SuperToken balance from escrow to the configured refund recipient.
    /// @param amount Amount to refund. Use max uint256 to refund all available balance.
    /// @return refunded Actual amount transferred.
    function refund(uint256 amount) external onlyController returns (uint256 refunded) {
        refunded = _transferOut(refundRecipient, amount);
        if (refunded != 0) emit Refunded(refundRecipient, refunded);
    }

    function _transferOut(address to, uint256 amount) internal returns (uint256 transferred) {
        uint256 available = superToken.balanceOf(address(this));
        if (available == 0) return 0;

        transferred = amount > available ? available : amount;
        if (transferred == 0) return 0;

        bool success = superToken.transfer(to, transferred);
        if (!success) revert TRANSFER_FAILED();
    }
}
