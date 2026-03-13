// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";
import {FlowSuperfluidFrameworkDeployer} from "test/utils/FlowSuperfluidFrameworkDeployer.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {
    BudgetTCRTestSuperToken as MockBudgetTCRSuperToken,
    BudgetTCRGoalFlowHarness as MockGoalFlowForBudgetTCR,
    BudgetTCRGoalTreasuryHarness as MockGoalTreasuryForBudgetTCR,
    BudgetTCRChildFlowHarness as MockBudgetChildFlow,
    BudgetTCRRewardEscrowHarness as MockRewardEscrowForBudgetTCR,
    BudgetTCRStakeLedgerHarness as MockBudgetStakeLedgerForBudgetTCR,
    BudgetTCRStakeVaultHarness as MockStakeVaultForBudgetTCR
} from "test/helpers/BudgetTCRSystemHarnesses.sol";
import {BudgetTCRConfigHelpers} from "test/helpers/BudgetTCRConfigHelpers.sol";
import {NoopZeroCoverageBudgetGatePolicy} from "test/helpers/ZeroCoverageBudgetGatePolicies.sol";

import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {BudgetStackDeployer} from "src/goals/BudgetStackDeployer.sol";
import {BudgetTopologyRegistryLib} from "src/goals/library/BudgetTopologyRegistryLib.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {JurorSlasherRouter} from "src/goals/JurorSlasherRouter.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {TeamFlow} from "src/teamflow/TeamFlow.sol";
import {TeamFlowFactory} from "src/teamflow/TeamFlowFactory.sol";

import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IBudgetController} from "src/interfaces/IBudgetController.sol";
import {IBudgetGatePolicy} from "src/interfaces/IBudgetGatePolicy.sol";
import {BudgetStackTypes} from "src/interfaces/BudgetStackTypes.sol";
import {IBudgetStackDeployer} from "src/interfaces/IBudgetStackDeployer.sol";
import {IBudgetStackTopologyReader} from "src/interfaces/IBudgetStackTopologyReader.sol";
import {IBudgetFlowRouterStrategy} from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {
    ERC1820RegistryCompiled
} from "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperToken} from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import {TestToken} from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockUnderwriterSlasherRouter} from "test/mocks/MockUnderwriterSlasherRouter.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";
import {StakeCoverageGatePolicy} from "src/goals/policies/StakeCoverageGatePolicy.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig,
    TreasuryUmaResolverMockFactory
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";

