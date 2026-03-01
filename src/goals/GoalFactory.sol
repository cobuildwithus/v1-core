// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";
import { UnderwriterSlasherRouter } from "src/goals/UnderwriterSlasherRouter.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";

import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { GoalFactoryBudgetTcrDeploy } from "src/goals/library/GoalFactoryBudgetTcrDeploy.sol";
import { GoalFactoryCoreStackDeploy } from "src/goals/library/GoalFactoryCoreStackDeploy.sol";
import { GoalFactoryRevnetDeploy } from "src/goals/library/GoalFactoryRevnetDeploy.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

contract GoalFactory {
    IREVDeployer public immutable REV_DEPLOYER;
    BudgetTCRFactory public immutable BUDGET_TCR_FACTORY;
    ISuperfluid public immutable SUPERFLUID_HOST;

    address public immutable COBUILD_TOKEN;
    uint8 public immutable COBUILD_DECIMALS;
    uint256 public immutable COBUILD_REVNET_ID;

    address public immutable GOAL_TREASURY_IMPL;
    address public immutable FLOW_IMPL;
    address public immutable SPLIT_HOOK_IMPL;

    address public immutable DEFAULT_SUBMISSION_DEPOSIT_STRATEGY;
    address public immutable DEFAULT_BUDGET_TCR_GOVERNOR;
    address public immutable DEFAULT_INVALID_ROUND_REWARDS_SINK;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint32 internal constant SCALE_1E6 = 1_000_000;
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    struct RevnetParams {
        address owner;
        string name;
        string ticker;
        string uri;
        uint112 initialIssuance;
        uint16 cashOutTaxRate;
        uint16 reservedPercent;
        uint32 durationSeconds;
    }

    struct GoalTimingParams {
        uint256 minRaise;
        uint32 minRaiseDurationSeconds;
    }

    struct SuccessParams {
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
    }

    struct FlowMetadataParams {
        string title;
        string description;
        string image;
        string tagline;
        string url;
    }

    struct UnderwritingParams {
        uint256 coverageLambda;
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
    }

    struct BudgetTCRParams {
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
        IBudgetTCR.BudgetValidationBounds budgetBounds;
        IBudgetTCR.OracleValidationBounds oracleBounds;
        address budgetSuccessResolver;
        IArbitrator.ArbitratorParams arbitratorParams;
    }

    struct DeployParams {
        RevnetParams revnet;
        GoalTimingParams timing;
        SuccessParams success;
        FlowMetadataParams flowMetadata;
        UnderwritingParams underwriting;
        BudgetTCRParams budgetTCR;
    }

    struct DeployedGoalStack {
        uint256 goalRevnetId;
        address goalToken;
        address goalSuperToken;
        address goalTreasury;
        address goalFlow;
        address goalStakeVault;
        address budgetStakeLedger;
        address splitHook;
        address budgetTCR;
        address arbitrator;
    }

    event GoalDeployed(address indexed caller, uint256 indexed goalRevnetId, DeployedGoalStack stack);

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error INVALID_DURATION();
    error INVALID_RESERVED_PERCENT();
    error INVALID_TAX_RATE();
    error INVALID_ASSERTION_CONFIG();
    error INVALID_SCALE();
    error INVALID_MIN_RAISE_WINDOW(uint32 minRaiseDurationSeconds, uint32 goalDurationSeconds);
    error BUDGET_TCR_ADDRESS_MISMATCH(address predicted, address deployed);

    constructor(
        IREVDeployer revDeployer,
        ISuperfluid superfluidHost,
        BudgetTCRFactory budgetTcrFactory,
        address cobuildToken,
        uint256 cobuildRevnetId,
        address goalTreasuryImpl,
        address flowImpl,
        address splitHookImpl,
        address defaultSubmissionDepositStrategy,
        address defaultBudgetTcrGovernor,
        address defaultInvalidRoundRewardsSink
    ) {
        if (address(revDeployer) == address(0)) revert ADDRESS_ZERO();
        if (address(superfluidHost) == address(0)) revert ADDRESS_ZERO();
        if (address(budgetTcrFactory) == address(0)) revert ADDRESS_ZERO();
        if (cobuildToken == address(0)) revert ADDRESS_ZERO();
        if (goalTreasuryImpl == address(0)) revert ADDRESS_ZERO();
        if (flowImpl == address(0)) revert ADDRESS_ZERO();
        if (splitHookImpl == address(0)) revert ADDRESS_ZERO();
        if (defaultSubmissionDepositStrategy == address(0)) revert ADDRESS_ZERO();
        if (defaultBudgetTcrGovernor == address(0)) revert ADDRESS_ZERO();
        if (defaultInvalidRoundRewardsSink == address(0)) revert ADDRESS_ZERO();
        if (goalTreasuryImpl.code.length == 0) revert NOT_A_CONTRACT(goalTreasuryImpl);
        if (flowImpl.code.length == 0) revert NOT_A_CONTRACT(flowImpl);
        if (splitHookImpl.code.length == 0) revert NOT_A_CONTRACT(splitHookImpl);
        if (defaultSubmissionDepositStrategy.code.length == 0) {
            revert NOT_A_CONTRACT(defaultSubmissionDepositStrategy);
        }

        REV_DEPLOYER = revDeployer;
        SUPERFLUID_HOST = superfluidHost;
        BUDGET_TCR_FACTORY = budgetTcrFactory;

        COBUILD_TOKEN = cobuildToken;
        COBUILD_DECIMALS = IERC20Metadata(cobuildToken).decimals();
        COBUILD_REVNET_ID = cobuildRevnetId;

        GOAL_TREASURY_IMPL = goalTreasuryImpl;
        FLOW_IMPL = flowImpl;
        SPLIT_HOOK_IMPL = splitHookImpl;

        DEFAULT_SUBMISSION_DEPOSIT_STRATEGY = defaultSubmissionDepositStrategy;
        DEFAULT_BUDGET_TCR_GOVERNOR = defaultBudgetTcrGovernor;
        DEFAULT_INVALID_ROUND_REWARDS_SINK = defaultInvalidRoundRewardsSink;
    }

    function deployGoal(DeployParams calldata p) external returns (DeployedGoalStack memory out) {
        if (p.revnet.owner == address(0)) revert ADDRESS_ZERO();
        if (p.revnet.durationSeconds == 0) revert INVALID_DURATION();
        if (p.revnet.reservedPercent > BPS_DENOMINATOR) revert INVALID_RESERVED_PERCENT();
        if (p.revnet.cashOutTaxRate > BPS_DENOMINATOR) revert INVALID_TAX_RATE();

        if (p.success.successResolver == address(0)) revert ADDRESS_ZERO();
        if (
            p.success.successAssertionLiveness == 0 ||
            p.success.successOracleSpecHash == bytes32(0) ||
            p.success.successAssertionPolicyHash == bytes32(0)
        ) {
            revert INVALID_ASSERTION_CONFIG();
        }

        if (p.underwriting.budgetPremiumPpm > SCALE_1E6 || p.underwriting.budgetSlashPpm > SCALE_1E6) {
            revert INVALID_SCALE();
        }

        GoalTreasury goalTreasury = GoalTreasury(Clones.clone(GOAL_TREASURY_IMPL));
        GoalRevnetSplitHook splitHook = GoalRevnetSplitHook(payable(Clones.clone(SPLIT_HOOK_IMPL)));
        CustomFlow goalFlow = CustomFlow(payable(Clones.clone(FLOW_IMPL)));

        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet = _deployRevnet(p, splitHook);

        address predictedBudgetTCR = BUDGET_TCR_FACTORY.predictBudgetTCRAddress(
            address(this),
            address(goalFlow),
            address(goalTreasury),
            revnet.goalRevnetId,
            COBUILD_TOKEN
        );

        uint32 minRaiseWindow = _resolveMinRaiseWindow(p.revnet.durationSeconds, p.timing.minRaiseDurationSeconds);
        uint64 minRaiseDeadline = uint64(block.timestamp + minRaiseWindow);

        GoalFactoryCoreStackDeploy.CoreStackResult memory core = _initializeCoreStack(
            p,
            goalTreasury,
            splitHook,
            goalFlow,
            revnet,
            predictedBudgetTCR,
            minRaiseDeadline
        );

        BudgetTCRFactory.DeployedBudgetTCRStack memory tcrStack = _deployBudgetTcr(p, core, revnet, predictedBudgetTCR);
        if (tcrStack.budgetTCR != predictedBudgetTCR) {
            revert BUDGET_TCR_ADDRESS_MISMATCH(predictedBudgetTCR, tcrStack.budgetTCR);
        }

        out = DeployedGoalStack({
            goalRevnetId: revnet.goalRevnetId,
            goalToken: revnet.goalToken,
            goalSuperToken: address(core.goalSuperToken),
            goalTreasury: address(core.goalTreasury),
            goalFlow: address(core.goalFlow),
            goalStakeVault: address(core.stakeVault),
            budgetStakeLedger: address(core.budgetStakeLedger),
            splitHook: address(core.splitHook),
            budgetTCR: tcrStack.budgetTCR,
            arbitrator: tcrStack.arbitrator
        });

        emit GoalDeployed(msg.sender, revnet.goalRevnetId, out);
    }

    function _deployRevnet(
        DeployParams calldata p,
        GoalRevnetSplitHook splitHook
    ) private returns (GoalFactoryRevnetDeploy.RevnetDeploymentResult memory) {
        return
            GoalFactoryRevnetDeploy.deployRevnet(
                GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
                    revDeployer: REV_DEPLOYER,
                    cobuildToken: COBUILD_TOKEN,
                    cobuildDecimals: COBUILD_DECIMALS,
                    cobuildRevnetId: COBUILD_REVNET_ID,
                    splitHook: address(splitHook),
                    owner: p.revnet.owner,
                    name: p.revnet.name,
                    ticker: p.revnet.ticker,
                    uri: p.revnet.uri,
                    initialIssuance: p.revnet.initialIssuance,
                    cashOutTaxRate: p.revnet.cashOutTaxRate,
                    reservedPercent: p.revnet.reservedPercent,
                    durationSeconds: p.revnet.durationSeconds,
                    burnAddress: BURN_ADDRESS
                })
            );
    }

    function _initializeCoreStack(
        DeployParams calldata p,
        GoalTreasury goalTreasury,
        GoalRevnetSplitHook splitHook,
        CustomFlow goalFlow,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        address predictedBudgetTCR,
        uint64 minRaiseDeadline
    ) private returns (GoalFactoryCoreStackDeploy.CoreStackResult memory) {
        return
            GoalFactoryCoreStackDeploy.initializeCoreStack(
                GoalFactoryCoreStackDeploy.CoreStackRequest({
                    goalTreasury: goalTreasury,
                    splitHook: splitHook,
                    goalFlow: goalFlow,
                    flowImpl: FLOW_IMPL,
                    superfluidHost: SUPERFLUID_HOST,
                    budgetTcrFactory: address(BUDGET_TCR_FACTORY),
                    cobuildToken: COBUILD_TOKEN,
                    cobuildDecimals: COBUILD_DECIMALS,
                    goalRevnetId: revnet.goalRevnetId,
                    goalToken: revnet.goalToken,
                    predictedBudgetTcr: predictedBudgetTCR,
                    rulesets: revnet.rulesets,
                    directory: revnet.directory,
                    revnetName: p.revnet.name,
                    revnetTicker: p.revnet.ticker,
                    flowTitle: p.flowMetadata.title,
                    flowDescription: p.flowMetadata.description,
                    flowImage: p.flowMetadata.image,
                    flowTagline: p.flowMetadata.tagline,
                    flowUrl: p.flowMetadata.url,
                    minRaiseDeadline: minRaiseDeadline,
                    minRaise: p.timing.minRaise,
                    coverageLambda: p.underwriting.coverageLambda,
                    budgetPremiumPpm: p.underwriting.budgetPremiumPpm,
                    budgetSlashPpm: p.underwriting.budgetSlashPpm,
                    successResolver: p.success.successResolver,
                    successAssertionLiveness: p.success.successAssertionLiveness,
                    successAssertionBond: p.success.successAssertionBond,
                    successOracleSpecHash: p.success.successOracleSpecHash,
                    successAssertionPolicyHash: p.success.successAssertionPolicyHash
                })
            );
    }

    function _deployBudgetTcr(
        DeployParams calldata p,
        GoalFactoryCoreStackDeploy.CoreStackResult memory core,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        address predictedBudgetTCR
    ) private returns (BudgetTCRFactory.DeployedBudgetTCRStack memory) {
        address premiumEscrowImplementation = address(new PremiumEscrow());
        address underwriterSlasherRouter = address(
            new UnderwriterSlasherRouter(
                IStakeVault(address(core.stakeVault)),
                predictedBudgetTCR,
                revnet.directory,
                revnet.goalRevnetId,
                IERC20Metadata(revnet.goalToken),
                IERC20Metadata(COBUILD_TOKEN),
                core.goalSuperToken,
                address(core.goalFlow)
            )
        );

        return
            GoalFactoryBudgetTcrDeploy.deployBudgetTcrStack(
                GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest({
                    budgetTcrFactory: BUDGET_TCR_FACTORY,
                    registryConfig: GoalFactoryBudgetTcrDeploy.RegistryConfigArgs({
                        governor: p.budgetTCR.governor,
                        invalidRoundRewardsSink: p.budgetTCR.invalidRoundRewardsSink,
                        submissionDepositStrategy: p.budgetTCR.submissionDepositStrategy,
                        submissionBaseDeposit: p.budgetTCR.submissionBaseDeposit,
                        removalBaseDeposit: p.budgetTCR.removalBaseDeposit,
                        submissionChallengeBaseDeposit: p.budgetTCR.submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit: p.budgetTCR.removalChallengeBaseDeposit,
                        registrationMetaEvidence: p.budgetTCR.registrationMetaEvidence,
                        clearingMetaEvidence: p.budgetTCR.clearingMetaEvidence,
                        challengePeriodDuration: p.budgetTCR.challengePeriodDuration,
                        arbitratorExtraData: p.budgetTCR.arbitratorExtraData
                    }),
                    defaultGovernor: DEFAULT_BUDGET_TCR_GOVERNOR,
                    defaultInvalidRoundRewardsSink: DEFAULT_INVALID_ROUND_REWARDS_SINK,
                    defaultSubmissionDepositStrategy: DEFAULT_SUBMISSION_DEPOSIT_STRATEGY,
                    cobuildToken: COBUILD_TOKEN,
                    cobuildDecimals: COBUILD_DECIMALS,
                    budgetSuccessResolver: p.budgetTCR.budgetSuccessResolver,
                    budgetBounds: p.budgetTCR.budgetBounds,
                    oracleBounds: p.budgetTCR.oracleBounds,
                    arbitratorParams: p.budgetTCR.arbitratorParams,
                    goalFlow: core.goalFlow,
                    goalTreasury: core.goalTreasury,
                    goalToken: revnet.goalToken,
                    goalRulesets: revnet.rulesets,
                    goalRevnetId: revnet.goalRevnetId,
                    premiumEscrowImplementation: premiumEscrowImplementation,
                    underwriterSlasherRouter: underwriterSlasherRouter,
                    budgetPremiumPpm: p.underwriting.budgetPremiumPpm,
                    budgetSlashPpm: p.underwriting.budgetSlashPpm
                })
            );
    }

    function _resolveRegistryConfig(
        BudgetTCRParams calldata p
    ) internal view returns (BudgetTCRFactory.RegistryConfigInput memory) {
        return
            GoalFactoryBudgetTcrDeploy.resolveRegistryConfig(
                GoalFactoryBudgetTcrDeploy.RegistryConfigArgs({
                    governor: p.governor,
                    invalidRoundRewardsSink: p.invalidRoundRewardsSink,
                    submissionDepositStrategy: p.submissionDepositStrategy,
                    submissionBaseDeposit: p.submissionBaseDeposit,
                    removalBaseDeposit: p.removalBaseDeposit,
                    submissionChallengeBaseDeposit: p.submissionChallengeBaseDeposit,
                    removalChallengeBaseDeposit: p.removalChallengeBaseDeposit,
                    registrationMetaEvidence: p.registrationMetaEvidence,
                    clearingMetaEvidence: p.clearingMetaEvidence,
                    challengePeriodDuration: p.challengePeriodDuration,
                    arbitratorExtraData: p.arbitratorExtraData
                }),
                DEFAULT_BUDGET_TCR_GOVERNOR,
                DEFAULT_INVALID_ROUND_REWARDS_SINK,
                DEFAULT_SUBMISSION_DEPOSIT_STRATEGY,
                COBUILD_TOKEN
            );
    }

    function _resolveMinRaiseWindow(
        uint32 durationSeconds,
        uint32 minRaiseDurationSeconds
    ) internal pure returns (uint32) {
        uint32 resolved = minRaiseDurationSeconds;
        if (resolved == 0) {
            resolved = durationSeconds / 2;
            if (resolved == 0) resolved = durationSeconds;
        }
        if (resolved == 0 || resolved > durationSeconds) {
            revert INVALID_MIN_RAISE_WINDOW(resolved, durationSeconds);
        }
        return resolved;
    }
}
