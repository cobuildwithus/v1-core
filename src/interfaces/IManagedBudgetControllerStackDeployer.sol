// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IManagedBudgetController } from "./IManagedBudgetController.sol";

interface IManagedBudgetControllerStackDeployer {
    struct PreparationResult {
        address strategy;
        address budgetTreasury;
        address premiumEscrow;
    }

    error ADDRESS_ZERO();

    function prepareBudgetStack(
        address controller,
        address budgetAllocationLedger,
        address goalFlow,
        address goalTreasury
    ) external returns (PreparationResult memory result);

    function deployBudgetTreasury(
        address controller,
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address budgetAllocationLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        IManagedBudgetController.BudgetConfig calldata config,
        address successResolver,
        address spendPolicy,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external returns (address deployedBudgetTreasury);
}
