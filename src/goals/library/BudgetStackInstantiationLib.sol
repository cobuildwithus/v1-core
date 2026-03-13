// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { FlowTypes } from "src/storage/FlowStorage.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IPremiumEscrowManagerRewardPool } from "src/interfaces/IPremiumEscrow.sol";

library BudgetStackInstantiationLib {
    struct BudgetLifecycleConfig {
        uint64 fundingDeadline;
        uint64 executionDuration;
        uint256 activationThreshold;
        uint256 runwayCap;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
    }

    struct BudgetRuntimeConfig {
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        address spendPolicy;
    }

    struct PreparedBudgetStackContext {
        bytes32 itemID;
        FlowTypes.RecipientMetadata metadata;
        ICustomFlow goalFlow;
        IBudgetStackDeployer deployer;
        IBudgetStackDeployer.PreparationResult prepared;
        BudgetLifecycleConfig lifecycleConfig;
        BudgetRuntimeConfig runtimeConfig;
        uint32 premiumPpm;
        bool useRiskModule;
        IBudgetStackDeployer.RiskModuleInitConfig riskModuleInitConfig;
    }

    struct InstantiatedBudgetStack {
        address childFlow;
        address budgetTreasury;
        address premiumEscrow;
        address strategy;
        address allocationMechanism;
    }

    error BUDGET_TREASURY_MISMATCH();
    error PREMIUM_ESCROW_NOT_PREPARED();
    error PREMIUM_ESCROW_REQUIRES_ZERO_RATES();
    error MANAGER_REWARD_DISTRIBUTION_POOL_NOT_CONFIGURED();

    function instantiatePreparedBudgetStack(
        PreparedBudgetStackContext memory ctx
    ) internal returns (InstantiatedBudgetStack memory deployed) {
        IBudgetStackDeployer.PreparationResult memory prepared = ctx.prepared;
        address premiumEscrow = prepared.premiumEscrow;
        if (ctx.useRiskModule) {
            if (premiumEscrow == address(0)) revert PREMIUM_ESCROW_NOT_PREPARED();
        } else if (premiumEscrow != address(0)) {
            revert PREMIUM_ESCROW_REQUIRES_ZERO_RATES();
        }

        bool hasPremiumEscrow = premiumEscrow != address(0);
        (, address childFlow) = ctx.goalFlow.addFlowRecipient(
            ctx.itemID,
            ctx.metadata,
            prepared.childFlowRecipientAdmin,
            prepared.budgetTreasury,
            prepared.budgetTreasury,
            premiumEscrow,
            hasPremiumEscrow ? ctx.premiumPpm : 0,
            IAllocationStrategy(prepared.strategy)
        );

        ctx.deployer.registerChildFlowRecipient(ctx.itemID, childFlow);

        IBudgetTreasury.BudgetConfig memory budgetConfig = IBudgetTreasury.BudgetConfig({
            flow: childFlow,
            premiumEscrow: premiumEscrow,
            fundingDeadline: ctx.lifecycleConfig.fundingDeadline,
            executionDuration: ctx.lifecycleConfig.executionDuration,
            activationThreshold: ctx.lifecycleConfig.activationThreshold,
            runwayCap: ctx.lifecycleConfig.runwayCap,
            successResolver: ctx.runtimeConfig.successResolver,
            successAssertionLiveness: ctx.runtimeConfig.successAssertionLiveness,
            successAssertionBond: ctx.runtimeConfig.successAssertionBond,
            successOracleSpecHash: ctx.lifecycleConfig.successOracleSpecHash,
            successAssertionPolicyHash: ctx.lifecycleConfig.successAssertionPolicyHash,
            spendPolicy: ctx.runtimeConfig.spendPolicy
        });

        address budgetTreasury = ctx.useRiskModule
            ? ctx.deployer.deployBudgetTreasuryWithRiskModule(
                prepared.budgetTreasury,
                budgetConfig,
                ctx.riskModuleInitConfig
            )
            : ctx.deployer.deployBudgetTreasury(prepared.budgetTreasury, budgetConfig);

        if (hasPremiumEscrow) {
            address managerRewardDistributionPool = address(IFlow(childFlow).managerRewardDistributionPool());
            if (managerRewardDistributionPool == address(0)) {
                revert MANAGER_REWARD_DISTRIBUTION_POOL_NOT_CONFIGURED();
            }
            IPremiumEscrowManagerRewardPool(premiumEscrow).connectManagerRewardPool(managerRewardDistributionPool);
        }

        if (budgetTreasury != prepared.budgetTreasury) revert BUDGET_TREASURY_MISMATCH();

        deployed = InstantiatedBudgetStack({
            childFlow: childFlow,
            budgetTreasury: budgetTreasury,
            premiumEscrow: premiumEscrow,
            strategy: prepared.strategy,
            allocationMechanism: prepared.allocationMechanism
        });
    }
}
