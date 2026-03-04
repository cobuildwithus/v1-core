// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {GoalFactory} from "src/goals/GoalFactory.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";

contract GoalFactoryUnderwritingSlashConfigGuardTest is Test {
    address internal constant REV_DEPLOYER = address(0x1001);
    address internal constant SUPERFLUID_HOST = address(0x1002);
    address internal constant BUDGET_TCR_FACTORY = address(0x1003);
    address internal constant DEFAULT_ALLOCATION_MECHANISM_ADMIN = address(0x1004);
    address internal constant DEFAULT_INVALID_ROUND_REWARDS_SINK = address(0x1005);

    GoalFactory internal factory;
    address internal configuredCobuildTerminal;
    address internal configuredStakeVaultImpl;
    address internal configuredBudgetStakeLedgerImpl;
    address internal configuredGoalFlowAllocationLedgerPipelineImpl;
    address internal configuredPremiumEscrowImpl;
    address internal configuredJurorSlasherRouterImpl;
    address internal configuredUnderwriterSlasherRouterImpl;
    address internal configuredBuybackHookDataHook;
    address internal configuredBuybackHook;

    function setUp() public {
        configuredCobuildTerminal = address(new DummyContract());
        configuredStakeVaultImpl = address(new DummyContract());
        configuredBudgetStakeLedgerImpl = address(new DummyContract());
        configuredGoalFlowAllocationLedgerPipelineImpl = address(new DummyContract());
        configuredPremiumEscrowImpl = address(new DummyContract());
        configuredJurorSlasherRouterImpl = address(new DummyContract());
        configuredUnderwriterSlasherRouterImpl = address(new DummyContract());
        configuredBuybackHookDataHook = address(new DummyContract());
        configuredBuybackHook = address(new DummyContract());
        factory = _newFactory(
            configuredStakeVaultImpl,
            configuredBudgetStakeLedgerImpl,
            configuredGoalFlowAllocationLedgerPipelineImpl,
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            configuredUnderwriterSlasherRouterImpl,
            DEFAULT_ALLOCATION_MECHANISM_ADMIN
        );
    }

    function test_constructor_revertsWhenDefaultAllocationMechanismAdminIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            address(0),
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenCobuildTerminalIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            address(0),
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenCobuildTerminalHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeCobuildTerminal = address(0xC0B1D);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeCobuildTerminal));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            noCodeCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenBuybackHookDataHookIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            address(0),
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenBuybackHookHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeBuybackHook = address(0xB00B);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeBuybackHook));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            noCodeBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenPremiumEscrowImplementationIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(0),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenBudgetStakeLedgerImplementationIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(0),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenBudgetStakeLedgerImplementationHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeBudgetStakeLedgerImpl = address(0xCA11AB1E);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeBudgetStakeLedgerImpl));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            noCodeBudgetStakeLedgerImpl,
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenGoalFlowAllocationLedgerPipelineImplementationIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(0),
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenGoalFlowAllocationLedgerPipelineImplementationHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodePipelineImpl = address(0xDA7A);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodePipelineImpl));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            noCodePipelineImpl,
            address(premiumEscrowImpl),
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenPremiumEscrowImplementationHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodePremiumEscrowImpl = address(0xCAFE);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodePremiumEscrowImpl));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            noCodePremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            address(underwriterSlasherRouterImpl),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenJurorSlasherRouterImplementationIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            configuredPremiumEscrowImpl,
            address(0),
            configuredUnderwriterSlasherRouterImpl,
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenJurorSlasherRouterImplementationHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeJurorRouterImpl = address(0xA11CE42);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeJurorRouterImpl));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            configuredPremiumEscrowImpl,
            noCodeJurorRouterImpl,
            configuredUnderwriterSlasherRouterImpl,
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenUnderwriterSlasherRouterImplementationIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            address(0),
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenUnderwriterSlasherRouterImplementationHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeRouterImpl = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeRouterImpl));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            configuredStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            noCodeRouterImpl,
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenStakeVaultImplementationIsZero() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            address(0),
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            configuredUnderwriterSlasherRouterImpl,
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_revertsWhenStakeVaultImplementationHasNoCode() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeStakeVaultImpl = address(0xA11CE);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeStakeVaultImpl));
        new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            noCodeStakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            configuredUnderwriterSlasherRouterImpl,
            address(defaultSubmissionDepositStrategy),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_constructor_setsStakeVaultImplementationImmutable() public view {
        assertEq(factory.STAKE_VAULT_IMPL(), configuredStakeVaultImpl);
    }

    function test_constructor_setsPremiumEscrowImplementationImmutable() public view {
        assertEq(factory.PREMIUM_ESCROW_IMPL(), configuredPremiumEscrowImpl);
    }

    function test_constructor_setsJurorSlasherRouterImplementationImmutable() public view {
        assertEq(factory.JUROR_SLASHER_ROUTER_IMPL(), configuredJurorSlasherRouterImpl);
    }

    function test_constructor_setsBudgetStakeLedgerImplementationImmutable() public view {
        assertEq(factory.BUDGET_STAKE_LEDGER_IMPL(), configuredBudgetStakeLedgerImpl);
    }

    function test_constructor_setsGoalFlowAllocationLedgerPipelineImplementationImmutable() public view {
        assertEq(factory.GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL(), configuredGoalFlowAllocationLedgerPipelineImpl);
    }

    function test_constructor_setsUnderwriterSlasherRouterImplementationImmutable() public view {
        assertEq(factory.UNDERWRITER_SLASHER_ROUTER_IMPL(), configuredUnderwriterSlasherRouterImpl);
    }

    function test_constructor_setsCobuildTerminalImmutable() public view {
        assertEq(factory.COBUILD_TERMINAL(), configuredCobuildTerminal);
    }

    function test_constructor_setsDefaultAllocationMechanismAdminImmutable() public view {
        assertEq(factory.DEFAULT_ALLOCATION_MECHANISM_ADMIN(), DEFAULT_ALLOCATION_MECHANISM_ADMIN);
    }

    function test_deployGoal_revertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.underwriting.coverageLambda = 10;
        p.underwriting.budgetPremiumPpm = 0;
        p.underwriting.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.underwriting.budgetPremiumPpm,
                p.underwriting.budgetSlashPpm,
                p.underwriting.coverageLambda
            )
        );
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSlashEnabledAndCoverageLambdaIsZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.underwriting.coverageLambda = 0;
        p.underwriting.budgetPremiumPpm = 100_000;
        p.underwriting.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.underwriting.budgetPremiumPpm,
                p.underwriting.budgetSlashPpm,
                p.underwriting.coverageLambda
            )
        );
        factory.deployGoal(p);
    }

    function _baseDeployParams() internal pure returns (GoalFactory.DeployParams memory p) {
        p.revnet = GoalFactory.RevnetParams({
            owner: address(0xAAAA),
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
            successResolver: address(0xBBBB),
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
    }

    function _newFactory(
        address stakeVaultImpl,
        address budgetStakeLedgerImpl,
        address goalFlowAllocationLedgerPipelineImpl,
        address premiumEscrowImpl,
        address jurorSlasherRouterImpl,
        address underwriterSlasherRouterImpl,
        address allocationMechanismAdmin
    ) internal returns (GoalFactory) {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        return new GoalFactory(
            IREVDeployer(REV_DEPLOYER),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            address(goalTreasuryImpl),
            stakeVaultImpl,
            address(flowImpl),
            address(splitHookImpl),
            budgetStakeLedgerImpl,
            goalFlowAllocationLedgerPipelineImpl,
            premiumEscrowImpl,
            jurorSlasherRouterImpl,
            underwriterSlasherRouterImpl,
            address(defaultSubmissionDepositStrategy),
            allocationMechanismAdmin,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }
}

contract DummyContract {}

contract MockToken is ERC20 {
    constructor() ERC20("Cobuild", "CBD") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
