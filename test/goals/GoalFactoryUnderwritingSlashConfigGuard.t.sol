// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {GoalFactory} from "src/goals/GoalFactory.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {CobuildTerminal} from "src/juicebox/CobuildTerminal.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/structs/JBTerminalConfig.sol";

contract GoalFactoryUnderwritingSlashConfigGuardTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 1;
    uint24 internal constant DEFAULT_BUYBACK_POOL_FEE = 3_000;
    uint32 internal constant DEFAULT_BUYBACK_POOL_TWAP_WINDOW = 1 hours;
    address internal constant SUPERFLUID_HOST = address(0x1002);
    address internal constant BUDGET_TCR_FACTORY = address(0x1003);
    address internal constant DEFAULT_ALLOCATION_MECHANISM_ADMIN = address(0x1004);
    address internal constant DEFAULT_INVALID_ROUND_REWARDS_SINK = address(0x1005);

    GoalFactory internal factory;
    address internal configuredCobuildTerminal;
    address internal configuredJbMultiTerminal;
    address internal configuredGoalDeploymentRegistry;
    address internal configuredGoalTreasuryImpl;
    address internal configuredGoalSpendPolicy;
    address internal configuredFlowImpl;
    address internal configuredSplitHookImpl;
    address internal configuredDefaultSubmissionDepositStrategy;
    address internal configuredStakeVaultImpl;
    address internal configuredBudgetStakeLedgerImpl;
    address internal configuredGoalFlowAllocationLedgerPipelineImpl;
    address internal configuredPremiumEscrowImpl;
    address internal configuredJurorSlasherRouterImpl;
    address internal configuredUnderwriterSlasherRouterImpl;
    address internal configuredBuybackHookDataHook;
    address internal configuredBuybackHook;
    MockDirectory internal revnetDirectory;
    MockTokens internal revnetTokens;
    MockController internal revnetController;
    MockRevDeployer internal revDeployer;

    function setUp() public {
        revnetDirectory = new MockDirectory();
        revnetTokens = new MockTokens();
        revnetController = new MockController(address(revnetTokens), address(new DummyContract()));
        revDeployer = new MockRevDeployer(address(revnetDirectory), address(revnetController));
        address cobuildNativeTerminal = address(new DummyContract());
        revnetDirectory.setPrimaryTerminal(
            COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(cobuildNativeTerminal)
        );

        configuredStakeVaultImpl = address(new DummyContract());
        configuredBudgetStakeLedgerImpl = address(new DummyContract());
        configuredGoalFlowAllocationLedgerPipelineImpl = address(new DummyContract());
        configuredPremiumEscrowImpl = address(new DummyContract());
        configuredJurorSlasherRouterImpl = address(new DummyContract());
        configuredUnderwriterSlasherRouterImpl = address(new DummyContract());
        configuredGoalDeploymentRegistry = address(new GoalDeploymentRegistry(address(this), address(0)));
        configuredGoalTreasuryImpl = address(new DummyContract());
        configuredGoalSpendPolicy = address(new DummyContract());
        configuredFlowImpl = address(new DummyContract());
        configuredSplitHookImpl = address(new DummyContract());
        configuredDefaultSubmissionDepositStrategy = address(new DummyContract());
        configuredBuybackHookDataHook = address(new DummyContract());
        configuredBuybackHook = address(new DummyContract());
        configuredJbMultiTerminal = address(new DummyContract());
        revDeployer.setExpectedBuybackHooks(configuredBuybackHookDataHook, configuredBuybackHook);
        revDeployer.setExpectedJbMultiTerminal(configuredJbMultiTerminal);
        factory = _newFactory(
            configuredStakeVaultImpl,
            configuredBudgetStakeLedgerImpl,
            configuredGoalFlowAllocationLedgerPipelineImpl,
            configuredPremiumEscrowImpl,
            configuredJurorSlasherRouterImpl,
            configuredUnderwriterSlasherRouterImpl,
            DEFAULT_ALLOCATION_MECHANISM_ADMIN
        );
        revDeployer.setExpectedCobuildTerminal(configuredCobuildTerminal);
    }

    function test_constructor_revertsWhenDefaultAllocationMechanismAdminIsZero() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            address(0),
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            noCodeCobuildTerminal,
            configuredJbMultiTerminal,
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

    function test_constructor_revertsWhenJbMultiTerminalIsZero() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
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

    function test_constructor_revertsWhenJbMultiTerminalHasNoCode() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeJbMultiTerminal = address(0xB0A1);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeJbMultiTerminal));
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            noCodeJbMultiTerminal,
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

    function test_constructor_revertsWhenCobuildTerminalDirectoryMismatch() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        MockDirectory wrongDirectory = new MockDirectory();
        CobuildTerminal mismatchedTerminal =
            new CobuildTerminal(IJBDirectory(address(wrongDirectory)), address(cobuildToken), COBUILD_REVNET_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_COBUILD_TERMINAL_DIRECTORY.selector,
                address(revnetDirectory),
                address(wrongDirectory)
            )
        );
        _newFactoryForCobuildConfig(address(cobuildToken), COBUILD_REVNET_ID, address(mismatchedTerminal));
    }

    function test_constructor_revertsWhenCobuildTerminalTokenMismatch() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        MockToken wrongToken = new MockToken();
        CobuildTerminal mismatchedTerminal =
            new CobuildTerminal(IJBDirectory(address(revnetDirectory)), address(wrongToken), COBUILD_REVNET_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_COBUILD_TERMINAL_TOKEN.selector, address(cobuildToken), address(wrongToken)
            )
        );
        _newFactoryForCobuildConfig(address(cobuildToken), COBUILD_REVNET_ID, address(mismatchedTerminal));
    }

    function test_constructor_revertsWhenCobuildTerminalRevnetIdMismatch() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        uint256 wrongRevnetId = COBUILD_REVNET_ID + 1;
        CobuildTerminal mismatchedTerminal =
            new CobuildTerminal(IJBDirectory(address(revnetDirectory)), address(cobuildToken), wrongRevnetId);

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_COBUILD_TERMINAL_REVNET_ID.selector, COBUILD_REVNET_ID, wrongRevnetId
            )
        );
        _newFactoryForCobuildConfig(address(cobuildToken), COBUILD_REVNET_ID, address(mismatchedTerminal));
    }

    function test_constructor_revertsWhenCobuildRevnetTokenMismatch() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        MockToken wrongToken = new MockToken();
        revnetTokens.setTokenOf(COBUILD_REVNET_ID, address(wrongToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_COBUILD_REVNET_TOKEN.selector,
                address(cobuildToken),
                address(wrongToken),
                COBUILD_REVNET_ID
            )
        );
        _newFactoryForCobuildConfig(address(cobuildToken), COBUILD_REVNET_ID, configuredCobuildTerminal);
    }

    function test_constructor_revertsWhenCobuildNativeTerminalMissing() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        revnetDirectory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));

        vm.expectRevert(abi.encodeWithSelector(GoalFactory.INVALID_COBUILD_NATIVE_TERMINAL.selector, address(0)));
        _newFactoryForCobuildConfig(address(cobuildToken), COBUILD_REVNET_ID, configuredCobuildTerminal);
    }

    function test_constructor_revertsWhenCobuildNativeTerminalIsCobuildTerminal() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        revnetDirectory.setPrimaryTerminal(
            COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(configuredCobuildTerminal)
        );

        vm.expectRevert(
            abi.encodeWithSelector(GoalFactory.INVALID_COBUILD_NATIVE_TERMINAL.selector, configuredCobuildTerminal)
        );
        _newFactoryForCobuildConfig(address(cobuildToken), COBUILD_REVNET_ID, configuredCobuildTerminal);
    }

    function test_constructor_revertsWhenBuybackHookDataHookIsZero() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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

    function test_constructor_revertsWhenBuybackHookIsZero() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
            configuredBuybackHookDataHook,
            address(0),
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

    function test_constructor_revertsWhenBuybackHookDataHookHasNoCode() public {
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeBuybackHookDataHook = address(0xB00C);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeBuybackHookDataHook));
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
            noCodeBuybackHookDataHook,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract premiumEscrowImpl = new DummyContract();
        DummyContract underwriterSlasherRouterImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
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
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeJurorRouterImpl = address(0xA11CE42);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeJurorRouterImpl));
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeRouterImpl = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeRouterImpl));
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract budgetStakeLedgerImpl = new DummyContract();
        DummyContract goalFlowAllocationLedgerPipelineImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        address noCodeStakeVaultImpl = address(0xA11CE);
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCodeStakeVaultImpl));
        new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            1,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
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

    function test_constructor_setsJbMultiTerminalImmutable() public view {
        assertEq(factory.JB_MULTI_TERMINAL(), configuredJbMultiTerminal);
    }

    function test_constructor_setsDefaultAllocationMechanismAdminImmutable() public view {
        assertEq(factory.DEFAULT_ALLOCATION_MECHANISM_ADMIN(), DEFAULT_ALLOCATION_MECHANISM_ADMIN);
    }

    function test_deployGoal_revertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.underwriting.budgetPremiumPpm = 0;
        p.underwriting.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.underwriting.budgetPremiumPpm,
                p.underwriting.budgetSlashPpm
            )
        );
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenGoalSpendPolicyIsZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.goalSpendPolicy = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenGoalSpendPolicyHasNoCode() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.goalSpendPolicy = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, p.goalSpendPolicy));
        factory.deployGoal(p);
    }

    function test_deployGoal_allowsSlashEnabledWhenPremiumIsNonZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.underwriting.budgetPremiumPpm = 100_000;
        p.underwriting.budgetSlashPpm = 50_000;

        uint256 deploymentNonce = vm.getNonce(address(factory));
        address expectedSplitHook = vm.computeCreateAddress(address(factory), deploymentNonce + 1);
        revDeployer.setExpectedSplitHook(expectedSplitHook);
        revDeployer.setRevertWithObserved(true);
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
        factory.deployGoal(p);
    }

    function test_deployGoal_forwardsBuybackDefaultsAndFactorySeededSaltToRevDeployer() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        uint256 deploymentNonce = vm.getNonce(address(factory));
        address expectedSplitHook = vm.computeCreateAddress(address(factory), deploymentNonce + 1);
        revDeployer.setExpectedSplitHook(expectedSplitHook);
        revDeployer.setRevertWithObserved(true);

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
        factory.deployGoal(p);
    }

    function test_deployGoal_usesConfiguredJbMultiTerminalWithoutCobuildDirectoryLookup() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        uint256 deploymentNonce = vm.getNonce(address(factory));
        address expectedSplitHook = vm.computeCreateAddress(address(factory), deploymentNonce + 1);
        revDeployer.setExpectedSplitHook(expectedSplitHook);
        revDeployer.setRevertWithObserved(true);
        revnetDirectory.setPrimaryTerminal(COBUILD_REVNET_ID, factory.COBUILD_TOKEN(), IJBTerminal(address(0)));

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
        factory.deployGoal(p);
    }

    function _baseDeployParams() internal view returns (GoalFactory.DeployParams memory p) {
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
        p.budgetTCR.budgetSpendPolicy = configuredGoalSpendPolicy;
        p.goalSpendPolicy = configuredGoalSpendPolicy;
    }

    function _newCobuildTokenForRevnet() internal returns (MockToken cobuildToken) {
        cobuildToken = new MockToken();
        revnetTokens.setTokenOf(COBUILD_REVNET_ID, address(cobuildToken));
        revnetDirectory.setPrimaryTerminal(
            COBUILD_REVNET_ID, address(cobuildToken), IJBTerminal(address(new DummyMultiTerminal()))
        );
        configuredCobuildTerminal = address(
            new CobuildTerminal(IJBDirectory(address(revnetDirectory)), address(cobuildToken), COBUILD_REVNET_ID)
        );
    }

    function _newFactoryForCobuildConfig(address cobuildToken, uint256 cobuildRevnetId, address cobuildTerminal)
        internal
        returns (GoalFactory)
    {
        GoalFactory goalFactory = new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            cobuildToken,
            cobuildRevnetId,
            cobuildTerminal,
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
            configuredDefaultSubmissionDepositStrategy,
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
        GoalDeploymentRegistry(configuredGoalDeploymentRegistry).setRegistrar(address(goalFactory), true);
        return goalFactory;
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
        MockToken cobuildToken = _newCobuildTokenForRevnet();
        GoalFactory goalFactory = new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(SUPERFLUID_HOST),
            BudgetTCRFactory(BUDGET_TCR_FACTORY),
            IGoalDeploymentRegistry(configuredGoalDeploymentRegistry),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            configuredCobuildTerminal,
            configuredJbMultiTerminal,
            configuredBuybackHookDataHook,
            configuredBuybackHook,
            configuredGoalTreasuryImpl,
            stakeVaultImpl,
            configuredFlowImpl,
            configuredSplitHookImpl,
            budgetStakeLedgerImpl,
            goalFlowAllocationLedgerPipelineImpl,
            premiumEscrowImpl,
            jurorSlasherRouterImpl,
            underwriterSlasherRouterImpl,
            configuredDefaultSubmissionDepositStrategy,
            allocationMechanismAdmin,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
        GoalDeploymentRegistry(configuredGoalDeploymentRegistry).setRegistrar(address(goalFactory), true);
        return goalFactory;
    }
}

