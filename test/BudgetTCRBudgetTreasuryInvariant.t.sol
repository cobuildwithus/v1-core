// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {
    BudgetTCRTestSuperToken as MockBudgetTCRSuperToken,
    BudgetTCRGoalFlowHarness as MockGoalFlowForBudgetTCR,
    BudgetTCRGoalTreasuryHarness as MockGoalTreasuryForBudgetTCR,
    BudgetTCRRewardEscrowHarness as MockRewardEscrowForBudgetTCR,
    BudgetTCRStakeLedgerHarness as MockBudgetStakeLedgerForBudgetTCR,
    BudgetTCRStakeVaultHarness as MockStakeVaultForBudgetTCR
} from "test/helpers/BudgetTCRSystemHarnesses.sol";
import {BudgetTCRConfigHelpers} from "test/helpers/BudgetTCRConfigHelpers.sol";

import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {BudgetStackInstantiationLib} from "src/goals/library/BudgetStackInstantiationLib.sol";
import {BudgetStackPresetConfigLib} from "src/goals/library/BudgetStackPresetConfigLib.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {BudgetStackTypes} from "src/interfaces/BudgetStackTypes.sol";
import {IBudgetStackDeployer} from "src/interfaces/IBudgetStackDeployer.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {MockUnderwriterSlasherRouter} from "test/mocks/MockUnderwriterSlasherRouter.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";
import {StakeCoverageGatePolicy} from "src/goals/policies/StakeCoverageGatePolicy.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";

contract BudgetTCRInvariantPremiumEscrowConnectMock {
    function connectManagerRewardPool(address) external {}
}

contract MismatchingBudgetTCRStackDeployer is IBudgetStackDeployer {
    address internal configuredController;
    address internal immutable preparedBudgetTreasury;
    address internal immutable deployedBudgetTreasury;
    address internal immutable strategy;
    address internal immutable premiumEscrow;
    address internal immutable configuredPremiumEscrowImplementation;
    address internal immutable _roundFactory;
    address internal immutable _mechanismTcrImplementation;
    address internal immutable _mechanismArbitratorImplementation;

    constructor(
        address preparedBudgetTreasury_,
        address deployedBudgetTreasury_,
        address premiumEscrow_,
        address configuredPremiumEscrowImplementation_
    ) {
        preparedBudgetTreasury = preparedBudgetTreasury_;
        deployedBudgetTreasury = deployedBudgetTreasury_;
        strategy = address(0x2222222222222222222222222222222222222222);
        premiumEscrow = premiumEscrow_;
        configuredPremiumEscrowImplementation = configuredPremiumEscrowImplementation_;
        _roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        _mechanismTcrImplementation = address(new AllocationMechanismTCR(address(new MechanismFundingEscrow())));
        _mechanismArbitratorImplementation = address(new ERC20VotesArbitrator());
    }

    function controller() external view returns (address controller_) {
        controller_ = configuredController;
    }

    function setController(address controller_) external {
        configuredController = controller_;
    }

    function initializeWithConfig(address, BudgetStackTypes.StackModuleConfig calldata) external {}

    function prepareBudgetStack(address, address) external returns (BudgetStackTypes.PreparationResult memory result) {
        result = BudgetStackTypes.PreparationResult({
            strategy: strategy,
            budgetTreasury: preparedBudgetTreasury,
            premiumEscrow: premiumEscrow,
            childFlowRecipientAdmin: address(0x3333333333333333333333333333333333333333),
            allocationMechanism: address(0)
        });
    }

    function deployBudgetTreasury(
        address,
        IBudgetTreasury.BudgetConfig calldata
    ) external returns (address budgetTreasury) {
        budgetTreasury = deployedBudgetTreasury;
    }

    function deployBudgetTreasuryWithRiskModule(
        address,
        IBudgetTreasury.BudgetConfig calldata,
        BudgetStackTypes.RiskModuleInitConfig calldata
    ) external returns (address budgetTreasury) {
        budgetTreasury = deployedBudgetTreasury;
    }

    function registerChildFlowRecipient(bytes32, address) external {}

    function stackModuleConfig() external view returns (BudgetStackTypes.StackModuleConfig memory config) {
        config = BudgetStackPresetConfigLib.openPreset(configuredPremiumEscrowImplementation);
    }

    function roundFactory() external view returns (address) {
        return _roundFactory;
    }

    function initialMechanismFactories() external view returns (address[] memory factories) {
        factories = new address[](1);
        factories[0] = _roundFactory;
    }

    function allocationMechanismTcrImplementation() external view returns (address) {
        return _mechanismTcrImplementation;
    }

    function allocationMechanismArbitratorImplementation() external view returns (address) {
        return _mechanismArbitratorImplementation;
    }
}

