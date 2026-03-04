// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { TestUtils } from "test/utils/TestUtils.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    MockBudgetTCRSuperToken,
    MockGoalTreasuryForBudgetTCR,
    MockBudgetStakeLedgerForBudgetTCR,
    MockRewardEscrowForBudgetTCR,
    MockStakeVaultForBudgetTCR
} from "test/mocks/MockBudgetTCRSystem.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { MechanismFundingEscrow } from "src/escrow/MechanismFundingEscrow.sol";

import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

import { IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { ISuperToken, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { MockUnderwriterSlasherRouter } from "test/mocks/MockUnderwriterSlasherRouter.sol";

contract BudgetTCRManagerRewardPoolWiringTest is TestUtils {
    MockVotesToken internal depositToken;
    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;

    MockBudgetTCRSuperToken internal superToken;
    BudgetTCRWiringGoalFlow internal goalFlow;
    MockGoalTreasuryForBudgetTCR internal goalTreasury;
    MockBudgetStakeLedgerForBudgetTCR internal budgetStakeLedger;

    BudgetTCR internal budgetTcr;
    ERC20VotesArbitrator internal arbitrator;
    address internal stackDeployer;
    address internal premiumEscrowImplementation;
    address internal underwriterSlasherRouter;

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
        goalFlow = new BudgetTCRWiringGoalFlow(
            address(this),
            address(this),
            managerRewardPool,
            ISuperToken(address(superToken))
        );
        goalTreasury = new MockGoalTreasuryForBudgetTCR(uint64(block.timestamp + 120 days));
        budgetStakeLedger = new MockBudgetStakeLedgerForBudgetTCR();
        goalTreasury.setRewardEscrow(address(new MockRewardEscrowForBudgetTCR(address(budgetStakeLedger))));
        goalTreasury.setFlow(address(goalFlow));
        goalTreasury.setStakeVault(address(new MockStakeVaultForBudgetTCR(address(goalTreasury))));

        premiumEscrowImplementation = address(new BudgetTCRWiringPremiumEscrowMock());
        underwriterSlasherRouter =
            address(new MockUnderwriterSlasherRouter(address(this), goalTreasury.stakeVault()));

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(_deployBudgetTcrDeployer());
        BudgetTCRDeployer(stackDeployer).initialize(tcrInstance, premiumEscrowImplementation);

        bytes memory arbInit = _defaultArbitratorInitData(
            owner,
            address(depositToken),
            tcrInstance,
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );
        address arbProxy = _deployProxy(address(arbImpl), arbInit);

        arbitrator = ERC20VotesArbitrator(arbProxy);
        budgetTcr = BudgetTCR(tcrInstance);

        budgetTcr.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());
        goalFlow.setRecipientAdmin(address(budgetTcr));
    }

    function test_activateRegisteredBudget_connectsPremiumEscrow_whenChildManagerRewardDistributionPoolConfigured() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        address distributionPool = address(new BudgetTCRWiringMockDistributionPool());
        goalFlow.setChildManagerRewardDistributionPool(distributionPool);

        budgetTcr.activateRegisteredBudget(itemID);

        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        BudgetTCRWiringPremiumEscrowMock wiringEscrow = BudgetTCRWiringPremiumEscrowMock(premiumEscrow);

        assertEq(wiringEscrow.connectCalls(), 1);
        assertEq(wiringEscrow.lastConnectedPool(), distributionPool);
    }

    function test_activateRegisteredBudget_reverts_whenChildManagerRewardDistributionPoolIsZero() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        vm.expectRevert(IBudgetTCR.MANAGER_REWARD_DISTRIBUTION_POOL_NOT_CONFIGURED.selector);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function _approveAddCost(address who) internal returns (uint256 addCost) {
        (addCost,,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), addCost);
    }

    function _submitListing(address submitter, IBudgetTCR.BudgetListing memory listing)
        internal
        returns (bytes32 itemID)
    {
        vm.prank(submitter);
        itemID = budgetTcr.addItem(abi.encode(listing));
    }

    function _defaultRegistryConfig() internal view returns (IBudgetTCR.RegistryConfig memory registryConfig) {
        registryConfig = IBudgetTCR.RegistryConfig({
            allocationMechanismAdmin: allocationMechanismAdmin,
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
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({ liveness: 1 days, bondAmount: 10e18 })
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

    function _deployBudgetTcrDeployer() internal returns (BudgetTCRDeployer) {
        return BudgetTCRDeployer(
            new BudgetTCRDeployer(
                address(new BudgetTreasury()),
                address(new RoundFactory()),
                address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
                address(new ERC20VotesArbitrator())
            )
        );
    }
}

contract BudgetTCRWiringGoalFlow {
    error NOT_RECIPIENT_ADMIN();
    error NOT_OWNER_OR_RECIPIENT_ADMIN();

    struct RecipientInfo {
        address recipient;
        bool isRemoved;
    }

    address private _owner;
    address private _recipientAdmin;
    address private _managerRewardPool;
    uint32 private _managerRewardPoolFlowRatePpm;
    address private _childManagerRewardDistributionPool;
    ISuperToken private immutable _superToken;

    mapping(bytes32 => RecipientInfo) public recipients;
    mapping(address => uint256) private _activeRecipientRefs;

    constructor(address owner_, address recipientAdmin_, address managerRewardPool_, ISuperToken superToken_) {
        _owner = owner_;
        _recipientAdmin = recipientAdmin_;
        _managerRewardPool = managerRewardPool_;
        _superToken = superToken_;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }

    function managerRewardPool() external view returns (address) {
        return _managerRewardPool;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        return _managerRewardPoolFlowRatePpm;
    }

    function strategies() external pure returns (IAllocationStrategy[] memory s) {
        s = new IAllocationStrategy[](0);
    }

    function parent() external pure returns (address) {
        return address(0);
    }

    function distributionPool() external pure returns (ISuperfluidPool) {
        return ISuperfluidPool(address(0));
    }

    function getMemberFlowRate(address) external pure returns (int96 flowRate) {
        return flowRate;
    }

    function recipientExists(address recipient) external view returns (bool exists) {
        return _activeRecipientRefs[recipient] != 0;
    }

    function setRecipientAdmin(address newRecipientAdmin) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _recipientAdmin = newRecipientAdmin;
    }

    function setManagerRewardPool(address newManagerRewardPool) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _managerRewardPool = newManagerRewardPool;
    }

    function setManagerRewardPoolFlowRatePpm(uint32 newManagerRewardPoolFlowRatePpm) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _managerRewardPoolFlowRatePpm = newManagerRewardPoolFlowRatePpm;
    }

    function setChildManagerRewardDistributionPool(address pool) external {
        _childManagerRewardDistributionPool = pool;
    }

    function addFlowRecipient(
        bytes32 newRecipientId,
        FlowTypes.RecipientMetadata memory,
        address childRecipientAdmin,
        address flowOperator,
        address sweeper,
        address childManagerRewardPool,
        uint32 childManagerRewardPoolFlowRatePpm,
        IAllocationStrategy[] calldata childStrategies
    ) external returns (bytes32 recipientId, address recipientAddress) {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        address strategy = childStrategies.length == 0 ? address(0) : address(childStrategies[0]);

        BudgetTCRWiringChildFlow child = new BudgetTCRWiringChildFlow(
            _superToken,
            childRecipientAdmin,
            flowOperator,
            sweeper,
            address(this),
            childManagerRewardPool,
            strategy,
            childManagerRewardPoolFlowRatePpm,
            _childManagerRewardDistributionPool
        );

        RecipientInfo storage previous = recipients[newRecipientId];
        if (previous.recipient != address(0) && !previous.isRemoved) {
            _activeRecipientRefs[previous.recipient] -= 1;
        }

        recipients[newRecipientId] = RecipientInfo({ recipient: address(child), isRemoved: false });
        _activeRecipientRefs[address(child)] += 1;
        return (newRecipientId, address(child));
    }
}

