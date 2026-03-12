// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    ISuperfluid,
    ISuperToken,
    ISuperTokenFactory,
    ISuperfluidPool
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {JBApprovalStatus} from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/structs/JBTerminalConfig.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";

import {GoalFactory} from "src/goals/GoalFactory.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {ManagedBudgetController} from "src/goals/ManagedBudgetController.sol";
import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {SingleAllocatorStrategy} from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IBudgetStackDeployer} from "src/interfaces/IBudgetStackDeployer.sol";
import {IBudgetStackTopologyReader} from "src/interfaces/IBudgetStackTopologyReader.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {IManagedBudgetController} from "src/interfaces/IManagedBudgetController.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {LinearSpendPolicy} from "src/goals/policies/LinearSpendPolicy.sol";
import {StakeCoverageGatePolicy} from "src/goals/policies/StakeCoverageGatePolicy.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";

contract GoalFactorySpendPolicyDeployTest is Test, SpendPolicyTestUtils {
    uint256 internal constant COBUILD_REVNET_ID = 1;
    uint256 internal constant GOAL_REVNET_ID = 2;
    address internal constant PREDICTED_BUDGET_TCR = address(0xBEEF);
    address internal constant DEFAULT_ALLOCATION_MECHANISM_ADMIN = address(0xA11CE);
    address internal constant DEFAULT_INVALID_ROUND_REWARDS_SINK = address(0xCAFE);

    GoalFactory internal factory;
    FactoryDeployMockToken internal cobuildToken;
    FactoryDeployMockToken internal goalToken;
    FactoryDeployMockTokens internal tokens;
    FactoryDeployMockRulesets internal rulesets;
    FactoryDeployMockDirectory internal directory;
    FactoryDeployMockController internal controller;
    FactoryDeployMockRevDeployer internal revDeployer;
    FactoryDeployMockGoalTerminal internal goalTerminal;
    FactoryDeployMockSuperTokenFactory internal superTokenFactory;
    FactoryDeployMockSuperfluidHost internal superfluidHost;
    FactoryDeployMockBudgetTcrFactory internal budgetTcrFactory;
    BudgetTCRDeployer internal budgetTcrStackDeployerImplementation;
    FactoryDeployDummyContract internal successResolver;
    FactoryDeployDummyContract internal jbMultiTerminal;
    FactoryDeployDummyContract internal buybackHookDataHook;
    FactoryDeployDummyContract internal buybackHook;
    GoalTreasury internal goalTreasuryImpl;
    FactoryDeployMockStakeVault internal stakeVaultImpl;
    FactoryDeployMockFlow internal flowImpl;
    FactoryDeployMockSplitHook internal splitHookImpl;
    FactoryDeployMockBudgetStakeLedger internal budgetStakeLedgerImpl;
    FactoryDeployMockAllocationPipeline internal goalFlowAllocationLedgerPipelineImpl;
    FactoryDeployDummyContract internal premiumEscrowImpl;
    FactoryDeployDummyContract internal defaultSubmissionDepositStrategy;
    FactoryDeployMockJurorSlasherRouter internal jurorSlasherRouterImpl;
    FactoryDeployMockUnderwriterSlasherRouter internal underwriterSlasherRouterImpl;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    LinearSpendPolicy internal defaultGoalSpendPolicy;
    LinearSpendPolicy internal defaultBudgetSpendPolicy;
    StakeCoverageGatePolicy internal openBudgetGatePolicy;

    function setUp() public {
        cobuildToken = new FactoryDeployMockToken("Cobuild", "CBD");
        goalToken = new FactoryDeployMockToken("Goal", "GOAL");
        tokens = new FactoryDeployMockTokens();
        rulesets = new FactoryDeployMockRulesets();
        directory = new FactoryDeployMockDirectory();
        controller = new FactoryDeployMockController(address(tokens), address(rulesets));
        revDeployer = new FactoryDeployMockRevDeployer(address(directory), address(controller), GOAL_REVNET_ID);
        superTokenFactory = new FactoryDeployMockSuperTokenFactory();
        superfluidHost = new FactoryDeployMockSuperfluidHost(address(superTokenFactory));
        budgetTcrStackDeployerImplementation = _deployBudgetTcrDeployerImplementation();
        budgetTcrFactory =
            new FactoryDeployMockBudgetTcrFactory(PREDICTED_BUDGET_TCR, address(budgetTcrStackDeployerImplementation));
        successResolver = new FactoryDeployDummyContract();
        jbMultiTerminal = new FactoryDeployDummyContract();
        buybackHookDataHook = new FactoryDeployDummyContract();
        buybackHook = new FactoryDeployDummyContract();
        goalTreasuryImpl = new GoalTreasury();
        stakeVaultImpl = new FactoryDeployMockStakeVault();
        flowImpl = new FactoryDeployMockFlow();
        splitHookImpl = new FactoryDeployMockSplitHook();
        budgetStakeLedgerImpl = new FactoryDeployMockBudgetStakeLedger();
        goalFlowAllocationLedgerPipelineImpl = new FactoryDeployMockAllocationPipeline();
        premiumEscrowImpl = new FactoryDeployDummyContract();
        defaultSubmissionDepositStrategy = new FactoryDeployDummyContract();
        jurorSlasherRouterImpl = new FactoryDeployMockJurorSlasherRouter();
        underwriterSlasherRouterImpl = new FactoryDeployMockUnderwriterSlasherRouter();
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(0));
        goalTerminal = new FactoryDeployMockGoalTerminal(
            IJBDirectory(address(directory)), IGoalDeploymentRegistry(address(goalDeploymentRegistry))
        );
        openBudgetGatePolicy = new StakeCoverageGatePolicy();
        defaultGoalSpendPolicy = _deployLinearSpendPolicy();
        defaultBudgetSpendPolicy = _deployBudgetSpendPolicy();

        rulesets.setDirectory(IJBDirectory(address(directory)));
        rulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 7 days), 1e18);

        tokens.setTokenOf(COBUILD_REVNET_ID, address(cobuildToken));
        tokens.setProjectIdOf(address(cobuildToken), COBUILD_REVNET_ID);
        tokens.setTokenOf(GOAL_REVNET_ID, address(goalToken));
        tokens.setProjectIdOf(address(goalToken), GOAL_REVNET_ID);

        directory.setController(COBUILD_REVNET_ID, address(controller));
        directory.setController(GOAL_REVNET_ID, address(controller));
        directory.setPrimaryTerminal(
            COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(new FactoryDeployDummyContract()))
        );

        factory = _deployFactoryWithDefaultPolicies(address(defaultGoalSpendPolicy), address(defaultBudgetSpendPolicy));
        goalDeploymentRegistry.setRegistrar(address(factory), true);
    }

    function test_constructor_setsDefaultSpendPolicyImmutables() public view {
        assertEq(factory.OPEN_BUDGET_GATE_POLICY(), address(openBudgetGatePolicy));
        assertEq(factory.DEFAULT_GOAL_SPEND_POLICY(), address(defaultGoalSpendPolicy));
        assertEq(factory.DEFAULT_BUDGET_SPEND_POLICY(), address(defaultBudgetSpendPolicy));
    }

    function test_constructor_deploysSharedManagedPresetInfra() public view {
        assertTrue(factory.MANAGED_BUDGET_CONTROLLER_IMPL().code.length > 0);
        assertTrue(factory.MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL().code.length > 0);
        assertTrue(factory.MANAGED_BUDGET_CHILD_STRATEGY_FACTORY_IMPL().code.length > 0);
        assertTrue(factory.MANAGED_PREMIUM_ESCROW_IMPL().code.length > 0);
    }

    function test_constructor_revertsWhenDefaultGoalSpendPolicyIsInvalid() public {
        LinearSpendPolicy invalidDefaultGoalSpendPolicy = new LinearSpendPolicy();

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_DEFAULT_SPEND_POLICY.selector, address(invalidDefaultGoalSpendPolicy)
            )
        );
        _deployFactoryWithDefaultPolicies(address(invalidDefaultGoalSpendPolicy), address(defaultBudgetSpendPolicy));
    }

    function test_constructor_revertsWhenDefaultBudgetSpendPolicyIsInvalid() public {
        LinearSpendPolicy invalidDefaultBudgetSpendPolicy = new LinearSpendPolicy();

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_DEFAULT_SPEND_POLICY.selector, address(invalidDefaultBudgetSpendPolicy)
            )
        );
        _deployFactoryWithDefaultPolicies(address(defaultGoalSpendPolicy), address(invalidDefaultBudgetSpendPolicy));
    }

    function test_constructor_revertsWhenDefaultSpendPolicyReportsInvalidSyncMode() public {
        address invalidDefaultSpendPolicy = address(new GoalFactoryInvalidSyncModeSpendPolicy());

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.INVALID_DEFAULT_SPEND_POLICY.selector, invalidDefaultSpendPolicy)
        );
        _deployFactoryWithDefaultPolicies(invalidDefaultSpendPolicy, address(defaultBudgetSpendPolicy));
    }

    function test_deployGoal_setsConfiguredSpendPolicyOnDeployedGoalTreasury() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(_baseDeployParams(address(spendPolicy)));

        assertEq(deployed.goalRevnetId, GOAL_REVNET_ID);
        assertEq(IGoalTreasury(deployed.goalTreasury).spendPolicy(), address(spendPolicy));
    }

    function test_deployGoal_usesDefaultGoalSpendPolicyWhenOmitted() public {
        GoalFactory.DeployParams memory params = _baseDeployParams(address(0));

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(params);

        assertEq(IGoalTreasury(deployed.goalTreasury).spendPolicy(), address(defaultGoalSpendPolicy));
    }

    function test_deployGoal_openPreset_passesSharedOpenBudgetGatePolicyToBudgetTcrFactory() public {
        GoalFactory.DeployParams memory params = _baseDeployParams(address(defaultGoalSpendPolicy));

        factory.deployGoal(params);

        assertEq(budgetTcrFactory.lastBudgetGatePolicy(), address(openBudgetGatePolicy));
    }

    function test_deployGoal_registersCanonicalGoalTreasury() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(_baseDeployParams(address(spendPolicy)));

        assertTrue(goalDeploymentRegistry.isRegisteredGoal(deployed.goalRevnetId));
        assertEq(goalDeploymentRegistry.goalTreasuryOf(deployed.goalRevnetId), deployed.goalTreasury);
    }

    function test_deployGoal_openPreset_preservesStakeVaultAllocatorAndBudgetTcrController() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(_baseDeployParams(address(spendPolicy)));

        assertEq(deployed.goalAllocatorStrategy, deployed.stakeVault);
        assertEq(deployed.budgetController, PREDICTED_BUDGET_TCR);
        assertEq(deployed.arbitrator, address(0xA11CE));
        assertEq(
            FactoryDeployMockJurorSlasherRouter(deployed.jurorSlasherRouter).authority(), address(budgetTcrFactory)
        );
        assertEq(
            FactoryDeployMockUnderwriterSlasherRouter(deployed.underwriterSlasherRouter).budgetController(),
            deployed.budgetController
        );
        assertEq(
            FactoryDeployMockUnderwriterSlasherRouter(deployed.underwriterSlasherRouter).goalFundingTarget(),
            deployed.goalFlow
        );
    }

    function test_deployGoal_revertsWhenFactoryIsNotAuthorizedRegistrar() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();
        goalDeploymentRegistry.setRegistrar(address(factory), false);
        GoalFactory.DeployParams memory params = _baseDeployParams(address(spendPolicy));

        vm.expectRevert(IGoalDeploymentRegistry.UNAUTHORIZED.selector);
        factory.deployGoal(params);
    }

    function test_deployGoal_passesConfiguredBudgetSpendPolicyToBudgetTcrFactory() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();
        LinearSpendPolicy configuredBudgetSpendPolicy = _deployBudgetSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(goalSpendPolicy));
        params.budgetTCR.budgetSpendPolicy = address(configuredBudgetSpendPolicy);

        factory.deployGoal(params);

        assertEq(budgetTcrFactory.lastBudgetSpendPolicy(), address(configuredBudgetSpendPolicy));
    }

    function test_deployGoal_passesDefaultBudgetSpendPolicyToBudgetTcrFactoryWhenOmitted() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(goalSpendPolicy));
        params.budgetTCR.budgetSpendPolicy = address(0);

        factory.deployGoal(params);

        assertEq(budgetTcrFactory.lastBudgetSpendPolicy(), address(defaultBudgetSpendPolicy));
    }

    function test_deployGoal_revertsWhenBudgetControllerDeploymentMismatchesPrediction() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(goalSpendPolicy));
        address deployedBudgetController = address(new FactoryDeployDummyContract());
        budgetTcrFactory.setDeployedBudgetTcr(deployedBudgetController);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.BUDGET_CONTROLLER_ADDRESS_MISMATCH.selector, PREDICTED_BUDGET_TCR, deployedBudgetController
            )
        );
        factory.deployGoal(params);
    }

    function test_deployGoal_managedPreset_deploysManagedControllerBundle() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(goalSpendPolicy));
        address managedSafe = address(new FactoryDeployDummyContract());
        params.preset = GoalFactory.GoalPreset.Managed;
        params.managedSafe = managedSafe;

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(params);

        ManagedBudgetController managedController = ManagedBudgetController(deployed.budgetController);
        SingleAllocatorStrategy strategy = SingleAllocatorStrategy(deployed.goalAllocatorStrategy);
        BudgetTCRDeployer stackDeployer = BudgetTCRDeployer(managedController.stackDeployer());
        IBudgetStackDeployer.StackModuleConfig memory stackConfig = stackDeployer.stackModuleConfig();

        assertEq(managedController.authority(), managedSafe);
        assertEq(managedController.goalTreasury(), deployed.goalTreasury);
        assertEq(managedController.goalFlow(), deployed.goalFlow);
        assertEq(managedController.budgetSuccessResolver(), params.budgetTCR.budgetSuccessResolver);
        assertEq(managedController.budgetSpendPolicy(), params.budgetTCR.budgetSpendPolicy);
        assertEq(IGoalTreasury(deployed.goalTreasury).budgetPremiumPpm(), params.underwriting.budgetPremiumPpm);
        assertEq(IGoalTreasury(deployed.goalTreasury).budgetSlashPpm(), params.underwriting.budgetSlashPpm);
        assertEq(IFlow(deployed.goalFlow).recipientAdmin(), deployed.budgetController);
        assertEq(strategy.allocator(), deployed.budgetController);
        assertEq(strategy.goalTreasury(), deployed.goalTreasury);
        assertEq(managedController.budgetGatePolicy(), address(0));
        assertTrue(deployed.budgetController != factory.MANAGED_BUDGET_CONTROLLER_IMPL());
        assertTrue(deployed.goalAllocatorStrategy != factory.MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL());
        assertTrue(managedController.stackDeployer() != address(0));
        assertTrue(managedController.stackDeployer() != address(budgetTcrStackDeployerImplementation));
        assertFalse(_sameRuntimeCode(managedController.stackDeployer(), address(budgetTcrStackDeployerImplementation)));
        assertEq(stackDeployer.controller(), deployed.budgetController);
        assertEq(uint8(stackConfig.childFlowStrategyMode), uint8(IBudgetStackDeployer.ChildFlowStrategyMode.Factory));
        assertEq(stackConfig.childFlowStrategyTarget, factory.MANAGED_BUDGET_CHILD_STRATEGY_FACTORY_IMPL());
        assertEq(uint8(stackConfig.mechanismLayerMode), uint8(IBudgetStackDeployer.MechanismLayerMode.None));
        assertEq(stackConfig.childFlowRecipientAdmin, deployed.budgetController);
        assertEq(uint8(stackConfig.premiumEscrowMode), uint8(IBudgetStackDeployer.PremiumEscrowMode.Shared));
        assertEq(stackDeployer.premiumEscrowImplementation(), factory.MANAGED_PREMIUM_ESCROW_IMPL());
        assertEq(deployed.arbitrator, address(0));
        assertEq(
            FactoryDeployMockJurorSlasherRouter(deployed.jurorSlasherRouter).authority(), deployed.budgetController
        );
        assertEq(
            FactoryDeployMockUnderwriterSlasherRouter(deployed.underwriterSlasherRouter).budgetController(),
            deployed.budgetController
        );
        assertEq(
            FactoryDeployMockUnderwriterSlasherRouter(deployed.underwriterSlasherRouter).goalFundingTarget(),
            deployed.goalFlow
        );
        assertFalse(_sameRuntimeCode(deployed.goalAllocatorStrategy, factory.MANAGED_GOAL_ALLOCATOR_STRATEGY_IMPL()));
    }

    function test_deployGoal_managedPreset_usesDefaultSpendPoliciesWhenOmitted() public {
        GoalFactory.DeployParams memory params = _baseDeployParams(address(0));
        address managedSafe = address(new FactoryDeployDummyContract());
        params.preset = GoalFactory.GoalPreset.Managed;
        params.managedSafe = managedSafe;
        params.budgetTCR.budgetSpendPolicy = address(0);

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(params);

        ManagedBudgetController managedController = ManagedBudgetController(deployed.budgetController);
        assertEq(IGoalTreasury(deployed.goalTreasury).spendPolicy(), address(defaultGoalSpendPolicy));
        assertEq(managedController.budgetSpendPolicy(), address(defaultBudgetSpendPolicy));
    }

    function test_deployGoal_managedPreset_reusesSharedInfraAcrossMultipleDeployments() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();

        GoalFactory.DeployParams memory firstParams = _baseDeployParams(address(goalSpendPolicy));
        firstParams.preset = GoalFactory.GoalPreset.Managed;
        firstParams.managedSafe = address(new FactoryDeployDummyContract());

        GoalFactory.DeployedGoalStack memory first = factory.deployGoal(firstParams);

        uint256 secondGoalRevnetId = GOAL_REVNET_ID + 1;
        FactoryDeployMockToken secondGoalToken = new FactoryDeployMockToken("Goal Two", "GL2");
        tokens.setTokenOf(secondGoalRevnetId, address(secondGoalToken));
        tokens.setProjectIdOf(address(secondGoalToken), secondGoalRevnetId);
        directory.setController(secondGoalRevnetId, address(controller));
        rulesets.configureTwoRulesetSchedule(secondGoalRevnetId, uint48(block.timestamp + 7 days), 1e18);
        revDeployer.setGoalRevnetId(secondGoalRevnetId);

        GoalFactory.DeployParams memory secondParams = _baseDeployParams(address(goalSpendPolicy));
        secondParams.preset = GoalFactory.GoalPreset.Managed;
        secondParams.managedSafe = address(new FactoryDeployDummyContract());

        GoalFactory.DeployedGoalStack memory second = factory.deployGoal(secondParams);

        ManagedBudgetController firstController = ManagedBudgetController(first.budgetController);
        ManagedBudgetController secondController = ManagedBudgetController(second.budgetController);
        SingleAllocatorStrategy firstStrategy = SingleAllocatorStrategy(first.goalAllocatorStrategy);
        SingleAllocatorStrategy secondStrategy = SingleAllocatorStrategy(second.goalAllocatorStrategy);

        assertEq(first.goalRevnetId, GOAL_REVNET_ID);
        assertEq(second.goalRevnetId, secondGoalRevnetId);
        assertEq(goalDeploymentRegistry.goalTreasuryOf(first.goalRevnetId), first.goalTreasury);
        assertEq(goalDeploymentRegistry.goalTreasuryOf(second.goalRevnetId), second.goalTreasury);

        assertEq(firstController.budgetGatePolicy(), address(0));
        assertEq(secondController.budgetGatePolicy(), address(0));

        assertEq(firstController.goalTreasury(), first.goalTreasury);
        assertEq(firstController.goalFlow(), first.goalFlow);
        assertEq(secondController.goalTreasury(), second.goalTreasury);
        assertEq(secondController.goalFlow(), second.goalFlow);
        assertEq(firstStrategy.goalTreasury(), first.goalTreasury);
        assertEq(firstStrategy.allocator(), first.budgetController);
        assertEq(secondStrategy.goalTreasury(), second.goalTreasury);
        assertEq(secondStrategy.allocator(), second.budgetController);

        assertTrue(first.budgetController != second.budgetController);
        assertTrue(first.goalAllocatorStrategy != second.goalAllocatorStrategy);
        assertTrue(first.goalTreasury != second.goalTreasury);
        assertTrue(first.goalFlow != second.goalFlow);
        assertTrue(firstController.stackDeployer() != secondController.stackDeployer());
        assertTrue(_sameRuntimeCode(first.budgetController, second.budgetController));
        assertTrue(_sameRuntimeCode(first.goalAllocatorStrategy, second.goalAllocatorStrategy));
        assertTrue(_sameRuntimeCode(firstController.stackDeployer(), secondController.stackDeployer()));
    }

    function test_deployGoal_managedPreset_canCreateMultipleBudgetsAndUpdateWeights() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(goalSpendPolicy));
        address managedSafe = address(new FactoryDeployDummyContract());
        params.preset = GoalFactory.GoalPreset.Managed;
        params.managedSafe = managedSafe;

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(params);

        ManagedBudgetController managedController = ManagedBudgetController(deployed.budgetController);
        SingleAllocatorStrategy goalStrategy = SingleAllocatorStrategy(deployed.goalAllocatorStrategy);

        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));

        vm.startPrank(managedSafe);
        (address childFlowA, address treasuryA) =
            managedController.createBudget(itemA, _managedBudgetConfig("Budget A"));
        (address childFlowB, address treasuryB) =
            managedController.createBudget(itemB, _managedBudgetConfig("Budget B"));

        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = itemA;
        itemIDs[1] = itemB;

        uint32[] memory ppm = new uint32[](2);
        ppm[0] = 400_000;
        ppm[1] = 600_000;
        managedController.setBudgetWeights(itemIDs, ppm);
        vm.stopPrank();

        assertEq(managedController.activeBudgetCount(), 2);
        assertEq(managedController.activeBudgetIdAt(0), itemA);
        assertEq(managedController.activeBudgetIdAt(1), itemB);
        assertEq(managedController.itemIdForBudgetTreasury(treasuryA), itemA);
        assertEq(managedController.itemIdForBudgetTreasury(treasuryB), itemB);
        assertEq(managedController.itemIdForChildFlow(childFlowA), itemA);
        assertEq(managedController.itemIdForChildFlow(childFlowB), itemB);

        assertEq(IFlow(childFlowA).recipientAdmin(), deployed.budgetController);
        assertEq(IFlow(childFlowA).flowOperator(), treasuryA);
        assertEq(IFlow(childFlowA).sweeper(), treasuryA);
        assertEq(IFlow(childFlowB).recipientAdmin(), deployed.budgetController);
        assertEq(IFlow(childFlowB).flowOperator(), treasuryB);
        assertEq(IFlow(childFlowB).sweeper(), treasuryB);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyA,) =
            managedController.budgetStackTopology(itemA);
        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyB,) =
            managedController.budgetStackTopology(itemB);
        assertEq(BudgetSingleAllocatorStrategy(topologyA.strategy).allocator(), deployed.budgetController);
        assertEq(BudgetSingleAllocatorStrategy(topologyB.strategy).allocator(), deployed.budgetController);

        uint256 controllerKey = goalStrategy.allocationKey(deployed.budgetController, bytes(""));
        assertEq(
            IFlow(deployed.goalFlow).getAllocationCommitment(deployed.goalAllocatorStrategy, controllerKey),
            keccak256(abi.encode(itemIDs, ppm))
        );

        (uint256 attempted, uint256 succeeded) = managedController.syncBudgetTreasuries(itemIDs);
        assertEq(attempted, 2);
        assertEq(succeeded, 2);
    }

    function test_deployGoal_managedPreset_goalAllocatorIdentityStaysBoundToControllerAcrossAuthorityRotation() public {
        LinearSpendPolicy goalSpendPolicy = _deployLinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(goalSpendPolicy));
        address managedSafe = address(new FactoryDeployDummyContract());
        address rotatedSafe = address(new FactoryDeployDummyContract());
        params.preset = GoalFactory.GoalPreset.Managed;
        params.managedSafe = managedSafe;

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(params);

        ManagedBudgetController managedController = ManagedBudgetController(deployed.budgetController);
        SingleAllocatorStrategy goalStrategy = SingleAllocatorStrategy(deployed.goalAllocatorStrategy);
        bytes32 itemA = bytes32(uint256(1));

        vm.prank(managedSafe);
        (address childFlow,) = managedController.createBudget(itemA, _managedBudgetConfig("Budget A"));

        (IBudgetStackTopologyReader.BudgetStackTopology memory topology,) = managedController.budgetStackTopology(itemA);
        BudgetSingleAllocatorStrategy childStrategy = BudgetSingleAllocatorStrategy(topology.strategy);
        bytes32 childRecipientIdA = bytes32(uint256(11));
        bytes32 childRecipientIdB = bytes32(uint256(12));

        assertEq(goalStrategy.allocator(), deployed.budgetController);
        assertEq(childStrategy.allocator(), deployed.budgetController);
        assertEq(IFlow(childFlow).recipientAdmin(), deployed.budgetController);

        vm.prank(managedSafe);
        managedController.addBudgetFlowRecipient(
            itemA,
            childRecipientIdA,
            makeAddr("managed-child-recipient-a"),
            _managedChildRecipientMetadata("Managed Child Recipient A")
        );

        _assertGoalAllocatorMutationPathAbsent(goalStrategy, managedSafe);
        _assertBudgetAllocatorMutationPathAbsent(childStrategy, managedSafe);
        _assertSelectorAbsent(address(childStrategy), abi.encodeWithSignature("owner()"));

        vm.prank(managedSafe);
        managedController.transferAuthority(rotatedSafe);

        vm.prank(rotatedSafe);
        managedController.acceptAuthority();

        assertEq(managedController.authority(), rotatedSafe);
        assertEq(goalStrategy.allocator(), deployed.budgetController);
        assertEq(childStrategy.allocator(), deployed.budgetController);

        _assertGoalAllocatorMutationPathAbsent(goalStrategy, managedSafe);

        _assertGoalAllocatorMutationPathAbsent(goalStrategy, rotatedSafe);
        _assertBudgetAllocatorMutationPathAbsent(childStrategy, rotatedSafe);

        vm.prank(rotatedSafe);
        managedController.addBudgetFlowRecipient(
            itemA,
            childRecipientIdB,
            makeAddr("managed-child-recipient-b"),
            _managedChildRecipientMetadata("Managed Child Recipient B")
        );

        bytes32[] memory childRecipientIds = new bytes32[](2);
        childRecipientIds[0] = childRecipientIdA;
        childRecipientIds[1] = childRecipientIdB;
        uint32[] memory childPpm = new uint32[](2);
        childPpm[0] = 400_000;
        childPpm[1] = 600_000;

        vm.prank(rotatedSafe);
        managedController.setBudgetFlowWeights(itemA, childRecipientIds, childPpm);

        uint256 childControllerKey = childStrategy.allocationKey(deployed.budgetController, bytes(""));
        assertEq(
            IFlow(childFlow).getAllocationCommitment(address(childStrategy), childControllerKey),
            keccak256(abi.encode(childRecipientIds, childPpm))
        );
    }

    function test_deployGoalForCommunity_overridesCallerFundingContextWithRegistryFundingContext() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();
        FactoryDeployMockToken wrongToken = new FactoryDeployMockToken("Other", "OTH");
        GoalFactory.DeployParams memory params = _baseDeployParams(address(spendPolicy));
        params.funding = GoalFactory.FundingContext({paymentToken: address(wrongToken), paymentRevnetId: 999});

        FactoryDeployMockCommunityGoalRegistry registry = new FactoryDeployMockCommunityGoalRegistry(
            address(this),
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COBUILD_REVNET_ID,
            address(cobuildToken)
        );

        GoalFactory.DeployedGoalStack memory deployed =
            factory.deployGoalForCommunity(ICommunityGoalRegistry(address(registry)), params);

        assertEq(deployed.goalRevnetId, GOAL_REVNET_ID);
        assertEq(goalDeploymentRegistry.goalTreasuryOf(deployed.goalRevnetId), deployed.goalTreasury);
    }

    function test_deployGoalForCommunity_allowsPermissionlessCallers() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(spendPolicy));
        FactoryDeployMockCommunityGoalRegistry registry = new FactoryDeployMockCommunityGoalRegistry(
            makeAddr("registry-owner"),
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COBUILD_REVNET_ID,
            address(cobuildToken)
        );

        address caller = makeAddr("permissionless-caller");
        vm.prank(caller);
        GoalFactory.DeployedGoalStack memory deployed =
            factory.deployGoalForCommunity(ICommunityGoalRegistry(address(registry)), params);

        assertEq(deployed.goalRevnetId, GOAL_REVNET_ID);
        assertEq(goalDeploymentRegistry.goalTreasuryOf(deployed.goalRevnetId), deployed.goalTreasury);
    }

    function test_deployGoal_bubblesInvalidSpendPolicyFromGoalTreasuryInitialization() public {
        FactoryDeployDummyContract invalidPolicy = new FactoryDeployDummyContract();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(invalidPolicy));

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(params);
    }

    function test_deployGoal_revertsForUninitializedLinearSpendPolicyImplementation() public {
        LinearSpendPolicy invalidPolicy = new LinearSpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(invalidPolicy));

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(params);
    }

    function test_deployGoal_revertsForUninitializedLinearSpendPolicyClone() public {
        LinearSpendPolicy implementation = new LinearSpendPolicy();
        LinearSpendPolicy invalidPolicy = LinearSpendPolicy(Clones.clone(address(implementation)));
        GoalFactory.DeployParams memory params = _baseDeployParams(address(invalidPolicy));

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(params);
    }

    function test_deployGoal_revertsForPolicyThatFailsActiveContextValidation() public {
        ZeroContextOnlySpendPolicy invalidPolicy = new ZeroContextOnlySpendPolicy();
        GoalFactory.DeployParams memory params = _baseDeployParams(address(invalidPolicy));

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(params);
    }

    function _deployLinearSpendPolicy() internal returns (LinearSpendPolicy policy) {
        policy = _deployLinearSpendPolicy(false, 0, ISpendPolicy.SyncMode.LinearSpendDownFallback);
    }

    function _deployBudgetSpendPolicy() internal returns (LinearSpendPolicy policy) {
        policy = _deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped);
    }

    function _deployFactoryWithDefaultPolicies(address goalDefaultSpendPolicy, address budgetDefaultSpendPolicy)
        internal
        returns (GoalFactory deployedFactory)
    {
        deployedFactory = new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(address(superfluidHost)),
            BudgetTCRFactory(address(budgetTcrFactory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            address(goalTerminal),
            address(jbMultiTerminal),
            address(buybackHookDataHook),
            address(buybackHook),
            address(goalTreasuryImpl),
            address(stakeVaultImpl),
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            address(jurorSlasherRouterImpl),
            address(underwriterSlasherRouterImpl),
            address(openBudgetGatePolicy),
            goalDefaultSpendPolicy,
            budgetDefaultSpendPolicy,
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function _deployBudgetTcrDeployerImplementation() internal returns (BudgetTCRDeployer implementation) {
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        implementation = new BudgetTCRDeployer(
            address(new BudgetTreasury()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
    }

    function _baseDeployParams(address goalSpendPolicy) internal returns (GoalFactory.DeployParams memory p) {
        p.preset = GoalFactory.GoalPreset.Open;
        p.managedSafe = address(0);
        p.funding =
            GoalFactory.FundingContext({paymentToken: address(cobuildToken), paymentRevnetId: COBUILD_REVNET_ID});
        p.revnet = GoalFactory.RevnetParams({
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 1,
            cashOutTaxRate: 0,
            reservedPercent: 0,
            durationSeconds: 7 days
        });
        p.timing = GoalFactory.GoalTimingParams({minRaise: 0, minRaiseDurationSeconds: 0});
        p.success = GoalFactory.SuccessParams({
            successResolver: address(successResolver),
            successAssertionLiveness: 1 days,
            successAssertionBond: 0,
            successOracleSpecHash: keccak256("spec"),
            successAssertionPolicyHash: keccak256("policy")
        });
        p.flowMetadata = GoalFactory.FlowMetadataParams({
            title: "title",
            description: "description",
            image: "ipfs://image",
            tagline: "tagline",
            url: "https://example.com"
        });
        p.underwriting = GoalFactory.UnderwritingParams({budgetPremiumPpm: 0, budgetSlashPpm: 0});
        p.budgetTCR = GoalFactory.BudgetTCRParams({
            allocationMechanismAdmin: address(0),
            invalidRoundRewardsSink: address(0),
            submissionDepositStrategy: address(0),
            submissionBaseDeposit: 0,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            challengePeriodDuration: 0,
            arbitratorExtraData: bytes(""),
            budgetBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 0,
                maxFundingHorizon: 0,
                minExecutionDuration: 0,
                maxExecutionDuration: 0,
                minActivationThreshold: 0,
                maxActivationThreshold: 0,
                maxRunwayCap: 0
            }),
            oracleBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 0}),
            budgetSuccessResolver: address(successResolver),
            budgetSpendPolicy: address(_deployBudgetSpendPolicy()),
            arbitratorParams: IArbitrator.ArbitratorParams({
                votingPeriod: 0,
                votingDelay: 0,
                revealPeriod: 0,
                arbitrationCost: 0,
                wrongOrMissedSlashBps: 0,
                slashCallerBountyBps: 0
            })
        });
        p.goalSpendPolicy = goalSpendPolicy;
    }

    function _managedBudgetConfig(string memory title)
        internal
        view
        returns (IManagedBudgetController.BudgetConfig memory config)
    {
        config = IManagedBudgetController.BudgetConfig({
            metadata: FlowTypes.RecipientMetadata({
                title: title,
                description: string.concat(title, " description"),
                image: "ipfs://budget-image",
                tagline: "managed budget",
                url: "https://example.com/budget"
            }),
            fundingDeadline: uint64(block.timestamp + 7 days),
            executionDuration: 30 days,
            activationThreshold: 0,
            runwayCap: 0,
            successOracleSpecHash: keccak256(bytes(string.concat(title, "-spec"))),
            successAssertionPolicyHash: keccak256(bytes(string.concat(title, "-policy")))
        });
    }

    function _sameRuntimeCode(address a, address b) internal view returns (bool) {
        return a.codehash == b.codehash;
    }

    function _managedChildRecipientMetadata(string memory title)
        internal
        pure
        returns (FlowTypes.RecipientMetadata memory metadata)
    {
        metadata = FlowTypes.RecipientMetadata({
            title: title,
            description: string.concat(title, " description"),
            image: "ipfs://managed-child-image",
            tagline: "managed child",
            url: "https://example.com/managed-child"
        });
    }

    function _assertGoalAllocatorMutationPathAbsent(SingleAllocatorStrategy goalStrategy, address caller) internal {
        _assertSelectorAbsentAs(
            caller, address(goalStrategy), abi.encodeWithSignature("changeAllocator(address)", caller)
        );
    }

    function _assertBudgetAllocatorMutationPathAbsent(BudgetSingleAllocatorStrategy childStrategy, address caller)
        internal
    {
        _assertSelectorAbsentAs(
            caller, address(childStrategy), abi.encodeWithSignature("changeAllocator(address)", caller)
        );
        _assertSelectorAbsentAs(
            caller, address(childStrategy), abi.encodeWithSignature("transferOwnership(address)", caller)
        );
    }

    function _assertSelectorAbsent(address target, bytes memory callData) internal view {
        (bool success, bytes memory returnData) = target.staticcall(callData);
        assertFalse(success);
        assertEq(returnData.length, 0);
    }

    function _assertSelectorAbsentAs(address caller, address target, bytes memory callData) internal {
        vm.prank(caller);
        (bool success, bytes memory returnData) = target.call(callData);
        assertFalse(success);
        assertEq(returnData.length, 0);
    }
}

