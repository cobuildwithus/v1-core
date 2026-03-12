// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";

interface IBudgetTCRDeployer is IBudgetStackDeployer {
    function budgetTCR() external view returns (address);
    function initialize(address budgetTCR_, address premiumEscrowImplementation_, address discoveryEmitter_) external;
}
