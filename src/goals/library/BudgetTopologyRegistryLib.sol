// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";

library BudgetTopologyRegistryLib {
    struct BudgetDeployment {
        address childFlow;
        address budgetTreasury;
        address premiumEscrow;
        address strategy;
        address allocationMechanism;
        address allocationMechanismArbitrator;
        bool active;
    }

    function topologyFromDeployment(
        BudgetDeployment storage deployment
    ) external view returns (IBudgetStackTopologyReader.BudgetStackTopology memory topology) {
        topology = IBudgetStackTopologyReader.BudgetStackTopology({
            childFlow: deployment.childFlow,
            budgetTreasury: deployment.budgetTreasury,
            premiumEscrow: deployment.premiumEscrow,
            strategy: deployment.strategy,
            allocationMechanism: deployment.allocationMechanism,
            allocationMechanismArbitrator: deployment.allocationMechanismArbitrator
        });
    }

    function recordBudgetStackTopology(
        mapping(bytes32 => BudgetDeployment) storage budgetDeployments,
        mapping(address => bytes32) storage itemIdByBudgetTreasury,
        mapping(address => bytes32) storage itemIdByChildFlow,
        bytes32 itemID,
        IBudgetStackTopologyReader.BudgetStackTopology memory topology
    ) external {
        BudgetDeployment storage deployment = budgetDeployments[itemID];

        address previousBudgetTreasury = deployment.budgetTreasury;
        if (previousBudgetTreasury != address(0) && itemIdByBudgetTreasury[previousBudgetTreasury] == itemID) {
            delete itemIdByBudgetTreasury[previousBudgetTreasury];
        }

        address previousChildFlow = deployment.childFlow;
        if (previousChildFlow != address(0) && itemIdByChildFlow[previousChildFlow] == itemID) {
            delete itemIdByChildFlow[previousChildFlow];
        }

        deployment.childFlow = topology.childFlow;
        deployment.budgetTreasury = topology.budgetTreasury;
        deployment.premiumEscrow = topology.premiumEscrow;
        deployment.strategy = topology.strategy;
        deployment.allocationMechanism = topology.allocationMechanism;
        deployment.allocationMechanismArbitrator = topology.allocationMechanismArbitrator;

        itemIdByBudgetTreasury[topology.budgetTreasury] = itemID;
        itemIdByChildFlow[topology.childFlow] = itemID;
    }

    function validatedItemIdForBudgetTreasury(
        mapping(bytes32 => BudgetDeployment) storage budgetDeployments,
        mapping(address => bytes32) storage itemIdByBudgetTreasury,
        address budgetTreasury
    ) external view returns (bytes32 itemID) {
        itemID = itemIdByBudgetTreasury[budgetTreasury];
        if (itemID == bytes32(0)) return bytes32(0);
        if (budgetDeployments[itemID].budgetTreasury != budgetTreasury) return bytes32(0);
    }

    function validatedItemIdForChildFlow(
        mapping(bytes32 => BudgetDeployment) storage budgetDeployments,
        mapping(address => bytes32) storage itemIdByChildFlow,
        address childFlow
    ) external view returns (bytes32 itemID) {
        itemID = itemIdByChildFlow[childFlow];
        if (itemID == bytes32(0)) return bytes32(0);
        if (budgetDeployments[itemID].childFlow != childFlow) return bytes32(0);
    }
}