contract BudgetTCRWiringMockDistributionPool { }

contract BudgetTCRWiringChildFlow {
    ISuperToken private immutable _superToken;
    address private _recipientAdmin;
    address private _flowOperator;
    address private _sweeper;
    address private immutable _parent;
    address private immutable _managerRewardPool;
    address private immutable _strategy;
    uint32 private immutable _managerRewardPoolFlowRatePpm;
    address private immutable _managerRewardDistributionPool;

    constructor(
        ISuperToken superToken_,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address parent_,
        address managerRewardPool_,
        address strategy_,
        uint32 managerRewardPoolFlowRatePpm_,
        address managerRewardDistributionPool_
    ) {
        _superToken = superToken_;
        _recipientAdmin = recipientAdmin_;
        _flowOperator = flowOperator_;
        _sweeper = sweeper_;
        _parent = parent_;
        _managerRewardPool = managerRewardPool_;
        _strategy = strategy_;
        _managerRewardPoolFlowRatePpm = managerRewardPoolFlowRatePpm_;
        _managerRewardDistributionPool = managerRewardDistributionPool_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function sweeper() external view returns (address) {
        return _sweeper;
    }

    function parent() external view returns (address) {
        return _parent;
    }

    function managerRewardPool() external view returns (address) {
        return _managerRewardPool;
    }

    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        return _managerRewardPoolFlowRatePpm;
    }

    function managerRewardDistributionPool() external view returns (ISuperfluidPool) {
        return ISuperfluidPool(_managerRewardDistributionPool);
    }

    function strategies() external view returns (IAllocationStrategy[] memory s) {
        if (_strategy == address(0)) return new IAllocationStrategy[](0);
        s = new IAllocationStrategy[](1);
        s[0] = IAllocationStrategy(_strategy);
    }
}

contract BudgetTCRWiringPremiumEscrowMock {
    address public budgetTreasury;
    address public budgetStakeLedger;
    address public goalFlow;
    address public underwriterSlasherRouter;
    uint32 public budgetSlashPpm;

    uint256 public connectCalls;
    address public lastConnectedPool;

    function initialize(
        address budgetTreasury_,
        address budgetStakeLedger_,
        address goalFlow_,
        address underwriterSlasherRouter_,
        uint32 budgetSlashPpm_
    ) external {
        budgetTreasury = budgetTreasury_;
        budgetStakeLedger = budgetStakeLedger_;
        goalFlow = goalFlow_;
        underwriterSlasherRouter = underwriterSlasherRouter_;
        budgetSlashPpm = budgetSlashPpm_;
    }

    function connectManagerRewardPool(address managerRewardPool_) external {
        connectCalls += 1;
        lastConnectedPool = managerRewardPool_;
    }

    function checkpoint(address) external { }

    function claim(address) external pure returns (uint256 amount) {
        return amount;
    }

    function close(IBudgetTreasury.BudgetState, uint64, uint64) external { }

    function slash(address) external pure returns (uint256 slashWeight) {
        return slashWeight;
    }
}
