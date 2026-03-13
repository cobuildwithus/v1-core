// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GoalFactory} from "src/goals/GoalFactory.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {CobuildGoalTerminal} from "src/juicebox/CobuildGoalTerminal.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {StakeCoverageGatePolicy} from "src/goals/policies/StakeCoverageGatePolicy.sol";
import {ManagedBudgetController} from "src/goals/ManagedBudgetController.sol";
import {SingleAllocatorStrategy} from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {BudgetSingleAllocatorStrategyFactory} from "src/allocation-strategies/BudgetSingleAllocatorStrategyFactory.sol";
import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {BudgetStackDeployer} from "src/goals/BudgetStackDeployer.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/structs/JBTerminalConfig.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig,
    TreasuryUmaResolverMockFactory
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";

contract GoalFactoryUnderwritingSlashConfigGuardTest is Test {
    uint256 internal constant PAYMENT_REVNET_ID = 1;
    uint24 internal constant DEFAULT_BUYBACK_POOL_FEE = 3_000;
    uint32 internal constant DEFAULT_BUYBACK_POOL_TWAP_WINDOW = 1 hours;
    address internal constant SUPERFLUID_HOST = address(0x1002);
    address internal constant DEFAULT_ALLOCATION_MECHANISM_ADMIN = address(0x1004);
    address internal constant DEFAULT_INVALID_ROUND_REWARDS_SINK = address(0x1005);

    GoalFactory internal factory;
    MockBudgetTcrFactory internal budgetTcrFactory;
    BudgetStackDeployer internal budgetTcrStackDeployerImplementation;
    MockDirectory internal revnetDirectory;
    MockTokens internal revnetTokens;
    MockController internal revnetController;
    MockRevDeployer internal revDeployer;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    MockToken internal paymentToken;
    address internal configuredGoalPaymentTerminal;
    address internal configuredJbMultiTerminal;
    address internal configuredGoalTreasuryImpl;
    address internal configuredGoalSpendPolicy;
    address internal configuredSuccessResolver;
    address internal configuredFlowImpl;
    address internal configuredSplitHookImpl;
    address internal configuredDefaultSubmissionDepositStrategy;
    address internal configuredStakeVaultImpl;
    address internal configuredBudgetStakeLedgerImpl;
    address internal configuredGoalFlowAllocationLedgerPipelineImpl;
    address internal configuredPremiumEscrowImpl;
    address internal configuredJurorSlasherRouterImpl;
    address internal configuredUnderwriterSlasherRouterImpl;
    address internal configuredManagedBudgetControllerImpl;
    address internal configuredManagedGoalAllocatorStrategyImpl;
    address internal configuredManagedBudgetChildStrategyFactoryImpl;
    address internal configuredBuybackHookDataHook;
    address internal configuredBuybackHook;
    address internal configuredOpenBudgetGatePolicy;
    address internal configuredDefaultGoalSpendPolicy;
    address internal configuredDefaultBudgetSpendPolicy;

    function setUp() public {
        revnetDirectory = new MockDirectory();
        revnetTokens = new MockTokens();
        revnetController = new MockController(address(revnetTokens));
        revDeployer = new MockRevDeployer(address(revnetDirectory), address(revnetController));
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(0));
        paymentToken = new MockToken();
        budgetTcrStackDeployerImplementation = _deployBudgetTcrDeployerImplementation();
        budgetTcrFactory = new MockBudgetTcrFactory(address(budgetTcrStackDeployerImplementation));

        configuredJbMultiTerminal = address(new DummyContract());
        configuredGoalTreasuryImpl = address(new DummyContract());
        configuredGoalSpendPolicy = address(new DummyContract());
        configuredSuccessResolver =
            address(TreasuryUmaResolverMockFactory.deployResolver(IERC20(address(paymentToken))));
        configuredFlowImpl = address(new DummyContract());
        configuredSplitHookImpl = address(new DummyContract());
        configuredDefaultSubmissionDepositStrategy = address(new DummyContract());
        configuredStakeVaultImpl = address(new DummyContract());
        configuredBudgetStakeLedgerImpl = address(new DummyContract());
        configuredGoalFlowAllocationLedgerPipelineImpl = address(new DummyContract());
        configuredPremiumEscrowImpl = address(new DummyContract());
        configuredJurorSlasherRouterImpl = address(new DummyContract());
        configuredUnderwriterSlasherRouterImpl = address(new DummyContract());
        configuredManagedBudgetControllerImpl = address(new ManagedBudgetController());
        configuredManagedGoalAllocatorStrategyImpl = address(new SingleAllocatorStrategy(address(0), address(0)));
        address managedBudgetChildStrategyImpl = address(new BudgetSingleAllocatorStrategy(address(0), address(0)));
        configuredManagedBudgetChildStrategyFactoryImpl =
            address(new BudgetSingleAllocatorStrategyFactory(managedBudgetChildStrategyImpl));
        configuredBuybackHookDataHook = address(new DummyContract());
        configuredBuybackHook = address(new DummyContract());
        configuredOpenBudgetGatePolicy = address(new StakeCoverageGatePolicy());
        configuredDefaultGoalSpendPolicy = address(new MockSpendPolicy());
        configuredDefaultBudgetSpendPolicy = address(new MockSpendPolicy());

        revnetTokens.setTokenOf(PAYMENT_REVNET_ID, address(paymentToken));
        revnetDirectory.setPrimaryTerminal(
            PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(new DummyTerminal()))
        );
        configuredGoalPaymentTerminal = address(
            new CobuildGoalTerminal(
                IJBDirectory(address(revnetDirectory)), IGoalDeploymentRegistry(address(goalDeploymentRegistry))
            )
        );

        factory = _deployFactory(configuredGoalPaymentTerminal);
        goalDeploymentRegistry.setRegistrar(address(factory), true);
    }

    function test_constructor_revertsWhenGoalPaymentTerminalIsZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactory(address(0));
    }

    function test_constructor_revertsWhenGoalPaymentTerminalHasNoCode() public {
        address noCodeGoalPaymentTerminal = address(0xC0B1D);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeGoalPaymentTerminal));
        _deployFactory(noCodeGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenManagedBudgetControllerImplIsZero() public {
        configuredManagedBudgetControllerImpl = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenManagedBudgetControllerImplHasNoCode() public {
        configuredManagedBudgetControllerImpl = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, configuredManagedBudgetControllerImpl)
        );
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenManagedGoalAllocatorStrategyImplIsZero() public {
        configuredManagedGoalAllocatorStrategyImpl = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenManagedGoalAllocatorStrategyImplHasNoCode() public {
        configuredManagedGoalAllocatorStrategyImpl = address(0xCAFE);

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, configuredManagedGoalAllocatorStrategyImpl)
        );
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenManagedBudgetChildStrategyFactoryImplIsZero() public {
        configuredManagedBudgetChildStrategyFactoryImpl = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenManagedBudgetChildStrategyFactoryImplHasNoCode() public {
        configuredManagedBudgetChildStrategyFactoryImpl = address(0xD00D);

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, configuredManagedBudgetChildStrategyFactoryImpl)
        );
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenOpenBudgetGatePolicyIsNotABudgetGatePolicy() public {
        configuredOpenBudgetGatePolicy = address(new DummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_BUDGET_GATE_POLICY.selector, configuredOpenBudgetGatePolicy)
        );
        _deployFactory(configuredGoalPaymentTerminal);
    }

    function test_constructor_revertsWhenGoalPaymentTerminalDirectoryMismatch() public {
        MockDirectory wrongDirectory = new MockDirectory();
        address mismatchedTerminal = address(
            new CobuildGoalTerminal(
                IJBDirectory(address(wrongDirectory)), IGoalDeploymentRegistry(address(goalDeploymentRegistry))
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_GOAL_TERMINAL_DIRECTORY.selector, address(revnetDirectory), address(wrongDirectory)
            )
        );
        _deployFactory(mismatchedTerminal);
    }

    function test_constructor_revertsWhenGoalPaymentTerminalRegistryMismatch() public {
        GoalDeploymentRegistry wrongRegistry = new GoalDeploymentRegistry(address(this), address(0));
        address mismatchedTerminal = address(
            new CobuildGoalTerminal(
                IJBDirectory(address(revnetDirectory)), IGoalDeploymentRegistry(address(wrongRegistry))
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_GOAL_TERMINAL_REGISTRY.selector,
                address(goalDeploymentRegistry),
                address(wrongRegistry)
            )
        );
        _deployFactory(mismatchedTerminal);
    }

    function test_constructor_setsGoalPaymentTerminalImmutable() public view {
        assertEq(factory.GOAL_PAYMENT_TERMINAL(), configuredGoalPaymentTerminal);
    }

    function test_deployGoal_revertsWhenFundingRevnetTokenMismatch() public {
        MockToken wrongToken = new MockToken();
        revnetTokens.setTokenOf(PAYMENT_REVNET_ID, address(wrongToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_PAYMENT_REVNET_TOKEN.selector,
                address(paymentToken),
                address(wrongToken),
                PAYMENT_REVNET_ID
            )
        );
        factory.deployOpenGoal(_baseOpenGoalParams());
    }

    function test_deployGoal_revertsWhenFundingNativeTerminalMissing() public {
        revnetDirectory.setPrimaryTerminal(PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.INVALID_PAYMENT_NATIVE_TERMINAL.selector, address(0), PAYMENT_REVNET_ID)
        );
        factory.deployOpenGoal(_baseOpenGoalParams());
    }

    function test_deployGoal_revertsWhenFundingNativeTerminalIsGoalPaymentTerminal() public {
        revnetDirectory.setPrimaryTerminal(
            PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(configuredGoalPaymentTerminal)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_PAYMENT_NATIVE_TERMINAL.selector, configuredGoalPaymentTerminal, PAYMENT_REVNET_ID
            )
        );
        factory.deployOpenGoal(_baseOpenGoalParams());
    }

    function test_deployGoal_revertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.common.underwriting.budgetPremiumPpm = 0;
        p.common.underwriting.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.common.underwriting.budgetPremiumPpm,
                p.common.underwriting.budgetSlashPpm
            )
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_managedPreset_revertsWhenManagedSafeIsZero() public {
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(0));

        vm.expectRevert(GoalFactory.MANAGED_SAFE_REQUIRED.selector);
        factory.deployManagedGoal(p);
    }

    function test_deployGoal_managedPreset_revertsWhenManagedSafeHasNoCode() public {
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(0xBEEF));

        vm.expectRevert(abi.encodeWithSelector(GoalFactory.MANAGED_SAFE_NOT_CONTRACT.selector, p.managedSafe));
        factory.deployManagedGoal(p);
    }

    function test_deployGoal_managedPreset_revertsWhenPremiumOrSlashAreNonZero() public {
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(new DummyContract()));
        p.common.underwriting.budgetPremiumPpm = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH.selector,
                p.common.underwriting.budgetPremiumPpm,
                p.common.underwriting.budgetSlashPpm
            )
        );
        factory.deployManagedGoal(p);
    }

    function test_deployGoal_managedPreset_revertsWhenSlashIsNonZeroAndPremiumIsZero() public {
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(new DummyContract()));
        p.common.underwriting.budgetPremiumPpm = 0;
        p.common.underwriting.budgetSlashPpm = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.common.underwriting.budgetPremiumPpm,
                p.common.underwriting.budgetSlashPpm
            )
        );
        factory.deployManagedGoal(p);
    }

    function test_deployGoal_managedPreset_revertsWhenBudgetAssertionLivenessIsZero() public {
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(new DummyContract()));
        p.budgetRuntime.oracleBounds.liveness = 0;

        vm.expectRevert(GoalFactory.INVALID_ASSERTION_CONFIG.selector);
        factory.deployManagedGoal(p);
    }

    function test_deployGoal_revertsWhenGoalSuccessResolverHasNoCode() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.common.success.successResolver = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, p.common.success.successResolver));
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_revertsWhenGoalSuccessResolverProbeFails() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.common.success.successResolver = address(new DummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.INVALID_SUCCESS_RESOLVER.selector, p.common.success.successResolver)
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_revertsWhenBudgetSuccessResolverIsZero() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.budgetRuntime.budgetSuccessResolver = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_revertsWhenBudgetSuccessResolverHasNoCode() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.budgetRuntime.budgetSuccessResolver = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, p.budgetRuntime.budgetSuccessResolver)
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_revertsWhenBudgetSuccessResolverProbeFails() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.budgetRuntime.budgetSuccessResolver = address(new DummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.INVALID_SUCCESS_RESOLVER.selector, p.budgetRuntime.budgetSuccessResolver)
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_revertsWhenBudgetSpendPolicyHasNoCode() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.budgetRuntime.budgetSpendPolicy = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, p.budgetRuntime.budgetSpendPolicy));
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_usesDefaultGoalSpendPolicyWhenOmitted() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.common.goalSpendPolicy = address(0);
        _expectObservedRevnetDeploy();

        vm.expectRevert(
            abi.encodeWithSelector(
                MockRevDeployer.DeployForForwarding.selector,
                DEFAULT_BUYBACK_POOL_FEE,
                DEFAULT_BUYBACK_POOL_TWAP_WINDOW,
                true,
                true,
                true,
                true,
                true
            )
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_revertsWhenGoalSpendPolicyHasNoCode() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        p.common.goalSpendPolicy = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, p.common.goalSpendPolicy));
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_forwardsBuybackDefaultsAndConfiguredTerminalsToRevDeployer() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        _expectObservedRevnetDeploy();

        vm.expectRevert(
            abi.encodeWithSelector(
                MockRevDeployer.DeployForForwarding.selector,
                DEFAULT_BUYBACK_POOL_FEE,
                DEFAULT_BUYBACK_POOL_TWAP_WINDOW,
                true,
                true,
                true,
                true,
                true
            )
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoal_usesConfiguredJbMultiTerminalWithoutPaymentTokenTerminalLookup() public {
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        _expectObservedRevnetDeploy();
        revnetDirectory.setPrimaryTerminal(PAYMENT_REVNET_ID, p.common.funding.paymentToken, IJBTerminal(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                MockRevDeployer.DeployForForwarding.selector,
                DEFAULT_BUYBACK_POOL_FEE,
                DEFAULT_BUYBACK_POOL_TWAP_WINDOW,
                true,
                true,
                true,
                true,
                true
            )
        );
        factory.deployOpenGoal(p);
    }

    function test_deployGoalForCommunity_revertsWhenRegistryDirectoryMismatch() public {
        MockCommunityGoalRegistry registry = new MockCommunityGoalRegistry(
            address(this),
            IJBDirectory(address(new MockDirectory())),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            PAYMENT_REVNET_ID,
            address(paymentToken)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_COMMUNITY_DIRECTORY.selector,
                address(revnetDirectory),
                address(registry.directory())
            )
        );
        factory.deployOpenGoalForCommunity(ICommunityGoalRegistry(address(registry)), _baseOpenGoalParams());
    }

    function test_deployGoalForCommunity_revertsWhenRegistryDeploymentRegistryMismatch() public {
        GoalDeploymentRegistry wrongRegistry = new GoalDeploymentRegistry(address(this), address(0));
        MockCommunityGoalRegistry registry = new MockCommunityGoalRegistry(
            address(this),
            IJBDirectory(address(revnetDirectory)),
            IGoalDeploymentRegistry(address(wrongRegistry)),
            PAYMENT_REVNET_ID,
            address(paymentToken)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_COMMUNITY_GOAL_DEPLOYMENT_REGISTRY.selector,
                address(goalDeploymentRegistry),
                address(wrongRegistry)
            )
        );
        factory.deployOpenGoalForCommunity(ICommunityGoalRegistry(address(registry)), _baseOpenGoalParams());
    }

    function test_deployGoalForCommunity_allowsPermissionlessCallers() public {
        address registryOwner = makeAddr("registry-owner");
        MockCommunityGoalRegistry registry = new MockCommunityGoalRegistry(
            registryOwner,
            IJBDirectory(address(revnetDirectory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            PAYMENT_REVNET_ID,
            address(paymentToken)
        );
        GoalFactory.OpenGoalParams memory p = _baseOpenGoalParams();
        _expectObservedRevnetDeploy();
        address caller = makeAddr("permissionless-caller");

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockRevDeployer.DeployForForwarding.selector,
                DEFAULT_BUYBACK_POOL_FEE,
                DEFAULT_BUYBACK_POOL_TWAP_WINDOW,
                true,
                true,
                true,
                true,
                true
            )
        );
        factory.deployOpenGoalForCommunity(ICommunityGoalRegistry(address(registry)), p);
    }

    function test_deployManagedGoalForCommunity_revertsWhenManagedSafeIsZero() public {
        MockCommunityGoalRegistry registry = new MockCommunityGoalRegistry(
            address(this),
            IJBDirectory(address(revnetDirectory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            PAYMENT_REVNET_ID,
            address(paymentToken)
        );
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(0));

        vm.expectRevert(GoalFactory.MANAGED_SAFE_REQUIRED.selector);
        factory.deployManagedGoalForCommunity(ICommunityGoalRegistry(address(registry)), p);
    }

    function test_deployManagedGoalForCommunity_revertsWhenPremiumOrSlashAreNonZero() public {
        MockCommunityGoalRegistry registry = new MockCommunityGoalRegistry(
            address(this),
            IJBDirectory(address(revnetDirectory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            PAYMENT_REVNET_ID,
            address(paymentToken)
        );
        GoalFactory.ManagedGoalParams memory p = _baseManagedGoalParams(address(new DummyContract()));
        p.common.underwriting.budgetPremiumPpm = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH.selector,
                p.common.underwriting.budgetPremiumPpm,
                p.common.underwriting.budgetSlashPpm
            )
        );
        factory.deployManagedGoalForCommunity(ICommunityGoalRegistry(address(registry)), p);
    }

    function _expectObservedRevnetDeploy() internal {
        uint256 deploymentNonce = vm.getNonce(address(factory));
        address expectedSplitHook = vm.computeCreateAddress(address(factory), deploymentNonce + 1);
        revDeployer.setExpectedSplitHook(expectedSplitHook);
        revDeployer.setExpectedGoalPaymentTerminal(configuredGoalPaymentTerminal);
        revDeployer.setExpectedJbMultiTerminal(configuredJbMultiTerminal);
        revDeployer.setExpectedBuybackHooks(configuredBuybackHookDataHook, configuredBuybackHook);
        revDeployer.setRevertWithObserved(true);
    }

    function _deployBudgetTcrDeployerImplementation() internal returns (BudgetStackDeployer implementation) {
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        implementation = new BudgetStackDeployer(
            address(new DummyContract()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
    }

    function _baseOpenGoalParams() internal view returns (GoalFactory.OpenGoalParams memory p) {
        p.common = GoalFactory.CommonGoalParams({
            funding: GoalFactory.FundingContext({
                paymentToken: address(paymentToken), paymentRevnetId: PAYMENT_REVNET_ID
            }),
            revnet: GoalFactory.RevnetParams({
                name: "Goal",
                ticker: "GOAL",
                uri: "ipfs://goal",
                initialIssuance: 1,
                cashOutTaxRate: 0,
                reservedPercent: 0,
                durationSeconds: 7 days
            }),
            timing: GoalFactory.GoalTimingParams({minRaise: 0, minRaiseDurationSeconds: 0}),
            success: GoalFactory.SuccessParams({
                successResolver: configuredSuccessResolver,
                successAssertionLiveness: 1 days,
                successAssertionBond: 0,
                successOracleSpecHash: keccak256("spec"),
                successAssertionPolicyHash: keccak256("policy")
            }),
            flowMetadata: GoalFactory.FlowMetadataParams({
                title: "title",
                description: "description",
                image: "ipfs://image",
                tagline: "tagline",
                url: "https://example.com"
            }),
            underwriting: GoalFactory.UnderwritingParams({budgetPremiumPpm: 0, budgetSlashPpm: 0}),
            goalSpendPolicy: configuredGoalSpendPolicy
        });
        p.budgetRuntime = GoalFactory.BudgetRuntimeParams({
            budgetSuccessResolver: configuredSuccessResolver,
            budgetSpendPolicy: configuredGoalSpendPolicy,
            oracleBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 0})
        });
    }

    function _baseManagedGoalParams(address managedSafe)
        internal
        view
        returns (GoalFactory.ManagedGoalParams memory p)
    {
        GoalFactory.OpenGoalParams memory openParams = _baseOpenGoalParams();
        p.common = openParams.common;
        p.budgetRuntime = openParams.budgetRuntime;
        p.managedSafe = managedSafe;
        p.managedBudgetGatePolicy = address(0);
    }

    function _deployFactory(address goalPaymentTerminal) internal returns (GoalFactory goalFactory) {
        goalFactory = new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(address(budgetTcrFactory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            goalPaymentTerminal,
            configuredJbMultiTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            configuredGoalTreasuryImpl,
            configuredStakeVaultImpl,
            configuredFlowImpl,
            configuredSplitHookImpl,
            configuredBudgetStakeLedgerImpl,
            configuredGoalFlowAllocationLedgerPipelineImpl,
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            configuredUnderwriterSlasherRouterImpl,
            configuredManagedBudgetControllerImpl,
            configuredManagedGoalAllocatorStrategyImpl,
            configuredManagedBudgetChildStrategyFactoryImpl,
            configuredOpenBudgetGatePolicy,
            configuredDefaultGoalSpendPolicy,
            configuredDefaultBudgetSpendPolicy,
            configuredDefaultSubmissionDepositStrategy,
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }
}

contract DummyContract {}

contract DummyTerminal {
    function STORE() external pure returns (address) {
        return address(0xB0A1);
    }
}

contract MockSpendPolicy is ISpendPolicy {
    function targetFlowRate(SpendContext calldata) external pure returns (int96) {
        return 0;
    }

    function syncMode() external pure returns (SyncMode) {
        return SyncMode.Capped;
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Payment", "PAY") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract MockBudgetTcrFactory {
    address internal immutable _stackDeployerImplementation;

    constructor(address stackDeployerImplementation_) {
        _stackDeployerImplementation = stackDeployerImplementation_;
    }

    function stackDeployerImplementation() external view returns (address) {
        return _stackDeployerImplementation;
    }

    function authorizedCaller() external view returns (address) {
        return msg.sender;
    }
}

contract MockBudgetTcrStackDeployerMetadata {
    address internal immutable _budgetTreasuryImplementation;

    constructor(address budgetTreasuryImplementation_) {
        _budgetTreasuryImplementation = budgetTreasuryImplementation_;
    }

    function budgetTreasuryImplementation() external view returns (address) {
        return _budgetTreasuryImplementation;
    }
}

contract MockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract MockTokens {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract MockController {
    address internal immutable _tokens;

    constructor(address tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (MockTokens) {
        return MockTokens(_tokens);
    }
}

contract MockCommunityGoalRegistry {
    address public owner;
    IJBDirectory public directory;
    IGoalDeploymentRegistry public goalDeploymentRegistry;
    uint256 public communityRevnetId;
    address public communityToken;

    constructor(
        address owner_,
        IJBDirectory directory_,
        IGoalDeploymentRegistry goalDeploymentRegistry_,
        uint256 communityRevnetId_,
        address communityToken_
    ) {
        owner = owner_;
        directory = directory_;
        goalDeploymentRegistry = goalDeploymentRegistry_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
    }
}

contract MockRevDeployer {
    error DeployForForwarding(
        uint24 buybackPoolFee,
        uint32 buybackPoolTwapWindow,
        bool saltMatchesFactorySeed,
        bool splitHookMatchesExpected,
        bool buybackHooksForwarded,
        bool goalPaymentTerminalForwarded,
        bool jbMultiTerminalForwarded
    );

    address internal immutable _directory;
    address internal immutable _controller;
    bool internal _revertWithObserved;
    address internal _expectedBuybackDataHook;
    address internal _expectedBuybackHook;
    address internal _expectedSplitHook;
    address internal _expectedGoalPaymentTerminal;
    address internal _expectedJbMultiTerminal;

    constructor(address directory_, address controller_) {
        _directory = directory_;
        _controller = controller_;
    }

    function setRevertWithObserved(bool value) external {
        _revertWithObserved = value;
    }

    function setExpectedBuybackHooks(address dataHook, address hookToConfigure) external {
        _expectedBuybackDataHook = dataHook;
        _expectedBuybackHook = hookToConfigure;
    }

    function setExpectedSplitHook(address splitHook) external {
        _expectedSplitHook = splitHook;
    }

    function setExpectedGoalPaymentTerminal(address terminal) external {
        _expectedGoalPaymentTerminal = terminal;
    }

    function setExpectedJbMultiTerminal(address terminal) external {
        _expectedJbMultiTerminal = terminal;
    }

    function deployFor(
        uint256,
        IREVDeployer.REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        IREVDeployer.REVBuybackHookConfig calldata buybackHookConfiguration,
        IREVDeployer.REVSuckerDeploymentConfig calldata
    ) external returns (uint256 revnetId) {
        address splitHook = address(0);
        if (configuration.stageConfigurations.length != 0 && configuration.stageConfigurations[0].splits.length != 0) {
            splitHook = configuration.stageConfigurations[0].splits[0].beneficiary;
        }

        uint24 observedFee;
        uint32 observedTwapWindow;
        if (buybackHookConfiguration.poolConfigurations.length != 0) {
            IREVDeployer.REVBuybackPoolConfig calldata poolConfiguration =
                buybackHookConfiguration.poolConfigurations[0];
            observedFee = poolConfiguration.fee;
            observedTwapWindow = poolConfiguration.twapWindow;
        }

        if (_revertWithObserved) {
            bool saltMatchesFactorySeed = configuration.description.salt == keccak256(abi.encode(msg.sender, splitHook));
            bool splitHookMatchesExpected = splitHook == _expectedSplitHook;
            bool buybackHooksForwarded = buybackHookConfiguration.dataHook == _expectedBuybackDataHook
                && buybackHookConfiguration.hookToConfigure == _expectedBuybackHook;
            bool goalPaymentTerminalForwarded = terminalConfigurations.length > 0
                && address(terminalConfigurations[0].terminal) == _expectedGoalPaymentTerminal;
            bool jbMultiTerminalForwarded = terminalConfigurations.length > 1
                && address(terminalConfigurations[1].terminal) == _expectedJbMultiTerminal;

            revert DeployForForwarding(
                observedFee,
                observedTwapWindow,
                saltMatchesFactorySeed,
                splitHookMatchesExpected,
                buybackHooksForwarded,
                goalPaymentTerminalForwarded,
                jbMultiTerminalForwarded
            );
        }

        revnetId = 1;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(_directory);
    }

    function CONTROLLER() external view returns (MockController) {
        return MockController(_controller);
    }
}