contract DummyContract {}

contract DummyMultiTerminal {
    function STORE() external pure returns (address) {
        return address(0xB0A1);
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Cobuild", "CBD") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract MockRevDeployer {
    error DeployForForwarding(
        uint24 buybackPoolFee,
        uint32 buybackPoolTwapWindow,
        bool saltMatchesFactorySeed,
        bool splitHookMatchesExpected,
        bool buybackHooksForwarded,
        bool cobuildTerminalForwarded,
        bool jbMultiTerminalForwarded
    );

    address internal immutable _directory;
    address internal immutable _controller;
    bool internal _revertWithObserved;
    address internal _expectedBuybackDataHook;
    address internal _expectedBuybackHook;
    address internal _expectedSplitHook;
    address internal _expectedCobuildTerminal;
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

    function setExpectedCobuildTerminal(address terminal) external {
        _expectedCobuildTerminal = terminal;
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
            bool cobuildTerminalForwarded = terminalConfigurations.length > 0
                && address(terminalConfigurations[0].terminal) == _expectedCobuildTerminal;
            bool jbMultiTerminalForwarded = terminalConfigurations.length > 1
                && address(terminalConfigurations[1].terminal) == _expectedJbMultiTerminal;

            revert DeployForForwarding(
                observedFee,
                observedTwapWindow,
                saltMatchesFactorySeed,
                splitHookMatchesExpected,
                buybackHooksForwarded,
                cobuildTerminalForwarded,
                jbMultiTerminalForwarded
            );
        }

        revnetId = 1;
    }

    function DIRECTORY() external view returns (address) {
        return _directory;
    }

    function CONTROLLER() external view returns (address) {
        return _controller;
    }
}

contract MockController {
    address internal immutable _tokens;
    address internal immutable _rulesets;

    constructor(address tokens_, address rulesets_) {
        _tokens = tokens_;
        _rulesets = rulesets_;
    }

    function TOKENS() external view returns (address) {
        return _tokens;
    }

    function RULESETS() external view returns (address) {
        return _rulesets;
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

contract MockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}
