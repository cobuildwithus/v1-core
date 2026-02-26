// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { ISuperfluid, ISuperToken, ISuperTokenFactory } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBAccountingContext } from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBTerminalConfig } from "@bananapus/core-v5/structs/JBTerminalConfig.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { GoalStakeVault } from "src/goals/GoalStakeVault.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";

import { GoalStakeVaultStrategy } from "src/allocation-strategies/GoalStakeVaultStrategy.sol";

import { CustomFlow } from "src/flows/CustomFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { GoalFlowAllocationLedgerPipeline } from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";

import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";

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

    struct SettlementParams {
        uint32 settlementRewardEscrowScaled;
        uint32 treasurySettlementRewardEscrowScaled;
    }

    struct FlowMetadataParams {
        string title;
        string description;
        string image;
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
        SettlementParams settlement;
        FlowMetadataParams flowMetadata;
        BudgetTCRParams budgetTCR;
        address rentRecipient;
        uint256 rentWadPerSecond;
    }

    struct DeployedGoalStack {
        uint256 goalRevnetId;
        address goalToken;
        address goalSuperToken;
        address goalTreasury;
        address goalFlow;
        address goalStakeVault;
        address budgetStakeLedger;
        address rewardEscrow;
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
        if (p.success.successAssertionLiveness == 0) revert INVALID_ASSERTION_CONFIG();
        if (p.success.successOracleSpecHash == bytes32(0)) revert INVALID_ASSERTION_CONFIG();
        if (p.success.successAssertionPolicyHash == bytes32(0)) revert INVALID_ASSERTION_CONFIG();

        if (p.settlement.settlementRewardEscrowScaled > SCALE_1E6) revert INVALID_SCALE();
        if (p.settlement.treasurySettlementRewardEscrowScaled > SCALE_1E6) revert INVALID_SCALE();

        GoalTreasury goalTreasury = GoalTreasury(Clones.clone(GOAL_TREASURY_IMPL));
        GoalRevnetSplitHook splitHook = GoalRevnetSplitHook(payable(Clones.clone(SPLIT_HOOK_IMPL)));
        CustomFlow goalFlow = CustomFlow(payable(Clones.clone(FLOW_IMPL)));

        uint32 cobuildCurrency = uint32(uint160(COBUILD_TOKEN));
        uint48 start = uint48(block.timestamp);

        JBSplit[] memory reservedSplits = new JBSplit[](1);
        reservedSplits[0] = JBSplit({
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: payable(address(splitHook)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(splitHook))
        });

        IREVDeployer.REVStageConfig[] memory stages = new IREVDeployer.REVStageConfig[](2);
        stages[0] = IREVDeployer.REVStageConfig({
            startsAtOrAfter: start,
            splitPercent: p.revnet.reservedPercent,
            initialIssuance: p.revnet.initialIssuance,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: p.revnet.cashOutTaxRate,
            extraMetadata: 0,
            splits: reservedSplits
        });
        stages[1] = IREVDeployer.REVStageConfig({
            startsAtOrAfter: start + p.revnet.durationSeconds,
            splitPercent: 0,
            initialIssuance: 0,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: p.revnet.cashOutTaxRate,
            extraMetadata: 0,
            splits: new JBSplit[](0)
        });

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: COBUILD_TOKEN,
            decimals: COBUILD_DECIMALS,
            currency: cobuildCurrency
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({
            terminal: IJBTerminal(address(REV_DEPLOYER.MULTI_TERMINAL())),
            accountingContextsToAccept: contexts
        });

        uint256 goalRevnetId = REV_DEPLOYER.deployFor(
            p.revnet.owner,
            IREVDeployer.REVConfig({
                description: IREVDeployer.REVDescription({
                    name: p.revnet.name,
                    ticker: p.revnet.ticker,
                    uri: p.revnet.uri
                }),
                baseCurrency: cobuildCurrency,
                splitOperator: BURN_ADDRESS,
                stageConfigurations: stages,
                loanSources: new IREVDeployer.REVLoanSource[](0),
                loans: address(0)
            }),
            terminalConfigs,
            IREVDeployer.REVBuybackHookConfig({
                dataHook: address(0),
                hookToConfigure: address(0),
                poolConfigurations: new IREVDeployer.REVBuybackPoolConfig[](0)
            }),
            IREVDeployer.REVSuckerDeploymentConfig({
                deployerConfigurations: new IREVDeployer.JBSuckerDeployerConfig[](0),
                salt: bytes32(0)
            })
        );

        IJBController controller = REV_DEPLOYER.CONTROLLER();
        IJBTokens tokens = controller.TOKENS();
        address goalToken = address(tokens.tokenOf(goalRevnetId));
        if (goalToken == address(0)) revert ADDRESS_ZERO();

        address predictedBudgetTCR = BUDGET_TCR_FACTORY.predictBudgetTCRAddress(
            address(this),
            address(goalFlow),
            address(goalTreasury),
            goalRevnetId,
            COBUILD_TOKEN
        );

        ISuperToken goalSuperToken = _createGoalSuperToken(goalToken, p.revnet.name, p.revnet.ticker);
        IJBRulesets rulesets = controller.RULESETS();

        GoalStakeVault stakeVault = new GoalStakeVault(
            address(goalTreasury),
            IERC20(goalToken),
            IERC20(COBUILD_TOKEN),
            rulesets,
            goalRevnetId,
            COBUILD_DECIMALS,
            p.rentRecipient == address(0) ? BURN_ADDRESS : p.rentRecipient,
            p.rentWadPerSecond
        );

        BudgetStakeLedger budgetStakeLedger = new BudgetStakeLedger(address(goalTreasury));
        GoalFlowAllocationLedgerPipeline allocationPipeline = new GoalFlowAllocationLedgerPipeline(
            address(budgetStakeLedger)
        );
        GoalStakeVaultStrategy stakeVaultStrategy = new GoalStakeVaultStrategy(stakeVault);

        IFlow.FlowParams memory flowParams = IFlow.FlowParams({ managerRewardPoolFlowRatePpm: 0 });
        FlowTypes.RecipientMetadata memory metadata = FlowTypes.RecipientMetadata({
            title: p.flowMetadata.title,
            description: p.flowMetadata.description,
            image: p.flowMetadata.image,
            tagline: "",
            url: ""
        });

        goalFlow.initialize(
            address(goalSuperToken),
            FLOW_IMPL,
            predictedBudgetTCR,
            address(goalTreasury),
            address(goalTreasury),
            address(0),
            address(allocationPipeline),
            address(0),
            address(0),
            flowParams,
            metadata,
            _oneStrategy(stakeVaultStrategy)
        );

        RewardEscrow rewardEscrow = new RewardEscrow(
            address(goalTreasury),
            IERC20(goalToken),
            stakeVault,
            goalSuperToken,
            budgetStakeLedger
        );

        uint32 minRaiseWindow = _resolveMinRaiseWindow(p.revnet.durationSeconds, p.timing.minRaiseDurationSeconds);
        uint64 minRaiseDeadline = uint64(block.timestamp + minRaiseWindow);

        IGoalTreasury.GoalConfig memory goalCfg = IGoalTreasury.GoalConfig({
            flow: address(goalFlow),
            stakeVault: address(stakeVault),
            rewardEscrow: address(rewardEscrow),
            hook: address(splitHook),
            goalRulesets: address(rulesets),
            goalRevnetId: goalRevnetId,
            minRaiseDeadline: minRaiseDeadline,
            minRaise: p.timing.minRaise,
            treasurySettlementRewardEscrowScaled: p.settlement.treasurySettlementRewardEscrowScaled,
            successResolver: p.success.successResolver,
            successAssertionLiveness: p.success.successAssertionLiveness,
            successAssertionBond: p.success.successAssertionBond,
            successOracleSpecHash: p.success.successOracleSpecHash,
            successAssertionPolicyHash: p.success.successAssertionPolicyHash
        });

        goalTreasury.initialize(address(BUDGET_TCR_FACTORY), goalCfg);

        splitHook.initialize(REV_DEPLOYER.DIRECTORY(), goalTreasury, goalFlow, goalRevnetId);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = _resolveRegistryConfig(p.budgetTCR);
        IBudgetTCR.DeploymentConfig memory tcrDeployCfg = IBudgetTCR.DeploymentConfig({
            stackDeployer: address(0),
            itemValidator: address(0),
            budgetSuccessResolver: p.budgetTCR.budgetSuccessResolver,
            goalFlow: goalFlow,
            goalTreasury: goalTreasury,
            goalToken: IERC20(goalToken),
            cobuildToken: IERC20(COBUILD_TOKEN),
            goalRulesets: rulesets,
            goalRevnetId: goalRevnetId,
            paymentTokenDecimals: COBUILD_DECIMALS,
            managerRewardPool: address(0),
            budgetValidationBounds: p.budgetTCR.budgetBounds,
            oracleValidationBounds: p.budgetTCR.oracleBounds
        });

        BudgetTCRFactory.DeployedBudgetTCRStack memory tcrStack = BUDGET_TCR_FACTORY.deployBudgetTCRStackForGoal(
            registryConfig,
            tcrDeployCfg,
            p.budgetTCR.arbitratorParams
        );
        if (tcrStack.budgetTCR != predictedBudgetTCR) {
            revert BUDGET_TCR_ADDRESS_MISMATCH(predictedBudgetTCR, tcrStack.budgetTCR);
        }

        out = DeployedGoalStack({
            goalRevnetId: goalRevnetId,
            goalToken: goalToken,
            goalSuperToken: address(goalSuperToken),
            goalTreasury: address(goalTreasury),
            goalFlow: address(goalFlow),
            goalStakeVault: address(stakeVault),
            budgetStakeLedger: address(budgetStakeLedger),
            rewardEscrow: address(rewardEscrow),
            splitHook: address(splitHook),
            budgetTCR: tcrStack.budgetTCR,
            arbitrator: tcrStack.arbitrator
        });

        emit GoalDeployed(msg.sender, goalRevnetId, out);
    }

    function _resolveRegistryConfig(
        BudgetTCRParams calldata p
    ) internal view returns (BudgetTCRFactory.RegistryConfigInput memory out) {
        out = BudgetTCRFactory.RegistryConfigInput({
            governor: p.governor == address(0) ? DEFAULT_BUDGET_TCR_GOVERNOR : p.governor,
            invalidRoundRewardsSink: p.invalidRoundRewardsSink == address(0)
                ? DEFAULT_INVALID_ROUND_REWARDS_SINK
                : p.invalidRoundRewardsSink,
            arbitratorExtraData: p.arbitratorExtraData,
            registrationMetaEvidence: p.registrationMetaEvidence,
            clearingMetaEvidence: p.clearingMetaEvidence,
            votingToken: IVotes(COBUILD_TOKEN),
            submissionBaseDeposit: p.submissionBaseDeposit,
            removalBaseDeposit: p.removalBaseDeposit,
            submissionChallengeBaseDeposit: p.submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: p.removalChallengeBaseDeposit,
            challengePeriodDuration: p.challengePeriodDuration,
            submissionDepositStrategy: ISubmissionDepositStrategy(
                p.submissionDepositStrategy == address(0)
                    ? DEFAULT_SUBMISSION_DEPOSIT_STRATEGY
                    : p.submissionDepositStrategy
            )
        });
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

    function _oneStrategy(GoalStakeVaultStrategy strategy) internal pure returns (IAllocationStrategy[] memory out) {
        out = new IAllocationStrategy[](1);
        out[0] = IAllocationStrategy(address(strategy));
    }

    function _createGoalSuperToken(
        address goalToken,
        string calldata name,
        string calldata ticker
    ) internal returns (ISuperToken superToken) {
        ISuperTokenFactory factory = SUPERFLUID_HOST.getSuperTokenFactory();
        superToken = factory.createERC20Wrapper(
            IERC20Metadata(goalToken),
            IERC20Metadata(goalToken).decimals(),
            ISuperTokenFactory.Upgradability.SEMI_UPGRADABLE,
            string.concat(name, " SuperToken"),
            string.concat(ticker, "x")
        );
    }
}
