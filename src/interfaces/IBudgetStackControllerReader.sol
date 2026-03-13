// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface IBudgetStackControllerReader {
    function controller() external view returns (address);
}
