// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { BudgetStackTypes } from "src/interfaces/BudgetStackTypes.sol";

library BudgetStackPresetConfigLib {
    function openPreset(
        address premiumEscrowImplementation
    ) internal pure returns (BudgetStackTypes.StackModuleConfig memory config) {
        config = BudgetStackTypes.StackModuleConfig({
            childFlowStrategyMode: BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter,
            childFlowStrategyTarget: address(0),
            mechanismLayerMode: BudgetStackTypes.MechanismLayerMode.AllocationMechanismTCR,
            childFlowRecipientAdmin: address(0),
            premiumEscrowImplementation: premiumEscrowImplementation
        });
    }

    function managedPreset(
        address childFlowStrategyFactory,
        address childFlowRecipientAdmin
    ) internal pure returns (BudgetStackTypes.StackModuleConfig memory config) {
        config = BudgetStackTypes.StackModuleConfig({
            childFlowStrategyMode: BudgetStackTypes.ChildFlowStrategyMode.Factory,
            childFlowStrategyTarget: childFlowStrategyFactory,
            mechanismLayerMode: BudgetStackTypes.MechanismLayerMode.None,
            childFlowRecipientAdmin: childFlowRecipientAdmin,
            premiumEscrowImplementation: address(0)
        });
    }
}
