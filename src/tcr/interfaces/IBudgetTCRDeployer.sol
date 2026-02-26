// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCRStackDeployer } from "./IBudgetTCRStackDeployer.sol";

interface IBudgetTCRDeployer is IBudgetTCRStackDeployer {
    error ALREADY_INITIALIZED();

    function budgetTCR() external view returns (address);
    function initialize(address budgetTCR_) external;
}
