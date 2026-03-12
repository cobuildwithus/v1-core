// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { SingleAllocatorStrategy } from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { ManagedBudgetController } from "src/goals/ManagedBudgetController.sol";

library GoalFactoryManagedPresetDeploy {
    struct ManagedPresetBundle {
        ManagedBudgetController budgetController;
        address goalAllocatorStrategy;
        address stackDeployer;
    }

    struct ManagedPresetBootstrapConfig {
        address budgetControllerImplementation;
        address goalAllocatorStrategyImplementation;
        address stackDeployerImplementation;
        address budgetChildStrategyFactoryImplementation;
    }

    function bootstrapManagedPreset(
        address goalTreasury,
        ManagedPresetBootstrapConfig memory config
    ) external returns (ManagedPresetBundle memory out) {
        out.budgetController = ManagedBudgetController(Clones.clone(config.budgetControllerImplementation));
        out.goalAllocatorStrategy = Clones.clone(config.goalAllocatorStrategyImplementation);
        out.stackDeployer = Clones.clone(config.stackDeployerImplementation);
        SingleAllocatorStrategy(out.goalAllocatorStrategy).initialize(goalTreasury, address(out.budgetController));
        IBudgetStackDeployer(out.stackDeployer).initializeWithConfig(
            address(out.budgetController),
            IBudgetStackDeployer.StackModuleConfig({
                childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.Factory,
                childFlowStrategyTarget: config.budgetChildStrategyFactoryImplementation,
                mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.None,
                childFlowRecipientAdmin: address(out.budgetController),
                premiumEscrowMode: IBudgetStackDeployer.PremiumEscrowMode.None,
                premiumEscrowImplementation: address(0)
            }),
            address(0)
        );
    }
}
