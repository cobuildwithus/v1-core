// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface ITreasuryDonations {
    function donateSuperToken(uint256 amount) external returns (uint256 received);
    function donateUnderlyingAndUpgrade(uint256 amount) external returns (uint256 received);
}
