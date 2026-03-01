// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { TestUtils } from "test/utils/TestUtils.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    MockBudgetTCRSuperToken,
    MockGoalFlowForBudgetTCR,
    MockGoalTreasuryForBudgetTCR,
    MockRewardEscrowForBudgetTCR,
    MockBudgetStakeLedgerForBudgetTCR,
    MockStakeVaultForBudgetTCR
} from "test/mocks/MockBudgetTCRSystem.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTCRStackDeployer } from "src/tcr/interfaces/IBudgetTCRStackDeployer.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { MockUnderwriterSlasherRouter } from "test/mocks/MockUnderwriterSlasherRouter.sol";

contract MismatchingBudgetTCRStackDeployer is IBudgetTCRStackDeployer {
    address internal immutable preparedBudgetTreasury;
    address internal immutable deployedBudgetTreasury;
    address internal immutable strategy;
    address internal immutable premiumEscrow;
    address internal immutable _roundFactory;
    address internal immutable _mechanismTcrImplementation;
    address internal immutable _mechanismArbitratorImplementation;

    constructor(address preparedBudgetTreasury_, address deployedBudgetTreasury_) {
        preparedBudgetTreasury = preparedBudgetTreasury_;
        deployedBudgetTreasury = deployedBudgetTreasury_;
        strategy = address(0x2222222222222222222222222222222222222222);
        premiumEscrow = address(0x3333333333333333333333333333333333333333);
        _roundFactory = address(new RoundFactory());
        _mechanismTcrImplementation = address(new AllocationMechanismTCR());
        _mechanismArbitratorImplementation = address(new ERC20VotesArbitrator());
    }

    function prepareBudgetStack(
        IERC20,
        IERC20,
        IJBRulesets,
        uint256,
        uint8,
        address,
        address,
        address,
        uint32,
        bytes32
    ) external returns (PreparationResult memory result) {
        result =
            PreparationResult({ strategy: strategy, budgetTreasury: preparedBudgetTreasury, premiumEscrow: premiumEscrow });
    }

    function deployBudgetTreasury(
        address,
        address,
        address,
        address,
        address,
        address,
        uint32,
        IBudgetTCR.BudgetListing calldata,
        address,
        uint64,
        uint256
    ) external returns (address budgetTreasury) {
        budgetTreasury = deployedBudgetTreasury;
    }

    function registerChildFlowRecipient(bytes32, address) external { }

    function roundFactory() external view returns (address) {
        return _roundFactory;
    }

    function allocationMechanismTcrImplementation() external view returns (address) {
        return _mechanismTcrImplementation;
    }

    function allocationMechanismArbitratorImplementation() external view returns (address) {
        return _mechanismArbitratorImplementation;
    }
}

contract BudgetTCRBudgetTreasuryInvariantTest is TestUtils {
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
        underwriterSlasherRouter = address(new MockUnderwriterSlasherRouter(address(this), address(0)));

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(
            new MismatchingBudgetTCRStackDeployer(
                makeAddr("preparedBudgetTreasury"),
                makeAddr("deployedBudgetTreasury")
            )
        );

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

    function test_activateRegisteredBudget_reverts_when_budget_treasury_mismatches_prepared_address() public {
        (uint256 addCost,,,,) = budgetTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(budgetTcr), addCost);

        vm.prank(requester);
        bytes32 itemID = budgetTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRegistrationPending(itemID));

        vm.expectRevert(BudgetTCR.BUDGET_TREASURY_MISMATCH.selector);
        budgetTcr.activateRegisteredBudget(itemID);
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
