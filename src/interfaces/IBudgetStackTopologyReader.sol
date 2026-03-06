// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @notice Read-only surface for canonical budget-stack topology stored by the budget registry.
interface IBudgetStackTopologyReader {
    struct BudgetStackTopology {
        address childFlow;
        address budgetTreasury;
        address premiumEscrow;
        address strategy;
        address allocationMechanism;
        address allocationMechanismArbitrator;
    }

    function budgetStackTopology(
        bytes32 itemID
    ) external view returns (BudgetStackTopology memory topology, bool active);

    function budgetStackTopologyForBudgetTreasury(
        address budgetTreasury
    ) external view returns (BudgetStackTopology memory topology, bool active);

    function budgetStackTopologyForChildFlow(
        address childFlow
    ) external view returns (BudgetStackTopology memory topology, bool active);

    function itemIdForBudgetTreasury(address budgetTreasury) external view returns (bytes32 itemID);

    function itemIdForChildFlow(address childFlow) external view returns (bytes32 itemID);
}
