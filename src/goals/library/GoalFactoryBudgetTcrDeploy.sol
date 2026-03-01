// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";

library GoalFactoryBudgetTcrDeploy {
    struct RegistryConfigArgs {
        address governor;
        address invalidRoundRewardsSink;
        address submissionDepositStrategy;
        uint256 submissionBaseDeposit;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        uint256 challengePeriodDuration;
        bytes arbitratorExtraData;
    }

    struct BudgetTcrDeployRequest {
        BudgetTCRFactory budgetTcrFactory;
        RegistryConfigArgs registryConfig;
        address defaultGovernor;
        address defaultInvalidRoundRewardsSink;
        address defaultSubmissionDepositStrategy;
        address cobuildToken;
        uint8 cobuildDecimals;
        address budgetSuccessResolver;
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
        RegistryConfigArgs memory p,
        address defaultGovernor,
        address defaultInvalidRoundRewardsSink,
        address defaultSubmissionDepositStrategy,
        address cobuildToken
    ) public pure returns (BudgetTCRFactory.RegistryConfigInput memory out) {
        out = BudgetTCRFactory.RegistryConfigInput({
            governor: p.governor == address(0) ? defaultGovernor : p.governor,
            invalidRoundRewardsSink: p.invalidRoundRewardsSink == address(0)
                ? defaultInvalidRoundRewardsSink
                : p.invalidRoundRewardsSink,
            arbitratorExtraData: p.arbitratorExtraData,
            registrationMetaEvidence: p.registrationMetaEvidence,
            clearingMetaEvidence: p.clearingMetaEvidence,
            votingToken: IVotes(cobuildToken),
            submissionBaseDeposit: p.submissionBaseDeposit,
            removalBaseDeposit: p.removalBaseDeposit,
            submissionChallengeBaseDeposit: p.submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: p.removalChallengeBaseDeposit,
            challengePeriodDuration: p.challengePeriodDuration,
            submissionDepositStrategy: ISubmissionDepositStrategy(
                p.submissionDepositStrategy == address(0)
                    ? defaultSubmissionDepositStrategy
                    : p.submissionDepositStrategy
            )
        });
    }

    function deployBudgetTcrStack(
        BudgetTcrDeployRequest memory request
    ) external returns (BudgetTCRFactory.DeployedBudgetTCRStack memory) {
        IBudgetTCR.DeploymentConfig memory tcrDeployCfg = IBudgetTCR.DeploymentConfig({
            stackDeployer: address(0),
            budgetSuccessResolver: request.budgetSuccessResolver,
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
            managerRewardPool: address(0),
            budgetValidationBounds: request.budgetBounds,
            oracleValidationBounds: request.oracleBounds
        });

        return
            request.budgetTcrFactory.deployBudgetTCRStackForGoal(
                resolveRegistryConfig(
                    request.registryConfig,
                    request.defaultGovernor,
                    request.defaultInvalidRoundRewardsSink,
                    request.defaultSubmissionDepositStrategy,
                    request.cobuildToken
                ),
                tcrDeployCfg,
                request.arbitratorParams
            );
    }
}
