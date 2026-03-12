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

    /// @notice Prepares the managed budget stack pieces that do not depend on live goal topology.
    /// @dev This phase only needs the controller so the deployer can enforce caller ownership and
    ///      scope the per-budget allocator strategy. Allocation-ledger, goal-flow, and
    ///      goal-treasury-derived runtime wiring happens later during `deployBudgetTreasury(...)`.
    function prepareBudgetStack(address controller) external returns (PreparationResult memory result);

    /// @notice Completes a prepared managed budget stack after the child flow exists.
    /// @dev Goal-flow, ledger, and other live runtime wiring belongs to this phase rather than
    ///      `prepareBudgetStack(...)`.
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
