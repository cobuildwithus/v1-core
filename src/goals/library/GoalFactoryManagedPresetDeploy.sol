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

    struct ManagedControllerInitRequest {
        address authority;
        address goalTreasury;
        address goalFlow;
        address budgetAllocationLedger;
        address stackDeployer;
        address budgetGatePolicy;
        address budgetSuccessResolver;
        address budgetSpendPolicy;
        address underwriterSlasherRouter;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
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
        ManagedControllerInitRequest memory request
    ) external {
        budgetController.initialize(
            IManagedBudgetController.InitConfig({
                authority: request.authority,
                goalTreasury: request.goalTreasury,
                goalFlow: request.goalFlow,
                budgetAllocationLedger: request.budgetAllocationLedger,
                stackDeployer: request.stackDeployer,
                budgetGatePolicy: request.budgetGatePolicy,
                budgetSuccessResolver: request.budgetSuccessResolver,
                budgetSpendPolicy: request.budgetSpendPolicy,
                underwriterSlasherRouter: request.underwriterSlasherRouter,
                successAssertionLiveness: request.successAssertionLiveness,
                successAssertionBond: request.successAssertionBond,
                budgetPremiumPpm: request.budgetPremiumPpm,
                budgetSlashPpm: request.budgetSlashPpm
            })
        );
    }
}
