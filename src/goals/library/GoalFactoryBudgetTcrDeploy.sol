// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";

library GoalFactoryBudgetTcrDeploy {
    struct BudgetTcrDeployRequest {
        BudgetTCRFactory budgetTcrFactory;
        address allocationMechanismAdmin;
        address invalidRoundRewardsSink;
        address submissionDepositStrategy;
        IGeneralizedTCRConfig.RegistryPolicy registryPolicy;
        address defaultAllocationMechanismAdmin;
        address defaultInvalidRoundRewardsSink;
        address defaultSubmissionDepositStrategy;
        address budgetGatePolicy;
        address cobuildToken;
        uint8 cobuildDecimals;
        address budgetSuccessResolver;
        address budgetSpendPolicy;
        IBudgetTCR.BudgetValidationBounds budgetBounds;
        IBudgetTCR.OracleValidationBounds oracleBounds;
        IArbitrator.ArbitratorParams arbitratorParams;
        CustomFlow goalFlow;
        GoalTreasury goalTreasury;
        address goalToken;
        IJBRulesets goalRulesets;
        uint256 goalRevnetId;
        address premiumEscrowImplementation;
        address underwriterSlasherRouter;
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
    }

    function resolveRegistryConfig(
        BudgetTcrDeployRequest memory request
    ) public pure returns (BudgetTCRFactory.RegistryConfigInput memory out) {
        out = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: request.allocationMechanismAdmin == address(0)
                ? request.defaultAllocationMechanismAdmin
                : request.allocationMechanismAdmin,
            invalidRoundRewardsSink: request.invalidRoundRewardsSink == address(0)
                ? request.defaultInvalidRoundRewardsSink
                : request.invalidRoundRewardsSink,
            votingToken: IVotes(request.cobuildToken),
            submissionDepositStrategy: ISubmissionDepositStrategy(
                request.submissionDepositStrategy == address(0)
                    ? request.defaultSubmissionDepositStrategy
                    : request.submissionDepositStrategy
            ),
            registryPolicy: request.registryPolicy
        });
    }

    function deployBudgetTcrStack(
        BudgetTcrDeployRequest memory request
    ) external returns (BudgetTCRFactory.DeployedBudgetTCRStack memory) {
        IBudgetTCR.DeploymentConfig memory tcrDeployCfg = IBudgetTCR.DeploymentConfig({
            stackDeployer: address(0),
            budgetSuccessResolver: request.budgetSuccessResolver,
            budgetSpendPolicy: request.budgetSpendPolicy,
            budgetGatePolicy: request.budgetGatePolicy,
            goalFlow: request.goalFlow,
            goalTreasury: request.goalTreasury,
            goalToken: IERC20(request.goalToken),
            cobuildToken: IERC20(request.cobuildToken),
            goalRulesets: request.goalRulesets,
            goalRevnetId: request.goalRevnetId,
            paymentTokenDecimals: request.cobuildDecimals,
            premiumEscrowImplementation: request.premiumEscrowImplementation,
            underwriterSlasherRouter: request.underwriterSlasherRouter,
            budgetPremiumPpm: request.budgetPremiumPpm,
            budgetSlashPpm: request.budgetSlashPpm,
            budgetValidationBounds: request.budgetBounds,
            oracleValidationBounds: request.oracleBounds
        });

        return
            request.budgetTcrFactory.deployBudgetTCRStackForGoal(
                resolveRegistryConfig(request),
                tcrDeployCfg,
                request.arbitratorParams
            );
    }
}