contract FactoryDeployMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract ZeroContextOnlySpendPolicy is ISpendPolicy {
    error ACTIVE_CONTEXT_REJECTED();

    function targetFlowRate(SpendContext calldata ctx) external pure returns (int96) {
        if (ctx.timeRemaining == 0) return 0;
        revert ACTIVE_CONTEXT_REJECTED();
    }

    function syncMode() external pure returns (SyncMode) {
        return SyncMode.Capped;
    }
}

contract GoalFactoryInvalidSyncModeSpendPolicy is ISpendPolicy {
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

contract FactoryDeployDummyContract {}

contract FactoryDeployMockBudgetTcrFactory {
    address internal immutable _predictedBudgetTcr;
    address internal immutable _stackDeployerImplementation;
    address public deployedBudgetTcr;
    address public lastBudgetSpendPolicy;
    address public lastBudgetGatePolicy;

    constructor(address predictedBudgetTcr_, address stackDeployerImplementation_) {
        _predictedBudgetTcr = predictedBudgetTcr_;
        _stackDeployerImplementation = stackDeployerImplementation_;
        deployedBudgetTcr = predictedBudgetTcr_;
    }

    function predictBudgetTCRAddress(address, address, address, uint256, address) external view returns (address) {
        return _predictedBudgetTcr;
    }

    function setDeployedBudgetTcr(address deployedBudgetTcr_) external {
        deployedBudgetTcr = deployedBudgetTcr_;
    }

    function deployBudgetTCRStackForGoal(
        BudgetTCRFactory.RegistryConfigInput calldata,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        IArbitrator.ArbitratorParams calldata
    ) external returns (BudgetTCRFactory.DeployedBudgetTCRStack memory deployed) {
        lastBudgetSpendPolicy = deploymentConfig.budgetSpendPolicy;
        lastBudgetGatePolicy = deploymentConfig.budgetGatePolicy;
        deployed.budgetTCR = deployedBudgetTcr;
        deployed.arbitrator = address(0xA11CE);
        deployed.token = address(0xCAFE);
    }

    function stackDeployerImplementation() external view returns (address) {
        return _stackDeployerImplementation;
    }
}

contract FactoryDeployBudgetTcrStackDeployerMetadataMock {
    address internal immutable _budgetTreasuryImplementation;

    constructor(address budgetTreasuryImplementation_) {
        _budgetTreasuryImplementation = budgetTreasuryImplementation_;
    }

    function budgetTreasuryImplementation() external view returns (address) {
        return _budgetTreasuryImplementation;
    }
}

contract FactoryDeployMockRevDeployer {
    address internal immutable _directory;
    address internal immutable _controller;
    uint256 internal _goalRevnetId;

    constructor(address directory_, address controller_, uint256 goalRevnetId_) {
        _directory = directory_;
        _controller = controller_;
        _goalRevnetId = goalRevnetId_;
    }

    function setGoalRevnetId(uint256 goalRevnetId_) external {
        _goalRevnetId = goalRevnetId_;
    }

    function deployFor(
        uint256,
        IREVDeployer.REVConfig calldata,
        JBTerminalConfig[] calldata,
        IREVDeployer.REVBuybackHookConfig calldata,
        IREVDeployer.REVSuckerDeploymentConfig calldata
    ) external view returns (uint256 revnetId) {
        revnetId = _goalRevnetId;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(_directory);
    }

    function CONTROLLER() external view returns (FactoryDeployMockController) {
        return FactoryDeployMockController(_controller);
    }
}

contract FactoryDeployMockController {
    address internal immutable _tokens;
    address internal immutable _rulesets;

    constructor(address tokens_, address rulesets_) {
        _tokens = tokens_;
        _rulesets = rulesets_;
    }

    function TOKENS() external view returns (IJBTokens) {
        return IJBTokens(_tokens);
    }

    function RULESETS() external view returns (IJBRulesets) {
        return IJBRulesets(_rulesets);
    }
}

contract FactoryDeployMockTokens {
    mapping(uint256 => address) internal _tokenOf;
    mapping(address => uint256) internal _projectIdOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function setProjectIdOf(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}

contract FactoryDeployMockRulesets {
    struct RulesetPair {
        JBRuleset base;
        JBRuleset terminal;
    }

    IJBDirectory internal _directory;
    mapping(uint256 => RulesetPair) internal _pairOf;

    function setDirectory(IJBDirectory directory_) external {
        _directory = directory_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function configureTwoRulesetSchedule(uint256 projectId, uint48 terminalStart, uint112 openWeight) external {
        uint48 nowTs = uint48(block.timestamp);
        _pairOf[projectId] = RulesetPair({
            base: JBRuleset({
                cycleNumber: 1,
                id: 1,
                basedOnId: 0,
                start: nowTs,
                duration: 0,
                weight: openWeight,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            }),
            terminal: JBRuleset({
                cycleNumber: 2,
                id: 2,
                basedOnId: 1,
                start: terminalStart,
                duration: 0,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            })
        });
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory) {
        return _pairOf[projectId].base;
    }

    function latestQueuedOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBApprovalStatus approvalStatus)
    {
        return (_pairOf[projectId].terminal, JBApprovalStatus.Approved);
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory) {
        if (rulesetId == _pairOf[projectId].base.id) return _pairOf[projectId].base;
        if (rulesetId == _pairOf[projectId].terminal.id) return _pairOf[projectId].terminal;
        return JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
    }
}

contract FactoryDeployMockDirectory {
    mapping(uint256 => address) internal _controllerOf;
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract FactoryDeployMockGoalTerminal {
    IJBDirectory private immutable _directory;
    IGoalDeploymentRegistry private immutable _goalDeploymentRegistry;

    constructor(IJBDirectory directory_, IGoalDeploymentRegistry goalDeploymentRegistry_) {
        _directory = directory_;
        _goalDeploymentRegistry = goalDeploymentRegistry_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function GOAL_DEPLOYMENT_REGISTRY() external view returns (IGoalDeploymentRegistry) {
        return _goalDeploymentRegistry;
    }
}

contract FactoryDeployMockCommunityGoalRegistry {
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

contract FactoryDeployMockSuperfluidHost {
    address private immutable _superTokenFactory;

    constructor(address superTokenFactory_) {
        _superTokenFactory = superTokenFactory_;
    }

    function getSuperTokenFactory() external view returns (ISuperTokenFactory) {
        return ISuperTokenFactory(_superTokenFactory);
    }
}

contract FactoryDeployMockSuperTokenFactory {
    function createERC20Wrapper(
        IERC20Metadata token,
        uint8,
        ISuperTokenFactory.Upgradability,
        string calldata,
        string calldata
    ) external returns (ISuperToken) {
        return ISuperToken(address(new FactoryDeployMockSuperToken(address(token))));
    }
}

contract FactoryDeployMockSuperToken is ERC20 {
    address private immutable _underlyingToken;

    constructor(address underlyingToken_) ERC20("Goal Super Token", "GOALX") {
        _underlyingToken = underlyingToken_;
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlyingToken;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FactoryDeployMockSplitHook {
    function initialize(IJBDirectory, IGoalTreasury, uint256) external {}
}

contract FactoryDeployMockFlow {
    struct RecipientInfo {
        address recipient;
        bool isRemoved;
    }

    ISuperToken public superToken;
    address public recipientAdmin;
    address public flowOperator;
    address public sweeper;
    ISuperfluidPool public distributionPool;
    ISuperfluidPool public managerRewardDistributionPool;
    address public managerRewardPool;
    address public allocationPipeline;
    address public parent;
    IAllocationStrategy public strategy;
    int96 public targetOutflowRate;

    mapping(bytes32 => RecipientInfo) internal _recipients;
    mapping(address => int96) internal _memberFlowRate;
    mapping(address => mapping(uint256 => bytes32)) internal _allocationCommitment;

    function initialize(
        address superToken_,
        address,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address managerRewardPool_,
        address allocationPipeline_,
        address parent_,
        IFlow.FlowParams memory,
        FlowTypes.RecipientMetadata memory,
        IAllocationStrategy strategy_
    ) external {
        superToken = ISuperToken(superToken_);
        recipientAdmin = recipientAdmin_;
        flowOperator = flowOperator_;
        sweeper = sweeper_;
        managerRewardPool = managerRewardPool_;
        allocationPipeline = allocationPipeline_;
        parent = parent_;
        strategy = strategy_;
        distributionPool = ISuperfluidPool(address(new FactoryDeployMockDistributionPool()));
        managerRewardDistributionPool = ISuperfluidPool(address(new FactoryDeployMockDistributionPool()));
    }

    function addFlowRecipient(
        bytes32 newRecipientId,
        FlowTypes.RecipientMetadata memory,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address managerRewardPool_,
        uint32,
        IAllocationStrategy strategy_
    ) external returns (bytes32 recipientId, address recipientAddress) {
        FactoryDeployMockFlow child = FactoryDeployMockFlow(Clones.clone(address(this)));
        child.initializeChild(
            address(superToken), recipientAdmin_, flowOperator_, sweeper_, managerRewardPool_, address(this), strategy_
        );
        recipientId = newRecipientId;
        recipientAddress = address(child);
        _recipients[newRecipientId] = RecipientInfo({recipient: recipientAddress, isRemoved: false});
        _memberFlowRate[recipientAddress] = 0;
    }

    function initializeChild(
        address superToken_,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address managerRewardPool_,
        address parent_,
        IAllocationStrategy strategy_
    ) external {
        superToken = ISuperToken(superToken_);
        recipientAdmin = recipientAdmin_;
        flowOperator = flowOperator_;
        sweeper = sweeper_;
        managerRewardPool = managerRewardPool_;
        parent = parent_;
        strategy = strategy_;
        distributionPool = ISuperfluidPool(address(new FactoryDeployMockDistributionPool()));
        managerRewardDistributionPool = ISuperfluidPool(address(new FactoryDeployMockDistributionPool()));
    }

    function addRecipient(bytes32 newRecipientId, address recipient, FlowTypes.RecipientMetadata memory)
        external
        returns (bytes32 recipientId, address recipientAddress)
    {
        if (msg.sender != recipientAdmin) revert();
        recipientId = newRecipientId;
        recipientAddress = recipient;
        _recipients[newRecipientId] = RecipientInfo({recipient: recipient, isRemoved: false});
        _memberFlowRate[recipient] = 0;
    }

    function setTargetOutflowRate(int96 targetOutflowRate_) external {
        targetOutflowRate = targetOutflowRate_;
    }

    function allocate(bytes32[] calldata recipientIds, uint32[] calldata allocationsPpm) external {
        _allocationCommitment[address(strategy)][uint256(uint160(msg.sender))] =
            keccak256(abi.encode(recipientIds, allocationsPpm));
    }

    function getAllocationCommitment(address strategyAddress, uint256 allocationKey) external view returns (bytes32) {
        return _allocationCommitment[strategyAddress][allocationKey];
    }

    function getMemberFlowRate(address member) external view returns (int96) {
        return _memberFlowRate[member];
    }

    function getActualFlowRate() external view returns (int96) {
        return targetOutflowRate;
    }

    function getNetFlowRate() external view returns (int96) {
        return -targetOutflowRate;
    }

    function getMaxSafeFlowRate() external pure returns (int96) {
        return type(int96).max;
    }

    function removeRecipient(bytes32 recipientId) external {
        _recipients[recipientId].isRemoved = true;
    }

    function setRecipientEnabled(bytes32, bool) external {}
}

contract FactoryDeployMockDistributionPool {
    function getTotalUnits() external pure returns (uint128) {
        return 0;
    }
}

contract FactoryDeployMockStakeVault {
    address public goalTreasury;
    IERC20 public goalToken;
    IERC20 public cobuildToken;
    address public jurorSlasher;
    address public underwriterSlasher;

    function initialize(address goalTreasury_, IERC20 goalToken_, IERC20 cobuildToken_, IJBRulesets, uint256, uint8)
        external
    {
        goalTreasury = goalTreasury_;
        goalToken = goalToken_;
        cobuildToken = cobuildToken_;
    }

    function setJurorSlasher(address slasher) external {
        jurorSlasher = slasher;
    }

    function setUnderwriterSlasher(address slasher) external {
        underwriterSlasher = slasher;
    }
}

contract FactoryDeployMockBudgetStakeLedger {
    address public goalTreasury;
    mapping(bytes32 => address) internal _budgetForRecipient;

    function initialize(address goalTreasury_) external {
        goalTreasury = goalTreasury_;
    }

    function registerBudget(bytes32 recipientId, address budget) external {
        _budgetForRecipient[recipientId] = budget;
    }

    function removeBudget(bytes32 recipientId) external {
        delete _budgetForRecipient[recipientId];
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetForRecipient[recipientId];
    }
}

contract FactoryDeployMockAllocationPipeline {
    address public allocationLedger;

    function initialize(address allocationLedger_) external {
        allocationLedger = allocationLedger_;
    }
}

contract FactoryDeployMockJurorSlasherRouter {
    IStakeVault public stakeVault;
    address public authority;

    function initialize(IStakeVault stakeVault_, address authority_) external {
        stakeVault = stakeVault_;
        authority = authority_;
    }
}

contract FactoryDeployMockUnderwriterSlasherRouter {
    IStakeVault public stakeVault;
    address public budgetController;
    address public goalFundingTarget;

    function initialize(
        IStakeVault stakeVault_,
        address budgetController_,
        IJBDirectory,
        uint256,
        IERC20Metadata,
        IERC20Metadata,
        ISuperToken,
        address goalFundingTarget_
    ) external {
        stakeVault = stakeVault_;
        budgetController = budgetController_;
        goalFundingTarget = goalFundingTarget_;
    }
}
