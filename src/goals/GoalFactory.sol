// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";

import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { GoalFactoryBudgetTcrDeploy } from "src/goals/library/GoalFactoryBudgetTcrDeploy.sol";
import { GoalFactoryCoreStackDeploy } from "src/goals/library/GoalFactoryCoreStackDeploy.sol";
import { GoalFactoryRevnetDeploy } from "src/goals/library/GoalFactoryRevnetDeploy.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

interface ICobuildTerminalConfig {
    function DIRECTORY() external view returns (IJBDirectory);
    function COBUILD_TOKEN() external view returns (address);
    function COBUILD_REVNET_ID() external view returns (uint256);
}

contract GoalFactory {
    IREVDeployer public immutable REV_DEPLOYER;
    BudgetTCRFactory public immutable BUDGET_TCR_FACTORY;
    ISuperfluid public immutable SUPERFLUID_HOST;

    address public immutable COBUILD_TOKEN;
    uint8 public immutable COBUILD_DECIMALS;
    uint256 public immutable COBUILD_REVNET_ID;
    address public immutable COBUILD_TERMINAL;
    address public immutable JB_MULTI_TERMINAL;
    address public immutable BUYBACK_HOOK_DATA_HOOK;
    address public immutable BUYBACK_HOOK;

    address public immutable GOAL_TREASURY_IMPL;
    address public immutable STAKE_VAULT_IMPL;
    address public immutable FLOW_IMPL;
    address public immutable SPLIT_HOOK_IMPL;
    address public immutable BUDGET_STAKE_LEDGER_IMPL;
    address public immutable GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL;
    address public immutable PREMIUM_ESCROW_IMPL;
    address public immutable JUROR_SLASHER_ROUTER_IMPL;
    address public immutable UNDERWRITER_SLASHER_ROUTER_IMPL;

    address public immutable DEFAULT_SUBMISSION_DEPOSIT_STRATEGY;
    address public immutable DEFAULT_ALLOCATION_MECHANISM_ADMIN;
    address public immutable DEFAULT_INVALID_ROUND_REWARDS_SINK;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint24 internal constant BUYBACK_POOL_FEE = 3_000;
    uint32 internal constant BUYBACK_TWAP_WINDOW = 1 hours;

    struct RevnetParams {
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
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
    }

    struct BudgetTCRParams {
        address allocationMechanismAdmin;
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
        address goalFlowAllocationLedgerPipeline;
        address stakeVault;
        address budgetStakeLedger;
        address splitHook;
        address jurorSlasherRouter;
        address underwriterSlasherRouter;
        address successResolver;
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
    error INVALID_UNDERWRITING_SLASH_CONFIG(uint32 budgetPremiumPpm, uint32 budgetSlashPpm);
    error INVALID_MIN_RAISE_WINDOW(uint32 minRaiseDurationSeconds, uint32 goalDurationSeconds);
    error BUDGET_TCR_ADDRESS_MISMATCH(address predicted, address deployed);
    error INVALID_COBUILD_TERMINAL_DIRECTORY(address expected, address actual);
    error INVALID_COBUILD_TERMINAL_TOKEN(address expected, address actual);
    error INVALID_COBUILD_TERMINAL_REVNET_ID(uint256 expected, uint256 actual);
    error INVALID_COBUILD_REVNET_TOKEN(address expected, address actual, uint256 revnetId);
    error INVALID_COBUILD_NATIVE_TERMINAL(address terminal);

    constructor(
        IREVDeployer revDeployer,
        ISuperfluid superfluidHost,
        BudgetTCRFactory budgetTcrFactory,
        address cobuildToken,
        uint256 cobuildRevnetId,
        address cobuildTerminal,
        address jbMultiTerminal,
        address buybackHookDataHook,
        address buybackHook,
        address goalTreasuryImpl,
        address stakeVaultImpl,
        address flowImpl,
        address splitHookImpl,
        address budgetStakeLedgerImpl,
        address goalFlowAllocationLedgerPipelineImpl,
        address premiumEscrowImpl,
        address jurorSlasherRouterImpl,
        address underwriterSlasherRouterImpl,
        address defaultSubmissionDepositStrategy,
        address defaultAllocationMechanismAdmin,
        address defaultInvalidRoundRewardsSink
    ) {
        if (address(revDeployer) == address(0)) revert ADDRESS_ZERO();
        if (address(superfluidHost) == address(0)) revert ADDRESS_ZERO();
        if (address(budgetTcrFactory) == address(0)) revert ADDRESS_ZERO();
        if (cobuildToken == address(0)) revert ADDRESS_ZERO();
        if (cobuildTerminal == address(0)) revert ADDRESS_ZERO();
        if (jbMultiTerminal == address(0)) revert ADDRESS_ZERO();
        if (buybackHookDataHook == address(0)) revert ADDRESS_ZERO();
        if (buybackHook == address(0)) revert ADDRESS_ZERO();
        if (goalTreasuryImpl == address(0)) revert ADDRESS_ZERO();
        if (stakeVaultImpl == address(0)) revert ADDRESS_ZERO();
        if (flowImpl == address(0)) revert ADDRESS_ZERO();
        if (splitHookImpl == address(0)) revert ADDRESS_ZERO();
        if (budgetStakeLedgerImpl == address(0)) revert ADDRESS_ZERO();
        if (goalFlowAllocationLedgerPipelineImpl == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrowImpl == address(0)) revert ADDRESS_ZERO();
        if (jurorSlasherRouterImpl == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouterImpl == address(0)) revert ADDRESS_ZERO();
        if (defaultSubmissionDepositStrategy == address(0)) revert ADDRESS_ZERO();
        if (defaultAllocationMechanismAdmin == address(0)) revert ADDRESS_ZERO();
        if (defaultInvalidRoundRewardsSink == address(0)) revert ADDRESS_ZERO();
        if (goalTreasuryImpl.code.length == 0) revert NOT_A_CONTRACT(goalTreasuryImpl);
        if (stakeVaultImpl.code.length == 0) revert NOT_A_CONTRACT(stakeVaultImpl);
        if (flowImpl.code.length == 0) revert NOT_A_CONTRACT(flowImpl);
        if (splitHookImpl.code.length == 0) revert NOT_A_CONTRACT(splitHookImpl);
        if (budgetStakeLedgerImpl.code.length == 0) revert NOT_A_CONTRACT(budgetStakeLedgerImpl);
        if (goalFlowAllocationLedgerPipelineImpl.code.length == 0) {
            revert NOT_A_CONTRACT(goalFlowAllocationLedgerPipelineImpl);
        }
        if (premiumEscrowImpl.code.length == 0) revert NOT_A_CONTRACT(premiumEscrowImpl);
        if (jurorSlasherRouterImpl.code.length == 0) revert NOT_A_CONTRACT(jurorSlasherRouterImpl);
        if (underwriterSlasherRouterImpl.code.length == 0) revert NOT_A_CONTRACT(underwriterSlasherRouterImpl);
        if (cobuildTerminal.code.length == 0) revert NOT_A_CONTRACT(cobuildTerminal);
        if (jbMultiTerminal.code.length == 0) revert NOT_A_CONTRACT(jbMultiTerminal);
        if (buybackHookDataHook.code.length == 0) revert NOT_A_CONTRACT(buybackHookDataHook);
        if (buybackHook.code.length == 0) revert NOT_A_CONTRACT(buybackHook);
        if (defaultSubmissionDepositStrategy.code.length == 0) {
            revert NOT_A_CONTRACT(defaultSubmissionDepositStrategy);
        }
        _validateCobuildConfig(revDeployer, cobuildToken, cobuildRevnetId, cobuildTerminal);

        REV_DEPLOYER = revDeployer;
        SUPERFLUID_HOST = superfluidHost;
        BUDGET_TCR_FACTORY = budgetTcrFactory;

        COBUILD_TOKEN = cobuildToken;
        COBUILD_DECIMALS = IERC20Metadata(cobuildToken).decimals();
        COBUILD_REVNET_ID = cobuildRevnetId;
        COBUILD_TERMINAL = cobuildTerminal;
        JB_MULTI_TERMINAL = jbMultiTerminal;
        BUYBACK_HOOK_DATA_HOOK = buybackHookDataHook;
        BUYBACK_HOOK = buybackHook;

        GOAL_TREASURY_IMPL = goalTreasuryImpl;
        STAKE_VAULT_IMPL = stakeVaultImpl;
        FLOW_IMPL = flowImpl;
        SPLIT_HOOK_IMPL = splitHookImpl;
        BUDGET_STAKE_LEDGER_IMPL = budgetStakeLedgerImpl;
        GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL = goalFlowAllocationLedgerPipelineImpl;
        PREMIUM_ESCROW_IMPL = premiumEscrowImpl;
        JUROR_SLASHER_ROUTER_IMPL = jurorSlasherRouterImpl;
        UNDERWRITER_SLASHER_ROUTER_IMPL = underwriterSlasherRouterImpl;

        DEFAULT_SUBMISSION_DEPOSIT_STRATEGY = defaultSubmissionDepositStrategy;
        DEFAULT_ALLOCATION_MECHANISM_ADMIN = defaultAllocationMechanismAdmin;
        DEFAULT_INVALID_ROUND_REWARDS_SINK = defaultInvalidRoundRewardsSink;
    }

    function _validateCobuildConfig(
        IREVDeployer revDeployer,
        address cobuildToken,
        uint256 cobuildRevnetId,
        address cobuildTerminal
    ) private view {
        IJBDirectory directory = revDeployer.DIRECTORY();
        ICobuildTerminalConfig cobuildTerminalConfig = ICobuildTerminalConfig(cobuildTerminal);

        IJBDirectory terminalDirectory = cobuildTerminalConfig.DIRECTORY();
        if (terminalDirectory != directory) {
            revert INVALID_COBUILD_TERMINAL_DIRECTORY(address(directory), address(terminalDirectory));
        }

        address terminalToken = cobuildTerminalConfig.COBUILD_TOKEN();
        if (terminalToken != cobuildToken) {
            revert INVALID_COBUILD_TERMINAL_TOKEN(cobuildToken, terminalToken);
        }

        uint256 terminalRevnetId = cobuildTerminalConfig.COBUILD_REVNET_ID();
        if (terminalRevnetId != cobuildRevnetId) {
            revert INVALID_COBUILD_TERMINAL_REVNET_ID(cobuildRevnetId, terminalRevnetId);
        }

        IJBController controller = revDeployer.CONTROLLER();
        IJBTokens tokens = controller.TOKENS();
        address revnetToken = address(tokens.tokenOf(cobuildRevnetId));
        if (revnetToken != cobuildToken) {
            revert INVALID_COBUILD_REVNET_TOKEN(cobuildToken, revnetToken, cobuildRevnetId);
        }

        address nativeTerminal = address(directory.primaryTerminalOf(cobuildRevnetId, JBConstants.NATIVE_TOKEN));
        if (nativeTerminal == address(0) || nativeTerminal == cobuildTerminal) {
            revert INVALID_COBUILD_NATIVE_TERMINAL(nativeTerminal);
        }
    }

    function deployGoal(DeployParams calldata p) external returns (DeployedGoalStack memory out) {
        if (p.revnet.durationSeconds == 0) revert INVALID_DURATION();
        if (p.revnet.reservedPercent > FlowProtocolConstants.BPS_SCALE) revert INVALID_RESERVED_PERCENT();
        if (p.revnet.cashOutTaxRate > FlowProtocolConstants.BPS_SCALE) revert INVALID_TAX_RATE();

        if (p.success.successResolver == address(0)) revert ADDRESS_ZERO();
        if (
            p.success.successAssertionLiveness == 0 ||
            p.success.successOracleSpecHash == bytes32(0) ||
            p.success.successAssertionPolicyHash == bytes32(0)
        ) {
            revert INVALID_ASSERTION_CONFIG();
        }

        if (
            p.underwriting.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE ||
            p.underwriting.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE
        ) {
            revert INVALID_SCALE();
        }
        if (p.underwriting.budgetSlashPpm != 0 && p.underwriting.budgetPremiumPpm == 0) {
            revert INVALID_UNDERWRITING_SLASH_CONFIG(p.underwriting.budgetPremiumPpm, p.underwriting.budgetSlashPpm);
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
            goalFlowAllocationLedgerPipeline: core.goalFlowAllocationLedgerPipeline,
            stakeVault: address(core.stakeVault),
            budgetStakeLedger: address(core.budgetStakeLedger),
            splitHook: address(core.splitHook),
            jurorSlasherRouter: core.jurorSlasherRouter,
            underwriterSlasherRouter: core.underwriterSlasherRouter,
            successResolver: p.success.successResolver,
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
                    cobuildTerminal: COBUILD_TERMINAL,
                    jbMultiTerminal: JB_MULTI_TERMINAL,
                    splitHook: address(splitHook),
                    name: p.revnet.name,
                    ticker: p.revnet.ticker,
                    uri: p.revnet.uri,
                    initialIssuance: p.revnet.initialIssuance,
                    cashOutTaxRate: p.revnet.cashOutTaxRate,
                    reservedPercent: p.revnet.reservedPercent,
                    durationSeconds: p.revnet.durationSeconds,
                    buybackHookDataHook: BUYBACK_HOOK_DATA_HOOK,
                    buybackHook: BUYBACK_HOOK,
                    buybackPoolFee: BUYBACK_POOL_FEE,
                    buybackTwapWindow: BUYBACK_TWAP_WINDOW,
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
                    stakeVaultImpl: STAKE_VAULT_IMPL,
                    jurorSlasherRouterImpl: JUROR_SLASHER_ROUTER_IMPL,
                    flowImpl: FLOW_IMPL,
                    superfluidHost: SUPERFLUID_HOST,
                    budgetTcrFactory: address(BUDGET_TCR_FACTORY),
                    underwriterSlasherRouterImpl: UNDERWRITER_SLASHER_ROUTER_IMPL,
                    budgetStakeLedgerImpl: BUDGET_STAKE_LEDGER_IMPL,
                    goalFlowAllocationLedgerPipelineImpl: GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL,
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
        return
            GoalFactoryBudgetTcrDeploy.deployBudgetTcrStack(
                GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest({
                    budgetTcrFactory: BUDGET_TCR_FACTORY,
                    allocationMechanismAdmin: p.budgetTCR.allocationMechanismAdmin,
                    invalidRoundRewardsSink: p.budgetTCR.invalidRoundRewardsSink,
                    submissionDepositStrategy: p.budgetTCR.submissionDepositStrategy,
                    registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                        arbitratorExtraData: p.budgetTCR.arbitratorExtraData,
                        registrationMetaEvidence: p.budgetTCR.registrationMetaEvidence,
                        clearingMetaEvidence: p.budgetTCR.clearingMetaEvidence,
                        submissionBaseDeposit: p.budgetTCR.submissionBaseDeposit,
                        removalBaseDeposit: p.budgetTCR.removalBaseDeposit,
                        submissionChallengeBaseDeposit: p.budgetTCR.submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit: p.budgetTCR.removalChallengeBaseDeposit,
                        challengePeriodDuration: p.budgetTCR.challengePeriodDuration
                    }),
                    defaultAllocationMechanismAdmin: DEFAULT_ALLOCATION_MECHANISM_ADMIN,
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
                    premiumEscrowImplementation: PREMIUM_ESCROW_IMPL,
                    underwriterSlasherRouter: core.underwriterSlasherRouter,
                    budgetPremiumPpm: p.underwriting.budgetPremiumPpm,
                    budgetSlashPpm: p.underwriting.budgetSlashPpm
                })
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
