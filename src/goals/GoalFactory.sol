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

import { BudgetSingleAllocatorStrategyFactory } from "src/allocation-strategies/BudgetSingleAllocatorStrategyFactory.sol";
import { BudgetSingleAllocatorStrategy } from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import { SingleAllocatorStrategy } from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { ManagedBudgetController } from "src/goals/ManagedBudgetController.sol";

import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { GoalFactoryBudgetTcrDeploy } from "src/goals/library/GoalFactoryBudgetTcrDeploy.sol";
import { GoalFactoryCoreStackDeploy } from "src/goals/library/GoalFactoryCoreStackDeploy.sol";
import { GoalFactoryManagedPresetDeploy } from "src/goals/library/GoalFactoryManagedPresetDeploy.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { GoalFactoryRevnetDeploy } from "src/goals/library/GoalFactoryRevnetDeploy.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { SpendPolicyValidationLib } from "src/library/SpendPolicyValidationLib.sol";

interface IGoalFundingTerminalConfig {
    function DIRECTORY() external view returns (IJBDirectory);
    function GOAL_DEPLOYMENT_REGISTRY() external view returns (IGoalDeploymentRegistry);
}

contract GoalFactory {
    enum GoalPreset {
        Open,
        Managed
    }

    IREVDeployer public immutable REV_DEPLOYER;
    BudgetTCRFactory public immutable BUDGET_TCR_FACTORY;
    ISuperfluid public immutable SUPERFLUID_HOST;
    IGoalDeploymentRegistry public immutable GOAL_DEPLOYMENT_REGISTRY;

    address public immutable GOAL_PAYMENT_TERMINAL;
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
    address public immutable MANAGED_BUDGET_CONTROLLER_IMPL;
    address public immutable MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL;
    address public immutable MANAGED_BUDGET_CHILD_STRATEGY_FACTORY_IMPL;
    address public immutable MANAGED_PREMIUM_ESCROW_IMPL;
    address public immutable OPEN_BUDGET_GATE_POLICY;

    address public immutable DEFAULT_GOAL_SPEND_POLICY;
    address public immutable DEFAULT_BUDGET_SPEND_POLICY;
    address public immutable DEFAULT_SUBMISSION_DEPOSIT_STRATEGY;
    address public immutable DEFAULT_ALLOCATION_MECHANISM_ADMIN;
    address public immutable DEFAULT_INVALID_ROUND_REWARDS_SINK;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint24 internal constant BUYBACK_POOL_FEE = 3_000;
    uint32 internal constant BUYBACK_TWAP_WINDOW = 1 hours;

    struct FundingContext {
        address paymentToken;
        uint256 paymentRevnetId;
    }

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
        address budgetSpendPolicy;
        IArbitrator.ArbitratorParams arbitratorParams;
    }

    struct DeployParams {
        GoalPreset preset;
        address managedSafe;
        FundingContext funding;
        RevnetParams revnet;
        GoalTimingParams timing;
        SuccessParams success;
        FlowMetadataParams flowMetadata;
        UnderwritingParams underwriting;
        BudgetTCRParams budgetTCR;
        address goalSpendPolicy;
    }

    struct DeployedGoalStack {
        uint256 goalRevnetId;
        address goalToken;
        address goalSuperToken;
        address goalTreasury;
        address goalFlow;
        address goalAllocatorStrategy;
        address goalFlowAllocationLedgerPipeline;
        address stakeVault;
        address budgetStakeLedger;
        address splitHook;
        address jurorSlasherRouter;
        address underwriterSlasherRouter;
        address successResolver;
        address budgetController;
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
    error BUDGET_CONTROLLER_ADDRESS_MISMATCH(address predicted, address deployed);
    error INVALID_GOAL_TERMINAL_DIRECTORY(address expected, address actual);
    error INVALID_GOAL_TERMINAL_REGISTRY(address expected, address actual);
    error INVALID_PAYMENT_REVNET_TOKEN(address expected, address actual, uint256 revnetId);
    error INVALID_PAYMENT_NATIVE_TERMINAL(address terminal, uint256 revnetId);
    error INVALID_DEPLOYED_FUNDING_CONTEXT(
        address expectedToken,
        address actualToken,
        uint256 expectedRevnetId,
        uint256 actualRevnetId
    );
    error INVALID_COMMUNITY_DIRECTORY(address expected, address actual);
    error INVALID_COMMUNITY_GOAL_DEPLOYMENT_REGISTRY(address expected, address actual);
    error MANAGED_SAFE_REQUIRED();
    error MANAGED_SAFE_NOT_CONTRACT(address safe);
    error MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH(uint32 budgetPremiumPpm, uint32 budgetSlashPpm);
    error INVALID_DEFAULT_SPEND_POLICY(address policy);

    constructor(
        IREVDeployer revDeployer,
        ISuperfluid superfluidHost,
        BudgetTCRFactory budgetTcrFactory,
        IGoalDeploymentRegistry goalDeploymentRegistry,
        address goalPaymentTerminal,
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
        address openBudgetGatePolicy,
        address defaultGoalSpendPolicy,
        address defaultBudgetSpendPolicy,
        address defaultSubmissionDepositStrategy,
        address defaultAllocationMechanismAdmin,
        address defaultInvalidRoundRewardsSink
    ) {
        if (address(revDeployer) == address(0)) revert ADDRESS_ZERO();
        if (address(superfluidHost) == address(0)) revert ADDRESS_ZERO();
        if (address(budgetTcrFactory) == address(0)) revert ADDRESS_ZERO();
        if (address(goalDeploymentRegistry) == address(0)) revert ADDRESS_ZERO();
        if (goalPaymentTerminal == address(0)) revert ADDRESS_ZERO();
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
        if (openBudgetGatePolicy == address(0)) revert ADDRESS_ZERO();
        if (defaultGoalSpendPolicy == address(0)) revert ADDRESS_ZERO();
        if (defaultBudgetSpendPolicy == address(0)) revert ADDRESS_ZERO();
        if (defaultSubmissionDepositStrategy == address(0)) revert ADDRESS_ZERO();
        if (defaultAllocationMechanismAdmin == address(0)) revert ADDRESS_ZERO();
        if (defaultInvalidRoundRewardsSink == address(0)) revert ADDRESS_ZERO();
        if (goalTreasuryImpl.code.length == 0) revert NOT_A_CONTRACT(goalTreasuryImpl);
        if (address(goalDeploymentRegistry).code.length == 0) revert NOT_A_CONTRACT(address(goalDeploymentRegistry));
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
        if (openBudgetGatePolicy.code.length == 0) revert NOT_A_CONTRACT(openBudgetGatePolicy);
        if (!BudgetGatePolicyHook.supportsBudgetGatePolicy(IBudgetGatePolicy(openBudgetGatePolicy))) {
            revert IBudgetTCR.INVALID_BUDGET_GATE_POLICY(openBudgetGatePolicy);
        }
        if (defaultGoalSpendPolicy.code.length == 0) revert NOT_A_CONTRACT(defaultGoalSpendPolicy);
        if (defaultBudgetSpendPolicy.code.length == 0) revert NOT_A_CONTRACT(defaultBudgetSpendPolicy);
        if (goalPaymentTerminal.code.length == 0) revert NOT_A_CONTRACT(goalPaymentTerminal);
        if (jbMultiTerminal.code.length == 0) revert NOT_A_CONTRACT(jbMultiTerminal);
        if (buybackHookDataHook.code.length == 0) revert NOT_A_CONTRACT(buybackHookDataHook);
        if (buybackHook.code.length == 0) revert NOT_A_CONTRACT(buybackHook);
        if (defaultSubmissionDepositStrategy.code.length == 0) {
            revert NOT_A_CONTRACT(defaultSubmissionDepositStrategy);
        }
        _requireValidDefaultSpendPolicy(defaultGoalSpendPolicy);
        _requireValidDefaultSpendPolicy(defaultBudgetSpendPolicy);
        _validateGoalTerminalConfig(revDeployer, goalDeploymentRegistry, goalPaymentTerminal);

        address managedBudgetControllerImplementation = address(new ManagedBudgetController());
        address managedGoalAllocatorStrategyImplementation = address(
            new SingleAllocatorStrategy(address(0), address(0))
        );
        address managedBudgetChildStrategyImplementation = address(
            new BudgetSingleAllocatorStrategy(address(0), address(0))
        );
        address managedBudgetChildStrategyFactoryImplementation = address(
            new BudgetSingleAllocatorStrategyFactory(managedBudgetChildStrategyImplementation)
        );

        REV_DEPLOYER = revDeployer;
        SUPERFLUID_HOST = superfluidHost;
        BUDGET_TCR_FACTORY = budgetTcrFactory;
        GOAL_DEPLOYMENT_REGISTRY = goalDeploymentRegistry;

        GOAL_PAYMENT_TERMINAL = goalPaymentTerminal;
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
        MANAGED_BUDGET_CONTROLLER_IMPL = managedBudgetControllerImplementation;
        MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL = managedGoalAllocatorStrategyImplementation;
        MANAGED_BUDGET_CHILD_STRATEGY_FACTORY_IMPL = managedBudgetChildStrategyFactoryImplementation;
        MANAGED_PREMIUM_ESCROW_IMPL = address(0);
        OPEN_BUDGET_GATE_POLICY = openBudgetGatePolicy;

        DEFAULT_GOAL_SPEND_POLICY = defaultGoalSpendPolicy;
        DEFAULT_BUDGET_SPEND_POLICY = defaultBudgetSpendPolicy;
        DEFAULT_SUBMISSION_DEPOSIT_STRATEGY = defaultSubmissionDepositStrategy;
        DEFAULT_ALLOCATION_MECHANISM_ADMIN = defaultAllocationMechanismAdmin;
        DEFAULT_INVALID_ROUND_REWARDS_SINK = defaultInvalidRoundRewardsSink;
    }

    function deployGoalForCommunity(
        ICommunityGoalRegistry registry,
        DeployParams calldata p
    ) external returns (DeployedGoalStack memory out) {
        if (address(registry) == address(0)) revert ADDRESS_ZERO();
        if (address(registry).code.length == 0) revert NOT_A_CONTRACT(address(registry));

        IJBDirectory directory = REV_DEPLOYER.DIRECTORY();
        IJBDirectory registryDirectory = registry.directory();
        if (address(registryDirectory) != address(directory)) {
            revert INVALID_COMMUNITY_DIRECTORY(address(directory), address(registryDirectory));
        }
        address registryGoalDeploymentRegistry = address(registry.goalDeploymentRegistry());
        if (registryGoalDeploymentRegistry != address(GOAL_DEPLOYMENT_REGISTRY)) {
            revert INVALID_COMMUNITY_GOAL_DEPLOYMENT_REGISTRY(
                address(GOAL_DEPLOYMENT_REGISTRY),
                registryGoalDeploymentRegistry
            );
        }

        DeployParams memory params = p;
        params.funding = FundingContext({
            paymentToken: registry.communityToken(),
            paymentRevnetId: registry.communityRevnetId()
        });
        out = _deployGoal(params);
    }

    function deployGoal(DeployParams calldata p) external returns (DeployedGoalStack memory out) {
        DeployParams memory params = p;
        out = _deployGoal(params);
    }

    function _validateGoalTerminalConfig(
        IREVDeployer revDeployer,
        IGoalDeploymentRegistry goalDeploymentRegistry,
        address goalPaymentTerminal
    ) private view {
        IJBDirectory directory = revDeployer.DIRECTORY();
        IGoalFundingTerminalConfig goalTerminalConfig = IGoalFundingTerminalConfig(goalPaymentTerminal);

        IJBDirectory terminalDirectory = goalTerminalConfig.DIRECTORY();
        if (terminalDirectory != directory) {
            revert INVALID_GOAL_TERMINAL_DIRECTORY(address(directory), address(terminalDirectory));
        }

        address terminalRegistry = address(goalTerminalConfig.GOAL_DEPLOYMENT_REGISTRY());
        if (terminalRegistry != address(goalDeploymentRegistry)) {
            revert INVALID_GOAL_TERMINAL_REGISTRY(address(goalDeploymentRegistry), terminalRegistry);
        }
    }

    function _requireValidDefaultSpendPolicy(address policy) private view {
        if (!SpendPolicyValidationLib.passesValidationProbe(policy)) {
            revert INVALID_DEFAULT_SPEND_POLICY(policy);
        }
    }

    function _resolveFundingContext(
        FundingContext memory funding
    ) private view returns (address paymentToken, uint8 paymentTokenDecimals, uint256 paymentRevnetId) {
        paymentToken = funding.paymentToken;
        paymentRevnetId = funding.paymentRevnetId;

        if (paymentToken == address(0) || paymentRevnetId == 0) revert ADDRESS_ZERO();
        if (paymentToken.code.length == 0) revert NOT_A_CONTRACT(paymentToken);

        IJBController controller = REV_DEPLOYER.CONTROLLER();
        IJBTokens tokens = controller.TOKENS();
        address revnetToken = address(tokens.tokenOf(paymentRevnetId));
        if (revnetToken != paymentToken) {
            revert INVALID_PAYMENT_REVNET_TOKEN(paymentToken, revnetToken, paymentRevnetId);
        }

        address nativeTerminal = address(
            REV_DEPLOYER.DIRECTORY().primaryTerminalOf(paymentRevnetId, JBConstants.NATIVE_TOKEN)
        );
        if (nativeTerminal == address(0) || nativeTerminal == GOAL_PAYMENT_TERMINAL) {
            revert INVALID_PAYMENT_NATIVE_TERMINAL(nativeTerminal, paymentRevnetId);
        }

        paymentTokenDecimals = IERC20Metadata(paymentToken).decimals();
    }

    function _deployGoal(DeployParams memory p) private returns (DeployedGoalStack memory out) {
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
        p.goalSpendPolicy = _resolveSpendPolicyOrDefault(p.goalSpendPolicy, DEFAULT_GOAL_SPEND_POLICY);
        if (p.preset == GoalPreset.Managed) {
            if (p.managedSafe == address(0)) revert MANAGED_SAFE_REQUIRED();
            if (p.managedSafe.code.length == 0) revert MANAGED_SAFE_NOT_CONTRACT(p.managedSafe);
            if (p.budgetTCR.oracleBounds.liveness == 0) revert INVALID_ASSERTION_CONFIG();
        }
        if (p.budgetTCR.budgetSuccessResolver == address(0)) revert ADDRESS_ZERO();
        if (p.budgetTCR.budgetSuccessResolver.code.length == 0) {
            revert NOT_A_CONTRACT(p.budgetTCR.budgetSuccessResolver);
        }
        p.budgetTCR.budgetSpendPolicy = _resolveSpendPolicyOrDefault(
            p.budgetTCR.budgetSpendPolicy,
            DEFAULT_BUDGET_SPEND_POLICY
        );

        if (
            p.underwriting.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE ||
            p.underwriting.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE
        ) {
            revert INVALID_SCALE();
        }
        if (p.underwriting.budgetSlashPpm != 0 && p.underwriting.budgetPremiumPpm == 0) {
            revert INVALID_UNDERWRITING_SLASH_CONFIG(p.underwriting.budgetPremiumPpm, p.underwriting.budgetSlashPpm);
        }
        if (
            p.preset == GoalPreset.Managed &&
            (p.underwriting.budgetPremiumPpm != 0 || p.underwriting.budgetSlashPpm != 0)
        ) {
            revert MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH(
                p.underwriting.budgetPremiumPpm,
                p.underwriting.budgetSlashPpm
            );
        }

        (address paymentToken, uint8 paymentTokenDecimals, uint256 paymentRevnetId) = _resolveFundingContext(p.funding);

        GoalTreasury goalTreasury = GoalTreasury(Clones.clone(GOAL_TREASURY_IMPL));
        GoalRevnetSplitHook splitHook = GoalRevnetSplitHook(payable(Clones.clone(SPLIT_HOOK_IMPL)));
        CustomFlow goalFlow = CustomFlow(payable(Clones.clone(FLOW_IMPL)));

        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet = _deployRevnet(
            p,
            splitHook,
            paymentToken,
            paymentTokenDecimals
        );

        address predictedBudgetController;
        address goalAllocatorStrategy;
        address jurorSlasherAuthority;
        address arbitrator;
        GoalFactoryManagedPresetDeploy.ManagedPresetBundle memory managedPreset;

        if (p.preset == GoalPreset.Managed) {
            managedPreset = _bootstrapManagedPreset(address(goalTreasury));
            predictedBudgetController = address(managedPreset.budgetController);
            goalAllocatorStrategy = managedPreset.goalAllocatorStrategy;
            jurorSlasherAuthority = predictedBudgetController;
        } else {
            predictedBudgetController = BUDGET_TCR_FACTORY.predictBudgetTCRAddress(
                address(this),
                address(goalFlow),
                address(goalTreasury),
                revnet.goalRevnetId,
                paymentToken
            );
            jurorSlasherAuthority = address(BUDGET_TCR_FACTORY);
        }

        uint32 minRaiseWindow = _resolveMinRaiseWindow(p.revnet.durationSeconds, p.timing.minRaiseDurationSeconds);
        uint64 minRaiseDeadline = uint64(block.timestamp + minRaiseWindow);

        GoalFactoryCoreStackDeploy.CoreStackResult memory core = _deployCoreBase(
            goalTreasury,
            splitHook,
            goalFlow,
            revnet,
            p,
            paymentToken,
            paymentTokenDecimals
        );

        if (p.preset == GoalPreset.Open) {
            goalAllocatorStrategy = address(core.stakeVault);
        }

        core = _finalizeCoreStack(
            p,
            core,
            revnet,
            predictedBudgetController,
            goalAllocatorStrategy,
            jurorSlasherAuthority,
            minRaiseDeadline,
            paymentToken
        );

        address budgetController = predictedBudgetController;
        if (p.preset == GoalPreset.Managed) {
            _initializeManagedBudgetController(p, core, managedPreset);
        } else {
            BudgetTCRFactory.DeployedBudgetTCRStack memory tcrStack = _deployBudgetTcr(
                p,
                core,
                revnet,
                predictedBudgetController,
                paymentToken,
                paymentTokenDecimals
            );
            if (tcrStack.budgetTCR != predictedBudgetController) {
                revert BUDGET_CONTROLLER_ADDRESS_MISMATCH(predictedBudgetController, tcrStack.budgetTCR);
            }
            budgetController = tcrStack.budgetTCR;
            arbitrator = tcrStack.arbitrator;
        }

        GOAL_DEPLOYMENT_REGISTRY.registerGoal(revnet.goalRevnetId, address(core.goalTreasury));

        uint256 actualPaymentRevnetId = core.goalTreasury.cobuildRevnetId();
        address actualPaymentToken = address(core.stakeVault.cobuildToken());
        if (actualPaymentRevnetId != paymentRevnetId || actualPaymentToken != paymentToken) {
            revert INVALID_DEPLOYED_FUNDING_CONTEXT(
                paymentToken,
                actualPaymentToken,
                paymentRevnetId,
                actualPaymentRevnetId
            );
        }

        out = DeployedGoalStack({
            goalRevnetId: revnet.goalRevnetId,
            goalToken: revnet.goalToken,
            goalSuperToken: address(core.goalSuperToken),
            goalTreasury: address(core.goalTreasury),
            goalFlow: address(core.goalFlow),
            goalAllocatorStrategy: goalAllocatorStrategy,
            goalFlowAllocationLedgerPipeline: core.goalFlowAllocationLedgerPipeline,
            stakeVault: address(core.stakeVault),
            budgetStakeLedger: address(core.budgetStakeLedger),
            splitHook: address(core.splitHook),
            jurorSlasherRouter: core.jurorSlasherRouter,
            underwriterSlasherRouter: core.underwriterSlasherRouter,
            successResolver: p.success.successResolver,
            budgetController: budgetController,
            arbitrator: arbitrator
        });

        emit GoalDeployed(msg.sender, revnet.goalRevnetId, out);
    }

    function _deployRevnet(
        DeployParams memory p,
        GoalRevnetSplitHook splitHook,
        address paymentToken,
        uint8 paymentTokenDecimals
    ) private returns (GoalFactoryRevnetDeploy.RevnetDeploymentResult memory) {
        return
            GoalFactoryRevnetDeploy.deployRevnet(
                GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
                    revDeployer: REV_DEPLOYER,
                    cobuildToken: paymentToken,
                    cobuildDecimals: paymentTokenDecimals,
                    goalPaymentTerminal: GOAL_PAYMENT_TERMINAL,
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

    function _deployCoreBase(
        GoalTreasury goalTreasury,
        GoalRevnetSplitHook splitHook,
        CustomFlow goalFlow,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        DeployParams memory p,
        address paymentToken,
        uint8 paymentTokenDecimals
    ) private returns (GoalFactoryCoreStackDeploy.CoreStackResult memory) {
        return
            GoalFactoryCoreStackDeploy.deployCoreBase(
                GoalFactoryCoreStackDeploy.CoreBaseRequest({
                    goalTreasury: goalTreasury,
                    splitHook: splitHook,
                    goalFlow: goalFlow,
                    stakeVaultImpl: STAKE_VAULT_IMPL,
                    superfluidHost: SUPERFLUID_HOST,
                    budgetStakeLedgerImpl: BUDGET_STAKE_LEDGER_IMPL,
                    goalFlowAllocationLedgerPipelineImpl: GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL,
                    cobuildToken: paymentToken,
                    cobuildDecimals: paymentTokenDecimals,
                    goalRevnetId: revnet.goalRevnetId,
                    goalToken: revnet.goalToken,
                    rulesets: revnet.rulesets,
                    revnetName: p.revnet.name,
                    revnetTicker: p.revnet.ticker
                })
            );
    }

    function _finalizeCoreStack(
        DeployParams memory p,
        GoalFactoryCoreStackDeploy.CoreStackResult memory core,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        address budgetController,
        address goalAllocatorStrategy,
        address jurorSlasherAuthority,
        uint64 minRaiseDeadline,
        address paymentToken
    ) private returns (GoalFactoryCoreStackDeploy.CoreStackResult memory) {
        return
            GoalFactoryCoreStackDeploy.finalizeCoreStack(
                core,
                GoalFactoryCoreStackDeploy.CoreFinalizeRequest({
                    goalAllocatorStrategy: goalAllocatorStrategy,
                    budgetController: budgetController,
                    jurorSlasherAuthority: jurorSlasherAuthority,
                    jurorSlasherRouterImpl: JUROR_SLASHER_ROUTER_IMPL,
                    underwriterSlasherRouterImpl: UNDERWRITER_SLASHER_ROUTER_IMPL,
                    flowImpl: FLOW_IMPL,
                    goalToken: revnet.goalToken,
                    cobuildToken: paymentToken,
                    goalRevnetId: revnet.goalRevnetId,
                    rulesets: revnet.rulesets,
                    directory: revnet.directory,
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
                    successAssertionPolicyHash: p.success.successAssertionPolicyHash,
                    goalSpendPolicy: p.goalSpendPolicy
                })
            );
    }

    function _bootstrapManagedPreset(
        address goalTreasury
    ) private returns (GoalFactoryManagedPresetDeploy.ManagedPresetBundle memory) {
        return
            GoalFactoryManagedPresetDeploy.bootstrapManagedPreset(
                goalTreasury,
                GoalFactoryManagedPresetDeploy.ManagedPresetBootstrapConfig({
                    budgetControllerImplementation: MANAGED_BUDGET_CONTROLLER_IMPL,
                    goalAllocatorStrategyImplementation: MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL,
                    stackDeployerImplementation: BUDGET_TCR_FACTORY.stackDeployerImplementation(),
                    budgetChildStrategyFactoryImplementation: MANAGED_BUDGET_CHILD_STRATEGY_FACTORY_IMPL
                })
            );
    }

    function _initializeManagedBudgetController(
        DeployParams memory p,
        GoalFactoryCoreStackDeploy.CoreStackResult memory core,
        GoalFactoryManagedPresetDeploy.ManagedPresetBundle memory managedPreset
    ) private {
        GoalFactoryManagedPresetDeploy.initializeManagedController(
            managedPreset.budgetController,
            IManagedBudgetController.InitConfig({
                authority: p.managedSafe,
                goalTreasury: address(core.goalTreasury),
                goalFlow: address(core.goalFlow),
                stackDeployer: managedPreset.stackDeployer,
                budgetGatePolicy: address(0),
                budgetSuccessResolver: p.budgetTCR.budgetSuccessResolver,
                budgetSpendPolicy: p.budgetTCR.budgetSpendPolicy,
                successAssertionLiveness: p.budgetTCR.oracleBounds.liveness,
                successAssertionBond: p.budgetTCR.oracleBounds.bondAmount
            })
        );
    }

    function _deployBudgetTcr(
        DeployParams memory p,
        GoalFactoryCoreStackDeploy.CoreStackResult memory core,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        address predictedBudgetTCR,
        address paymentToken,
        uint8 paymentTokenDecimals
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
                    budgetGatePolicy: OPEN_BUDGET_GATE_POLICY,
                    cobuildToken: paymentToken,
                    cobuildDecimals: paymentTokenDecimals,
                    budgetSuccessResolver: p.budgetTCR.budgetSuccessResolver,
                    budgetBounds: p.budgetTCR.budgetBounds,
                    oracleBounds: p.budgetTCR.oracleBounds,
                    arbitratorParams: p.budgetTCR.arbitratorParams,
                    budgetSpendPolicy: p.budgetTCR.budgetSpendPolicy,
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

    function _resolveSpendPolicyOrDefault(
        address configuredPolicy,
        address defaultPolicy
    ) private view returns (address spendPolicy) {
        spendPolicy = configuredPolicy == address(0) ? defaultPolicy : configuredPolicy;
        if (spendPolicy.code.length == 0) revert NOT_A_CONTRACT(spendPolicy);
    }
}
