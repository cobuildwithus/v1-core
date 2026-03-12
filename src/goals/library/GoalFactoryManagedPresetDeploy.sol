// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { SingleAllocatorStrategy } from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { ManagedBudgetController } from "src/goals/ManagedBudgetController.sol";

library GoalFactoryManagedPresetDeploy {
    struct ManagedPresetBundle {
        ManagedBudgetController budgetController;
        address goalAllocatorStrategy;
        address gatePolicy;
        address stackDeployer;
    }

    struct ManagedPresetBootstrapConfig {
        address budgetControllerImplementation;
        address goalAllocatorStrategyImplementation;
        address gatePolicy;
        address stackDeployer;
    }

    function bootstrapManagedPreset(
        address goalTreasury,
        ManagedPresetBootstrapConfig memory config
    ) external returns (ManagedPresetBundle memory out) {
        out.budgetController = ManagedBudgetController(Clones.clone(config.budgetControllerImplementation));
        out.goalAllocatorStrategy = Clones.clone(config.goalAllocatorStrategyImplementation);
        SingleAllocatorStrategy(out.goalAllocatorStrategy).initialize(goalTreasury, address(out.budgetController));
        out.gatePolicy = config.gatePolicy;
        out.stackDeployer = config.stackDeployer;
    }

    function initializeManagedController(
        ManagedBudgetController budgetController,
        IManagedBudgetController.InitConfig memory initConfig
    ) external {
        budgetController.initialize(initConfig);
    }
}
