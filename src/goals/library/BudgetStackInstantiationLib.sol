// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { FlowTypes } from "src/storage/FlowStorage.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { BudgetStackTypes } from "src/interfaces/BudgetStackTypes.sol";
import { IBudgetStackRuntimeDeployer } from "src/interfaces/IBudgetStackRuntimeDeployer.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IPremiumEscrowManagerRewardPool } from "src/interfaces/IPremiumEscrow.sol";

library BudgetStackInstantiationLib {
    struct PreparedBudgetStackContextInput {
        bytes32 itemID;
        FlowTypes.RecipientMetadata metadata;
        ICustomFlow goalFlow;
        IBudgetStackRuntimeDeployer deployer;
        BudgetStackTypes.PreparationResult prepared;
        uint64 fundingDeadline;
        uint64 executionDuration;
        uint256 activationThreshold;
        uint256 runwayCap;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        address spendPolicy;
        uint32 premiumPpm;
    }

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
        IBudgetStackRuntimeDeployer deployer;
        BudgetStackTypes.PreparationResult prepared;
        BudgetLifecycleConfig lifecycleConfig;
        BudgetRuntimeConfig runtimeConfig;
        uint32 premiumPpm;
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

    function buildPreparedBudgetStackContext(
        PreparedBudgetStackContextInput memory input
    ) internal pure returns (PreparedBudgetStackContext memory ctx) {
        ctx = PreparedBudgetStackContext({
            itemID: input.itemID,
            metadata: input.metadata,
            goalFlow: input.goalFlow,
            deployer: input.deployer,
            prepared: input.prepared,
            lifecycleConfig: BudgetLifecycleConfig({
                fundingDeadline: input.fundingDeadline,
                executionDuration: input.executionDuration,
                activationThreshold: input.activationThreshold,
                runwayCap: input.runwayCap,
                successOracleSpecHash: input.successOracleSpecHash,
                successAssertionPolicyHash: input.successAssertionPolicyHash
            }),
            runtimeConfig: BudgetRuntimeConfig({
                successResolver: input.successResolver,
                successAssertionLiveness: input.successAssertionLiveness,
                successAssertionBond: input.successAssertionBond,
                spendPolicy: input.spendPolicy
            }),
            premiumPpm: input.premiumPpm
        });
    }

    function instantiatePreparedBudgetStackWithoutRiskModule(
        PreparedBudgetStackContext memory ctx
    ) internal returns (InstantiatedBudgetStack memory deployed) {
        if (ctx.prepared.premiumEscrow != address(0)) {
            revert PREMIUM_ESCROW_REQUIRES_ZERO_RATES();
        }
        BudgetStackTypes.RiskModuleInitConfig memory riskModuleInitConfig;
        deployed = _instantiatePreparedBudgetStack(ctx, riskModuleInitConfig);
    }

    function instantiatePreparedBudgetStackWithRiskModule(
        PreparedBudgetStackContext memory ctx,
        BudgetStackTypes.RiskModuleInitConfig memory riskModuleInitConfig
    ) internal returns (InstantiatedBudgetStack memory deployed) {
        if (ctx.prepared.premiumEscrow == address(0)) revert PREMIUM_ESCROW_NOT_PREPARED();
        deployed = _instantiatePreparedBudgetStack(ctx, riskModuleInitConfig);
    }

    function _instantiatePreparedBudgetStack(
        PreparedBudgetStackContext memory ctx,
        BudgetStackTypes.RiskModuleInitConfig memory riskModuleInitConfig
    ) private returns (InstantiatedBudgetStack memory deployed) {
        address childFlow = _deployChildFlow(ctx);
        address budgetTreasury = _deployBudgetTreasury(ctx, childFlow, riskModuleInitConfig);
        _connectManagerRewardPoolIfConfigured(childFlow, ctx.prepared.premiumEscrow);
        deployed = _finalizePreparedBudgetStack(ctx.prepared, childFlow, budgetTreasury);
    }

    function _deployChildFlow(PreparedBudgetStackContext memory ctx) private returns (address childFlow) {
        BudgetStackTypes.PreparationResult memory prepared = ctx.prepared;
        address premiumEscrow = prepared.premiumEscrow;
        bool hasPremiumEscrow = premiumEscrow != address(0);
        (, childFlow) = ctx.goalFlow.addFlowRecipient(
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
    }

    function _deployBudgetTreasury(
        PreparedBudgetStackContext memory ctx,
        address childFlow,
        BudgetStackTypes.RiskModuleInitConfig memory riskModuleInitConfig
    ) private returns (address budgetTreasury) {
        IBudgetTreasury.BudgetConfig memory budgetConfig = _budgetConfig(ctx, childFlow, ctx.prepared.premiumEscrow);
        if (ctx.prepared.premiumEscrow == address(0)) {
            return ctx.deployer.deployBudgetTreasury(ctx.prepared.budgetTreasury, budgetConfig);
        }

        budgetTreasury = ctx.deployer.deployBudgetTreasuryWithRiskModule(
            ctx.prepared.budgetTreasury,
            budgetConfig,
            riskModuleInitConfig
        );
    }

    function _budgetConfig(
        PreparedBudgetStackContext memory ctx,
        address childFlow,
        address premiumEscrow
    ) private pure returns (IBudgetTreasury.BudgetConfig memory budgetConfig) {
        budgetConfig = IBudgetTreasury.BudgetConfig({
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
    }

    function _connectManagerRewardPoolIfConfigured(address childFlow, address premiumEscrow) private {
        if (premiumEscrow == address(0)) return;

        address managerRewardDistributionPool = address(IFlow(childFlow).managerRewardDistributionPool());
        if (managerRewardDistributionPool == address(0)) {
            revert MANAGER_REWARD_DISTRIBUTION_POOL_NOT_CONFIGURED();
        }
        IPremiumEscrowManagerRewardPool(premiumEscrow).connectManagerRewardPool(managerRewardDistributionPool);
    }

    function _finalizePreparedBudgetStack(
        BudgetStackTypes.PreparationResult memory prepared,
        address childFlow,
        address budgetTreasury
    ) private pure returns (InstantiatedBudgetStack memory deployed) {
        if (budgetTreasury != prepared.budgetTreasury) revert BUDGET_TREASURY_MISMATCH();

        deployed = InstantiatedBudgetStack({
            childFlow: childFlow,
            budgetTreasury: budgetTreasury,
            premiumEscrow: prepared.premiumEscrow,
            strategy: prepared.strategy,
            allocationMechanism: prepared.allocationMechanism
        });
    }
}
