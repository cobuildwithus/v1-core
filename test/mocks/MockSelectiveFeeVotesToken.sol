// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { MockVotesToken } from "./MockVotesToken.sol";

/// @dev Votes token that charges a fee only when transferring from `feeFrom`.
contract MockSelectiveFeeVotesToken is MockVotesToken {
    uint256 public immutable feeBps;
    address public immutable feeRecipient;
    address public feeFrom;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_, address feeRecipient_)
        MockVotesToken(name_, symbol_)
    {
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
    }

    function setFeeFrom(address from) external {
        feeFrom = from;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == feeFrom && from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (amount * feeBps) / 10_000;
            uint256 remainder = amount - fee;

            if (fee != 0) super._update(from, feeRecipient, fee);
            if (remainder != 0) super._update(from, to, remainder);
            return;
        }

        super._update(from, to, amount);
    }
}
