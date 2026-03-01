// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { TestUtils } from "test/utils/TestUtils.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    MockBudgetTCRSuperToken,
    MockGoalFlowForBudgetTCR,
    MockGoalTreasuryForBudgetTCR,
    MockBudgetChildFlow,
    MockRewardEscrowForBudgetTCR,
    MockBudgetStakeLedgerForBudgetTCR,
    MockStakeVaultForBudgetTCR
} from "test/mocks/MockBudgetTCRSystem.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";

import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetFlowRouterStrategy } from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Vm } from "forge-std/Vm.sol";
import { MockUnderwriterSlasherRouter } from "test/mocks/MockUnderwriterSlasherRouter.sol";

contract BudgetTCRTest is TestUtils {
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

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
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
        submissionDepositStrategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(depositToken))))
        );

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

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(new BudgetTCRDeployer());
        BudgetTCRDeployer(stackDeployer).initialize(tcrInstance, premiumEscrowImplementation);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (
                owner,
                address(depositToken),
                tcrInstance,
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost
            )
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
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.stackDeployer = address(0);

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_flow_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalFlow = IFlow(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_treasury_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalTreasury = IGoalTreasury(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_token_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalToken = IERC20(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_cobuild_token_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.cobuildToken = IERC20(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_goal_rulesets_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.goalRulesets = IJBRulesets(address(0));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_premium_escrow_implementation_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.premiumEscrowImplementation = address(0);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION.selector, address(0))
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_premium_escrow_implementation_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        address noCodePremiumEscrowImplementation = makeAddr("no-code-premium-escrow-implementation");
        deploymentConfig.premiumEscrowImplementation = noCodePremiumEscrowImplementation;

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION.selector,
                noCodePremiumEscrowImplementation
            )
        );
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_underwriter_slasher_router_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.underwriterSlasherRouter = address(0);

        vm.expectRevert(IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_underwriter_slasher_router_has_no_code() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.underwriterSlasherRouter = makeAddr("no-code-underwriter-slasher-router");

        vm.expectRevert(IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_budget_premium_ppm_exceeds_scale() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
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
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        goalTreasury.setBudgetStakeLedger(address(0));

        vm.expectRevert(IBudgetTCR.BUDGET_STAKE_LEDGER_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_max_execution_duration_lt_min_execution_duration() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
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
            IBudgetTCR.RegistryConfig memory registryConfig,
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
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.oracleValidationBounds.liveness = 0;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_oracle_bond_amount_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.oracleValidationBounds.bondAmount = 0;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_governor_is_init_only_with_no_direct_setter() public {
        address initialGovernor = budgetTcr.governor();

        (bool success, bytes memory revertData) =
            address(budgetTcr).call(abi.encodeWithSignature("setGovernor(address)", makeAddr("new-governor")));
        assertFalse(success);
        assertEq(revertData.length, 0);

        vm.prank(governor);
        (bool governorSuccess, bytes memory governorRevertData) =
            address(budgetTcr).call(abi.encodeWithSignature("setGovernor(address)", makeAddr("another-governor")));
        assertFalse(governorSuccess);
        assertEq(governorRevertData.length, 0);

        assertEq(budgetTcr.governor(), initialGovernor);
    }

    function test_setMetaEvidenceURIs_has_no_direct_setter() public {
        string memory beforeRegistration = budgetTcr.registrationMetaEvidence();
        string memory beforeClearing = budgetTcr.clearingMetaEvidence();

        vm.prank(governor);
        (bool success, bytes memory revertData) = address(budgetTcr).call(
            abi.encodeWithSignature("setMetaEvidenceURIs(string,string)", "ipfs://new-reg", "ipfs://new-clear")
        );
        assertFalse(success);
        assertEq(revertData.length, 0);

        assertEq(budgetTcr.registrationMetaEvidence(), beforeRegistration);
        assertEq(budgetTcr.clearingMetaEvidence(), beforeClearing);
    }

    function test_metaEvidenceUpdates_getter_selector_is_removed() public {
        (bool success, bytes memory revertData) = address(budgetTcr).call(abi.encodeWithSignature("metaEvidenceUpdates()"));
        assertFalse(success);
        assertEq(revertData.length, 0);

        vm.prank(governor);
        (bool governorSuccess, bytes memory governorRevertData) =
            address(budgetTcr).call(abi.encodeWithSignature("metaEvidenceUpdates()"));
        assertFalse(governorSuccess);
        assertEq(governorRevertData.length, 0);
    }

    function test_requestMetaEvidenceIDs_are_fixed_across_budget_lifecycle() public {
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
        vm.prank(requester);
        budgetTcr.addItem(abi.encode(listing));

        (,,,,,,,,, uint256 reRegistrationMetaEvidenceID) = budgetTcr.getRequestInfo(itemID, 2);
        assertEq(reRegistrationMetaEvidenceID, 0);
    }

    function test_addItem_reverts_when_listing_invalid() public {
        _approveAddCost(requester);

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        listing.fundingDeadline = uint64(block.timestamp + 10 minutes);

        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        vm.prank(requester);
        budgetTcr.addItem(abi.encode(listing));
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
        (bool configuredFound, uint256 configuredIndex) =
            _findBudgetConfiguredLogIndex(activationLogs, budgetTreasury);
        assertTrue(deployedFound);
        assertTrue(configuredFound);
        assertLt(deployedIndex, configuredIndex);

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

        assertEq(MockBudgetChildFlow(childFlow).managerRewardPool(), premiumEscrow);
        assertEq(MockBudgetChildFlow(childFlow).managerRewardPoolFlowRatePpm(), 100_000);
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
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        uint64 expectedLiveness = 4 days;
        uint256 expectedBond = 77e18;

        address freshStackDeployer = address(new BudgetTCRDeployer());
        BudgetTCRDeployer(freshStackDeployer).initialize(address(freshTcr), premiumEscrowImplementation);
        ERC20VotesArbitrator freshArbImpl = new ERC20VotesArbitrator();
        bytes memory freshArbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (
                owner,
                address(depositToken),
                address(freshTcr),
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost
            )
        );
        address freshArbProxy = _deployProxy(address(freshArbImpl), freshArbInit);

        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.oracleValidationBounds.liveness = expectedLiveness;
        deploymentConfig.oracleValidationBounds.bondAmount = expectedBond;
        registryConfig.arbitrator = IArbitrator(freshArbProxy);

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

        IAllocationStrategy[] memory strategiesA = IFlow(childFlowA).strategies();
        IAllocationStrategy[] memory strategiesB = IFlow(childFlowB).strategies();
        assertEq(strategiesA.length, 1);
        assertEq(strategiesB.length, 1);
        assertEq(address(strategiesA[0]), address(strategiesB[0]));
        assertEq(address(strategiesA[0]), BudgetTCRDeployer(stackDeployer).sharedBudgetFlowStrategy());
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
        address roundFactory = BudgetTCRDeployer(stackDeployer).roundFactory();

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

        address sharedStrategy = BudgetTCRDeployer(stackDeployer).sharedBudgetFlowStrategy();
        IBudgetFlowRouterStrategy strategy = IBudgetFlowRouterStrategy(sharedStrategy);
        (bytes32 recipientA, bool registeredA) = strategy.recipientIdForFlow(childFlowA);
        (bytes32 recipientB, bool registeredB) = strategy.recipientIdForFlow(childFlowB);

        assertTrue(registeredA);
        assertTrue(registeredB);
        assertEq(recipientA, itemA);
        assertEq(recipientB, itemB);

        vm.expectRevert(abi.encodeWithSelector(IBudgetFlowRouterStrategy.FLOW_ALREADY_REGISTERED.selector, childFlowA));
        vm.prank(address(budgetTcr));
        BudgetTCRDeployer(stackDeployer).registerChildFlowRecipient(itemA, childFlowA);
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

        (bool found, bool removedFromParent, bool emittedTerminallyResolved) = _getBudgetStackRemovalHandled(
            logs, itemID, childFlow, budgetTreasury
        );
        assertTrue(found);
        assertTrue(removedFromParent);
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

    function test_finalizeRemovedBudget_forceZerosFlowRate_whenBudgetWasActive_strictlyTerminalizes() public {
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
        assertTrue(terminallyResolved);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(IBudgetTreasury(budgetTreasury).successResolutionDisabled());
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
        assertFalse(IBudgetTreasury(budgetTreasury).successResolutionDisabled());

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

        vm.mockCall(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolved.selector), abi.encode(false));
        bytes memory resolveFailureReason = abi.encodeWithSignature("Error(string)", "RESOLVE_FAILURE_FAILED");
        vm.mockCallRevert(
            budgetTreasury,
            abi.encodeWithSelector(IBudgetTreasury.resolveFailure.selector),
            resolveFailureReason
        );

        vm.expectRevert(resolveFailureReason);
        budgetTcr.finalizeRemovedBudget(itemID);
    }

    function test_finalizeRemovedBudget_revertsWhenTerminalResolutionUnresolved_andPreservesRemovalState() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        vm.mockCall(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolved.selector), abi.encode(false));

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
        assertFalse(IBudgetTreasury(budgetTreasury).successResolutionDisabled());

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

    function test_retryRemovedBudgetResolution_reportsResolvedAfterStrictFinalize() public {
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
        assertTrue(terminallyResolved);
        assertTrue(treasury.successResolutionDisabled());
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);

        vm.prank(makeAddr("keeper"));
        bool retryResolved = budgetTcr.retryRemovedBudgetResolution(itemID);

        assertTrue(retryResolved);
        assertTrue(treasury.successResolutionDisabled());
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_retryRemovedBudgetResolution_ignoresForceZeroMockAfterStrictFinalize() public {
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
        assertTrue(terminallyResolved);
        assertTrue(treasury.successResolutionDisabled());
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(MockBudgetChildFlow(childFlow).targetOutflowRate(), 0);

        bytes memory revertReason = abi.encodeWithSignature("Error(string)", "FORCE_ZERO_RETRY_FAILED");
        vm.mockCallRevert(
            budgetTreasury,
            abi.encodeWithSelector(IBudgetTreasury.forceFlowRateToZero.selector),
            revertReason
        );

        vm.prank(makeAddr("keeper"));
        bool retryResolved = budgetTcr.retryRemovedBudgetResolution(itemID);
        assertTrue(retryResolved);
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

    function test_retryRemovedBudgetResolution_emitsTerminalizationFailureEvent_whenDisableResolutionReverts() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "DISABLE_RETRY_FAILED");
        vm.mockCallRevert(
            budgetTreasury,
            abi.encodeWithSelector(IBudgetTreasury.disableSuccessResolution.selector),
            expectedReason
        );

        vm.recordLogs();
        budgetTcr.retryRemovedBudgetResolution(itemID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _hasBudgetTerminalizationStepFailed(
                logs,
                itemID,
                budgetTreasury,
                IBudgetTreasury.disableSuccessResolution.selector,
                expectedReason
            )
        );
    }

    function test_retryRemovedBudgetResolution_emitsTerminalizationFailureEvent_whenResolveFailureReverts() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        vm.mockCall(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolved.selector), abi.encode(false));
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "RESOLVE_FAILURE_RETRY_FAILED");
        vm.mockCallRevert(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.resolveFailure.selector), expectedReason);

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

    function test_finalizeRemovedBudget_clearsPendingSuccessAssertion_whenBudgetWasActive() public {
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

        _warpRoll(treasury.fundingDeadline());

        bytes32 assertionId = keccak256("pending-budget-success-assertion");
        vm.prank(owner);
        treasury.registerSuccessAssertion(assertionId);
        assertEq(treasury.pendingSuccessAssertionId(), assertionId);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        bool terminallyResolved = budgetTcr.finalizeRemovedBudget(itemID);
        assertTrue(terminallyResolved);
        assertTrue(treasury.successResolutionDisabled());
        assertEq(treasury.pendingSuccessAssertionId(), bytes32(0));
        assertTrue(treasury.resolved());
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
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
        assertTrue(_hasBudgetSyncCallFailed(logs, itemFail, treasuryFail, IBudgetTreasury.sync.selector, syncFailReason));
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

    function _hasBudgetEventForItem(
        Vm.Log[] memory logs,
        bytes32 eventSignature,
        bytes32 itemID
    ) internal view returns (bool) {
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

    function _getBudgetStackTerminalizationRetried(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address budgetTreasury
    ) internal view returns (bool found, bool terminallyResolved) {
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

    function _hasBudgetSyncSkipped(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address budgetTreasury,
        bytes32 expectedReason
    ) internal view returns (bool) {
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

    function _hasBudgetSyncAttempted(
        Vm.Log[] memory logs,
        bytes32 itemID,
        address budgetTreasury,
        bool expectedSuccess
    ) internal view returns (bool) {
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

    function _findBudgetConfiguredLogIndex(
        Vm.Log[] memory logs,
        address budgetTreasury
    ) internal view returns (bool found, uint256 index) {
        bytes32 controllerTopic = _addressToTopic(address(budgetTcr));
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != budgetTreasury) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != BUDGET_CONFIGURED_SIG) continue;
            if (logs[i].topics[1] != controllerTopic) continue;

            return (true, i);
        }
    }

    function _getBudgetAllocationMechanismDeployed(
        Vm.Log[] memory logs,
        bytes32 itemID
    )
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
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        )
    {
        BudgetTCR freshImplementation = new BudgetTCR();
        freshTcr = BudgetTCR(_deployProxy(address(freshImplementation), ""));
        registryConfig = _defaultRegistryConfig();
        deploymentConfig = _defaultDeploymentConfig();
    }

    function _defaultRegistryConfig() internal view returns (IBudgetTCR.RegistryConfig memory registryConfig) {
        registryConfig = IBudgetTCR.RegistryConfig({
            governor: governor,
            arbitrator: IArbitrator(address(arbitrator)),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://budget-reg-meta",
            clearingMetaEvidence: "ipfs://budget-clear-meta",
            votingToken: IVotes(address(depositToken)),
            submissionBaseDeposit: submissionBaseDeposit,
            removalBaseDeposit: removalBaseDeposit,
            submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: removalChallengeBaseDeposit,
            challengePeriodDuration: challengePeriodDuration,
            submissionDepositStrategy: submissionDepositStrategy
        });
    }

    function _defaultDeploymentConfig() internal view returns (IBudgetTCR.DeploymentConfig memory deploymentConfig) {
        deploymentConfig = IBudgetTCR.DeploymentConfig({
            stackDeployer: stackDeployer,
            budgetSuccessResolver: owner,
            goalFlow: IFlow(address(goalFlow)),
            goalTreasury: IGoalTreasury(address(goalTreasury)),
            goalToken: IERC20(address(goalToken)),
            cobuildToken: IERC20(address(cobuildToken)),
            goalRulesets: IJBRulesets(address(0x1234)),
            goalRevnetId: 1,
            paymentTokenDecimals: 18,
            premiumEscrowImplementation: premiumEscrowImplementation,
            underwriterSlasherRouter: underwriterSlasherRouter,
            budgetPremiumPpm: 100_000,
            budgetSlashPpm: 50_000,
            managerRewardPool: address(0),
            budgetValidationBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1 days,
                maxFundingHorizon: 60 days,
                minExecutionDuration: 1 days,
                maxExecutionDuration: 30 days,
                minActivationThreshold: 1e18,
                maxActivationThreshold: 1_000_000e18,
                maxRunwayCap: 2_000_000e18
            }),
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({
                liveness: 1 days,
                bondAmount: 10e18
            })
        });
    }

    function _approveRemoveCost(address who) internal returns (uint256 removeCost) {
        (, removeCost,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), removeCost);
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
            oracleSpecHash: keccak256("budget-oracle-spec"),
            assertionPolicyHash: keccak256("budget-assertion-policy")
        });
    }
}
