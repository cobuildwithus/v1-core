// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GoalFactoryBudgetTcrDeploy} from "src/goals/library/GoalFactoryBudgetTcrDeploy.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {BudgetTCRConfigHelpers} from "test/helpers/BudgetTCRConfigHelpers.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

contract GoalFactoryBudgetTcrDeployTest is Test {
    function test_resolveRegistryConfig_usesDefaults_whenOptionalAddressesAreZero() public pure {
        GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest memory request = _baseRequest(
            IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: hex"beef",
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 11e18,
                removalBaseDeposit: 22e18,
                submissionChallengeBaseDeposit: 33e18,
                removalChallengeBaseDeposit: 44e18,
                challengePeriodDuration: 3 days
            })
        );

        request.defaultAllocationMechanismAdmin = address(0xA11CE);
        request.defaultInvalidRoundRewardsSink = address(0xBEEF);
        request.defaultSubmissionDepositStrategy = address(0xCAFE);
        request.cobuildToken = address(0xD00D);

        BudgetTCRFactory.RegistryConfigInput memory resolved = GoalFactoryBudgetTcrDeploy.resolveRegistryConfig(request);

        assertEq(resolved.allocationMechanismAdmin, request.defaultAllocationMechanismAdmin);
        assertEq(resolved.invalidRoundRewardsSink, request.defaultInvalidRoundRewardsSink);
        assertEq(address(resolved.submissionDepositStrategy), request.defaultSubmissionDepositStrategy);
        assertEq(address(resolved.votingToken), request.cobuildToken);
        assertEq(resolved.registryPolicy.submissionBaseDeposit, request.registryPolicy.submissionBaseDeposit);
        assertEq(resolved.registryPolicy.removalBaseDeposit, request.registryPolicy.removalBaseDeposit);
        assertEq(
            resolved.registryPolicy.submissionChallengeBaseDeposit,
            request.registryPolicy.submissionChallengeBaseDeposit
        );
        assertEq(
            resolved.registryPolicy.removalChallengeBaseDeposit, request.registryPolicy.removalChallengeBaseDeposit
        );
        assertEq(resolved.registryPolicy.challengePeriodDuration, request.registryPolicy.challengePeriodDuration);
        assertEq(resolved.registryPolicy.registrationMetaEvidence, request.registryPolicy.registrationMetaEvidence);
        assertEq(resolved.registryPolicy.clearingMetaEvidence, request.registryPolicy.clearingMetaEvidence);
        assertEq(
            keccak256(resolved.registryPolicy.arbitratorExtraData),
            keccak256(request.registryPolicy.arbitratorExtraData)
        );
    }

    function test_resolveRegistryConfig_preservesExplicitAddresses_whenProvided() public pure {
        GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest memory request = _baseRequest(
            IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: hex"1234",
                registrationMetaEvidence: "reg-explicit",
                clearingMetaEvidence: "clear-explicit",
                submissionBaseDeposit: 1,
                removalBaseDeposit: 2,
                submissionChallengeBaseDeposit: 3,
                removalChallengeBaseDeposit: 4,
                challengePeriodDuration: 5
            })
        );

        request.allocationMechanismAdmin = address(0x1111);
        request.invalidRoundRewardsSink = address(0x2222);
        request.submissionDepositStrategy = address(0x3333);
        request.defaultAllocationMechanismAdmin = address(0xAAAA);
        request.defaultInvalidRoundRewardsSink = address(0xBBBB);
        request.defaultSubmissionDepositStrategy = address(0xCCCC);
        request.cobuildToken = address(0xDDDD);

        BudgetTCRFactory.RegistryConfigInput memory resolved = GoalFactoryBudgetTcrDeploy.resolveRegistryConfig(request);

        assertEq(resolved.allocationMechanismAdmin, request.allocationMechanismAdmin);
        assertEq(resolved.invalidRoundRewardsSink, request.invalidRoundRewardsSink);
        assertEq(address(resolved.submissionDepositStrategy), request.submissionDepositStrategy);
    }

    function test_resolveRequestedDeploymentConfig_usesNoGate_whenBudgetSlashIsZero() public pure {
        GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest memory request = _baseRequest(
            IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 0,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 0
            })
        );
        request.riskModuleRouting =
            BudgetTCRConfigHelpers.openRiskModuleRouting(address(0xBEEF), address(0xCAFE), address(0xF00D));
        request.budgetPremiumPpm = 100_000;
        request.budgetSlashPpm = 0;

        BudgetTCRFactory.RequestedBudgetTCRDeploymentConfig memory resolved =
            GoalFactoryBudgetTcrDeploy.resolveRequestedDeploymentConfig(request);

        assertEq(resolved.riskModuleRouting.budgetGatePolicy, request.riskModuleRouting.budgetGatePolicy);
        assertEq(
            resolved.riskModuleRouting.premiumEscrowImplementation,
            request.riskModuleRouting.premiumEscrowImplementation
        );
        assertEq(
            resolved.riskModuleRouting.underwriterSlasherRouter,
            request.riskModuleRouting.underwriterSlasherRouter
        );
    }

    function test_resolveRequestedDeploymentConfig_passesThroughNoPremiumRouting_whenBothRatesAreZero() public pure {
        GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest memory request = _baseRequest(
            IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 0,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 0
            })
        );
        request.riskModuleRouting = BudgetTCRConfigHelpers.noPremiumRiskModuleRouting(address(0));

        BudgetTCRFactory.RequestedBudgetTCRDeploymentConfig memory resolved =
            GoalFactoryBudgetTcrDeploy.resolveRequestedDeploymentConfig(request);

        assertEq(resolved.riskModuleRouting.budgetGatePolicy, address(0));
        assertEq(resolved.riskModuleRouting.premiumEscrowImplementation, address(0));
        assertEq(resolved.riskModuleRouting.underwriterSlasherRouter, address(0));
    }

    function _baseRequest(IGeneralizedTCRConfig.RegistryPolicy memory registryPolicy)
        private
        pure
        returns (GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest memory request)
    {
        request = GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest({
            budgetTcrFactory: BudgetTCRFactory(address(0)),
            allocationMechanismAdmin: address(0),
            invalidRoundRewardsSink: address(0),
            submissionDepositStrategy: address(0),
            registryPolicy: registryPolicy,
            defaultAllocationMechanismAdmin: address(0),
            defaultInvalidRoundRewardsSink: address(0),
            defaultSubmissionDepositStrategy: address(0),
            riskModuleRouting: BudgetTCRConfigHelpers.noPremiumRiskModuleRouting(address(0)),
            cobuildToken: address(0),
            budgetSuccessResolver: address(0),
            budgetSpendPolicy: address(0),
            budgetBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 0,
                maxFundingHorizon: 0,
                minExecutionDuration: 0,
                maxExecutionDuration: 0,
                minActivationThreshold: 0,
                maxActivationThreshold: 0,
                maxRunwayCap: 0
            }),
            oracleBounds: IBudgetTCR.OracleValidationBounds({liveness: 0, bondAmount: 0}),
            arbitratorParams: IArbitrator.ArbitratorParams({
                votingPeriod: 0,
                votingDelay: 0,
                revealPeriod: 0,
                arbitrationCost: 0,
                wrongOrMissedSlashBps: 0,
                slashCallerBountyBps: 0
            }),
            goalFlow: CustomFlow(address(0)),
            goalTreasury: GoalTreasury(address(0)),
            goalToken: address(0),
            goalRulesets: IJBRulesets(address(0)),
            goalRevnetId: 0,
            budgetPremiumPpm: 0,
            budgetSlashPpm: 0
        });
    }
}
