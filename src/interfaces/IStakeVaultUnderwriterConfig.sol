// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface IStakeVaultUnderwriterConfig {
    function setUnderwriterSlasher(address slasher) external;
}
