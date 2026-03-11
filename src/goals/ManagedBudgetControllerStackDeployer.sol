// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { IManagedBudgetControllerStackDeployer } from "src/interfaces/IManagedBudgetControllerStackDeployer.sol";

/// @notice Temporary wiring stub so managed goals can initialize a controller before stack-runtime work lands.
contract ManagedBudgetControllerStackDeployer is IManagedBudgetControllerStackDeployer {
    error NOT_A_CONTRACT(address account);
    error UNIMPLEMENTED();

    address public immutable premiumEscrowImplementation;

    constructor(address premiumEscrowImplementation_) {
        if (premiumEscrowImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrowImplementation_.code.length == 0) revert NOT_A_CONTRACT(premiumEscrowImplementation_);
        premiumEscrowImplementation = premiumEscrowImplementation_;
    }

    function prepareBudgetStack(
        address,
        address,
        address,
        address,
        address
    ) external pure override returns (PreparationResult memory) {
        revert UNIMPLEMENTED();
    }

    function deployBudgetTreasury(
        address,
        address,
        address,
        address,
        address,
        address,
        address,
        uint32,
        IManagedBudgetController.BudgetConfig calldata,
        address,
        address,
        uint64,
        uint256
    ) external pure override returns (address) {
        revert UNIMPLEMENTED();
    }
}
