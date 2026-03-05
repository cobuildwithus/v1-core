// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface IBudgetTCRFactoryDiscoveryEmitter {
    function onBudgetStackDeployed(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    ) external;

    function onBudgetAllocationMechanismDeployed(
        bytes32 itemID,
        address allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory
    ) external;
}
