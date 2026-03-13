// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";

library BudgetStackPresetConfigLib {
    function openPreset(
        address premiumEscrowImplementation
    ) internal pure returns (IBudgetStackDeployer.StackModuleConfig memory config) {
        config = IBudgetStackDeployer.StackModuleConfig({
            childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.SharedBudgetFlowRouter,
            childFlowStrategyTarget: address(0),
            mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.AllocationMechanismTCR,
            childFlowRecipientAdmin: address(0),
            premiumEscrowImplementation: premiumEscrowImplementation
        });
    }

    function managedPreset(
        address childFlowStrategyFactory,
        address childFlowRecipientAdmin
    ) internal pure returns (IBudgetStackDeployer.StackModuleConfig memory config) {
        config = IBudgetStackDeployer.StackModuleConfig({
            childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.Factory,
            childFlowStrategyTarget: childFlowStrategyFactory,
            mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.None,
            childFlowRecipientAdmin: childFlowRecipientAdmin,
            premiumEscrowImplementation: address(0)
        });
    }
}