contract BudgetTCRTest is TestUtils, SpendPolicyTestUtils {
    bytes32 internal constant BUDGET_STACK_DEPLOYED_SIG =
        keccak256("BudgetStackDeployed(bytes32,address,address,address)");
    bytes32 internal constant BUDGET_ALLOCATION_MECHANISM_DEPLOYED_SIG =
        keccak256("BudgetAllocationMechanismDeployed(bytes32,address,address,address)");
    bytes32 internal constant BUDGET_STACK_ACTIVATION_QUEUED_SIG = keccak256("BudgetStackActivationQueued(bytes32)");
    bytes32 internal constant BUDGET_STACK_REMOVAL_QUEUED_SIG = keccak256("BudgetStackRemovalQueued(bytes32)");
    bytes32 internal constant BUDGET_STACK_REMOVAL_HANDLED_SIG =
        keccak256("BudgetStackRemovalHandled(bytes32,address,address,bool,bool)");
    bytes32 internal constant BUDGET_STACK_TERMINALIZATION_RETRIED_SIG =
        keccak256("BudgetStackTerminalizationRetried(bytes32,address,bool)");
    bytes32 internal constant BUDGET_TERMINAL_RECIPIENT_PRUNED_SIG =
        keccak256("BudgetTerminalRecipientPruned(bytes32,address,address,bool,bool)");
    bytes32 internal constant BUDGET_TERMINALIZATION_STEP_FAILED_SIG =
        keccak256("BudgetTerminalizationStepFailed(bytes32,address,bytes4,bytes)");
    bytes32 internal constant BUDGET_CONFIGURED_SIG =
        keccak256("BudgetConfigured(address,address,uint64,uint64,uint256,uint256)");
    bytes32 internal constant BUDGET_TREASURY_BATCH_SYNC_ATTEMPTED_SIG =
        keccak256("BudgetTreasuryBatchSyncAttempted(bytes32,address,bool)");
    bytes32 internal constant BUDGET_TREASURY_BATCH_SYNC_SKIPPED_SIG =
        keccak256("BudgetTreasuryBatchSyncSkipped(bytes32,address,bytes32)");
    bytes32 internal constant BUDGET_TREASURY_CALL_FAILED_SIG =
        keccak256("BudgetTreasuryCallFailed(bytes32,address,bytes4,bytes)");
    bytes32 internal constant BUDGET_GATE_ENFORCEMENT_FAILED_SIG =
        keccak256("BudgetGateEnforcementFailed(bytes32,address,address,bytes4,bytes)");
    bytes32 internal constant SYNC_SKIP_NO_BUDGET_TREASURY = "NO_BUDGET_TREASURY";
    bytes32 internal constant SYNC_SKIP_STACK_INACTIVE = "STACK_INACTIVE";

    MockVotesToken internal depositToken;
    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;

    MockBudgetTCRSuperToken internal superToken;
    MockGoalFlowForBudgetTCR internal goalFlow;
    MockGoalTreasuryForBudgetTCR internal goalTreasury;
    MockBudgetStakeLedgerForBudgetTCR internal budgetStakeLedger;

    BudgetTCR internal budgetTcr;
    ERC20VotesArbitrator internal arbitrator;
    address internal stackDeployer;
    address internal premiumEscrowImplementation;
    address internal underwriterSlasherRouter;
    address internal budgetSuccessResolver;
    address internal budgetSpendPolicy;
    address internal budgetGatePolicy;

    function onBudgetStackDeployed(bytes32, address, address, address, address) external pure {}

    function onBudgetAllocationMechanismDeployed(bytes32, address, address, address) external pure {}

    address internal owner = makeAddr("owner");
    address internal allocationMechanismAdmin = makeAddr("allocation-mechanism-admin");
    address internal requester = makeAddr("requester");
    address internal managerRewardPool = makeAddr("managerRewardPool");

    uint256 internal votingPeriod = 20;
    uint256 internal votingDelay = 2;
    uint256 internal revealPeriod = 15;
    uint256 internal arbitrationCost = 10e18;

    uint256 internal submissionBaseDeposit = 100e18;
    uint256 internal removalBaseDeposit = 50e18;
    uint256 internal submissionChallengeBaseDeposit = 120e18;
    uint256 internal removalChallengeBaseDeposit = 70e18;
    uint256 internal challengePeriodDuration = 3 days;
    ISubmissionDepositStrategy internal submissionDepositStrategy;

    function setUp() public {
        depositToken = new MockVotesToken("BudgetTCR Votes", "BTV");
        goalToken = new MockVotesToken("GOAL", "GOAL");
        cobuildToken = new MockVotesToken("COBUILD", "COB");
        submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(depositToken)))));

        depositToken.mint(requester, 1_000_000e18);

        superToken = new MockBudgetTCRSuperToken();
        goalFlow = new MockGoalFlowForBudgetTCR(
            address(this), address(this), managerRewardPool, ISuperToken(address(superToken))
        );
        goalTreasury = new MockGoalTreasuryForBudgetTCR(uint64(block.timestamp + 120 days));
        budgetStakeLedger = new MockBudgetStakeLedgerForBudgetTCR();
        goalTreasury.setRewardEscrow(address(new MockRewardEscrowForBudgetTCR(address(budgetStakeLedger))));
        goalTreasury.setFlow(address(goalFlow));
        goalTreasury.setStakeVault(address(new MockStakeVaultForBudgetTCR(address(goalTreasury))));
        premiumEscrowImplementation = address(new PremiumEscrow());
        underwriterSlasherRouter = address(new MockUnderwriterSlasherRouter(address(this), goalTreasury.stakeVault()));
        budgetSuccessResolver = address(TreasuryUmaResolverMockFactory.deployResolver(IERC20(address(goalToken))));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));
        budgetGatePolicy = address(new StakeCoverageGatePolicy());

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(_deployBudgetTcrDeployer());
        _initializeOpenBudgetTcrDeployer(BudgetStackDeployer(stackDeployer), tcrInstance, premiumEscrowImplementation);

        bytes memory arbInit = _defaultArbitratorInitData(
            owner, address(depositToken), tcrInstance, votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address arbProxy = _deployProxy(address(arbImpl), arbInit);

        arbitrator = ERC20VotesArbitrator(arbProxy);
        budgetTcr = BudgetTCR(tcrInstance);

        budgetTcr.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());

        goalFlow.setRecipientAdmin(address(budgetTcr));
    }

    function test_initialize_reverts_when_called_on_implementation() public {
        BudgetTCR implementation = new BudgetTCR();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());
    }

    function test_initialize_reverts_when_called_twice_on_proxy() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        budgetTcr.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());
    }

    function test_initialize_reverts_when_stack_deployer_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.stackDeployer = address(0);

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_stack_deployer_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        address noCodeStackDeployer = makeAddr("no-code-stack-deployer");
        deploymentConfig.stackDeployer = noCodeStackDeployer;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.NOT_A_CONTRACT.selector, noCodeStackDeployer));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_discovery_emitter_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.discoveryEmitter = address(0);

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_discovery_emitter_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        address noCodeDiscoveryEmitter = makeAddr("no-code-discovery-emitter");
        deploymentConfig.discoveryEmitter = noCodeDiscoveryEmitter;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.NOT_A_CONTRACT.selector, noCodeDiscoveryEmitter));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_spend_policy_is_invalid() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetSpendPolicy = address(new BudgetTCRNonSpendPolicy());

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_SPEND_POLICY.selector, deploymentConfig.budgetSpendPolicy)
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_success_resolver_returns_invalid_uma_dependencies() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetSuccessResolver = address(
            new TreasuryMockUmaResolverConfig(
                OptimisticOracleV3Interface(address(new TreasuryMockOptimisticOracleV3())), IERC20(address(0))
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_SUCCESS_RESOLVER.selector, deploymentConfig.budgetSuccessResolver)
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_spend_policy_rejects_active_context() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetSpendPolicy = address(new BudgetTCRZeroContextOnlySpendPolicy());

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_SPEND_POLICY.selector, deploymentConfig.budgetSpendPolicy)
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_spend_policy_reports_invalid_sync_mode() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetSpendPolicy = address(new BudgetTCRInvalidSyncModeSpendPolicy());

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_SPEND_POLICY.selector, deploymentConfig.budgetSpendPolicy)
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_spend_policy_reports_malformed_sync_mode_abi() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetSpendPolicy = address(new BudgetTCRMalformedSyncModeAbiSpendPolicy());

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_SPEND_POLICY.selector, deploymentConfig.budgetSpendPolicy)
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_flow_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalFlow = IFlow(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_treasury_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalTreasury = IGoalTreasury(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_token_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalToken = IERC20(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_cobuild_token_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.cobuildToken = IERC20(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_allocation_mechanism_admin_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        registryConfig.allocationMechanismAdmin = address(0);

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_rulesets_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalRulesets = IJBRulesets(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_premium_escrow_implementation_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = address(0);

        vm.expectRevert(IBudgetTCR.PREMIUM_MODULE_ABSENCE_REQUIRES_ZERO_RATES.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_premium_escrow_implementation_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        address noCodePremiumEscrowImplementation = makeAddr("no-code-premium-escrow-implementation");
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = noCodePremiumEscrowImplementation;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION.selector, noCodePremiumEscrowImplementation
            )
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_gate_policy_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        address noCodeBudgetGatePolicy = makeAddr("no-code-budget-gate-policy");
        deploymentConfig.riskModuleRouting.budgetGatePolicy = noCodeBudgetGatePolicy;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_GATE_POLICY.selector, noCodeBudgetGatePolicy));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_gate_policy_does_not_implement_interface() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        address invalidBudgetGatePolicy = address(new BudgetTCRNonSpendPolicy());
        deploymentConfig.riskModuleRouting.budgetGatePolicy = invalidBudgetGatePolicy;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_GATE_POLICY.selector, invalidBudgetGatePolicy));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_setUp_uses_configured_budget_gate_policy() public view {
        assertEq(budgetTcr.budgetGatePolicy(), budgetGatePolicy);
    }

    function test_initialize_reverts_when_budget_gate_policy_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_allows_zero_budget_gate_policy_when_budget_slash_ppm_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetSlashPpm = 0;

        freshTcr.initialize(registryConfig, deploymentConfig);

        assertEq(freshTcr.budgetGatePolicy(), address(0));
    }

    function test_initialize_reverts_when_zero_slash_budget_gate_policy_disables_zero_coverage() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();
        deploymentConfig.budgetSlashPpm = 0;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_GATE_POLICY.selector, budgetGatePolicy));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_allows_zero_slash_budget_gate_policy_that_is_zero_coverage_compatible() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(new NoopZeroCoverageBudgetGatePolicy());
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetSlashPpm = 0;

        freshTcr.initialize(registryConfig, deploymentConfig);

        assertEq(freshTcr.budgetGatePolicy(), deploymentConfig.riskModuleRouting.budgetGatePolicy);
    }

    function test_initialize_reverts_when_zero_slash_budget_gate_policy_only_special_cases_probe() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(new BudgetTCRProbeAwareZeroCoverageGatePolicy());
        deploymentConfig.budgetSlashPpm = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetTCR.INVALID_BUDGET_GATE_POLICY.selector, deploymentConfig.riskModuleRouting.budgetGatePolicy
            )
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_slash_enabled_underwriter_slasher_router_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);

        vm.expectRevert(IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_slash_enabled_underwriter_slasher_router_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = makeAddr("no-code-underwriter-slasher-router");

        vm.expectRevert(IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_allows_premium_only_config_without_underwriter_router() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetSlashPpm = 0;

        freshTcr.initialize(registryConfig, deploymentConfig);

        assertEq(
            IBudgetStackDeployer(freshTcr.stackDeployer()).stackModuleConfig().premiumEscrowImplementation,
            deploymentConfig.riskModuleRouting.premiumEscrowImplementation
        );
        assertEq(freshTcr.underwriterSlasherRouter(), address(0));
    }

    function test_initialize_reverts_when_absent_premium_wiring_has_nonzero_rates() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);

        vm.expectRevert(IBudgetTCR.PREMIUM_MODULE_ABSENCE_REQUIRES_ZERO_RATES.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_zero_rate_routing_keeps_premium_escrow_implementation() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer).initializeWithConfig(address(freshTcr), _noPremiumStackModuleConfig());
        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;

        vm.expectRevert(IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_zero_rate_routing_keeps_underwriter_router() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer).initializeWithConfig(address(freshTcr), _noPremiumStackModuleConfig());
        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;

        vm.expectRevert(IBudgetTCR.UNDERWRITER_SLASHER_CONFIG_MISMATCH.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_stack_deployer_controller_does_not_match_budgetTcr() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer)
            .initializeWithConfig(
                makeAddr("wrong-budget-controller"),
                _openStackModuleConfig(deploymentConfig.riskModuleRouting.premiumEscrowImplementation)
            );
        deploymentConfig.stackDeployer = freshStackDeployer;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.INVALID_STACK_DEPLOYER.selector, freshStackDeployer));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_stack_deployer_tuple_mismatches_open_preset() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer)
            .initializeWithConfig(
                address(freshTcr),
                BudgetStackTypes.StackModuleConfig({
                childFlowStrategyMode: BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter,
                childFlowStrategyTarget: address(0),
                mechanismLayerMode: BudgetStackTypes.MechanismLayerMode.None,
                childFlowRecipientAdmin: address(this),
                premiumEscrowImplementation: deploymentConfig.riskModuleRouting.premiumEscrowImplementation
            })
            );
        deploymentConfig.stackDeployer = freshStackDeployer;

        vm.expectRevert(IBudgetTCR.STACK_MODULE_CONFIG_MISMATCH.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_stack_deployer_omits_premium_module_for_present_config() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer).initializeWithConfig(address(freshTcr), _noPremiumStackModuleConfig());
        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;

        vm.expectRevert(IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_stack_deployer_provides_premium_module_for_absent_config() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;

        vm.expectRevert(IBudgetTCR.STACK_MODULE_CONFIG_MISMATCH.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_premium_ppm_exceeds_scale() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        uint32 invalidBudgetPremiumPpm = 1_000_001;
        deploymentConfig.budgetPremiumPpm = invalidBudgetPremiumPpm;

        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.INVALID_PPM.selector, invalidBudgetPremiumPpm));
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_treasury_budget_stake_ledger_unset() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        goalTreasury.setBudgetStakeLedger(address(0));

        vm.expectRevert(IBudgetTCR.BUDGET_STAKE_LEDGER_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_max_execution_duration_lt_min_execution_duration() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetValidationBounds.maxExecutionDuration =
            deploymentConfig.budgetValidationBounds.minExecutionDuration - 1;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_max_activation_threshold_lt_min_activation_threshold() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetValidationBounds.maxActivationThreshold =
            deploymentConfig.budgetValidationBounds.minActivationThreshold - 1;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_oracle_liveness_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.oracleValidationBounds.liveness = 0;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_oracle_bond_amount_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.oracleValidationBounds.bondAmount = 0;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_allocationMechanismAdmin_is_init_only_with_no_direct_setter() public {
        address initialAllocationMechanismAdmin = budgetTcr.allocationMechanismAdmin();

        (bool success, bytes memory revertData) = address(budgetTcr)
            .call(abi.encodeWithSignature("setAllocationMechanismAdmin(address)", makeAddr("new-admin")));
        assertFalse(success);
        assertEq(revertData.length, 0);

        vm.prank(allocationMechanismAdmin);
        (bool governorSuccess, bytes memory governorRevertData) = address(budgetTcr)
            .call(abi.encodeWithSignature("setAllocationMechanismAdmin(address)", makeAddr("another-admin")));
        assertFalse(governorSuccess);
        assertEq(governorRevertData.length, 0);

        assertEq(budgetTcr.allocationMechanismAdmin(), initialAllocationMechanismAdmin);
    }

    function test_setMetaEvidenceURIs_has_no_direct_setter() public {
        string memory beforeRegistration = budgetTcr.registrationMetaEvidence();
        string memory beforeClearing = budgetTcr.clearingMetaEvidence();

        vm.prank(allocationMechanismAdmin);
        (bool success, bytes memory revertData) = address(budgetTcr)
            .call(abi.encodeWithSignature("setMetaEvidenceURIs(string,string)", "ipfs://new-reg", "ipfs://new-clear"));
        assertFalse(success);
        assertEq(revertData.length, 0);

        assertEq(budgetTcr.registrationMetaEvidence(), beforeRegistration);
        assertEq(budgetTcr.clearingMetaEvidence(), beforeClearing);
    }

    function test_metaEvidenceUpdates_getter_selector_is_removed() public {
        (bool success, bytes memory revertData) =
            address(budgetTcr).call(abi.encodeWithSignature("metaEvidenceUpdates()"));
        assertFalse(success);
        assertEq(revertData.length, 0);

        vm.prank(allocationMechanismAdmin);
        (bool governorSuccess, bytes memory governorRevertData) =
            address(budgetTcr).call(abi.encodeWithSignature("metaEvidenceUpdates()"));
        assertFalse(governorSuccess);
        assertEq(governorRevertData.length, 0);
    }

    function test_requestMetaEvidenceIDs_useRegistrationThenClearing_andRejectExactRelistAfterDeployment() public {
        IBudgetTCR.BudgetListing memory listing = _defaultListing();

        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, listing);

        (,,,,,,,,, uint256 registrationMetaEvidenceID) = budgetTcr.getRequestInfo(itemID, 0);
        assertEq(registrationMetaEvidenceID, 0);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        budgetTcr.activateRegisteredBudget(itemID);

        _approveRemoveCost(requester);
        vm.prank(requester);
        budgetTcr.removeItem(itemID, "");

        (,,,,,,,,, uint256 clearingMetaEvidenceID) = budgetTcr.getRequestInfo(itemID, 1);
        assertEq(clearingMetaEvidenceID, 1);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        _approveAddCost(requester);
        vm.expectRevert(abi.encodeWithSelector(IBudgetTCR.ITEM_RELIST_NOT_ALLOWED.selector, itemID));
        vm.prank(requester);
        budgetTcr.addItem(abi.encode(listing));
    }

    function test_addItem_reverts_when_listing_invalid() public {
        _approveAddCost(requester);

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        listing.fundingDeadline = uint64(block.timestamp + 10 minutes);

        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        vm.prank(requester);
        budgetTcr.addItem(abi.encode(listing));
    }

    function test_addItem_reverts_when_goal_terminal() public {
        _approveAddCost(requester);
        goalTreasury.setResolved(true);
        bytes memory item = abi.encode(_defaultListing());
        bytes32 itemID = keccak256(item);

        vm.expectRevert(IBudgetTCR.GOAL_TERMINAL.selector);
        vm.prank(requester);
        budgetTcr.addItem(item);

        (, IGeneralizedTCR.Status status,) = budgetTcr.getItemInfo(itemID);
        assertEq(uint8(status), uint8(IGeneralizedTCR.Status.Absent));
    }

    function test_executeRequest_queues_budget_activation_and_activateRegisteredBudget_deploys_stack() public {
        assertEq(goalFlow.recipientAdmin(), address(budgetTcr));

        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        assertTrue(budgetTcr.isRegistrationPending(itemID));
        assertFalse(budgetTcr.isRemovalPending(itemID));
        assertEq(budgetStakeLedger.registerCallCount(), 0);

        vm.recordLogs();
        budgetTcr.activateRegisteredBudget(itemID);
        Vm.Log[] memory activationLogs = vm.getRecordedLogs();

        assertFalse(budgetTcr.isRegistrationPending(itemID));
        assertEq(goalFlow.recipientAdmin(), address(budgetTcr));
        (address childFlow, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
        assertTrue(childFlow != address(0));

        address allocationMechanism = MockBudgetChildFlow(childFlow).recipientAdmin();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        assertTrue(allocationMechanism != address(0));
        assertTrue(budgetTreasury != address(0));
        assertTrue(premiumEscrow != address(0));
        assertEq(MockBudgetChildFlow(childFlow).flowOperator(), budgetTreasury);
        assertEq(MockBudgetChildFlow(childFlow).sweeper(), budgetTreasury);
        assertEq(MockBudgetChildFlow(childFlow).managerRewardPool(), premiumEscrow);
        assertEq(MockBudgetChildFlow(childFlow).managerRewardPoolFlowRatePpm(), 100_000);
        assertTrue(MockUnderwriterSlasherRouter(underwriterSlasherRouter).isAuthorizedPremiumEscrow(premiumEscrow));
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);
        assertEq(budgetStakeLedger.registerCallCount(), 1);
        assertEq(budgetStakeLedger.removeCallCount(), 0);

        (bool deployedFound, uint256 deployedIndex) =
            _findBudgetStackDeployedLogIndex(activationLogs, itemID, childFlow, budgetTreasury);
        (bool configuredFound, uint256 configuredIndex) = _findBudgetConfiguredLogIndex(activationLogs, budgetTreasury);
        assertTrue(deployedFound);
        assertTrue(configuredFound);
        assertLt(configuredIndex, deployedIndex);

        uint256 requesterBefore = depositToken.balanceOf(requester);
        budgetTcr.withdrawFeesAndRewards(requester, itemID, 0, 0);
        assertEq(depositToken.balanceOf(requester) - requesterBefore, arbitrationCost);
    }

    function test_activateRegisteredBudget_routesChildManagerRewardToPremiumEscrow() public {
        goalFlow.setManagerRewardPoolFlowRatePpm(250_000);

        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        budgetTcr.activateRegisteredBudget(itemID);

        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        address managerRewardDistributionPool = address(MockBudgetChildFlow(childFlow).managerRewardDistributionPool());

        assertEq(MockBudgetChildFlow(childFlow).managerRewardPool(), premiumEscrow);
        assertEq(MockBudgetChildFlow(childFlow).managerRewardPoolFlowRatePpm(), 100_000);
        assertEq(address(PremiumEscrow(premiumEscrow).managerRewardPool()), managerRewardDistributionPool);
        assertEq(PremiumEscrow(premiumEscrow).accountedManagerRewardReceived(), 0);
    }

    function test_activateRegisteredBudget_deploys_stack_without_premium_module_when_explicit_absence_mode() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer).initializeWithConfig(address(freshTcr), _noPremiumStackModuleConfig());

        ERC20VotesArbitrator freshArbImpl = new ERC20VotesArbitrator();
        bytes memory freshArbInit = _defaultArbitratorInitData(
            owner, address(depositToken), address(freshTcr), votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address freshArbProxy = _deployProxy(address(freshArbImpl), freshArbInit);

        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;
        registryConfig.tcrConfig.arbitrator = IArbitrator(freshArbProxy);

        freshTcr.initialize(registryConfig, deploymentConfig);
        goalFlow.setRecipientAdmin(address(freshTcr));

        (uint256 addCost,,,,) = freshTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(freshTcr), addCost);

        vm.prank(requester);
        bytes32 itemID = freshTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        freshTcr.executeRequest(itemID);
        freshTcr.activateRegisteredBudget(itemID);

        (address childFlow, bool removed) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            freshTcr.budgetStackTopology(itemID);

        assertFalse(removed);
        assertTrue(active);
        assertEq(topology.childFlow, childFlow);
        assertEq(topology.budgetTreasury, budgetTreasury);
        assertEq(topology.premiumEscrow, address(0));
        assertEq(IBudgetTreasury(budgetTreasury).premiumEscrow(), address(0));
        assertEq(MockBudgetChildFlow(childFlow).managerRewardPool(), address(0));
        assertEq(MockBudgetChildFlow(childFlow).managerRewardPoolFlowRatePpm(), 0);
        assertEq(budgetStakeLedger.registerCallCount(), 1);
    }

    function test_syncBudgetTreasuries_permissionless_openNoGateConfig_skipsBudgetGateHook() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer).initializeWithConfig(address(freshTcr), _noPremiumStackModuleConfig());

        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;

        freshTcr.initialize(registryConfig, deploymentConfig);
        goalFlow.setRecipientAdmin(address(freshTcr));

        (uint256 addCost,,,,) = freshTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(freshTcr), addCost);

        vm.prank(requester);
        bytes32 itemID = freshTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        freshTcr.executeRequest(itemID);
        freshTcr.activateRegisteredBudget(itemID);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = freshTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertFalse(_hasBudgetGateEnforcementFailed(logs, address(freshTcr)));
    }

    function test_activateRegisteredBudget_setsConfiguredBudgetSpendPolicyOnBudgetTreasury() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        assertEq(budgetTcr.budgetSpendPolicy(), budgetSpendPolicy);
        assertEq(IBudgetTreasury(budgetTreasury).spendPolicy(), budgetSpendPolicy);
    }

    function test_activateRegisteredBudget_initializesAllocationMechanismWithRegistryConfig() public {
        bytes32 itemID = _registerDefaultListing();

        (address childFlow,) = goalFlow.recipients(itemID);
        AllocationMechanismTCR allocationMechanism =
            AllocationMechanismTCR(MockBudgetChildFlow(childFlow).recipientAdmin());
        BudgetStackDeployer deployer = BudgetStackDeployer(stackDeployer);
        address[] memory initialFactories = allocationMechanism.initialMechanismFactories();

        assertTrue(address(allocationMechanism.arbitrator()) != address(0));
        assertEq(allocationMechanism.factoryManager(), allocationMechanismAdmin);
        assertEq(allocationMechanism.arbitratorExtraData(), bytes(""));
        assertEq(allocationMechanism.registrationMetaEvidence(), "ipfs://budget-reg-meta");
        assertEq(allocationMechanism.clearingMetaEvidence(), "ipfs://budget-clear-meta");
        assertEq(address(allocationMechanism.erc20()), address(depositToken));
        assertEq(address(allocationMechanism.submissionDepositStrategy()), address(submissionDepositStrategy));
        assertEq(allocationMechanism.submissionBaseDeposit(), submissionBaseDeposit);
        assertEq(allocationMechanism.removalBaseDeposit(), removalBaseDeposit);
        assertEq(allocationMechanism.submissionChallengeBaseDeposit(), submissionChallengeBaseDeposit);
        assertEq(allocationMechanism.removalChallengeBaseDeposit(), removalChallengeBaseDeposit);
        assertEq(allocationMechanism.challengePeriodDuration(), challengePeriodDuration);
        assertEq(initialFactories.length, 2);
        assertEq(initialFactories[0], deployer.roundFactory());
        assertEq(initialFactories[1], deployer.teamFlowFactory());
        assertTrue(allocationMechanism.mechanismFactoryAllowed(deployer.roundFactory()));
        assertTrue(allocationMechanism.mechanismFactoryAllowed(deployer.teamFlowFactory()));
    }

    function test_activateRegisteredBudget_exposesCanonicalTopologyAndReverseLookups() public {
        bytes32 itemID = _registerDefaultListing();

        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        address allocationMechanism = MockBudgetChildFlow(childFlow).recipientAdmin();
        address allocationMechanismArbitrator = address(AllocationMechanismTCR(allocationMechanism).arbitrator());
        IAllocationStrategy childStrategy = IFlow(childFlow).strategy();

        IBudgetStackTopologyReader.BudgetStackTopology memory expectedTopology =
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: childFlow,
                budgetTreasury: budgetTreasury,
                premiumEscrow: premiumEscrow,
                strategy: address(childStrategy),
                allocationMechanism: allocationMechanism,
                allocationMechanismArbitrator: allocationMechanismArbitrator
            });

        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            budgetTcr.budgetStackTopology(itemID);
        assertTrue(active);
        _assertBudgetStackTopology(topology, expectedTopology);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyByTreasury, bool activeByTreasury) =
            budgetTcr.budgetStackTopologyForBudgetTreasury(budgetTreasury);
        assertTrue(activeByTreasury);
        _assertBudgetStackTopology(topologyByTreasury, expectedTopology);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyByChildFlow, bool activeByChildFlow) =
            budgetTcr.budgetStackTopologyForChildFlow(childFlow);
        assertTrue(activeByChildFlow);
        _assertBudgetStackTopology(topologyByChildFlow, expectedTopology);

        assertEq(budgetTcr.itemIdForBudgetTreasury(budgetTreasury), itemID);
        assertEq(budgetTcr.itemIdForChildFlow(childFlow), itemID);

        address unknownBudgetTreasury = makeAddr("unknown-budget-treasury");
        address unknownChildFlow = makeAddr("unknown-child-flow");
        (IBudgetStackTopologyReader.BudgetStackTopology memory missingBudgetTopology, bool missingBudgetActive) =
            budgetTcr.budgetStackTopologyForBudgetTreasury(unknownBudgetTreasury);
        (IBudgetStackTopologyReader.BudgetStackTopology memory missingChildTopology, bool missingChildActive) =
            budgetTcr.budgetStackTopologyForChildFlow(unknownChildFlow);

        assertFalse(missingBudgetActive);
        assertFalse(missingChildActive);
        assertEq(missingBudgetTopology.budgetTreasury, address(0));
        assertEq(missingChildTopology.childFlow, address(0));
        assertEq(budgetTcr.itemIdForBudgetTreasury(unknownBudgetTreasury), bytes32(0));
        assertEq(budgetTcr.itemIdForChildFlow(unknownChildFlow), bytes32(0));
    }

    function test_openBudgetControllerInterface_exposesTopologyAndBatchSync() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        IBudgetController controller = IBudgetController(address(budgetTcr));
        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            controller.budgetStackTopologyForBudgetTreasury(budgetTreasury);
        assertTrue(active);
        assertEq(topology.childFlow, childFlow);
        assertEq(topology.budgetTreasury, budgetTreasury);
        assertEq(controller.itemIdForBudgetTreasury(budgetTreasury), itemID);
        assertEq(controller.itemIdForChildFlow(childFlow), itemID);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;
        (uint256 attempted, uint256 succeeded) = controller.syncBudgetTreasuries(itemIDs);
        assertEq(attempted, 1);
        assertEq(succeeded, 1);
    }

    function test_budgetControllerTopology_readsAllowZeroMechanismModules() public {
        BudgetTCRTopologyHarness harness = new BudgetTCRTopologyHarness();
        bytes32 itemID = keccak256("managed-budget-topology");
        address childFlow = makeAddr("managed-child-flow");
        address budgetTreasury = makeAddr("managed-budget-treasury");
        address premiumEscrow = makeAddr("managed-premium-escrow");
        address strategy = makeAddr("managed-budget-strategy");
        IBudgetStackTopologyReader.BudgetStackTopology memory expectedTopology =
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: childFlow,
                budgetTreasury: budgetTreasury,
                premiumEscrow: premiumEscrow,
                strategy: strategy,
                allocationMechanism: address(0),
                allocationMechanismArbitrator: address(0)
            });

        harness.seedBudgetStackTopology(itemID, expectedTopology, true);

        IBudgetController controller = IBudgetController(address(harness));
        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            controller.budgetStackTopology(itemID);
        assertTrue(active);
        _assertBudgetStackTopology(topology, expectedTopology);

        (IBudgetStackTopologyReader.BudgetStackTopology memory byTreasury, bool treasuryActive) =
            controller.budgetStackTopologyForBudgetTreasury(budgetTreasury);
        assertTrue(treasuryActive);
        _assertBudgetStackTopology(byTreasury, expectedTopology);

        (IBudgetStackTopologyReader.BudgetStackTopology memory byChildFlow, bool childFlowActive) =
            controller.budgetStackTopologyForChildFlow(childFlow);
        assertTrue(childFlowActive);
        _assertBudgetStackTopology(byChildFlow, expectedTopology);
        assertEq(controller.itemIdForBudgetTreasury(budgetTreasury), itemID);
        assertEq(controller.itemIdForChildFlow(childFlow), itemID);
    }

    function test_budgetControllerTopology_readsIgnoreStaleReverseIndexes() public {
        BudgetTCRTopologyHarness harness = new BudgetTCRTopologyHarness();
        bytes32 itemID = keccak256("canonical-budget-topology");
        address childFlow = makeAddr("canonical-child-flow");
        address budgetTreasury = makeAddr("canonical-budget-treasury");
        address staleBudgetTreasury = makeAddr("stale-budget-treasury");
        address staleChildFlow = makeAddr("stale-child-flow");
        IBudgetStackTopologyReader.BudgetStackTopology memory topology = IBudgetStackTopologyReader.BudgetStackTopology({
            childFlow: childFlow,
            budgetTreasury: budgetTreasury,
            premiumEscrow: makeAddr("canonical-premium-escrow"),
            strategy: makeAddr("canonical-budget-strategy"),
            allocationMechanism: address(0),
            allocationMechanismArbitrator: address(0)
        });

        harness.seedBudgetStackTopology(itemID, topology, true);
        harness.seedStaleReverseIndexes(itemID, staleBudgetTreasury, staleChildFlow);

        IBudgetController controller = IBudgetController(address(harness));
        (IBudgetStackTopologyReader.BudgetStackTopology memory staleBudgetTopology, bool budgetActive) =
            controller.budgetStackTopologyForBudgetTreasury(staleBudgetTreasury);
        (IBudgetStackTopologyReader.BudgetStackTopology memory staleChildTopology, bool childFlowActive) =
            controller.budgetStackTopologyForChildFlow(staleChildFlow);

        assertFalse(budgetActive);
        assertFalse(childFlowActive);
        assertEq(staleBudgetTopology.budgetTreasury, address(0));
        assertEq(staleChildTopology.childFlow, address(0));
        assertEq(controller.itemIdForBudgetTreasury(staleBudgetTreasury), bytes32(0));
        assertEq(controller.itemIdForChildFlow(staleChildFlow), bytes32(0));
        assertEq(controller.itemIdForBudgetTreasury(budgetTreasury), itemID);
        assertEq(controller.itemIdForChildFlow(childFlow), itemID);
    }

    function test_finalizeRemovedBudget_keepsTopologyDiscoverableButInactive() public {
        bytes32 itemID = _registerDefaultListing();

        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        address allocationMechanism = MockBudgetChildFlow(childFlow).recipientAdmin();
        address allocationMechanismArbitrator = address(AllocationMechanismTCR(allocationMechanism).arbitrator());
        address childStrategy = address(IFlow(childFlow).strategy());

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        IBudgetStackTopologyReader.BudgetStackTopology memory expectedTopology =
            IBudgetStackTopologyReader.BudgetStackTopology({
                childFlow: childFlow,
                budgetTreasury: budgetTreasury,
                premiumEscrow: premiumEscrow,
                strategy: childStrategy,
                allocationMechanism: allocationMechanism,
                allocationMechanismArbitrator: allocationMechanismArbitrator
            });

        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            budgetTcr.budgetStackTopology(itemID);
        assertFalse(active);
        _assertBudgetStackTopology(topology, expectedTopology);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyByTreasury, bool activeByTreasury) =
            budgetTcr.budgetStackTopologyForBudgetTreasury(budgetTreasury);
        assertFalse(activeByTreasury);
        _assertBudgetStackTopology(topologyByTreasury, expectedTopology);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyByChildFlow, bool activeByChildFlow) =
            budgetTcr.budgetStackTopologyForChildFlow(childFlow);
        assertFalse(activeByChildFlow);
        _assertBudgetStackTopology(topologyByChildFlow, expectedTopology);

        assertEq(budgetTcr.itemIdForBudgetTreasury(budgetTreasury), itemID);
        assertEq(budgetTcr.itemIdForChildFlow(childFlow), itemID);
    }

    function test_activateRegisteredBudget_reverts_when_underwriter_router_authorization_fails() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRegistrationPending(itemID));

        bytes memory authorizeReason = abi.encodeWithSignature("Error(string)", "AUTHORIZE_PREMIUM_ESCROW_FAILED");
        vm.mockCallRevert(
            underwriterSlasherRouter,
            abi.encodeWithSelector(MockUnderwriterSlasherRouter.setAuthorizedPremiumEscrow.selector),
            authorizeReason
        );

        vm.expectRevert(authorizeReason);
        budgetTcr.activateRegisteredBudget(itemID);

        assertTrue(budgetTcr.isRegistrationPending(itemID));
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertEq(budgetStakeLedger.registerCallCount(), 0);
        (address childFlow, bool removed) = goalFlow.recipients(itemID);
        assertEq(childFlow, address(0));
        assertFalse(removed);
    }

    function test_activateRegisteredBudget_usesGlobalOracleBoundsForSuccessAssertionConfig() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        uint64 expectedLiveness = 4 days;
        uint256 expectedBond = 77e18;

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        _initializeOpenBudgetTcrDeployer(
            BudgetStackDeployer(freshStackDeployer), address(freshTcr), premiumEscrowImplementation
        );
        ERC20VotesArbitrator freshArbImpl = new ERC20VotesArbitrator();
        bytes memory freshArbInit = _defaultArbitratorInitData(
            owner, address(depositToken), address(freshTcr), votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address freshArbProxy = _deployProxy(address(freshArbImpl), freshArbInit);

        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.oracleValidationBounds.liveness = expectedLiveness;
        deploymentConfig.oracleValidationBounds.bondAmount = expectedBond;
        registryConfig.tcrConfig.arbitrator = IArbitrator(freshArbProxy);

        freshTcr.initialize(registryConfig, deploymentConfig);
        goalFlow.setRecipientAdmin(address(freshTcr));

        (uint256 addCost,,,,) = freshTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(freshTcr), addCost);

        vm.prank(requester);
        bytes32 itemID = freshTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        freshTcr.executeRequest(itemID);
        assertTrue(freshTcr.isRegistrationPending(itemID));

        freshTcr.activateRegisteredBudget(itemID);

        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        assertEq(IBudgetTreasury(budgetTreasury).successAssertionLiveness(), expectedLiveness);
        assertEq(IBudgetTreasury(budgetTreasury).successAssertionBond(), expectedBond);
    }

    function test_executeRequest_registration_emitsBudgetStackActivationQueued() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        vm.recordLogs();
        budgetTcr.executeRequest(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBudgetEventForItem(logs, BUDGET_STACK_ACTIVATION_QUEUED_SIG, itemID));
    }

    function test_activateRegisteredBudget_reverts_when_not_pending() public {
        bytes32 itemID = keccak256("unknown-item");

        vm.expectRevert(IBudgetTCR.REGISTRATION_NOT_PENDING.selector);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function test_activateRegisteredBudget_reverts_when_goal_terminal() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        goalTreasury.setResolved(true);

        vm.expectRevert(IBudgetTCR.GOAL_TERMINAL.selector);
        budgetTcr.activateRegisteredBudget(itemID);

        assertTrue(budgetTcr.isRegistrationPending(itemID));
        assertEq(budgetStakeLedger.registerCallCount(), 0);
        (address childFlow, bool removed) = goalFlow.recipients(itemID);
        assertEq(childFlow, address(0));
        assertFalse(removed);
    }

    function test_activateRegisteredBudget_clears_only_target_pending_registration() public {
        _approveAddCost(requester);
        bytes32 itemA = _submitListing(requester, _defaultListing());

        IBudgetTCR.BudgetListing memory listingB = _defaultListing();
        listingB.metadata.title = "Budget B";
        listingB.metadata.url = "https://example.com/budget-b";

        _approveAddCost(requester);
        bytes32 itemB = _submitListing(requester, listingB);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemA);
        budgetTcr.executeRequest(itemB);

        assertTrue(budgetTcr.isRegistrationPending(itemA));
        assertTrue(budgetTcr.isRegistrationPending(itemB));

        budgetTcr.activateRegisteredBudget(itemA);

        assertFalse(budgetTcr.isRegistrationPending(itemA));
        assertTrue(budgetTcr.isRegistrationPending(itemB));
        assertEq(budgetStakeLedger.registerCallCount(), 1);

        (address childFlowA,) = goalFlow.recipients(itemA);
        (address childFlowB,) = goalFlow.recipients(itemB);
        assertTrue(childFlowA != address(0));
        assertEq(childFlowB, address(0));

        budgetTcr.activateRegisteredBudget(itemB);
        assertFalse(budgetTcr.isRegistrationPending(itemB));
        assertEq(budgetStakeLedger.registerCallCount(), 2);
    }

    function test_activateRegisteredBudget_reusesSharedBudgetFlowStrategyAcrossBudgets() public {
        _approveAddCost(requester);
        bytes32 itemA = _submitListing(requester, _defaultListing());

        IBudgetTCR.BudgetListing memory listingB = _defaultListing();
        listingB.metadata.title = "Budget B";
        listingB.metadata.url = "https://example.com/budget-b";

        _approveAddCost(requester);
        bytes32 itemB = _submitListing(requester, listingB);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemA);
        budgetTcr.executeRequest(itemB);

        budgetTcr.activateRegisteredBudget(itemA);
        budgetTcr.activateRegisteredBudget(itemB);

        (address childFlowA,) = goalFlow.recipients(itemA);
        (address childFlowB,) = goalFlow.recipients(itemB);

        IAllocationStrategy strategyA = IFlow(childFlowA).strategy();
        IAllocationStrategy strategyB = IFlow(childFlowB).strategy();
        assertEq(address(strategyA), address(strategyB));
        assertEq(address(strategyA), BudgetStackDeployer(stackDeployer).sharedBudgetFlowStrategy());
    }

    function test_activateRegisteredBudget_deploysDistinctMechanismAndArbitratorPerBudget() public {
        _approveAddCost(requester);
        bytes32 itemA = _submitListing(requester, _defaultListing());

        IBudgetTCR.BudgetListing memory listingB = _defaultListing();
        listingB.metadata.title = "Budget B";
        listingB.metadata.url = "https://example.com/budget-b";

        _approveAddCost(requester);
        bytes32 itemB = _submitListing(requester, listingB);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemA);
        budgetTcr.executeRequest(itemB);

        vm.recordLogs();
        budgetTcr.activateRegisteredBudget(itemA);
        Vm.Log[] memory logsA = vm.getRecordedLogs();

        vm.recordLogs();
        budgetTcr.activateRegisteredBudget(itemB);
        Vm.Log[] memory logsB = vm.getRecordedLogs();

        (address childFlowA,) = goalFlow.recipients(itemA);
        (address childFlowB,) = goalFlow.recipients(itemB);
        address budgetTreasuryA = budgetStakeLedger.budgetForRecipient(itemA);
        address budgetTreasuryB = budgetStakeLedger.budgetForRecipient(itemB);
        address roundFactory = BudgetStackDeployer(stackDeployer).roundFactory();

        (bool foundA, address mechanismA, address mechanismArbitratorA, address roundFactoryA) =
            _getBudgetAllocationMechanismDeployed(logsA, itemA);
        (bool foundB, address mechanismB, address mechanismArbitratorB, address roundFactoryB) =
            _getBudgetAllocationMechanismDeployed(logsB, itemB);

        assertTrue(foundA);
        assertTrue(foundB);
        assertEq(mechanismA, MockBudgetChildFlow(childFlowA).recipientAdmin());
        assertEq(mechanismB, MockBudgetChildFlow(childFlowB).recipientAdmin());
        assertEq(roundFactoryA, roundFactory);
        assertEq(roundFactoryB, roundFactory);
        assertTrue(mechanismA != mechanismB);
        assertTrue(mechanismArbitratorA != mechanismArbitratorB);

        assertEq(ERC20VotesArbitrator(mechanismArbitratorA).fixedBudgetTreasury(), budgetTreasuryA);
        assertEq(ERC20VotesArbitrator(mechanismArbitratorB).fixedBudgetTreasury(), budgetTreasuryB);
        assertEq(ERC20VotesArbitrator(mechanismArbitratorA).stakeVault(), goalTreasury.stakeVault());
        assertEq(ERC20VotesArbitrator(mechanismArbitratorB).stakeVault(), goalTreasury.stakeVault());
        assertEq(
            ERC20VotesArbitrator(mechanismArbitratorA).invalidRoundRewardsSink(),
            IERC20VotesArbitrator(address(arbitrator)).invalidRoundRewardsSink()
        );
        assertEq(
            ERC20VotesArbitrator(mechanismArbitratorB).invalidRoundRewardsSink(),
            IERC20VotesArbitrator(address(arbitrator)).invalidRoundRewardsSink()
        );
    }

    function test_activateRegisteredBudget_mechanismArbitrator_isNotAuthorizedInJurorSlasherRouter() public {
        address factoryAuthority = makeAddr("budget-tcr-factory");
        JurorSlasherRouter router = new JurorSlasherRouter(IStakeVault(goalTreasury.stakeVault()), factoryAuthority);
        MockStakeVaultForBudgetTCR(goalTreasury.stakeVault()).setJurorSlasher(address(router));

        vm.prank(factoryAuthority);
        router.setAuthorizedSlasher(address(arbitrator), true);

        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        vm.recordLogs();
        budgetTcr.activateRegisteredBudget(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found,, address mechanismArbitrator,) = _getBudgetAllocationMechanismDeployed(logs, itemID);
        assertTrue(found);
        assertTrue(mechanismArbitrator != address(0));
        assertTrue(router.isAuthorizedSlasher(address(arbitrator)));
        assertFalse(router.isAuthorizedSlasher(mechanismArbitrator));

        ERC20VotesArbitrator deployedMechanismArbitrator = ERC20VotesArbitrator(mechanismArbitrator);
        assertEq(deployedMechanismArbitrator.stakeVault(), goalTreasury.stakeVault());
        assertGt(deployedMechanismArbitrator.wrongOrMissedSlashBps(), 0);
        assertGt(deployedMechanismArbitrator.slashCallerBountyBps(), 0);
    }

    function test_activateRegisteredBudget_registersRecipientIdsPerChildFlowOnSharedStrategy() public {
        _approveAddCost(requester);
        bytes32 itemA = _submitListing(requester, _defaultListing());

        IBudgetTCR.BudgetListing memory listingB = _defaultListing();
        listingB.metadata.title = "Budget B";
        listingB.metadata.url = "https://example.com/budget-b";

        _approveAddCost(requester);
        bytes32 itemB = _submitListing(requester, listingB);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemA);
        budgetTcr.executeRequest(itemB);

        budgetTcr.activateRegisteredBudget(itemA);
        budgetTcr.activateRegisteredBudget(itemB);

        (address childFlowA,) = goalFlow.recipients(itemA);
        (address childFlowB,) = goalFlow.recipients(itemB);

        address sharedStrategy = BudgetStackDeployer(stackDeployer).sharedBudgetFlowStrategy();
        IBudgetFlowRouterStrategy strategy = IBudgetFlowRouterStrategy(sharedStrategy);
        (bytes32 recipientA, bool registeredA) = strategy.recipientIdForFlow(childFlowA);
        (bytes32 recipientB, bool registeredB) = strategy.recipientIdForFlow(childFlowB);

        assertTrue(registeredA);
        assertTrue(registeredB);
        assertEq(recipientA, itemA);
        assertEq(recipientB, itemB);

        vm.expectRevert(abi.encodeWithSelector(IBudgetFlowRouterStrategy.FLOW_ALREADY_REGISTERED.selector, childFlowA));
        vm.prank(address(budgetTcr));
        BudgetStackDeployer(stackDeployer).registerChildFlowRecipient(itemA, childFlowA);
    }

    function test_finalizeRemovedBudget_reverts_when_not_pending() public {
        bytes32 itemID = keccak256("unknown-item");

        vm.expectRevert(IBudgetTCR.REMOVAL_NOT_PENDING.selector);
        budgetTcr.finalizeRemovedBudget(itemID);
    }

    function test_executeRequest_removal_clears_pending_registration_when_stack_not_activated() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRegistrationPending(itemID));

        _approveRemoveCost(requester);
        vm.prank(requester);
        budgetTcr.removeItem(itemID, "");

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        vm.recordLogs();
        budgetTcr.executeRequest(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (, IGeneralizedTCR.Status status,) = budgetTcr.getItemInfo(itemID);
        assertEq(uint8(status), uint8(IGeneralizedTCR.Status.Absent));
        assertFalse(budgetTcr.isRegistrationPending(itemID));
        assertFalse(budgetTcr.isRemovalPending(itemID));
        assertFalse(_hasBudgetEventForItem(logs, BUDGET_STACK_REMOVAL_QUEUED_SIG, itemID));
    }

    function test_addItem_allowsExactRelist_afterPreActivationRemoval() public {
        IBudgetTCR.BudgetListing memory listing = _defaultListing();

        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, listing);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        _approveRemoveCost(requester);
        vm.prank(requester);
        budgetTcr.removeItem(itemID, "");

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        _approveAddCost(requester);
        vm.prank(requester);
        bytes32 relistedItemID = budgetTcr.addItem(abi.encode(listing));

        assertEq(relistedItemID, itemID);
        (,,,,,,,,, uint256 registrationMetaEvidenceID) = budgetTcr.getRequestInfo(itemID, 2);
        assertEq(registrationMetaEvidenceID, 0);
    }

    function test_executeRequest_removal_queues_then_finalizeRemovedBudget_handles_parent_removal() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        assertEq(goalFlow.recipientAdmin(), address(budgetTcr));

        assertFalse(IBudgetTreasury(budgetTreasury).resolved());

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        assertTrue(budgetTcr.isRemovalPending(itemID));
        assertFalse(budgetTcr.isRegistrationPending(itemID));
        (, bool removedBeforeFinalize) = goalFlow.recipients(itemID);
        assertFalse(removedBeforeFinalize);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);

        budgetTcr.finalizeRemovedBudget(itemID);

        assertFalse(budgetTcr.isRemovalPending(itemID));
        assertEq(goalFlow.recipientAdmin(), address(budgetTcr));
        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertEq(budgetStakeLedger.registerCallCount(), 1);
        assertEq(budgetStakeLedger.removeCallCount(), 1);
    }

    function test_executeRequest_removal_emitsBudgetStackRemovalQueued() public {
        bytes32 itemID = _registerDefaultListing();

        _queueRemovalRequest(itemID);
        vm.recordLogs();
        budgetTcr.executeRequest(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBudgetEventForItem(logs, BUDGET_STACK_REMOVAL_QUEUED_SIG, itemID));
    }

    function test_finalizeRemovedBudget_emitsBudgetStackRemovalHandled() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        vm.recordLogs();
        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, bool removedFromParent, bool emittedTerminallyResolved) =
            _getBudgetStackRemovalHandled(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertTrue(removedFromParent);
        assertEq(emittedTerminallyResolved, terminallyResolved);
    }

    function test_pruneTerminalBudget_revertsWhenBudgetNotTerminal() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        vm.expectRevert(IBudgetTCR.ITEM_NOT_TERMINAL.selector);
        budgetTcr.pruneTerminalBudget(budgetTreasury);

        (, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
    }

    function test_pruneTerminalBudget_revertsWhenBudgetTreasuryUnknown() public {
        _registerDefaultListing();
        address unknownBudgetTreasury = makeAddr("unknown-budget-treasury");

        vm.expectRevert(IBudgetTCR.ITEM_NOT_DEPLOYED.selector);
        budgetTcr.pruneTerminalBudget(unknownBudgetTreasury);
    }

    function test_pruneTerminalBudget_permissionless_removesRecipient_andSyncsGoal() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        _mockBudgetTreasuryResolved(budgetTreasury, true);

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (bool removedFromParent, bool goalSynced) = budgetTcr.pruneTerminalBudget(budgetTreasury);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(removedFromParent);
        assertTrue(goalSynced);
        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);

        (bool found, bool emittedRemovedFromParent, bool emittedGoalSynced) =
            _getBudgetTerminalRecipientPruned(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertEq(emittedRemovedFromParent, removedFromParent);
        assertEq(emittedGoalSynced, goalSynced);
    }

    function test_pruneTerminalBudget_goalSyncFailure_isReported_andReturnsFalse() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "GOAL_SYNC_FAILED");

        _mockBudgetTreasuryResolved(budgetTreasury, true);
        goalTreasury.setShouldRevertSync(true);

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (bool removedFromParent, bool goalSynced) = budgetTcr.pruneTerminalBudget(budgetTreasury);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(removedFromParent);
        assertFalse(goalSynced);
        assertTrue(_hasBudgetSyncCallFailed(logs, itemID, budgetTreasury, IGoalTreasury.sync.selector, expectedReason));
    }

    function test_pruneTerminalBudget_whenRecipientAlreadyPruned_returnsFalseAndStillSyncsGoal() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        _mockBudgetTreasuryResolved(budgetTreasury, true);

        vm.prank(address(budgetTcr));
        goalFlow.removeRecipient(itemID);

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (bool removedFromParent, bool goalSynced) = budgetTcr.pruneTerminalBudget(budgetTreasury);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(removedFromParent);
        assertTrue(goalSynced);
        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);

        (bool found, bool emittedRemovedFromParent, bool emittedGoalSynced) =
            _getBudgetTerminalRecipientPruned(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertEq(emittedRemovedFromParent, removedFromParent);
        assertEq(emittedGoalSynced, goalSynced);
    }

    function test_pruneTerminalBudget_inactivePendingRemoval_clearsRemovalPendingAfterLateTerminalization() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(terminallyResolved);
        assertTrue(budgetTcr.isRemovalPending(itemID));
        (, bool removedAfterFinalize) = goalFlow.recipients(itemID);
        assertTrue(removedAfterFinalize);

        bytes memory pruneFailureReason = abi.encodeWithSignature("Error(string)", "PARENT_PRUNE_FAILED");
        vm.mockCallRevert(
            address(budgetTcr),
            abi.encodeWithSelector(IBudgetController.pruneTerminalBudget.selector, budgetTreasury),
            pruneFailureReason
        );

        _warpRoll(treasury.deadline() + 1);
        treasury.sync();

        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertTrue(budgetTcr.isRemovalPending(itemID));

        vm.clearMockedCalls();

        uint256 syncCallCountBefore = goalTreasury.syncCallCount();
        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (bool removedFromParent, bool goalSynced) = budgetTcr.pruneTerminalBudget(budgetTreasury);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(removedFromParent);
        assertTrue(goalSynced);
        assertFalse(budgetTcr.isRemovalPending(itemID));
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);

        (bool found, bool emittedRemovedFromParent, bool emittedGoalSynced) =
            _getBudgetTerminalRecipientPruned(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertEq(emittedRemovedFromParent, removedFromParent);
        assertEq(emittedGoalSynced, goalSynced);
    }

    function test_finalizeRemovedBudget_handlesAlreadyPrunedRecipient() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        vm.prank(address(budgetTcr));
        goalFlow.removeRecipient(itemID);

        vm.recordLogs();
        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(terminallyResolved);
        assertFalse(budgetTcr.isRemovalPending(itemID));
        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));

        (bool found, bool removedFromParent, bool emittedTerminallyResolved) =
            _getBudgetStackRemovalHandled(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertFalse(removedFromParent);
        assertEq(emittedTerminallyResolved, terminallyResolved);
    }

    function test_finalizeRemovedBudget_clears_only_target_pending_removal() public {
        bytes32 itemA = _registerDefaultListing();
        bytes32 itemB = _registerDefaultListing();

        (address childFlowA,) = goalFlow.recipients(itemA);
        (address childFlowB,) = goalFlow.recipients(itemB);
        address budgetTreasuryB = budgetStakeLedger.budgetForRecipient(itemB);

        _queueRemovalRequest(itemA);
        budgetTcr.executeRequest(itemA);

        _queueRemovalRequest(itemB);
        budgetTcr.executeRequest(itemB);

        assertTrue(budgetTcr.isRemovalPending(itemA));
        assertTrue(budgetTcr.isRemovalPending(itemB));

        budgetTcr.finalizeRemovedBudget(itemA);

        assertFalse(budgetTcr.isRemovalPending(itemA));
        assertTrue(budgetTcr.isRemovalPending(itemB));
        assertEq(budgetStakeLedger.budgetForRecipient(itemA), address(0));
        assertEq(budgetStakeLedger.budgetForRecipient(itemB), budgetTreasuryB);

        (, bool removedA) = goalFlow.recipients(itemA);
        (, bool removedB) = goalFlow.recipients(itemB);
        assertTrue(removedA);
        assertFalse(removedB);

        assertEq(budgetStakeLedger.registerCallCount(), 2);
        assertEq(budgetStakeLedger.removeCallCount(), 1);
        assertEq(MockBudgetChildFlow(childFlowA).targetOutflowRate(), 0);

        budgetTcr.finalizeRemovedBudget(itemB);

        assertFalse(budgetTcr.isRemovalPending(itemB));
        assertEq(budgetStakeLedger.budgetForRecipient(itemB), address(0));
        assertEq(budgetStakeLedger.removeCallCount(), 2);
    }

    function test_finalizeRemovedBudget_returnsTerminallyResolvedTrue_whenBudgetWindowStillOpen() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertTrue(terminallyResolved);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
    }

    function test_finalizeRemovedBudget_forceZerosFlowRate_whenBudgetWasActive_withoutAutoFailure() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        IBudgetTreasury(budgetTreasury).sync();

        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Active));

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);

        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertFalse(terminallyResolved);
        assertFalse(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(IBudgetTreasury(budgetTreasury).successResolutionDisabled());
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_finalizeRemovedBudget_reverts_whenForceZeroingFails_but_request_resolves() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);

        vm.mockCallRevert(
            budgetTreasury,
            abi.encodeWithSelector(IBudgetTreasury.forceFlowRateToZero.selector),
            abi.encodeWithSignature("Error(string)", "FORCE_ZERO_FAILED")
        );

        budgetTcr.executeRequest(itemID);

        (, IGeneralizedTCR.Status status,) = budgetTcr.getItemInfo(itemID);
        assertEq(uint8(status), uint8(IGeneralizedTCR.Status.Absent));
        assertTrue(budgetTcr.isRemovalPending(itemID));

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "FORCE_ZERO_FAILED"));
        budgetTcr.finalizeRemovedBudget(itemID);

        (, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);
        assertEq(budgetStakeLedger.removeCallCount(), 0);
    }

    function test_finalizeRemovedBudget_revertsWhenForceZeroingFails_forActivationLockedRemoval_andPreservesRemovalState()
        public
    {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.successResolutionDisabled());

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        assertFalse(treasury.successResolutionDisabled());

        bytes memory revertReason = abi.encodeWithSignature("Error(string)", "FORCE_ZERO_FAILED_ACTIVE");
        vm.mockCallRevert(
            budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.forceFlowRateToZero.selector), revertReason
        );

        vm.expectRevert(revertReason);
        budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(budgetTcr.isRemovalPending(itemID));
        (, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);
        assertEq(budgetStakeLedger.removeCallCount(), 0);
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertFalse(treasury.successResolutionDisabled());

        vm.expectRevert(IBudgetTCR.STACK_STILL_ACTIVE.selector);
        vm.prank(makeAddr("keeper"));
        budgetTcr.retryRemovedBudgetResolution(itemID);
    }

    function test_finalizeRemovedBudget_revertsWhenDisableFails_andPreservesRemovalState() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        vm.mockCallRevert(
            budgetTreasury,
            abi.encodeWithSelector(IBudgetTreasury.disableSuccessResolution.selector),
            abi.encodeWithSignature("Error(string)", "DISABLE_FAILED")
        );

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "DISABLE_FAILED"));
        budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(budgetTcr.isRemovalPending(itemID));
        (, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);
        assertEq(budgetStakeLedger.removeCallCount(), 0);
        assertFalse(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Funding));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());

        vm.expectRevert(IBudgetTCR.STACK_STILL_ACTIVE.selector);
        vm.prank(makeAddr("keeper"));
        budgetTcr.retryRemovedBudgetResolution(itemID);

        vm.clearMockedCalls();

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertTrue(terminallyResolved);
        assertFalse(budgetTcr.isRemovalPending(itemID));
        (, bool removedAfterFinalize) = goalFlow.recipients(itemID);
        assertTrue(removedAfterFinalize);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());
    }

    function test_finalizeRemovedBudget_bubblesResolveFailureRevertReason() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        _mockBudgetTreasuryResolved(budgetTreasury, false);
        bytes memory resolveFailureReason = abi.encodeWithSignature("Error(string)", "RESOLVE_FAILURE_FAILED");
        vm.mockCallRevert(
            budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolveFailure.selector), resolveFailureReason
        );

        vm.expectRevert(resolveFailureReason);
        budgetTcr.finalizeRemovedBudget(itemID);
    }

    function test_finalizeRemovedBudget_revertsWhenTerminalResolutionUnresolved_andPreservesRemovalState() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        _mockBudgetTreasuryResolved(budgetTreasury, false);

        vm.expectRevert(IBudgetTCR.TERMINAL_RESOLUTION_FAILED.selector);
        budgetTcr.finalizeRemovedBudget(itemID);

        vm.clearMockedCalls();

        assertTrue(budgetTcr.isRemovalPending(itemID));
        (, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);
        assertEq(budgetStakeLedger.removeCallCount(), 0);
        assertFalse(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Funding));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());

        vm.expectRevert(IBudgetTCR.STACK_STILL_ACTIVE.selector);
        vm.prank(makeAddr("keeper"));
        budgetTcr.retryRemovedBudgetResolution(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertTrue(terminallyResolved);
        assertFalse(budgetTcr.isRemovalPending(itemID));
        (, bool removedAfterFinalize) = goalFlow.recipients(itemID);
        assertTrue(removedAfterFinalize);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());
    }

    function test_retryRemovedBudgetResolution_keepsBudgetFailedAfterImmediateTerminalization() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        // Keep treasury below activation threshold so removal follows pre-activation terminalization branch.
        superToken.mint(childFlow, 1e18);
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Funding));
        assertEq(IBudgetTreasury(budgetTreasury).deadline(), 0);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);

        vm.prank(makeAddr("keeper"));
        bool terminallyResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertTrue(terminallyResolved);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_finalizeRemovedBudget_preActivationRemoval_disallowsActivationBeforeFinalize() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        assertEq(treasury.activatedAt(), 0);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        assertTrue(treasury.successResolutionDisabled());

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(treasury.activatedAt(), 0);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertTrue(terminallyResolved);
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.successResolutionDisabled());
    }

    function test_executeRequest_removal_resolves_failure_after_budget_window() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        vm.warp(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);
        vm.roll(block.number + 1);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertEq(budgetStakeLedger.registerCallCount(), 1);
        assertEq(budgetStakeLedger.removeCallCount(), 1);
    }

    function test_retryRemovedBudgetResolution_revertsWhenStackStillActive() public {
        bytes32 itemID = _registerDefaultListing();

        vm.expectRevert(IBudgetTCR.STACK_STILL_ACTIVE.selector);
        budgetTcr.retryRemovedBudgetResolution(itemID);
    }

    function test_retryRemovedBudgetResolution_activationLocked_remainsUnresolvedUntilSyncFinalizes() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.deadline(), 0);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(terminallyResolved);
        assertFalse(treasury.successResolutionDisabled());
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);

        _warpRoll(treasury.deadline() + 1);
        vm.prank(makeAddr("keeper"));
        bool retryResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertTrue(retryResolved);
        assertFalse(treasury.successResolutionDisabled());
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_retryRemovedBudgetResolution_activationLocked_beforeDeadline_returnsFalseWithoutForcingFailure()
        public
    {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.deadline(), block.timestamp);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(terminallyResolved);
        assertFalse(treasury.successResolutionDisabled());
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);

        vm.prank(makeAddr("keeper"));
        bool retryResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertFalse(retryResolved);
        assertFalse(treasury.successResolutionDisabled());
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_finalizeRemovedBudget_activationLocked_keepsRemovalPendingUntilTerminalResolution() public {
        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, listing);
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        budgetTcr.activateRegisteredBudget(itemID);

        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(terminallyResolved);
        assertTrue(budgetTcr.isRemovalPending(itemID));

        _approveAddCost(requester);
        vm.expectRevert(IBudgetTCR.REMOVAL_FINALIZATION_PENDING.selector);
        vm.prank(requester);
        budgetTcr.addItem(abi.encode(listing));

        bool secondFinalizeResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(secondFinalizeResolved);
        assertTrue(budgetTcr.isRemovalPending(itemID));

        _warpRoll(treasury.deadline() + 1);
        vm.prank(makeAddr("keeper"));
        bool retryResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertTrue(retryResolved);
        assertFalse(budgetTcr.isRemovalPending(itemID));
    }

    function test_retryRemovedBudgetResolution_revertsWhenForceZeroingFails_forActivationLockedRemoval() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(terminallyResolved);
        assertFalse(treasury.successResolutionDisabled());
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);

        bytes memory revertReason = abi.encodeWithSignature("Error(string)", "FORCE_ZERO_RETRY_FAILED");
        vm.mockCallRevert(
            budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.forceFlowRateToZero.selector), revertReason
        );

        vm.prank(makeAddr("keeper"));
        vm.expectRevert(revertReason);
        budgetTcr.retryRemovedBudgetResolution(itemID);
    }

    function test_retryRemovedBudgetResolution_permissionlessReturnsTrue_whenAlreadyResolvedByFinalize() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(IBudgetTreasury(budgetTreasury).resolved());

        vm.prank(makeAddr("keeper"));
        bool terminallyResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertTrue(terminallyResolved);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
    }

    function test_retryRemovedBudgetResolution_emitsBudgetStackTerminalizationRetried() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        vm.recordLogs();
        bool terminallyResolved = budgetTcr.retryRemovedBudgetResolution(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, bool emittedTerminallyResolved) =
            _getBudgetStackTerminalizationRetried(logs, itemID, budgetTreasury);
        assertTrue(found);
        assertEq(emittedTerminallyResolved, terminallyResolved);
    }

    function test_retryRemovedBudgetResolution_emitsSyncFailureEvent_whenSyncReverts_forActivationLockedRemoval()
        public
    {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        IBudgetTreasury(budgetTreasury).sync();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "SYNC_RETRY_FAILED");
        vm.mockCallRevert(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.sync.selector), expectedReason);

        vm.recordLogs();
        bool terminallyResolved = budgetTcr.retryRemovedBudgetResolution(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(terminallyResolved);
        assertTrue(
            _hasBudgetSyncCallFailed(logs, itemID, budgetTreasury, IBudgetTreasury.sync.selector, expectedReason)
        );
    }

    function test_retryRemovedBudgetResolution_emitsTerminalizationFailureEvent_whenResolveFailureReverts() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        _mockBudgetTreasuryResolved(budgetTreasury, false);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "RESOLVE_FAILURE_RETRY_FAILED");
        vm.mockCallRevert(
            budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolveFailure.selector), expectedReason
        );

        vm.recordLogs();
        bool terminallyResolved = budgetTcr.retryRemovedBudgetResolution(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(terminallyResolved);
        assertTrue(
            _hasBudgetTerminalizationStepFailed(
                logs, itemID, budgetTreasury, IBudgetTreasury.resolveFailure.selector, expectedReason
            )
        );
    }

    function test_finalizeRemovedBudget_terminalizesWithoutStakeVaultSideEffects() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        assertTrue(budgetTcr.finalizeRemovedBudget(itemID));
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
    }

    function test_finalizeRemovedBudget_closesPremiumEscrow_onTerminalFailure() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
        address premiumEscrow = treasury.premiumEscrow();

        assertFalse(PremiumEscrow(premiumEscrow).closed());

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(terminallyResolved);
        assertTrue(PremiumEscrow(premiumEscrow).closed());
        assertEq(uint8(PremiumEscrow(premiumEscrow).finalState()), uint8(IBudgetTreasury.BudgetState.Failed));
        assertEq(PremiumEscrow(premiumEscrow).activatedAt(), treasury.activatedAt());
        assertEq(PremiumEscrow(premiumEscrow).closedAt(), treasury.resolvedAt());
    }

    function test_finalizeRemovedBudget_terminalizes_when_premium_escrow_close_reverts() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
        address premiumEscrow = treasury.premiumEscrow();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        vm.mockCallRevert(
            premiumEscrow,
            abi.encodeWithSelector(PremiumEscrow.close.selector),
            abi.encodeWithSignature("Error(string)", "PREMIUM_ESCROW_CLOSE_FAILED")
        );

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(terminallyResolved);
        assertFalse(budgetTcr.isRemovalPending(itemID));
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertFalse(PremiumEscrow(premiumEscrow).closed());
    }

    function test_finalizeRemovedBudget_keepsPendingSuccessAssertion_whenBudgetWasActive() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(1_000);
        superToken.mint(childFlow, 1_000e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.deadline(), treasury.fundingDeadline());

        _warpRoll(treasury.fundingDeadline() + 1);

        bytes32 assertionId = keccak256("pending-budget-success-assertion");
        vm.prank(budgetSuccessResolver);
        treasury.registerSuccessAssertion(assertionId);
        assertEq(treasury.pendingSuccessAssertionId(), assertionId);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertFalse(terminallyResolved);
        assertFalse(treasury.successResolutionDisabled());
        assertEq(treasury.pendingSuccessAssertionId(), assertionId);
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_syncBudgetTreasuries_permissionless_bestEffortAcrossActiveBudgets() public {
        bytes32 itemA = _registerDefaultListing();
        bytes32 itemB = _registerDefaultListing();
        address treasuryA = budgetStakeLedger.budgetForRecipient(itemA);
        address treasuryB = budgetStakeLedger.budgetForRecipient(itemB);

        vm.mockCallRevert(
            treasuryA,
            abi.encodeWithSelector(IBudgetTreasury.sync.selector),
            abi.encodeWithSignature("Error(string)", "SYNC_FAIL")
        );

        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = itemA;
        itemIDs[1] = itemB;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 2);
        assertEq(succeeded, 1);
    }

    function test_syncBudgetTreasuries_skipsUndeployedAndInactive() public {
        bytes32 itemID = _registerDefaultListing();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        bytes32 unknownItemID = keccak256("unknown-item");
        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = unknownItemID;
        itemIDs[1] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 0);
        assertEq(succeeded, 0);
    }

    function test_syncBudgetTreasuries_permissionless_activatesFundedBudget_butOutflowFailsClosedWithoutHost() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(500);
        superToken.mint(childFlow, 100e18);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_syncBudgetTreasuries_permissionless_doesNotPruneOrGoalSyncNonTerminalBudget() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        MockBudgetChildFlow(childFlow).setMaxSafeFlowRate(type(int96).max);
        MockBudgetChildFlow(childFlow).setNetFlowRate(500);
        superToken.mint(childFlow, 100e18);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertFalse(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Active));
        (, bool removed) = goalFlow.recipients(itemID);
        assertFalse(removed);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore);

        (bool found,,) = _getBudgetTerminalRecipientPruned(logs, itemID, childFlow, budgetTreasury);
        assertFalse(found);
    }

    function test_syncBudgetTreasuries_permissionless_expiresUnfundedBudgetAfterFundingDeadline() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        vm.warp(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Expired));
    }

    function test_syncBudgetTreasuries_permissionless_locallyPrunesBudgetWhenSyncExpiresIt() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        vm.warp(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Expired));
        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);

        (bool found, bool removedFromParent, bool goalSynced) =
            _getBudgetTerminalRecipientPruned(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertTrue(removedFromParent);
        assertTrue(goalSynced);

        uint256 syncCallCountAfterFirstSweep = goalTreasury.syncCallCount();

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attemptedSecond, uint256 succeededSecond) = budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();

        assertEq(attemptedSecond, 1);
        assertEq(succeededSecond, 1);
        assertEq(goalTreasury.syncCallCount(), syncCallCountAfterFirstSweep);

        (bool foundOnSecondSweep,,) = _getBudgetTerminalRecipientPruned(secondLogs, itemID, childFlow, budgetTreasury);
        assertFalse(foundOnSecondSweep);
    }

    function test_syncBudgetTreasuries_permissionless_goalSyncFailureRepairsViaRetryTerminalSideEffects() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "GOAL_SYNC_FAILED");

        vm.warp(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);
        goalTreasury.setShouldRevertSync(true);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore);
        (, bool removed) = goalFlow.recipients(itemID);
        assertTrue(removed);
        assertTrue(_hasBudgetSyncCallFailed(logs, itemID, budgetTreasury, IGoalTreasury.sync.selector, expectedReason));

        (bool found, bool removedFromParent, bool goalSynced) =
            _getBudgetTerminalRecipientPruned(logs, itemID, childFlow, budgetTreasury);
        assertTrue(found);
        assertTrue(removedFromParent);
        assertFalse(goalSynced);

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attemptedSecond, uint256 succeededSecond) = budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();

        assertEq(attemptedSecond, 1);
        assertEq(succeededSecond, 1);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore);
        assertFalse(
            _hasBudgetSyncCallFailed(secondLogs, itemID, budgetTreasury, IGoalTreasury.sync.selector, expectedReason)
        );

        (bool foundOnSecondSweep,,) = _getBudgetTerminalRecipientPruned(secondLogs, itemID, childFlow, budgetTreasury);
        assertFalse(foundOnSecondSweep);

        goalTreasury.setShouldRevertSync(false);

        vm.prank(makeAddr("keeper"));
        IBudgetTreasury(budgetTreasury).retryTerminalSideEffects();

        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);
    }

    function test_syncBudgetTreasuries_emitsBatchOutcomeEvents_forSkipFailAndSuccess() public {
        bytes32 itemFail = _registerDefaultListing();
        bytes32 itemSuccess = _registerDefaultListing();
        bytes32 itemInactive = _registerDefaultListing();

        address treasuryFail = budgetStakeLedger.budgetForRecipient(itemFail);
        address treasurySuccess = budgetStakeLedger.budgetForRecipient(itemSuccess);
        address treasuryInactive = budgetStakeLedger.budgetForRecipient(itemInactive);

        _queueRemovalRequest(itemInactive);
        budgetTcr.executeRequest(itemInactive);
        budgetTcr.finalizeRemovedBudget(itemInactive);

        bytes memory syncFailReason = abi.encodeWithSignature("Error(string)", "SYNC_FAIL");
        vm.mockCallRevert(treasuryFail, abi.encodeWithSelector(IBudgetTreasury.sync.selector), syncFailReason);

        bytes32 unknownItemID = keccak256("unknown-item");
        bytes32[] memory itemIDs = new bytes32[](4);
        itemIDs[0] = unknownItemID;
        itemIDs[1] = itemInactive;
        itemIDs[2] = itemFail;
        itemIDs[3] = itemSuccess;

        vm.recordLogs();
        budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasBudgetSyncSkipped(logs, unknownItemID, address(0), SYNC_SKIP_NO_BUDGET_TREASURY));
        assertTrue(_hasBudgetSyncSkipped(logs, itemInactive, treasuryInactive, SYNC_SKIP_STACK_INACTIVE));
        assertTrue(
            _hasBudgetSyncCallFailed(logs, itemFail, treasuryFail, IBudgetTreasury.sync.selector, syncFailReason)
        );
        assertTrue(_hasBudgetSyncAttempted(logs, itemFail, treasuryFail, false));
        assertTrue(_hasBudgetSyncAttempted(logs, itemSuccess, treasurySuccess, true));
    }

    function test_executeRequest_queues_activation_when_parent_flow_manager_is_not_tcr() public {
        goalFlow.setRecipientAdmin(address(this));

        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());
        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRegistrationPending(itemID));

        vm.expectRevert(MockGoalFlowForBudgetTCR.NOT_RECIPIENT_ADMIN.selector);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function _mockBudgetTreasuryResolved(address budgetTreasury, bool isResolved) internal {
        vm.mockCall(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolved.selector), abi.encode(isResolved));
    }

    function _hasBudgetEventForItem(Vm.Log[] memory logs, bytes32 eventSignature, bytes32 itemID)
        internal
        view
        returns (bool)
    {
        address emitter = address(budgetTcr);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != eventSignature) continue;
            if (logs[i].topics[1] == itemID) return true;
        }
        return false;
    }

    function _getBudgetStackRemovalHandled(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address childFlow,
        address budgetTreasury
    ) internal view returns (bool found, bool removedFromParent, bool terminallyResolved) {
        address emitter = address(budgetTcr);
        bytes32 childFlowTopic = _addressToTopic(childFlow);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != BUDGET_STACK_REMOVAL_HANDLED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != childFlowTopic) continue;
            if (logs[i].topics[3] != treasuryTopic) continue;

            (removedFromParent, terminallyResolved) = abi.decode(logs[i].data, (bool, bool));
            return (true, removedFromParent, terminallyResolved);
        }
    }

    function _getBudgetStackTerminalizationRetried(Vm.Log[] memory logs, bytes32 itemID, address budgetTreasury)
        internal
        view
        returns (bool found, bool terminallyResolved)
    {
        address emitter = address(budgetTcr);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] != BUDGET_STACK_TERMINALIZATION_RETRIED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != treasuryTopic) continue;

            terminallyResolved = abi.decode(logs[i].data, (bool));
            return (true, terminallyResolved);
        }
    }

    function _getBudgetTerminalRecipientPruned(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address childFlow,
        address budgetTreasury
    ) internal view returns (bool found, bool removedFromParent, bool goalSynced) {
        address emitter = address(budgetTcr);
        bytes32 childFlowTopic = _addressToTopic(childFlow);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != BUDGET_TERMINAL_RECIPIENT_PRUNED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != childFlowTopic) continue;
            if (logs[i].topics[3] != treasuryTopic) continue;

            (removedFromParent, goalSynced) = abi.decode(logs[i].data, (bool, bool));
            return (true, removedFromParent, goalSynced);
        }
    }

    function _hasBudgetSyncSkipped(Vm.Log[] memory logs, bytes32 itemID, address budgetTreasury, bytes32 expectedReason)
        internal
        view
        returns (bool)
    {
        address emitter = address(budgetTcr);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] != BUDGET_TREASURY_BATCH_SYNC_SKIPPED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != treasuryTopic) continue;

            bytes32 reason = abi.decode(logs[i].data, (bytes32));
            if (reason == expectedReason) return true;
        }
        return false;
    }

    function _hasBudgetSyncCallFailed(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address budgetTreasury,
        bytes4 expectedSelector,
        bytes memory expectedReason
    ) internal view returns (bool) {
        address emitter = address(budgetTcr);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        bytes32 selectorTopic = bytes32(expectedSelector);
        bytes32 expectedReasonHash = keccak256(expectedReason);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != BUDGET_TREASURY_CALL_FAILED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != treasuryTopic) continue;
            if (logs[i].topics[3] != selectorTopic) continue;

            bytes memory reason = abi.decode(logs[i].data, (bytes));
            if (keccak256(reason) == expectedReasonHash) return true;
        }
        return false;
    }

    function _hasBudgetTerminalizationStepFailed(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address budgetTreasury,
        bytes4 expectedSelector,
        bytes memory expectedReason
    ) internal view returns (bool) {
        address emitter = address(budgetTcr);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        bytes32 selectorTopic = bytes32(expectedSelector);
        bytes32 expectedReasonHash = keccak256(expectedReason);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != BUDGET_TERMINALIZATION_STEP_FAILED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != treasuryTopic) continue;
            if (logs[i].topics[3] != selectorTopic) continue;

            bytes memory reason = abi.decode(logs[i].data, (bytes));
            if (keccak256(reason) == expectedReasonHash) return true;
        }
        return false;
    }

    function _hasBudgetGateEnforcementFailed(Vm.Log[] memory logs, address emitter) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == BUDGET_GATE_ENFORCEMENT_FAILED_SIG) return true;
        }
        return false;
    }

    function _hasBudgetSyncAttempted(Vm.Log[] memory logs, bytes32 itemID, address budgetTreasury, bool expectedSuccess)
        internal
        view
        returns (bool)
    {
        address emitter = address(budgetTcr);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 3) continue;
            if (logs[i].topics[0] != BUDGET_TREASURY_BATCH_SYNC_ATTEMPTED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != treasuryTopic) continue;

            bool success = abi.decode(logs[i].data, (bool));
            if (success == expectedSuccess) return true;
        }
        return false;
    }

    function _findBudgetStackDeployedLogIndex(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address childFlow,
        address budgetTreasury
    ) internal view returns (bool found, uint256 index) {
        address emitter = address(budgetTcr);
        bytes32 childFlowTopic = _addressToTopic(childFlow);
        bytes32 treasuryTopic = _addressToTopic(budgetTreasury);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != BUDGET_STACK_DEPLOYED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;
            if (logs[i].topics[2] != childFlowTopic) continue;
            if (logs[i].topics[3] != treasuryTopic) continue;

            return (true, i);
        }
    }

    function _findBudgetConfiguredLogIndex(Vm.Log[] memory logs, address budgetTreasury)
        internal
        view
        returns (bool found, uint256 index)
    {
        bytes32 controllerTopic = _addressToTopic(address(budgetTcr));
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != budgetTreasury) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != BUDGET_CONFIGURED_SIG) continue;
            if (logs[i].topics[1] != controllerTopic) continue;

            return (true, i);
        }
    }

    function _getBudgetAllocationMechanismDeployed(Vm.Log[] memory logs, bytes32 itemID)
        internal
        view
        returns (bool found, address allocationMechanism, address mechanismArbitrator, address roundFactory)
    {
        address emitter = address(budgetTcr);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] != BUDGET_ALLOCATION_MECHANISM_DEPLOYED_SIG) continue;
            if (logs[i].topics[1] != itemID) continue;

            allocationMechanism = address(uint160(uint256(logs[i].topics[2])));
            mechanismArbitrator = address(uint160(uint256(logs[i].topics[3])));
            roundFactory = abi.decode(logs[i].data, (address));
            return (true, allocationMechanism, mechanismArbitrator, roundFactory);
        }
    }

    function _addressToTopic(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _approveAddCost(address who) internal returns (uint256 addCost) {
        (addCost,,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), addCost);
    }

    function _freshInitializeConfig()
        internal
        returns (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        )
    {
        BudgetTCR freshImplementation = new BudgetTCR();
        freshTcr = BudgetTCR(_deployProxy(address(freshImplementation), ""));
        registryConfig = _defaultRegistryConfig();
        deploymentConfig = _defaultDeploymentConfig();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        BudgetStackDeployer(freshStackDeployer)
            .initializeWithConfig(address(freshTcr), _openStackModuleConfig(premiumEscrowImplementation));
        deploymentConfig.stackDeployer = freshStackDeployer;
    }

    function _freshInitializeConfigWithFreshArbitrator()
        internal
        returns (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        )
    {
        (freshTcr, registryConfig, deploymentConfig) = _freshInitializeConfig();

        ERC20VotesArbitrator freshArbImpl = new ERC20VotesArbitrator();
        bytes memory freshArbInit = _defaultArbitratorInitData(
            owner, address(depositToken), address(freshTcr), votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address freshArbProxy = _deployProxy(address(freshArbImpl), freshArbInit);
        registryConfig.tcrConfig.arbitrator = IArbitrator(freshArbProxy);
    }

    function _defaultRegistryConfig() internal view returns (IBudgetTCR.InitConfig memory registryConfig) {
        registryConfig = IBudgetTCR.InitConfig({
            allocationMechanismAdmin: allocationMechanismAdmin,
            tcrConfig: IGeneralizedTCRConfig.RegistryConfig({
                arbitrator: IArbitrator(address(arbitrator)),
                votingToken: IVotes(address(depositToken)),
                submissionDepositStrategy: submissionDepositStrategy,
                registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                    arbitratorExtraData: bytes(""),
                    registrationMetaEvidence: "ipfs://budget-reg-meta",
                    clearingMetaEvidence: "ipfs://budget-clear-meta",
                    submissionBaseDeposit: submissionBaseDeposit,
                    removalBaseDeposit: removalBaseDeposit,
                    submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
                    removalChallengeBaseDeposit: removalChallengeBaseDeposit,
                    challengePeriodDuration: challengePeriodDuration
                })
            })
        });
    }

    function _defaultDeploymentConfig() internal view returns (IBudgetTCR.DeploymentConfig memory deploymentConfig) {
        deploymentConfig = IBudgetTCR.DeploymentConfig({
            stackDeployer: stackDeployer,
            discoveryEmitter: address(this),
            budgetSuccessResolver: budgetSuccessResolver,
            budgetSpendPolicy: budgetSpendPolicy,
            riskModuleRouting: BudgetTCRConfigHelpers.openRiskModuleRouting(
                budgetGatePolicy, premiumEscrowImplementation, underwriterSlasherRouter
            ),
            goalFlow: IFlow(address(goalFlow)),
            goalTreasury: IGoalTreasury(address(goalTreasury)),
            goalToken: IERC20(address(goalToken)),
            cobuildToken: IERC20(address(cobuildToken)),
            goalRulesets: IJBRulesets(address(0x1234)),
            goalRevnetId: 1,
            budgetPremiumPpm: 100_000,
            budgetSlashPpm: 50_000,
            budgetValidationBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1 days,
                maxFundingHorizon: 60 days,
                minExecutionDuration: 1 days,
                maxExecutionDuration: 30 days,
                minActivationThreshold: 1e18,
                maxActivationThreshold: 1_000_000e18,
                maxRunwayCap: 2_000_000e18
            }),
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        });
    }

    function _noPremiumStackModuleConfig()
        internal
        pure
        returns (BudgetStackTypes.StackModuleConfig memory stackModuleConfig)
    {
        stackModuleConfig = BudgetTCRConfigHelpers.noPremiumStackModuleConfig();
    }

    function _openStackModuleConfig(address premiumEscrowImplementation_)
        internal
        pure
        returns (BudgetStackTypes.StackModuleConfig memory stackModuleConfig)
    {
        stackModuleConfig = BudgetTCRConfigHelpers.openStackModuleConfig(premiumEscrowImplementation_);
    }

    function _initializeOpenBudgetTcrDeployer(
        BudgetStackDeployer deployer_,
        address budgetTcr_,
        address premiumEscrowImplementation_
    ) internal {
        deployer_.initializeWithConfig(budgetTcr_, _openStackModuleConfig(premiumEscrowImplementation_));
    }

    function _deployBudgetTcrDeployer() internal returns (BudgetStackDeployer) {
        RoundFactory roundFactory = new RoundFactory(
            address(new RoundSubmissionTCR()),
            address(new RoundPrizeVault()),
            address(new PrizePoolSubmissionDepositStrategy()),
            address(new ERC20VotesArbitrator())
        );
        TeamFlowFactory teamFlowFactory = new TeamFlowFactory(address(new TeamFlow()));
        BudgetStackDeployer implementation = new BudgetStackDeployer(
            address(new BudgetTreasury()),
            address(roundFactory),
            address(teamFlowFactory),
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
        return BudgetStackDeployer(Clones.clone(address(implementation)));
    }

    function _approveRemoveCost(address who) internal returns (uint256 removeCost) {
        (, removeCost,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), removeCost);
    }

    function _assertBudgetStackTopology(
        IBudgetStackTopologyReader.BudgetStackTopology memory actual,
        IBudgetStackTopologyReader.BudgetStackTopology memory expected
    ) internal pure {
        assertEq(actual.childFlow, expected.childFlow);
        assertEq(actual.budgetTreasury, expected.budgetTreasury);
        assertEq(actual.premiumEscrow, expected.premiumEscrow);
        assertEq(actual.strategy, expected.strategy);
        assertEq(actual.allocationMechanism, expected.allocationMechanism);
        assertEq(actual.allocationMechanismArbitrator, expected.allocationMechanismArbitrator);
    }

    function _registerDefaultListing() internal returns (bytes32 itemID) {
        _approveAddCost(requester);
        itemID = _submitListing(requester, _defaultListing());
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRegistrationPending(itemID));
        budgetTcr.activateRegisteredBudget(itemID);
        budgetTcr.withdrawFeesAndRewards(requester, itemID, 0, 0);
    }

    function _queueRemovalRequest(bytes32 itemID) internal {
        _approveRemoveCost(requester);
        vm.prank(requester);
        budgetTcr.removeItem(itemID, "");
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
    }

    function _submitListing(address submitter, IBudgetTCR.BudgetListing memory listing)
        internal
        returns (bytes32 itemID)
    {
        vm.prank(submitter);
        itemID = budgetTcr.addItem(abi.encode(listing));
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing.metadata = FlowTypes.RecipientMetadata({
            title: "Budget A",
            description: "Budget A description",
            image: "ipfs://budget-a-image",
            tagline: "ship budget a",
            url: "https://example.com/budget-a"
        });
        listing.fundingDeadline = uint64(block.timestamp + 10 days);
        listing.executionDuration = uint64(14 days);
        listing.activationThreshold = 100e18;
        listing.runwayCap = 1_000e18;
        listing.oracleConfig = IBudgetTCR.OracleConfig({
            oracleSpecHash: keccak256("budget-oracle-spec"), assertionPolicyHash: keccak256("budget-assertion-policy")
        });
    }
}

