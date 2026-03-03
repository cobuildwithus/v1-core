// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalFactoryBudgetTcrDeploy } from "src/goals/library/GoalFactoryBudgetTcrDeploy.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";

contract GoalFactoryBudgetTcrDeployTest is Test {
    function test_resolveRegistryConfig_usesDefaults_whenOptionalAddressesAreZero() public pure {
        GoalFactoryBudgetTcrDeploy.RegistryConfigArgs memory args = GoalFactoryBudgetTcrDeploy.RegistryConfigArgs({
            allocationMechanismAdmin: address(0),
            invalidRoundRewardsSink: address(0),
            submissionDepositStrategy: address(0),
            submissionBaseDeposit: 11e18,
            removalBaseDeposit: 22e18,
            submissionChallengeBaseDeposit: 33e18,
            removalChallengeBaseDeposit: 44e18,
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            challengePeriodDuration: 3 days,
            arbitratorExtraData: hex"beef"
        });

        address defaultAllocationMechanismAdmin = address(0xA11CE);
        address defaultInvalidRoundRewardsSink = address(0xBEEF);
        address defaultSubmissionDepositStrategy = address(0xCAFE);
        address cobuildToken = address(0xD00D);

        BudgetTCRFactory.RegistryConfigInput memory resolved = GoalFactoryBudgetTcrDeploy.resolveRegistryConfig(
            args,
            defaultAllocationMechanismAdmin,
            defaultInvalidRoundRewardsSink,
            defaultSubmissionDepositStrategy,
            cobuildToken
        );

        assertEq(resolved.allocationMechanismAdmin, defaultAllocationMechanismAdmin);
        assertEq(resolved.invalidRoundRewardsSink, defaultInvalidRoundRewardsSink);
        assertEq(address(resolved.submissionDepositStrategy), defaultSubmissionDepositStrategy);
        assertEq(address(resolved.votingToken), cobuildToken);
        assertEq(resolved.submissionBaseDeposit, args.submissionBaseDeposit);
        assertEq(resolved.removalBaseDeposit, args.removalBaseDeposit);
        assertEq(resolved.submissionChallengeBaseDeposit, args.submissionChallengeBaseDeposit);
        assertEq(resolved.removalChallengeBaseDeposit, args.removalChallengeBaseDeposit);
        assertEq(resolved.challengePeriodDuration, args.challengePeriodDuration);
        assertEq(resolved.registrationMetaEvidence, args.registrationMetaEvidence);
        assertEq(resolved.clearingMetaEvidence, args.clearingMetaEvidence);
        assertEq(keccak256(resolved.arbitratorExtraData), keccak256(args.arbitratorExtraData));
    }

    function test_resolveRegistryConfig_preservesExplicitAddresses_whenProvided() public pure {
        GoalFactoryBudgetTcrDeploy.RegistryConfigArgs memory args = GoalFactoryBudgetTcrDeploy.RegistryConfigArgs({
            allocationMechanismAdmin: address(0x1111),
            invalidRoundRewardsSink: address(0x2222),
            submissionDepositStrategy: address(0x3333),
            submissionBaseDeposit: 1,
            removalBaseDeposit: 2,
            submissionChallengeBaseDeposit: 3,
            removalChallengeBaseDeposit: 4,
            registrationMetaEvidence: "reg-explicit",
            clearingMetaEvidence: "clear-explicit",
            challengePeriodDuration: 5,
            arbitratorExtraData: hex"1234"
        });

        BudgetTCRFactory.RegistryConfigInput memory resolved = GoalFactoryBudgetTcrDeploy.resolveRegistryConfig(
            args,
            address(0xAAAA),
            address(0xBBBB),
            address(0xCCCC),
            address(0xDDDD)
        );

        assertEq(resolved.allocationMechanismAdmin, args.allocationMechanismAdmin);
        assertEq(resolved.invalidRoundRewardsSink, args.invalidRoundRewardsSink);
        assertEq(address(resolved.submissionDepositStrategy), args.submissionDepositStrategy);
    }
}
