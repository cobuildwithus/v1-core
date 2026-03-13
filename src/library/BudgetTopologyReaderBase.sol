// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { BudgetTopologyRegistryLib } from "src/goals/library/BudgetTopologyRegistryLib.sol";

abstract contract BudgetTopologyReaderBase is IBudgetStackTopologyReader {
    function budgetStackTopology(
        bytes32 itemID
    ) external view virtual override returns (BudgetStackTopology memory topology, bool active) {
        return _budgetStackTopologyAt(itemID);
    }

    function budgetStackTopologyForBudgetTreasury(
        address budgetTreasury
    ) external view virtual override returns (BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = _budgetTopologyItemIdForBudgetTreasury(budgetTreasury);
        if (itemID == bytes32(0)) return (topology, false);
        return _budgetStackTopologyAt(itemID);
    }

    function budgetStackTopologyForChildFlow(
        address childFlow
    ) external view virtual override returns (BudgetStackTopology memory topology, bool active) {
        bytes32 itemID = _budgetTopologyItemIdForChildFlow(childFlow);
        if (itemID == bytes32(0)) return (topology, false);
        return _budgetStackTopologyAt(itemID);
    }

    function itemIdForBudgetTreasury(address budgetTreasury) external view virtual override returns (bytes32 itemID) {
        itemID = _budgetTopologyItemIdForBudgetTreasury(budgetTreasury);
    }

    function itemIdForChildFlow(address childFlow) external view virtual override returns (bytes32 itemID) {
        itemID = _budgetTopologyItemIdForChildFlow(childFlow);
    }

    function _budgetStackTopologyAt(
        bytes32 itemID
    ) internal view returns (BudgetStackTopology memory topology, bool active) {
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment = _budgetTopologyDeployment(itemID);
        topology = BudgetTopologyRegistryLib.topologyFromDeployment(deployment);
        active = _budgetTopologyIsActive(itemID, deployment);
    }

    function _budgetTopologyDeployment(
        bytes32 itemID
    ) internal view virtual returns (BudgetTopologyRegistryLib.BudgetDeployment storage deployment);

    function _budgetTopologyItemIdForBudgetTreasury(
        address budgetTreasury
    ) internal view virtual returns (bytes32 itemID);

    function _budgetTopologyItemIdForChildFlow(address childFlow) internal view virtual returns (bytes32 itemID);

    function _budgetTopologyIsActive(
        bytes32 itemID,
        BudgetTopologyRegistryLib.BudgetDeployment storage deployment
    ) internal view virtual returns (bool active);
}