contract BudgetTCRBudgetTreasuryInvariantTest is TestUtils, SpendPolicyTestUtils {
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
    address internal budgetSpendPolicy;
    address internal budgetGatePolicy;

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

    function onBudgetStackDeployed(bytes32, address, address, address, address) external pure {}

    function onBudgetAllocationMechanismDeployed(bytes32, address, address, address) external pure {}

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
        underwriterSlasherRouter = address(new MockUnderwriterSlasherRouter(address(this), address(0)));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));
        budgetGatePolicy = address(new StakeCoverageGatePolicy());

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(
            new MismatchingBudgetTCRStackDeployer(
                makeAddr("preparedBudgetTreasury"),
                makeAddr("deployedBudgetTreasury"),
                address(new BudgetTCRInvariantPremiumEscrowConnectMock()),
                premiumEscrowImplementation
            )
        );
        MismatchingBudgetTCRStackDeployer(stackDeployer).setController(tcrInstance);

        bytes memory arbInit = _defaultArbitratorInitData(
            owner, address(depositToken), tcrInstance, votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address arbProxy = _deployProxy(address(arbImpl), arbInit);

        arbitrator = ERC20VotesArbitrator(arbProxy);
        budgetTcr = BudgetTCR(tcrInstance);

        budgetTcr.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());
        goalFlow.setRecipientAdmin(address(budgetTcr));
    }

    function test_activateRegisteredBudget_reverts_when_budget_treasury_mismatches_prepared_address() public {
        (uint256 addCost,,,,) = budgetTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(budgetTcr), addCost);

        vm.prank(requester);
        bytes32 itemID = budgetTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRegistrationPending(itemID));

        vm.expectRevert(BudgetStackInstantiationLib.BUDGET_TREASURY_MISMATCH.selector);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function test_activateRegisteredBudget_reverts_when_required_premium_escrow_is_not_prepared() public {
        address customStackDeployer = address(
            new MismatchingBudgetTCRStackDeployer(
                makeAddr("preparedBudgetTreasury"),
                makeAddr("preparedBudgetTreasury"),
                address(0),
                premiumEscrowImplementation
            )
        );
        BudgetTCR freshTcr = _deployInitializedBudgetTcr(
            customStackDeployer,
            budgetGatePolicy,
            premiumEscrowImplementation,
            underwriterSlasherRouter,
            100_000,
            50_000
        );

        bytes32 itemID = _queueBudgetRegistration(freshTcr);

        vm.expectRevert(BudgetStackInstantiationLib.PREMIUM_ESCROW_NOT_PREPARED.selector);
        freshTcr.activateRegisteredBudget(itemID);
    }

    function test_activateRegisteredBudget_reverts_when_zero_rate_stack_prepares_premium_escrow() public {
        address customStackDeployer = address(
            new MismatchingBudgetTCRStackDeployer(
                makeAddr("preparedBudgetTreasury"),
                makeAddr("preparedBudgetTreasury"),
                address(new BudgetTCRInvariantPremiumEscrowConnectMock()),
                address(0)
            )
        );
        BudgetTCR freshTcr = _deployInitializedBudgetTcr(customStackDeployer, address(0), address(0), address(0), 0, 0);

        bytes32 itemID = _queueBudgetRegistration(freshTcr);

        vm.expectRevert(BudgetStackInstantiationLib.PREMIUM_ESCROW_REQUIRES_ZERO_RATES.selector);
        freshTcr.activateRegisteredBudget(itemID);
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

    function _deployInitializedBudgetTcr(
        address customStackDeployer,
        address budgetGatePolicy_,
        address premiumEscrowImplementation_,
        address underwriterSlasherRouter_,
        uint32 budgetPremiumPpm_,
        uint32 budgetSlashPpm_
    ) internal returns (BudgetTCR freshTcr) {
        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        bytes memory arbInit = _defaultArbitratorInitData(
            owner, address(depositToken), tcrInstance, votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address arbProxy = _deployProxy(address(arbImpl), arbInit);

        freshTcr = BudgetTCR(tcrInstance);
        if (customStackDeployer.code.length != 0) {
            try MismatchingBudgetTCRStackDeployer(customStackDeployer).setController(address(freshTcr)) {} catch {}
        }
        IBudgetTCR.InitConfig memory registryConfig = _defaultRegistryConfig();
        registryConfig.tcrConfig.arbitrator = IArbitrator(arbProxy);

        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig();
        deploymentConfig.stackDeployer = customStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = budgetGatePolicy_;
        deploymentConfig.riskModuleRouting.premiumEscrowImplementation = premiumEscrowImplementation_;
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = underwriterSlasherRouter_;
        deploymentConfig.budgetPremiumPpm = budgetPremiumPpm_;
        deploymentConfig.budgetSlashPpm = budgetSlashPpm_;

        freshTcr.initialize(registryConfig, deploymentConfig);
        goalFlow.setRecipientAdmin(address(freshTcr));
    }

    function _queueBudgetRegistration(BudgetTCR targetTcr) internal returns (bytes32 itemID) {
        (uint256 addCost,,,,) = targetTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(targetTcr), addCost);

        vm.prank(requester);
        itemID = targetTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        targetTcr.executeRequest(itemID);
        assertTrue(targetTcr.isRegistrationPending(itemID));
    }

    function _defaultDeploymentConfig() internal view returns (IBudgetTCR.DeploymentConfig memory deploymentConfig) {
        deploymentConfig = IBudgetTCR.DeploymentConfig({
            stackDeployer: stackDeployer,
            discoveryEmitter: address(this),
            budgetSuccessResolver: owner,
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