contract BudgetTCRNonSpendPolicy {}

contract BudgetTCRProbeAwareZeroCoverageGatePolicy is IBudgetGatePolicy {
    function evaluateBudgetGate(SyncContext calldata context) external pure returns (SyncResult memory result) {
        if (
            context.itemID == bytes32(0) && address(context.goalFlow) == address(0) && context.childFlow == address(0)
                && context.budgetTreasury == address(0) && context.coverageSource == address(0)
                && context.coverageToCreditPpm == 0
        ) {
            result.failures = new CallFailure[](0);
            return result;
        }

        result.shouldSetRecipientEnabled = true;
        result.recipientEnabled = false;
        result.failures = new CallFailure[](0);
    }
}

contract BudgetTCRZeroContextOnlySpendPolicy is ISpendPolicy {
    error ACTIVE_CONTEXT_REJECTED();

    function targetFlowRate(SpendContext calldata ctx) external pure returns (int96) {
        if (ctx.timeRemaining == 0) return 0;
        revert ACTIVE_CONTEXT_REJECTED();
    }

    function syncMode() external pure returns (SyncMode) {
        return SyncMode.Capped;
    }
}

contract BudgetTCRInvalidSyncModeSpendPolicy is ISpendPolicy {
    function targetFlowRate(SpendContext calldata) external pure returns (int96) {
        return 1;
    }

    function syncMode() external pure returns (SyncMode) {
        assembly ("memory-safe") {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }
}

contract BudgetTCRMalformedSyncModeAbiSpendPolicy is ISpendPolicy {
    function targetFlowRate(SpendContext calldata) external pure returns (int96) {
        return 1;
    }

    function syncMode() external pure returns (SyncMode) {
        assembly ("memory-safe") {
            mstore(0x00, 1)
            return(0x1f, 0x01)
        }
    }
}

contract BudgetTCRTopologyHarness is BudgetTCR {
    function seedBudgetStackTopology(
        bytes32 itemID,
        IBudgetStackTopologyReader.BudgetStackTopology calldata topology,
        bool active
    ) external {
        _budgetDeployments[itemID] =
            BudgetTopologyRegistryLib.BudgetDeployment({
                childFlow: topology.childFlow,
                budgetTreasury: topology.budgetTreasury,
                premiumEscrow: topology.premiumEscrow,
                strategy: topology.strategy,
                allocationMechanism: topology.allocationMechanism,
                allocationMechanismArbitrator: topology.allocationMechanismArbitrator,
                active: active
            });
        _itemIdByBudgetTreasury[topology.budgetTreasury] = itemID;
        _itemIdByChildFlow[topology.childFlow] = itemID;
    }

    function seedStaleReverseIndexes(bytes32 itemID, address budgetTreasuryAlias, address childFlowAlias) external {
        _itemIdByBudgetTreasury[budgetTreasuryAlias] = itemID;
        _itemIdByChildFlow[childFlowAlias] = itemID;
    }
}

contract BudgetTCRRealFlowIntegrationTest is TestUtils, SpendPolicyTestUtils {
    address internal owner = makeAddr("owner");
    address internal allocationMechanismAdmin = makeAddr("allocation-mechanism-admin");
    address internal requester = makeAddr("requester");
    address internal keeper = makeAddr("keeper");
    address internal managerRewardPool = makeAddr("managerRewardPool");

    uint256 internal votingPeriod = 20;
    uint256 internal votingDelay = 2;
    uint256 internal revealPeriod = 15;
    uint256 internal arbitrationCost = 10e18;

    uint256 internal submissionBaseDeposit = 100e18;
    uint256 internal removalBaseDeposit = 50e18;
    uint256 internal submissionChallengeBaseDeposit = 120e18;
    uint256 internal removalChallengeBaseDeposit = 70e18;
    uint256 internal challengePeriodDuration = 3 days;
    ISubmissionDepositStrategy internal submissionDepositStrategy;

    MockVotesToken internal depositToken;
    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;

    FlowSuperfluidFrameworkDeployer internal sfDeployer;
    TestToken internal underlyingToken;
    SuperToken internal superToken;
    MockAllocationStrategy internal strategy;
    CustomFlow internal goalFlow;

    MockGoalTreasuryForBudgetTCR internal goalTreasury;
    BudgetStakeLedger internal budgetStakeLedger;

    BudgetTCR internal budgetTcr;
    ERC20VotesArbitrator internal arbitrator;
    address internal stackDeployer;
    address internal premiumEscrowImplementation;
    address internal underwriterSlasherRouter;
    address internal budgetSuccessResolver;
    address internal budgetSpendPolicy;
    address internal budgetGatePolicy;

    function onBudgetStackDeployed(bytes32, address, address, address, address) external pure {}

    function onBudgetAllocationMechanismDeployed(bytes32, address, address, address) external pure {}

    function setUp() public {
        depositToken = new MockVotesToken("BudgetTCR Votes", "BTV");
        goalToken = new MockVotesToken("GOAL", "GOAL");
        cobuildToken = new MockVotesToken("COBUILD", "COB");
        submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(depositToken)))));
        depositToken.mint(requester, 1_000_000e18);

        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        sfDeployer = new FlowSuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();
        (TestToken u, SuperToken s) =
            sfDeployer.deployWrapperSuperToken("MockUSD", "mUSD", 18, type(uint256).max, owner);
        underlyingToken = u;
        superToken = s;

        strategy = new MockAllocationStrategy();
        strategy.setUseAuxAsKey(true);

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(_deployBudgetTcrDeployer());
        premiumEscrowImplementation = address(new PremiumEscrow());
        budgetSuccessResolver = address(TreasuryUmaResolverMockFactory.deployResolver(IERC20(address(goalToken))));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));
        budgetGatePolicy = address(new StakeCoverageGatePolicy());

        CustomFlow goalFlowImplementation = new CustomFlow();
        address goalFlowProxy = _deployProxy(address(goalFlowImplementation), "");

        IAllocationStrategy strategies = IAllocationStrategy(address(strategy));

        FlowTypes.RecipientMetadata memory flowMetadata = FlowTypes.RecipientMetadata({
            title: "Goal Flow",
            description: "Goal flow for BudgetTCR real integration test",
            image: "ipfs://goal-flow",
            tagline: "goal-flow",
            url: "https://goal.flow.test"
        });

        IFlow.FlowParams memory flowParams = IFlow.FlowParams({managerRewardPoolFlowRatePpm: 100_000});

        vm.prank(owner);
        ICustomFlow(goalFlowProxy)
            .initialize(
                address(superToken),
                address(goalFlowImplementation),
                tcrInstance,
                tcrInstance,
                tcrInstance,
                managerRewardPool,
                address(0),
                address(0),
                flowParams,
                flowMetadata,
                strategies
            );
        goalFlow = CustomFlow(goalFlowProxy);

        goalTreasury = new MockGoalTreasuryForBudgetTCR(uint64(block.timestamp + 120 days));
        budgetStakeLedger = new BudgetStakeLedger(address(goalTreasury));
        goalTreasury.setBudgetStakeLedger(address(budgetStakeLedger));
        goalTreasury.setFlow(address(goalFlow));
        goalTreasury.setStakeVault(address(new MockStakeVaultForBudgetTCR(address(goalTreasury))));

        underwriterSlasherRouter = address(new MockUnderwriterSlasherRouter(address(this), goalTreasury.stakeVault()));
        _initializeOpenBudgetTcrDeployer(BudgetStackDeployer(stackDeployer), tcrInstance, premiumEscrowImplementation);

        bytes memory arbInit = _defaultArbitratorInitData(
            owner, address(depositToken), tcrInstance, votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address arbProxy = _deployProxy(address(arbImpl), arbInit);

        arbitrator = ERC20VotesArbitrator(arbProxy);
        budgetTcr = BudgetTCR(tcrInstance);
        budgetTcr.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());
    }

    function test_activateRegisteredBudget_deploysRealChildFlow_andRealLedgerWiring() public {
        bytes32 itemID = _registerDefaultListing();

        FlowTypes.FlowRecipient memory recipient = goalFlow.getRecipientById(itemID);
        address childFlow = recipient.recipient;
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();

        assertTrue(childFlow != address(0));
        assertFalse(recipient.isRemoved);
        assertTrue(IFlow(childFlow).recipientAdmin() != address(0));
        assertEq(IFlow(childFlow).flowOperator(), budgetTreasury);
        assertEq(IFlow(childFlow).sweeper(), budgetTreasury);
        assertEq(IFlow(childFlow).parent(), address(goalFlow));
        assertEq(
            address(PremiumEscrow(premiumEscrow).managerRewardPool()),
            address(IFlow(childFlow).managerRewardDistributionPool())
        );
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), budgetTreasury);
        assertEq(budgetStakeLedger.registeredBudgetCount(), 1);
        assertEq(budgetStakeLedger.trackedBudgetCount(), 1);
    }

    function test_syncBudgetTreasuries_realFlow_activatesFundedBudget() public {
        bytes32 itemID = _registerDefaultListing();
        address childFlow = goalFlow.getRecipientById(itemID).recipient;
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _mintSuperToken(owner, 100e18);
        vm.prank(owner);
        superToken.transfer(childFlow, 100e18);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(keeper);
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGe(IFlow(childFlow).targetOutflowRate(), IBudgetTreasury(budgetTreasury).targetFlowRate());
        assertGt(uint256(uint96(IFlow(childFlow).targetOutflowRate())), 0);
    }

    function test_syncBudgetTreasuries_realFlow_mixedBatch_onlyFundedBudgetActivates() public {
        bytes32 fundedItemID = _registerDefaultListing();
        bytes32 unfundedItemID = _registerDefaultListing();

        address fundedChildFlow = goalFlow.getRecipientById(fundedItemID).recipient;
        address unfundedChildFlow = goalFlow.getRecipientById(unfundedItemID).recipient;
        address fundedBudgetTreasury = budgetStakeLedger.budgetForRecipient(fundedItemID);
        address unfundedBudgetTreasury = budgetStakeLedger.budgetForRecipient(unfundedItemID);

        _mintSuperToken(owner, 100e18);
        vm.prank(owner);
        superToken.transfer(fundedChildFlow, 100e18);

        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = fundedItemID;
        itemIDs[1] = unfundedItemID;

        vm.prank(keeper);
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 2);
        assertEq(succeeded, 2);
        assertEq(uint256(IBudgetTreasury(fundedBudgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(uint256(IBudgetTreasury(unfundedBudgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Funding));
        assertGt(uint256(uint96(IFlow(fundedChildFlow).targetOutflowRate())), 0);
        assertEq(IFlow(unfundedChildFlow).targetOutflowRate(), 0);
        assertGt(IBudgetTreasury(fundedBudgetTreasury).activatedAt(), 0);
        assertEq(IBudgetTreasury(unfundedBudgetTreasury).activatedAt(), 0);
    }

    function test_finalizeRemovedBudget_preActivation_realFlow_finalizesFailureAndClosesEscrow() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        address childFlow = goalFlow.getRecipientById(itemID).recipient;

        _executeRemovalRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);

        assertTrue(terminallyResolved);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertEq(budgetStakeLedger.trackedBudgetCount(), 0);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());
        assertTrue(PremiumEscrow(premiumEscrow).closed());
        assertEq(uint8(PremiumEscrow(premiumEscrow).finalState()), uint8(IBudgetTreasury.BudgetState.Failed));
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_retryRemovedBudgetResolution_activationLocked_realFlow_expiresAfterDeadline() public {
        bytes32 itemID = _registerDefaultListing();
        address childFlow = goalFlow.getRecipientById(itemID).recipient;
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        _activateBudget(childFlow, budgetTreasury, 100e18);

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.deadline(), block.timestamp);

        _executeRemovalRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);

        assertFalse(terminallyResolved);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertFalse(treasury.successResolutionDisabled());
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);

        _warpRoll(treasury.deadline() + 1);
        vm.prank(keeper);
        bool retryResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertTrue(retryResolved);
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Expired));
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_finalizeRemovedBudget_activationLocked_realFlow_preservesPendingSuccessAssertion() public {
        bytes32 itemID = _registerDefaultListing();
        address childFlow = goalFlow.getRecipientById(itemID).recipient;
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);

        _activateBudget(childFlow, budgetTreasury, 100e18);
        _warpRoll(treasury.fundingDeadline() + 1);

        bytes32 assertionId = keccak256("real-flow-budget-success-assertion");
        vm.prank(budgetSuccessResolver);
        treasury.registerSuccessAssertion(assertionId);

        _executeRemovalRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);

        assertFalse(terminallyResolved);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));
        assertFalse(treasury.successResolutionDisabled());
        assertEq(treasury.pendingSuccessAssertionId(), assertionId);
        assertFalse(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);
    }

    function _activateBudget(address childFlow, address budgetTreasury, uint256 fundingAmount) internal {
        _mintSuperToken(owner, fundingAmount);
        vm.prank(owner);
        superToken.transfer(childFlow, fundingAmount);
        IBudgetTreasury(budgetTreasury).sync();
    }

    function _mintSuperToken(address to, uint256 amount) internal {
        underlyingToken.mint(to, amount);
        vm.startPrank(to);
        underlyingToken.approve(address(superToken), amount);
        ISuperToken(address(superToken)).upgrade(amount);
        vm.stopPrank();
    }

    function _approveAddCost(address who) internal returns (uint256 addCost) {
        (addCost,,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), addCost);
    }

    function _approveRemoveCost(address who) internal returns (uint256 removeCost) {
        (, removeCost,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), removeCost);
    }

    function _registerDefaultListing() internal returns (bytes32 itemID) {
        _approveAddCost(requester);
        vm.prank(requester);
        itemID = budgetTcr.addItem(abi.encode(_defaultListing()));
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function _queueRemovalRequest(bytes32 itemID) internal {
        _approveRemoveCost(requester);
        vm.prank(requester);
        budgetTcr.removeItem(itemID, "");
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
    }

    function _executeRemovalRequest(bytes32 itemID) internal {
        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
    }

    function _defaultRegistryConfig() internal view returns (IBudgetTCR.InitConfig memory registryConfig) {
        registryConfig = IBudgetTCR.InitConfig({
            allocationMechanismAdmin: allocationMechanismAdmin,
            tcrConfig: IGeneralizedTCRConfig.RegistryConfig({
                arbitrator: IArbitrator(address(arbitrator)),
                votingToken: IVotes(address(depositToken)),
                submissionDepositStrategy: submissionDepositStrategy,
                registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                    arbitratorExtraData: bytes(""),
                    registrationMetaEvidence: "ipfs://budget-reg-meta",
                    clearingMetaEvidence: "ipfs://budget-clear-meta",
                    submissionBaseDeposit: submissionBaseDeposit,
                    removalBaseDeposit: removalBaseDeposit,
                    submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
                    removalChallengeBaseDeposit: removalChallengeBaseDeposit,
                    challengePeriodDuration: challengePeriodDuration
                })
            })
        });
    }

    function _defaultDeploymentConfig() internal view returns (IBudgetTCR.DeploymentConfig memory deploymentConfig) {
        deploymentConfig = IBudgetTCR.DeploymentConfig({
            stackDeployer: stackDeployer,
            discoveryEmitter: address(this),
            budgetSuccessResolver: budgetSuccessResolver,
            budgetSpendPolicy: budgetSpendPolicy,
            riskModuleRouting: BudgetTCRConfigHelpers.openRiskModuleRouting(
                budgetGatePolicy, premiumEscrowImplementation, underwriterSlasherRouter
            ),
            goalFlow: IFlow(address(goalFlow)),
            goalTreasury: IGoalTreasury(address(goalTreasury)),
            goalToken: IERC20(address(goalToken)),
            cobuildToken: IERC20(address(cobuildToken)),
            goalRulesets: IJBRulesets(address(0x1234)),
            goalRevnetId: 1,
            budgetPremiumPpm: 100_000,
            budgetSlashPpm: 50_000,
            budgetValidationBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1 days,
                maxFundingHorizon: 60 days,
                minExecutionDuration: 1 days,
                maxExecutionDuration: 30 days,
                minActivationThreshold: 1e18,
                maxActivationThreshold: 1_000_000e18,
                maxRunwayCap: 2_000_000e18
            }),
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        });
    }

    function _openStackModuleConfig(address premiumEscrowImplementation_)
        internal
        pure
        returns (BudgetStackTypes.StackModuleConfig memory stackModuleConfig)
    {
        stackModuleConfig = BudgetTCRConfigHelpers.openStackModuleConfig(premiumEscrowImplementation_);
    }

    function _initializeOpenBudgetTcrDeployer(
        BudgetStackDeployer deployer_,
        address budgetTcr_,
        address premiumEscrowImplementation_
    ) internal {
        deployer_.initializeWithConfig(budgetTcr_, _openStackModuleConfig(premiumEscrowImplementation_));
    }

    function _deployBudgetTcrDeployer() internal returns (BudgetStackDeployer) {
        RoundFactory roundFactory = new RoundFactory(
            address(new RoundSubmissionTCR()),
            address(new RoundPrizeVault()),
            address(new PrizePoolSubmissionDepositStrategy()),
            address(new ERC20VotesArbitrator())
        );
        TeamFlowFactory teamFlowFactory = new TeamFlowFactory(address(new TeamFlow()));
        BudgetStackDeployer implementation = new BudgetStackDeployer(
            address(new BudgetTreasury()),
            address(roundFactory),
            address(teamFlowFactory),
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
        return BudgetStackDeployer(Clones.clone(address(implementation)));
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing.metadata = FlowTypes.RecipientMetadata({
            title: "Budget A",
            description: "Budget A description",
            image: "ipfs://budget-a-image",
            tagline: "ship budget a",
            url: "https://example.com/budget-a"
        });
        listing.fundingDeadline = uint64(block.timestamp + 10 days);
        listing.executionDuration = uint64(14 days);
        listing.activationThreshold = 100e18;
        listing.runwayCap = 1_000e18;
        listing.oracleConfig = IBudgetTCR.OracleConfig({
            oracleSpecHash: keccak256("budget-oracle-spec"), assertionPolicyHash: keccak256("budget-assertion-policy")
        });
    }
}
