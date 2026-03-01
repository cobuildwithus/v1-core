// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { TestUtils } from "test/utils/TestUtils.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    MockGoalTreasuryForBudgetTCR,
    MockRewardEscrowForBudgetTCR,
    MockBudgetStakeLedgerForBudgetTCR,
    MockStakeVaultForBudgetTCR
} from "test/mocks/MockBudgetTCRSystem.sol";
import { MockAllocationStrategy } from "test/mocks/MockAllocationStrategy.sol";
import { FlowSuperfluidFrameworkDeployer } from "test/utils/FlowSuperfluidFrameworkDeployer.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";

import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { ERC1820RegistryCompiled } from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { MockUnderwriterSlasherRouter } from "test/mocks/MockUnderwriterSlasherRouter.sol";

contract BudgetTCRFlowRemovalLivenessTest is TestUtils {
    uint256 internal constant INITIAL_WEIGHT = 12e24;
    uint32 internal constant HALF_SCALED = 500_000;
    bytes32 internal constant EXTRA_RECIPIENT_ID = bytes32(uint256(1));
    address internal constant EXTRA_RECIPIENT = address(0x1111);

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
    address internal requester = makeAddr("requester");
    address internal allocator = makeAddr("allocator");
    address internal keeper = makeAddr("keeper");
    address internal managerRewardPool = makeAddr("managerRewardPool");

    uint256 internal votingPeriod = 20;
    uint256 internal votingDelay = 2;
    uint256 internal revealPeriod = 15;
    uint256 internal arbitrationCost = 10e18;
    uint256 internal allocationKey;

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
    CustomFlow internal goalFlowImpl;

    MockGoalTreasuryForBudgetTCR internal goalTreasury;
    MockBudgetStakeLedgerForBudgetTCR internal budgetStakeLedger;

    BudgetTCR internal budgetTcr;
    ERC20VotesArbitrator internal arbitrator;
    address internal stackDeployer;
    address internal premiumEscrowImplementation;
    address internal underwriterSlasherRouter;

    function setUp() public {
        depositToken = new MockVotesToken("BudgetTCR Votes", "BTV");
        goalToken = new MockVotesToken("GOAL", "GOAL");
        cobuildToken = new MockVotesToken("COBUILD", "COB");
        submissionDepositStrategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(depositToken))))
        );
        depositToken.mint(requester, 1_000_000e18);

        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        sfDeployer = new FlowSuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();
        (TestToken u, SuperToken s) = sfDeployer.deployWrapperSuperToken(
            "MockUSD",
            "mUSD",
            18,
            type(uint256).max,
            owner
        );
        underlyingToken = u;
        superToken = s;

        strategy = new MockAllocationStrategy();
        strategy.setUseAuxAsKey(true);
        allocationKey = strategy.allocationKey(allocator, bytes(""));
        strategy.setWeight(allocationKey, INITIAL_WEIGHT);
        strategy.setCanAllocate(allocationKey, allocator, true);

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(new BudgetTCRDeployer());
        premiumEscrowImplementation = address(new PremiumEscrow());
        underwriterSlasherRouter = address(new MockUnderwriterSlasherRouter(address(this), address(0)));
        BudgetTCRDeployer(stackDeployer).initialize(tcrInstance, premiumEscrowImplementation);

        goalFlowImpl = new CustomFlow();
        address goalFlowProxy = _deployProxy(address(goalFlowImpl), "");

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        FlowTypes.RecipientMetadata memory flowMetadata = FlowTypes.RecipientMetadata({
            title: "Goal Flow",
            description: "Goal flow for BudgetTCR liveness test",
            image: "ipfs://goal-flow",
            tagline: "goal-flow",
            url: "https://goal.flow.test"
        });

        IFlow.FlowParams memory flowParams = IFlow.FlowParams({ managerRewardPoolFlowRatePpm: 100_000 });

        vm.prank(owner);
        ICustomFlow(goalFlowProxy).initialize(
            address(superToken),
            address(goalFlowImpl),
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

        FlowTypes.RecipientMetadata memory extraMetadata = FlowTypes.RecipientMetadata({
            title: "Extra Recipient",
            description: "Allocator can reallocate here after budget removal",
            image: "ipfs://extra-recipient",
            tagline: "extra-recipient",
            url: "https://extra.recipient.test"
        });
        vm.prank(tcrInstance);
        goalFlow.addRecipient(EXTRA_RECIPIENT_ID, EXTRA_RECIPIENT, extraMetadata);

        goalTreasury = new MockGoalTreasuryForBudgetTCR(uint64(block.timestamp + 120 days));
        budgetStakeLedger = new MockBudgetStakeLedgerForBudgetTCR();
        goalTreasury.setRewardEscrow(address(new MockRewardEscrowForBudgetTCR(address(budgetStakeLedger))));
        goalTreasury.setFlow(address(goalFlow));
        goalTreasury.setStakeVault(address(new MockStakeVaultForBudgetTCR(address(goalTreasury))));

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
    }

    function test_budgetRemoval_keepsSyncAllocationLiveForPriorCommit() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetRecipient = goalFlow.getRecipientById(itemID).recipient;

        bytes32[] memory ids = _sortedRecipientIds(itemID, EXTRA_RECIPIENT_ID);
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;

        _allocateWithPrevState(allocator, ids, scaled);

        _removeListing(itemID);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);

        uint256 reducedWeight = INITIAL_WEIGHT / 4;
        strategy.setWeight(allocationKey, reducedWeight);
        vm.prank(keeper);
        goalFlow.syncAllocation(address(strategy), allocationKey);

        assertEq(goalFlow.distributionPool().getUnits(budgetRecipient), 0);
        assertEq(goalFlow.distributionPool().getUnits(EXTRA_RECIPIENT), _units(reducedWeight, HALF_SCALED));
        assertEq(
            goalFlow.getAllocationCommitment(address(strategy), allocationKey),
            keccak256(abi.encode(ids, scaled))
        );
    }

    function test_budgetRegistration_setsChildFlowAuthoritiesToBudgetTreasury() public {
        bytes32 itemID = _registerDefaultListing();

        address childFlow = goalFlow.getRecipientById(itemID).recipient;
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address allocationMechanism = IFlow(childFlow).recipientAdmin();

        assertTrue(childFlow != address(0));
        assertTrue(budgetTreasury != address(0));
        assertTrue(allocationMechanism != address(0));
        assertTrue(allocationMechanism != budgetTreasury);
        assertEq(IFlow(childFlow).flowOperator(), budgetTreasury);
        assertEq(IFlow(childFlow).sweeper(), budgetTreasury);
    }

    function test_budgetRemoval_keepsAllocateLiveForPriorCommit() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetRecipient = goalFlow.getRecipientById(itemID).recipient;

        bytes32[] memory ids = _sortedRecipientIds(itemID, EXTRA_RECIPIENT_ID);
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;

        _allocateWithPrevState(allocator, ids, scaled);

        _removeListing(itemID);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);

        bytes32[] memory nextIds = new bytes32[](1);
        nextIds[0] = EXTRA_RECIPIENT_ID;
        uint32[] memory nextScaled = new uint32[](1);
        nextScaled[0] = 1_000_000;

        _allocateWithPrevState(allocator, nextIds, nextScaled);

        assertEq(goalFlow.distributionPool().getUnits(budgetRecipient), 0);
        assertEq(
            goalFlow.distributionPool().getUnits(EXTRA_RECIPIENT),
            _units(INITIAL_WEIGHT, 1_000_000)
        );
        assertEq(
            goalFlow.getAllocationCommitment(address(strategy), allocationKey),
            keccak256(abi.encode(nextIds, nextScaled))
        );
    }

    function test_budgetRemoval_allocateAfterRemovalWithWeightChange_usesCurrentWeight() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetRecipient = goalFlow.getRecipientById(itemID).recipient;

        bytes32[] memory ids = _sortedRecipientIds(itemID, EXTRA_RECIPIENT_ID);
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;

        _allocateWithPrevState(allocator, ids, scaled);

        _removeListing(itemID);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);

        uint256 reducedWeight = INITIAL_WEIGHT / 4;
        strategy.setWeight(allocationKey, reducedWeight);

        bytes32[] memory nextIds = new bytes32[](1);
        nextIds[0] = EXTRA_RECIPIENT_ID;
        uint32[] memory nextScaled = new uint32[](1);
        nextScaled[0] = 1_000_000;

        _allocateWithPrevState(allocator, nextIds, nextScaled);

        assertEq(goalFlow.distributionPool().getUnits(budgetRecipient), 0);
        assertEq(
            goalFlow.distributionPool().getUnits(EXTRA_RECIPIENT),
            _units(reducedWeight, 1_000_000)
        );
        assertEq(
            goalFlow.getAllocationCommitment(address(strategy), allocationKey),
            keccak256(abi.encode(nextIds, nextScaled))
        );
    }

    function test_budgetRemoval_keepsClearStaleAllocationLiveForPriorCommit() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetRecipient = goalFlow.getRecipientById(itemID).recipient;

        bytes32[] memory ids = _sortedRecipientIds(itemID, EXTRA_RECIPIENT_ID);
        uint32[] memory scaled = new uint32[](2);
        scaled[0] = HALF_SCALED;
        scaled[1] = HALF_SCALED;

        _allocateWithPrevState(allocator, ids, scaled);

        _removeListing(itemID);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);

        strategy.setWeight(allocationKey, 0);
        vm.prank(keeper);
        goalFlow.clearStaleAllocation(address(strategy), allocationKey);

        assertEq(goalFlow.distributionPool().getUnits(budgetRecipient), 0);
        assertEq(goalFlow.distributionPool().getUnits(EXTRA_RECIPIENT), 0);
        assertEq(
            goalFlow.getAllocationCommitment(address(strategy), allocationKey),
            keccak256(abi.encode(ids, scaled))
        );
    }

    function _allocateWithPrevState(
        address caller,
        bytes32[] memory recipientIds,
        uint32[] memory allocationsPpm
    ) internal {
        vm.prank(caller);
        goalFlow.allocate(recipientIds, allocationsPpm);
    }

    function _sortedRecipientIds(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        if (a < b) {
            ids[0] = a;
            ids[1] = b;
        } else {
            ids[0] = b;
            ids[1] = a;
        }
    }

    function _units(uint256 weight, uint32 scaled) internal pure returns (uint128) {
        uint256 weighted = Math.mulDiv(weight, scaled, 1e6);
        return uint128(weighted / 1e15);
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
        assertTrue(budgetTcr.isRegistrationPending(itemID));
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function _removeListing(bytes32 itemID) internal {
        _approveRemoveCost(requester);
        vm.prank(requester);
        budgetTcr.removeItem(itemID, "");
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.isRemovalPending(itemID));
        budgetTcr.finalizeRemovedBudget(itemID);
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
