// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { GoalFactory } from "src/goals/GoalFactory.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

contract DeployGoalFromFactory is Script {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factoryAddr = vm.envAddress("GOAL_FACTORY");
        GoalFactory factory = GoalFactory(factoryAddr);

        address goalOwner = vm.envOr("GOAL_OWNER", deployer);
        string memory goalName = vm.envOr("GOAL_NAME", string("Test Goal"));
        string memory goalTicker = vm.envOr("GOAL_TICKER", string("TGOAL"));
        string memory goalUri = vm.envOr("GOAL_URI", string("ipfs://TEST"));

        uint32 duration = uint32(vm.envOr("GOAL_DURATION_SECONDS", uint256(6 hours)));
        uint16 reservedPercent = uint16(vm.envOr("GOAL_RESERVED_PERCENT_BPS", uint256(9900)));
        uint16 cashOutTax = uint16(vm.envOr("GOAL_CASHOUT_TAX_BPS", uint256(0)));
        uint112 issuance = uint112(vm.envOr("GOAL_ISSUANCE", uint256(1e18)));

        uint256 minRaise = vm.envOr("GOAL_MIN_RAISE", uint256(100e18));
        uint32 minRaiseWindow = uint32(vm.envOr("GOAL_MIN_RAISE_WINDOW_SECONDS", uint256(0)));

        address successResolver = vm.envOr("SUCCESS_RESOLVER", BURN);
        uint64 successLiveness = uint64(vm.envOr("SUCCESS_LIVENESS", uint256(1 hours)));
        uint256 successBond = vm.envOr("SUCCESS_BOND", uint256(0));
        bytes32 specHash = keccak256(bytes(vm.envOr("SUCCESS_SPEC", string("FAKE_SPEC"))));
        bytes32 policyHash = keccak256(bytes(vm.envOr("SUCCESS_POLICY", string("FAKE_POLICY"))));

        uint32 settlementPpm = uint32(vm.envOr("SETTLEMENT_ESCROW_PPM", uint256(1_000_000)));
        uint32 treasurySettlementPpm = uint32(vm.envOr("TREASURY_SETTLEMENT_ESCROW_PPM", uint256(1_000_000)));

        string memory flowTitle = vm.envOr("FLOW_TITLE", string("Goal"));
        string memory flowDesc = vm.envOr("FLOW_DESC", string("Goal flow"));
        string memory flowImage = vm.envOr("FLOW_IMAGE", string("ipfs://IMAGE"));

        address budgetSuccessResolver = vm.envOr("BUDGET_SUCCESS_RESOLVER", successResolver);
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
            maxOracleType: uint8(vm.envOr("TCR_MAX_ORACLE_TYPE", uint256(1))),
            liveness: uint64(vm.envOr("TCR_ORACLE_LIVENESS", uint256(1))),
            bondAmount: vm.envOr("TCR_ORACLE_BOND", uint256(0))
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
            timing: GoalFactory.GoalTimingParams({ minRaise: minRaise, minRaiseDurationSeconds: minRaiseWindow }),
            success: GoalFactory.SuccessParams({
                successResolver: successResolver,
                successAssertionLiveness: successLiveness,
                successAssertionBond: successBond,
                successOracleSpecHash: specHash,
                successAssertionPolicyHash: policyHash
            }),
            settlement: GoalFactory.SettlementParams({
                settlementRewardEscrowScaled: settlementPpm,
                treasurySettlementRewardEscrowScaled: treasurySettlementPpm
            }),
            flowMetadata: GoalFactory.FlowMetadataParams({
                title: flowTitle,
                description: flowDesc,
                image: flowImage
            }),
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

        vm.startBroadcast(pk);
        GoalFactory.DeployedGoalStack memory out = factory.deployGoal(params);
        vm.stopBroadcast();

        console2.log("Goal deployed by:", deployer);
        console2.log("goalRevnetId:", out.goalRevnetId);
        console2.log("goalToken:", out.goalToken);
        console2.log("goalSuperToken:", out.goalSuperToken);
        console2.log("goalTreasury:", out.goalTreasury);
        console2.log("goalFlow:", out.goalFlow);
        console2.log("goalStakeVault:", out.goalStakeVault);
        console2.log("budgetStakeLedger:", out.budgetStakeLedger);
        console2.log("rewardEscrow:", out.rewardEscrow);
        console2.log("splitHook:", out.splitHook);
        console2.log("budgetTCR:", out.budgetTCR);
        console2.log("arbitrator:", out.arbitrator);
    }
}
