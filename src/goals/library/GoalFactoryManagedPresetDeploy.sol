// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { SingleAllocatorStrategy } from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import { IBudgetStackRuntimeDeployer } from "src/interfaces/IBudgetStackRuntimeDeployer.sol";
import { ManagedBudgetController } from "src/goals/ManagedBudgetController.sol";
import { BudgetStackPresetConfigLib } from "src/goals/library/BudgetStackPresetConfigLib.sol";

library GoalFactoryManagedPresetDeploy {
    struct ManagedPresetBundle {
        ManagedBudgetController budgetController;
        address goalAllocatorStrategy;
        address stackDeployer;
    }

    struct ManagedPresetBootstrapConfig {
        address budgetControllerImplementation;
        address goalAllocatorStrategyImplementation;
        address budgetChildStrategyFactoryImplementation;
    }

    function bootstrapManagedPreset(
        address goalTreasury,
        address stackDeployerImplementation,
        ManagedPresetBootstrapConfig memory config
    ) external returns (ManagedPresetBundle memory out) {
        out.budgetController = ManagedBudgetController(Clones.clone(config.budgetControllerImplementation));
        out.goalAllocatorStrategy = Clones.clone(config.goalAllocatorStrategyImplementation);
        out.stackDeployer = Clones.clone(stackDeployerImplementation);
        SingleAllocatorStrategy(out.goalAllocatorStrategy).initialize(goalTreasury, address(out.budgetController));
        IBudgetStackRuntimeDeployer(out.stackDeployer).initializeWithConfig(
            address(out.budgetController),
            BudgetStackPresetConfigLib.managedPreset(
                config.budgetChildStrategyFactoryImplementation,
                address(out.budgetController)
            )
        );
    }
}
