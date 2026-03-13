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

import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { GoalFactoryBudgetTcrDeploy } from "src/goals/library/GoalFactoryBudgetTcrDeploy.sol";
import { GoalFactoryBudgetTcrRouting } from "src/goals/library/GoalFactoryBudgetTcrRouting.sol";
import { GoalFactoryCoreStackDeploy } from "src/goals/library/GoalFactoryCoreStackDeploy.sol";
import { GoalFactoryManagedPresetDeploy } from "src/goals/library/GoalFactoryManagedPresetDeploy.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { GoalFactoryRevnetDeploy } from "src/goals/library/GoalFactoryRevnetDeploy.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { SpendPolicyValidationLib } from "src/library/SpendPolicyValidationLib.sol";
import { SuccessResolverValidationLib } from "src/library/SuccessResolverValidationLib.sol";

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
    address public immutable OPEN_BUDGET_GATE_POLICY;

    address public immutable DEFAULT_GOAL_SPEND_POLICY;
    address public immutable DEFAULT_BUDGET_SPEND_POLICY;
    address public immutable DEFAULT_SUBMISSION_DEPOSIT_STRATEGY;
    address public immutable DEFAULT_ALLOCATION_MECHANISM_ADMIN;
    address public immutable DEFAULT_INVALID_ROUND_REWARDS_SINK;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint24 internal constant BUYBACK_POOL_FEE = 3_000;
    uint32 internal constant BUYBACK_TWAP_WINDOW = 1 hours;
    uint64 internal constant MANAGED_TERMINAL_ROLLOVER_COOLDOWN = 30 days;

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

    struct CommonGoalParams {
        FundingContext funding;
        RevnetParams revnet;
        GoalTimingParams timing;
        SuccessParams success;
        FlowMetadataParams flowMetadata;
        UnderwritingParams underwriting;
        address goalSpendPolicy;
    }

    struct BudgetRuntimeParams {
        address budgetSuccessResolver;
        address budgetSpendPolicy;
        IBudgetTCR.OracleValidationBounds oracleBounds;
    }

    struct OpenBudgetTCRParams {
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
        IArbitrator.ArbitratorParams arbitratorParams;
    }

    struct OpenGoalParams {
        CommonGoalParams common;
        BudgetRuntimeParams budgetRuntime;
        OpenBudgetTCRParams openBudgetTCR;
    }

    struct ManagedGoalParams {
        CommonGoalParams common;
        address managedSafe;
        address managedBudgetGatePolicy;
        BudgetRuntimeParams budgetRuntime;
    }

    struct SharedDeployContext {
        GoalFactoryRevnetDeploy.RevnetDeploymentResult revnet;
        GoalFactoryCoreStackDeploy.CoreStackResult core;
        address paymentToken;
        uint256 paymentRevnetId;
        uint64 minRaiseDeadline;
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
    error INVALID_BUDGET_TCR_FACTORY_CALLER(address expected, address actual);
    error INVALID_COMMUNITY_DIRECTORY(address expected, address actual);
    error INVALID_COMMUNITY_GOAL_DEPLOYMENT_REGISTRY(address expected, address actual);
    error MANAGED_SAFE_REQUIRED();
    error MANAGED_SAFE_NOT_CONTRACT(address safe);
    error MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH(uint32 budgetPremiumPpm, uint32 budgetSlashPpm);
    error INVALID_DEFAULT_SPEND_POLICY(address policy);
    error INVALID_SUCCESS_RESOLVER(address resolver);

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
        address managedBudgetControllerImplementation,
        address managedGoalAllocatorStrategyImplementation,
        address managedBudgetChildStrategyFactoryImplementation,
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
        if (managedBudgetControllerImplementation == address(0)) revert ADDRESS_ZERO();
        if (managedGoalAllocatorStrategyImplementation == address(0)) revert ADDRESS_ZERO();
        if (managedBudgetChildStrategyFactoryImplementation == address(0)) revert ADDRESS_ZERO();
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
        if (managedBudgetControllerImplementation.code.length == 0) {
            revert NOT_A_CONTRACT(managedBudgetControllerImplementation);
        }
        if (managedGoalAllocatorStrategyImplementation.code.length == 0) {
            revert NOT_A_CONTRACT(managedGoalAllocatorStrategyImplementation);
        }
        if (managedBudgetChildStrategyFactoryImplementation.code.length == 0) {
            revert NOT_A_CONTRACT(managedBudgetChildStrategyFactoryImplementation);
        }
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
        address budgetStackDeployerImplementation = budgetTcrFactory.stackDeployerImplementation();
        if (budgetStackDeployerImplementation == address(0)) revert ADDRESS_ZERO();
        if (budgetStackDeployerImplementation.code.length == 0) {
            revert NOT_A_CONTRACT(budgetStackDeployerImplementation);
        }
        address authorizedCaller = budgetTcrFactory.authorizedCaller();
        if (authorizedCaller != address(this)) {
            revert INVALID_BUDGET_TCR_FACTORY_CALLER(address(this), authorizedCaller);
        }
        _requireValidDefaultSpendPolicy(defaultGoalSpendPolicy);
        _requireValidDefaultSpendPolicy(defaultBudgetSpendPolicy);
        _validateGoalTerminalConfig(revDeployer, goalDeploymentRegistry, goalPaymentTerminal);

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
        OPEN_BUDGET_GATE_POLICY = openBudgetGatePolicy;

        DEFAULT_GOAL_SPEND_POLICY = defaultGoalSpendPolicy;
        DEFAULT_BUDGET_SPEND_POLICY = defaultBudgetSpendPolicy;
        DEFAULT_SUBMISSION_DEPOSIT_STRATEGY = defaultSubmissionDepositStrategy;
        DEFAULT_ALLOCATION_MECHANISM_ADMIN = defaultAllocationMechanismAdmin;
        DEFAULT_INVALID_ROUND_REWARDS_SINK = defaultInvalidRoundRewardsSink;
    }

    function deployOpenGoalForCommunity(
        ICommunityGoalRegistry registry,
        OpenGoalParams calldata p
    ) external returns (DeployedGoalStack memory out) {
        OpenGoalParams memory params = p;
        params.common.funding = _communityFundingContext(registry);
        out = _deployOpenGoal(params);
    }

    function deployManagedGoalForCommunity(
        ICommunityGoalRegistry registry,
        ManagedGoalParams calldata p
    ) external returns (DeployedGoalStack memory out) {
        ManagedGoalParams memory params = p;
        params.common.funding = _communityFundingContext(registry);
        out = _deployManagedGoal(params);
    }

    function deployOpenGoal(OpenGoalParams calldata p) external returns (DeployedGoalStack memory out) {
        OpenGoalParams memory params = p;
        out = _deployOpenGoal(params);
    }

    function deployManagedGoal(ManagedGoalParams calldata p) external returns (DeployedGoalStack memory out) {
        ManagedGoalParams memory params = p;
        out = _deployManagedGoal(params);
    }

    function _communityFundingContext(
        ICommunityGoalRegistry registry
    ) private view returns (FundingContext memory funding) {
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

        funding = FundingContext({
            paymentToken: registry.communityToken(),
            paymentRevnetId: registry.communityRevnetId()
        });
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

    function _requireValidSuccessResolver(address resolver) private view {
        if (resolver.code.length == 0) revert NOT_A_CONTRACT(resolver);
        if (!SuccessResolverValidationLib.passesValidationProbe(resolver)) {
            revert INVALID_SUCCESS_RESOLVER(resolver);
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

    function _validateCommonGoalConfig(CommonGoalParams memory common) private view returns (CommonGoalParams memory) {
        if (common.revnet.durationSeconds == 0) revert INVALID_DURATION();
        if (common.revnet.reservedPercent > FlowProtocolConstants.BPS_SCALE) revert INVALID_RESERVED_PERCENT();
        if (common.revnet.cashOutTaxRate > FlowProtocolConstants.BPS_SCALE) revert INVALID_TAX_RATE();

        if (common.success.successResolver == address(0)) revert ADDRESS_ZERO();
        _requireValidSuccessResolver(common.success.successResolver);
        if (
            common.success.successAssertionLiveness == 0 ||
            common.success.successOracleSpecHash == bytes32(0) ||
            common.success.successAssertionPolicyHash == bytes32(0)
        ) {
            revert INVALID_ASSERTION_CONFIG();
        }

        common.goalSpendPolicy = _resolveSpendPolicyOrDefault(common.goalSpendPolicy, DEFAULT_GOAL_SPEND_POLICY);
        return common;
    }

    function _validateManagedGoalConfig(ManagedGoalParams memory params) private view {
        if (params.managedSafe == address(0)) revert MANAGED_SAFE_REQUIRED();
        if (params.managedSafe.code.length == 0) revert MANAGED_SAFE_NOT_CONTRACT(params.managedSafe);
        if (params.budgetRuntime.oracleBounds.liveness == 0) revert INVALID_ASSERTION_CONFIG();
    }

    function _validateBudgetRuntime(
        BudgetRuntimeParams memory budgetRuntime
    ) private view returns (BudgetRuntimeParams memory) {
        if (budgetRuntime.budgetSuccessResolver == address(0)) revert ADDRESS_ZERO();
        _requireValidSuccessResolver(budgetRuntime.budgetSuccessResolver);
        budgetRuntime.budgetSpendPolicy = _resolveSpendPolicyOrDefault(
            budgetRuntime.budgetSpendPolicy,
            DEFAULT_BUDGET_SPEND_POLICY
        );
        return budgetRuntime;
    }

    function _validateUnderwriting(UnderwritingParams memory underwriting) private pure {
        if (
            underwriting.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE ||
            underwriting.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE
        ) {
            revert INVALID_SCALE();
        }
        if (underwriting.budgetSlashPpm != 0 && underwriting.budgetPremiumPpm == 0) {
            revert INVALID_UNDERWRITING_SLASH_CONFIG(underwriting.budgetPremiumPpm, underwriting.budgetSlashPpm);
        }
    }

    function _validateManagedUnderwriting(UnderwritingParams memory underwriting) private pure {
        if (underwriting.budgetPremiumPpm != 0 || underwriting.budgetSlashPpm != 0) {
            revert MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH(
                underwriting.budgetPremiumPpm,
                underwriting.budgetSlashPpm
            );
        }
    }

    function _prepareSharedDeployment(
        CommonGoalParams memory common
    ) private returns (SharedDeployContext memory shared) {
        (address paymentToken, uint8 paymentTokenDecimals, uint256 paymentRevnetId) = _resolveFundingContext(
            common.funding
        );

        GoalTreasury goalTreasury = GoalTreasury(Clones.clone(GOAL_TREASURY_IMPL));
        GoalRevnetSplitHook splitHook = GoalRevnetSplitHook(payable(Clones.clone(SPLIT_HOOK_IMPL)));
        CustomFlow goalFlow = CustomFlow(payable(Clones.clone(FLOW_IMPL)));
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet = _deployRevnet(
            common,
            splitHook,
            paymentToken,
            paymentTokenDecimals
        );

        shared = SharedDeployContext({
            revnet: revnet,
            core: _deployCoreBase(
                goalTreasury,
                splitHook,
                goalFlow,
                revnet,
                common,
                paymentToken,
                paymentTokenDecimals
            ),
            paymentToken: paymentToken,
            paymentRevnetId: paymentRevnetId,
            minRaiseDeadline: uint64(
                block.timestamp +
                    _resolveMinRaiseWindow(common.revnet.durationSeconds, common.timing.minRaiseDurationSeconds)
            )
        });
    }

    function _deployOpenGoal(OpenGoalParams memory params) private returns (DeployedGoalStack memory out) {
        params.common = _validateCommonGoalConfig(params.common);
        params.budgetRuntime = _validateBudgetRuntime(params.budgetRuntime);
        _validateUnderwriting(params.common.underwriting);

        SharedDeployContext memory shared = _prepareSharedDeployment(params.common);
        address budgetController = BUDGET_TCR_FACTORY.predictBudgetTCRAddress(
            address(this),
            address(shared.core.goalFlow),
            address(shared.core.goalTreasury),
            shared.revnet.goalRevnetId,
            shared.paymentToken
        );
        address goalAllocatorStrategy = address(shared.core.stakeVault);

        shared.core = _finalizeCoreStack(
            params.common,
            shared.core,
            shared.revnet,
            budgetController,
            goalAllocatorStrategy,
            true,
            address(BUDGET_TCR_FACTORY),
            shared.minRaiseDeadline,
            0,
            shared.paymentToken
        );

        BudgetTCRFactory.DeployedBudgetTCRStack memory tcrStack = _deployOpenBudgetTcr(
            params,
            shared.core,
            shared.revnet,
            shared.paymentToken
        );
        if (tcrStack.budgetTCR != budgetController) {
            revert BUDGET_CONTROLLER_ADDRESS_MISMATCH(budgetController, tcrStack.budgetTCR);
        }

        out = _completeGoalDeployment(
            params.common,
            shared,
            goalAllocatorStrategy,
            tcrStack.budgetTCR,
            tcrStack.arbitrator
        );
    }

    function _deployManagedGoal(ManagedGoalParams memory params) private returns (DeployedGoalStack memory out) {
        params.common = _validateCommonGoalConfig(params.common);
        _validateManagedGoalConfig(params);
        params.budgetRuntime = _validateBudgetRuntime(params.budgetRuntime);
        _validateUnderwriting(params.common.underwriting);
        _validateManagedUnderwriting(params.common.underwriting);

        SharedDeployContext memory shared = _prepareSharedDeployment(params.common);
        GoalFactoryManagedPresetDeploy.ManagedPresetBundle memory managedPreset = _bootstrapManagedPreset(
            address(shared.core.goalTreasury)
        );
        address budgetController = address(managedPreset.budgetController);
        address goalAllocatorStrategy = managedPreset.goalAllocatorStrategy;

        shared.core = _finalizeCoreStack(
            params.common,
            shared.core,
            shared.revnet,
            budgetController,
            goalAllocatorStrategy,
            false,
            address(0),
            shared.minRaiseDeadline,
            MANAGED_TERMINAL_ROLLOVER_COOLDOWN,
            shared.paymentToken
        );

        managedPreset.budgetController.initialize(
            IManagedBudgetController.InitConfig({
                authority: params.managedSafe,
                goalTreasury: address(shared.core.goalTreasury),
                goalFlow: address(shared.core.goalFlow),
                stackDeployer: managedPreset.stackDeployer,
                budgetGatePolicy: params.managedBudgetGatePolicy,
                budgetSuccessResolver: params.budgetRuntime.budgetSuccessResolver,
                budgetSpendPolicy: params.budgetRuntime.budgetSpendPolicy,
                successAssertionLiveness: params.budgetRuntime.oracleBounds.liveness,
                successAssertionBond: params.budgetRuntime.oracleBounds.bondAmount
            })
        );

        out = _completeGoalDeployment(params.common, shared, goalAllocatorStrategy, budgetController, address(0));
    }

    function _completeGoalDeployment(
        CommonGoalParams memory common,
        SharedDeployContext memory shared,
        address goalAllocatorStrategy,
        address budgetController,
        address arbitrator
    ) private returns (DeployedGoalStack memory out) {
        GOAL_DEPLOYMENT_REGISTRY.registerGoal(shared.revnet.goalRevnetId, address(shared.core.goalTreasury));

        uint256 actualPaymentRevnetId = shared.core.goalTreasury.cobuildRevnetId();
        address actualPaymentToken = address(shared.core.stakeVault.cobuildToken());
        if (actualPaymentRevnetId != shared.paymentRevnetId || actualPaymentToken != shared.paymentToken) {
            revert INVALID_DEPLOYED_FUNDING_CONTEXT(
                shared.paymentToken,
                actualPaymentToken,
                shared.paymentRevnetId,
                actualPaymentRevnetId
            );
        }

        out = DeployedGoalStack({
            goalRevnetId: shared.revnet.goalRevnetId,
            goalToken: shared.revnet.goalToken,
            goalSuperToken: address(shared.core.goalSuperToken),
            goalTreasury: address(shared.core.goalTreasury),
            goalFlow: address(shared.core.goalFlow),
            goalAllocatorStrategy: goalAllocatorStrategy,
            goalFlowAllocationLedgerPipeline: shared.core.goalFlowAllocationLedgerPipeline,
            stakeVault: address(shared.core.stakeVault),
            budgetStakeLedger: address(shared.core.budgetStakeLedger),
            splitHook: address(shared.core.splitHook),
            jurorSlasherRouter: shared.core.jurorSlasherRouter,
            underwriterSlasherRouter: shared.core.underwriterSlasherRouter,
            successResolver: common.success.successResolver,
            budgetController: budgetController,
            arbitrator: arbitrator
        });

        emit GoalDeployed(msg.sender, shared.revnet.goalRevnetId, out);
    }

    function _deployRevnet(
        CommonGoalParams memory common,
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
                    name: common.revnet.name,
                    ticker: common.revnet.ticker,
                    uri: common.revnet.uri,
                    initialIssuance: common.revnet.initialIssuance,
                    cashOutTaxRate: common.revnet.cashOutTaxRate,
                    reservedPercent: common.revnet.reservedPercent,
                    durationSeconds: common.revnet.durationSeconds,
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
        CommonGoalParams memory common,
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
                    revnetName: common.revnet.name,
                    revnetTicker: common.revnet.ticker
                })
            );
    }

    function _finalizeCoreStack(
        CommonGoalParams memory common,
        GoalFactoryCoreStackDeploy.CoreStackResult memory core,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        address budgetController,
        address goalAllocatorStrategy,
        bool deployJurorSlasherRouter,
        address jurorSlasherAuthority,
        uint64 minRaiseDeadline,
        uint64 terminalRolloverCooldown,
        address paymentToken
    ) private returns (GoalFactoryCoreStackDeploy.CoreStackResult memory) {
        return
            GoalFactoryCoreStackDeploy.finalizeCoreStack(
                core,
                GoalFactoryCoreStackDeploy.CoreFinalizeRequest({
                    goalAllocatorStrategy: goalAllocatorStrategy,
                    budgetController: budgetController,
                    deployJurorSlasherRouter: deployJurorSlasherRouter,
                    jurorSlasherAuthority: jurorSlasherAuthority,
                    jurorSlasherRouterImpl: JUROR_SLASHER_ROUTER_IMPL,
                    underwriterSlasherRouterImpl: UNDERWRITER_SLASHER_ROUTER_IMPL,
                    flowImpl: FLOW_IMPL,
                    goalToken: revnet.goalToken,
                    cobuildToken: paymentToken,
                    goalRevnetId: revnet.goalRevnetId,
                    rulesets: revnet.rulesets,
                    directory: revnet.directory,
                    flowTitle: common.flowMetadata.title,
                    flowDescription: common.flowMetadata.description,
                    flowImage: common.flowMetadata.image,
                    flowTagline: common.flowMetadata.tagline,
                    flowUrl: common.flowMetadata.url,
                    minRaiseDeadline: minRaiseDeadline,
                    minRaise: common.timing.minRaise,
                    budgetPremiumPpm: common.underwriting.budgetPremiumPpm,
                    budgetSlashPpm: common.underwriting.budgetSlashPpm,
                    successResolver: common.success.successResolver,
                    successAssertionLiveness: common.success.successAssertionLiveness,
                    successAssertionBond: common.success.successAssertionBond,
                    successOracleSpecHash: common.success.successOracleSpecHash,
                    successAssertionPolicyHash: common.success.successAssertionPolicyHash,
                    goalSpendPolicy: common.goalSpendPolicy,
                    terminalRolloverCooldown: terminalRolloverCooldown
                })
            );
    }

    function _bootstrapManagedPreset(
        address goalTreasury
    ) private returns (GoalFactoryManagedPresetDeploy.ManagedPresetBundle memory) {
        return
            GoalFactoryManagedPresetDeploy.bootstrapManagedPreset(
                goalTreasury,
                BUDGET_TCR_FACTORY.stackDeployerImplementation(),
                GoalFactoryManagedPresetDeploy.ManagedPresetBootstrapConfig({
                    budgetControllerImplementation: MANAGED_BUDGET_CONTROLLER_IMPL,
                    goalAllocatorStrategyImplementation: MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL,
                    budgetChildStrategyFactoryImplementation: MANAGED_BUDGET_CHILD_STRATEGY_FACTORY_IMPL
                })
            );
    }

    function _deployOpenBudgetTcr(
        OpenGoalParams memory params,
        GoalFactoryCoreStackDeploy.CoreStackResult memory core,
        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory revnet,
        address paymentToken
    ) private returns (BudgetTCRFactory.DeployedBudgetTCRStack memory) {
        IBudgetTCR.RiskModuleRouting memory routing = GoalFactoryBudgetTcrRouting.resolveOpenPresetRouting(
            params.common.underwriting.budgetPremiumPpm,
            params.common.underwriting.budgetSlashPpm,
            OPEN_BUDGET_GATE_POLICY,
            PREMIUM_ESCROW_IMPL,
            core.underwriterSlasherRouter
        );

        return
            GoalFactoryBudgetTcrDeploy.deployBudgetTcrStack(
                GoalFactoryBudgetTcrDeploy.BudgetTcrDeployRequest({
                    budgetTcrFactory: BUDGET_TCR_FACTORY,
                    allocationMechanismAdmin: params.openBudgetTCR.allocationMechanismAdmin,
                    invalidRoundRewardsSink: params.openBudgetTCR.invalidRoundRewardsSink,
                    submissionDepositStrategy: params.openBudgetTCR.submissionDepositStrategy,
                    registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                        arbitratorExtraData: params.openBudgetTCR.arbitratorExtraData,
                        registrationMetaEvidence: params.openBudgetTCR.registrationMetaEvidence,
                        clearingMetaEvidence: params.openBudgetTCR.clearingMetaEvidence,
                        submissionBaseDeposit: params.openBudgetTCR.submissionBaseDeposit,
                        removalBaseDeposit: params.openBudgetTCR.removalBaseDeposit,
                        submissionChallengeBaseDeposit: params.openBudgetTCR.submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit: params.openBudgetTCR.removalChallengeBaseDeposit,
                        challengePeriodDuration: params.openBudgetTCR.challengePeriodDuration
                    }),
                    defaultAllocationMechanismAdmin: DEFAULT_ALLOCATION_MECHANISM_ADMIN,
                    defaultInvalidRoundRewardsSink: DEFAULT_INVALID_ROUND_REWARDS_SINK,
                    defaultSubmissionDepositStrategy: DEFAULT_SUBMISSION_DEPOSIT_STRATEGY,
                    riskModuleRouting: routing,
                    cobuildToken: paymentToken,
                    budgetSuccessResolver: params.budgetRuntime.budgetSuccessResolver,
                    budgetBounds: params.openBudgetTCR.budgetBounds,
                    oracleBounds: params.budgetRuntime.oracleBounds,
                    arbitratorParams: params.openBudgetTCR.arbitratorParams,
                    budgetSpendPolicy: params.budgetRuntime.budgetSpendPolicy,
                    goalFlow: core.goalFlow,
                    goalTreasury: core.goalTreasury,
                    goalToken: revnet.goalToken,
                    goalRulesets: revnet.rulesets,
                    goalRevnetId: revnet.goalRevnetId,
                    budgetPremiumPpm: params.common.underwriting.budgetPremiumPpm,
                    budgetSlashPpm: params.common.underwriting.budgetSlashPpm
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
