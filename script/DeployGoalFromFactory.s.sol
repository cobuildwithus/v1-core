// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";

contract DeployGoalFromFactory is DeployScript {
    address internal goalFactoryAddressOut;
    address internal goalOwnerOut;
    address internal successResolverOut;
    address internal budgetSuccessResolverOut;

    uint256 internal goalRevnetIdOut;
    address internal goalTokenOut;
    address internal goalSuperTokenOut;
    address internal goalTreasuryOut;
    address internal goalFlowOut;
    address internal goalStakeVaultOut;
    address internal budgetStakeLedgerOut;
    address internal rewardEscrowOut;
    address internal splitHookOut;
    address internal budgetTcrOut;
    address internal arbitratorOut;

    function deploy() internal override {
        GoalFactory factory = GoalFactory(vm.envAddress("GOAL_FACTORY"));
        goalFactoryAddressOut = address(factory);

        address goalOwner = vm.envOr("GOAL_OWNER", deployerAddress);
        string memory goalName = vm.envOr("GOAL_NAME", string("Test Goal"));
        string memory goalTicker = vm.envOr("GOAL_TICKER", string("TGOAL"));
        string memory goalUri = vm.envOr("GOAL_URI", string("ipfs://TEST"));

        uint32 duration = uint32(vm.envOr("GOAL_DURATION_SECONDS", uint256(6 hours)));
        uint16 reservedPercent = uint16(vm.envOr("GOAL_RESERVED_PERCENT_BPS", uint256(9900)));
        uint16 cashOutTax = uint16(vm.envOr("GOAL_CASHOUT_TAX_BPS", uint256(0)));
        uint112 issuance = uint112(vm.envOr("GOAL_ISSUANCE", uint256(1e18)));

        uint256 minRaise = vm.envOr("GOAL_MIN_RAISE", uint256(100e18));
        uint32 minRaiseWindow = uint32(vm.envOr("GOAL_MIN_RAISE_WINDOW_SECONDS", uint256(0)));

        address defaultSuccessResolver = vm.envOr("FAKE_SUCCESS_RESOLVER", BURN);
        address successResolver = vm.envOr("SUCCESS_RESOLVER", defaultSuccessResolver);
        uint64 successLiveness = uint64(vm.envOr("SUCCESS_LIVENESS", uint256(1 hours)));
        uint256 successBond = vm.envOr("SUCCESS_BOND", uint256(0));
        bytes32 specHash = keccak256(bytes(vm.envOr("SUCCESS_SPEC", string("FAKE_SPEC"))));
        bytes32 policyHash = keccak256(bytes(vm.envOr("SUCCESS_POLICY", string("FAKE_POLICY"))));

        uint32 successSettlementRewardEscrowPpm =
            uint32(vm.envOr("SUCCESS_SETTLEMENT_REWARD_ESCROW_PPM", uint256(1_000_000)));

        string memory flowTitle = vm.envOr("FLOW_TITLE", string("Goal"));
        string memory flowDesc = vm.envOr("FLOW_DESC", string("Goal flow"));
        string memory flowImage = vm.envOr("FLOW_IMAGE", string("ipfs://IMAGE"));
        string memory flowTagline = vm.envOr("FLOW_TAGLINE", string(""));
        string memory flowUrl = vm.envOr("FLOW_URL", string(""));
        uint256 managerRewardPoolFlowRatePpmRaw = vm.envOr("FLOW_MANAGER_REWARD_POOL_FLOW_RATE_PPM", uint256(100_000));
        if (managerRewardPoolFlowRatePpmRaw > 1_000_000) {
            revert FLOW_MANAGER_REWARD_POOL_FLOW_RATE_PPM_INVALID(managerRewardPoolFlowRatePpmRaw);
        }
        uint32 managerRewardPoolFlowRatePpm = uint32(managerRewardPoolFlowRatePpmRaw);

        address budgetSuccessResolver = vm.envOr("BUDGET_SUCCESS_RESOLVER", successResolver);
        if (successResolver == BURN) revert SUCCESS_RESOLVER_REQUIRED();
        if (successResolver.code.length == 0) revert SUCCESS_RESOLVER_NOT_CONTRACT(successResolver);
        if (budgetSuccessResolver == BURN) revert BUDGET_SUCCESS_RESOLVER_REQUIRED();
        if (budgetSuccessResolver.code.length == 0) {
            revert BUDGET_SUCCESS_RESOLVER_NOT_CONTRACT(budgetSuccessResolver);
        }

        uint256 challengePeriod = vm.envOr("TCR_CHALLENGE_PERIOD_SECONDS", uint256(2 hours));
        uint256 votingPeriod = vm.envOr("TCR_VOTING_PERIOD_SECONDS", uint256(2 hours));
        uint256 votingDelay = vm.envOr("TCR_VOTING_DELAY_SECONDS", uint256(1));
        uint256 revealPeriod = vm.envOr("TCR_REVEAL_PERIOD_SECONDS", uint256(1));
        uint256 arbitrationCost = vm.envOr("TCR_ARBITRATION_COST", uint256(1e15));
        uint256 wrongOrMissedSlashBps = vm.envOr("TCR_WRONG_OR_MISSED_SLASH_BPS", uint256(50));
        uint256 slashCallerBountyBps = vm.envOr("TCR_SLASH_CALLER_BOUNTY_BPS", uint256(100));

        IBudgetTCR.BudgetValidationBounds memory budgetBounds = IBudgetTCR.BudgetValidationBounds({
            minFundingLeadTime: 0,
            maxFundingHorizon: uint64(duration),
            minExecutionDuration: 0,
            maxExecutionDuration: uint64(duration),
            minActivationThreshold: 0,
            maxActivationThreshold: vm.envOr("TCR_MAX_ACTIVATION_THRESHOLD", uint256(1e18)),
            maxRunwayCap: vm.envOr("TCR_MAX_RUNWAY_CAP", uint256(1e18))
        });

        IBudgetTCR.OracleValidationBounds memory oracleBounds = IBudgetTCR.OracleValidationBounds({
            liveness: uint64(vm.envOr("TCR_ORACLE_LIVENESS", uint256(1))),
            bondAmount: vm.envOr("TCR_ORACLE_BOND", uint256(1))
        });

        IArbitrator.ArbitratorParams memory arbParams = IArbitrator.ArbitratorParams({
            votingPeriod: votingPeriod,
            votingDelay: votingDelay,
            revealPeriod: revealPeriod,
            arbitrationCost: arbitrationCost,
            wrongOrMissedSlashBps: wrongOrMissedSlashBps,
            slashCallerBountyBps: slashCallerBountyBps
        });

        GoalFactory.DeployParams memory params = GoalFactory.DeployParams({
            revnet: GoalFactory.RevnetParams({
                owner: goalOwner,
                name: goalName,
                ticker: goalTicker,
                uri: goalUri,
                initialIssuance: issuance,
                cashOutTaxRate: cashOutTax,
                reservedPercent: reservedPercent,
                durationSeconds: duration
            }),
            timing: GoalFactory.GoalTimingParams({minRaise: minRaise, minRaiseDurationSeconds: minRaiseWindow}),
            success: GoalFactory.SuccessParams({
                successResolver: successResolver,
                successAssertionLiveness: successLiveness,
                successAssertionBond: successBond,
                successOracleSpecHash: specHash,
                successAssertionPolicyHash: policyHash
            }),
            settlement: GoalFactory.SettlementParams({
                successSettlementRewardEscrowPpm: successSettlementRewardEscrowPpm
            }),
            flowMetadata: GoalFactory.FlowMetadataParams({
                title: flowTitle, description: flowDesc, image: flowImage, tagline: flowTagline, url: flowUrl
            }),
            flowConfig: GoalFactory.FlowConfigParams({managerRewardPoolFlowRatePpm: managerRewardPoolFlowRatePpm}),
            budgetTCR: GoalFactory.BudgetTCRParams({
                governor: address(0),
                invalidRoundRewardsSink: BURN,
                submissionDepositStrategy: address(0),
                submissionBaseDeposit: vm.envOr("TCR_SUBMISSION_BASE_DEPOSIT", uint256(0)),
                removalBaseDeposit: vm.envOr("TCR_REMOVAL_BASE_DEPOSIT", uint256(0)),
                submissionChallengeBaseDeposit: vm.envOr("TCR_SUBMISSION_CHALLENGE_DEPOSIT", uint256(0)),
                removalChallengeBaseDeposit: vm.envOr("TCR_REMOVAL_CHALLENGE_DEPOSIT", uint256(0)),
                registrationMetaEvidence: vm.envOr("TCR_REG_META", string("ipfs://REG")),
                clearingMetaEvidence: vm.envOr("TCR_CLEAR_META", string("ipfs://CLEAR")),
                challengePeriodDuration: challengePeriod,
                arbitratorExtraData: bytes(""),
                budgetBounds: budgetBounds,
                oracleBounds: oracleBounds,
                budgetSuccessResolver: budgetSuccessResolver,
                arbitratorParams: arbParams
            }),
            rentRecipient: vm.envOr("GOAL_RENT_RECIPIENT", BURN),
            rentWadPerSecond: vm.envOr("GOAL_RENT_WAD_PER_SECOND", uint256(0))
        });

        GoalFactory.DeployedGoalStack memory out = factory.deployGoal(params);

        goalOwnerOut = goalOwner;
        successResolverOut = successResolver;
        budgetSuccessResolverOut = budgetSuccessResolver;

        goalRevnetIdOut = out.goalRevnetId;
        goalTokenOut = out.goalToken;
        goalSuperTokenOut = out.goalSuperToken;
        goalTreasuryOut = out.goalTreasury;
        goalFlowOut = out.goalFlow;
        goalStakeVaultOut = out.goalStakeVault;
        budgetStakeLedgerOut = out.budgetStakeLedger;
        rewardEscrowOut = out.rewardEscrow;
        splitHookOut = out.splitHook;
        budgetTcrOut = out.budgetTCR;
        arbitratorOut = out.arbitrator;

        console2.log("Goal deployed by:", deployerAddress);
        console2.log("successResolver:", successResolverOut);
        console2.log("budgetSuccessResolver:", budgetSuccessResolverOut);
        console2.log("goalRevnetId:", goalRevnetIdOut);
        console2.log("goalToken:", goalTokenOut);
        console2.log("goalSuperToken:", goalSuperTokenOut);
        console2.log("goalTreasury:", goalTreasuryOut);
        console2.log("goalFlow:", goalFlowOut);
        console2.log("goalStakeVault:", goalStakeVaultOut);
        console2.log("budgetStakeLedger:", budgetStakeLedgerOut);
        console2.log("rewardEscrow:", rewardEscrowOut);
        console2.log("splitHook:", splitHookOut);
        console2.log("budgetTCR:", budgetTcrOut);
        console2.log("arbitrator:", arbitratorOut);
    }

    function deploymentName() internal pure override returns (string memory) {
        return "DeployGoalFromFactory";
    }

    function writeDeploymentDetails(string memory filePath) internal override {
        _writeAddressLine(filePath, "GOAL_FACTORY", goalFactoryAddressOut);
        _writeAddressLine(filePath, "GOAL_OWNER", goalOwnerOut);
        _writeAddressLine(filePath, "SUCCESS_RESOLVER", successResolverOut);
        _writeAddressLine(filePath, "BUDGET_SUCCESS_RESOLVER", budgetSuccessResolverOut);

        _writeUintLine(filePath, "goalRevnetId", goalRevnetIdOut);
        _writeAddressLine(filePath, "goalToken", goalTokenOut);
        _writeAddressLine(filePath, "goalSuperToken", goalSuperTokenOut);
        _writeAddressLine(filePath, "goalTreasury", goalTreasuryOut);
        _writeAddressLine(filePath, "goalFlow", goalFlowOut);
        _writeAddressLine(filePath, "goalStakeVault", goalStakeVaultOut);
        _writeAddressLine(filePath, "budgetStakeLedger", budgetStakeLedgerOut);
        _writeAddressLine(filePath, "rewardEscrow", rewardEscrowOut);
        _writeAddressLine(filePath, "splitHook", splitHookOut);
        _writeAddressLine(filePath, "budgetTCR", budgetTcrOut);
        _writeAddressLine(filePath, "arbitrator", arbitratorOut);
    }

    error SUCCESS_RESOLVER_REQUIRED();
    error SUCCESS_RESOLVER_NOT_CONTRACT(address resolver);
    error BUDGET_SUCCESS_RESOLVER_REQUIRED();
    error BUDGET_SUCCESS_RESOLVER_NOT_CONTRACT(address resolver);
    error FLOW_MANAGER_REWARD_POOL_FLOW_RATE_PPM_INVALID(uint256 value);
}
