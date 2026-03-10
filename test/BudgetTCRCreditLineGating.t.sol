// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {
    BudgetTCRTestSuperToken as MockBudgetTCRSuperToken,
    BudgetTCRGoalFlowHarness as MockGoalFlowForBudgetTCR,
    BudgetTCRGoalTreasuryHarness as MockGoalTreasuryForBudgetTCR,
    BudgetTCRStakeVaultHarness as MockStakeVaultForBudgetTCR
} from "test/helpers/BudgetTCRSystemHarnesses.sol";
import {MockUnderwriterSlasherRouter} from "test/mocks/MockUnderwriterSlasherRouter.sol";

import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";

import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IBudgetStakeLedger} from "src/interfaces/IBudgetStakeLedger.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {Vm} from "forge-std/Vm.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";

contract BudgetTCRCreditLineGatingTest is TestUtils, SpendPolicyTestUtils {
    bytes32 internal constant BUDGET_CREDIT_CAP_ENFORCEMENT_FAILED_SIG =
        keccak256("BudgetCreditCapEnforcementFailed(bytes32,address,address,bytes4,bytes)");
    bytes32 internal constant BUDGET_TREASURY_BATCH_SYNC_ATTEMPTED_SIG =
        keccak256("BudgetTreasuryBatchSyncAttempted(bytes32,address,bool)");

    event BudgetCreditCapEnforcementFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        address callTarget,
        bytes4 indexed selector,
        bytes reason
    );

    MockVotesToken internal depositToken;
    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;

    MockBudgetTCRSuperToken internal superToken;
    BudgetTCRCreditLineGoalFlow internal goalFlow;
    MockGoalTreasuryForBudgetTCR internal goalTreasury;
    BudgetStakeLedger internal budgetStakeLedger;

    BudgetTCR internal budgetTcr;
    ERC20VotesArbitrator internal arbitrator;
    address internal stackDeployer;
    address internal premiumEscrowImplementation;
    address internal underwriterSlasherRouter;
    address internal budgetSpendPolicy;

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
        goalFlow = new BudgetTCRCreditLineGoalFlow(
            address(this), address(this), managerRewardPool, ISuperToken(address(superToken))
        );
        goalTreasury = new MockGoalTreasuryForBudgetTCR(uint64(block.timestamp + 120 days));
        budgetStakeLedger = new BudgetStakeLedger(address(goalTreasury));
        goalTreasury.setBudgetStakeLedger(address(budgetStakeLedger));
        goalTreasury.setFlow(address(goalFlow));
        goalTreasury.setStakeVault(address(new MockStakeVaultForBudgetTCR(address(goalTreasury))));
        premiumEscrowImplementation = address(new PremiumEscrow());
        underwriterSlasherRouter = address(new MockUnderwriterSlasherRouter(address(this), goalTreasury.stakeVault()));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));

        BudgetTCR tcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        address tcrInstance = _deployProxy(address(tcrImpl), "");
        stackDeployer = address(_deployBudgetTcrDeployer());
        BudgetTCRDeployer(stackDeployer).initialize(tcrInstance, premiumEscrowImplementation, address(0));

        bytes memory arbInit = _defaultArbitratorInitData(
            owner, address(depositToken), tcrInstance, votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        address arbProxy = _deployProxy(address(arbImpl), arbInit);

        arbitrator = ERC20VotesArbitrator(arbProxy);
        budgetTcr = BudgetTCR(tcrInstance);

        budgetTcr.initialize(_defaultRegistryConfig(), _defaultDeploymentConfig());

        goalFlow.setRecipientAdmin(address(budgetTcr));
    }

    function test_syncBudgetTreasuries_enablesBelowInsuredLine() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        uint256 coverage = 1_000e18;
        uint256 received = 49e18;

        _checkpointCoverage(itemID, requester, coverage);
        goalFlow.setTotalReceivedByMember(childFlow, received);
        goalFlow.setRecipientEnabledState(itemID, false);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(budgetTreasury != address(0));
        assertTrue(goalFlow.recipientEnabled(itemID));
    }

    function test_syncBudgetTreasuries_disablesAtRunwayBoundaryWhenRunwayIsLower() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);

        uint256 coverage = 50_000e18;

        _checkpointCoverage(itemID, requester, coverage);
        goalFlow.setTotalReceivedByMember(childFlow, 1_000e18);
        goalFlow.setRecipientEnabledState(itemID, true);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertFalse(goalFlow.recipientEnabled(itemID));
    }

    function test_syncBudgetTreasuries_disablesRecipient_whenReceivedAtInsuredLineBoundary() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);

        uint256 coverage = 1_000e18;
        uint256 received = 50e18;

        _checkpointCoverage(itemID, requester, coverage);
        goalFlow.setTotalReceivedByMember(childFlow, received);
        goalFlow.setRecipientEnabledState(itemID, true);

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertEq(budgetStakeLedger.budgetTotalAllocatedStake(budgetTreasury), coverage);
        assertFalse(goalFlow.recipientEnabled(itemID));
    }

    function test_syncBudgetTreasuries_emitsCreditCapFailure_whenStakeReadReverts() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "STAKE_READ_FAIL");

        vm.mockCallRevert(
            address(budgetStakeLedger),
            abi.encodeWithSelector(IBudgetStakeLedger.budgetTotalAllocatedStake.selector, budgetTreasury),
            reason
        );

        vm.expectEmit(true, true, true, true, address(budgetTcr));
        emit BudgetCreditCapEnforcementFailed(
            itemID,
            budgetTreasury,
            address(budgetStakeLedger),
            IBudgetStakeLedger.budgetTotalAllocatedStake.selector,
            reason
        );

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        budgetTcr.syncBudgetTreasuries(itemIDs);
    }

    function test_syncBudgetTreasuries_emitsCreditCapFailure_whenReceivedReadReverts() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "RECEIVED_READ_FAIL");

        _checkpointCoverage(itemID, requester, 50_000e18);
        goalFlow.setRecipientEnabledState(itemID, true);
        vm.mockCallRevert(
            address(goalFlow), abi.encodeWithSelector(IFlow.getTotalReceivedByMember.selector, childFlow), reason
        );

        vm.expectEmit(true, true, true, true, address(budgetTcr));
        emit BudgetCreditCapEnforcementFailed(
            itemID, budgetTreasury, address(goalFlow), IFlow.getTotalReceivedByMember.selector, reason
        );

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(goalFlow.recipientEnabled(itemID));
    }

    function test_syncBudgetTreasuries_emitsCreditCapFailure_whenRecipientToggleReverts() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "RECIPIENT_TOGGLE_FAIL");

        _checkpointCoverage(itemID, requester, 50_000e18);
        goalFlow.setTotalReceivedByMember(childFlow, 1_000e18);
        goalFlow.setRecipientEnabledState(itemID, true);
        vm.mockCallRevert(
            address(goalFlow), abi.encodeWithSelector(IFlow.setRecipientEnabled.selector, itemID, false), reason
        );

        vm.expectEmit(true, true, true, true, address(budgetTcr));
        emit BudgetCreditCapEnforcementFailed(
            itemID, budgetTreasury, address(goalFlow), IFlow.setRecipientEnabled.selector, reason
        );

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(goalFlow.recipientEnabled(itemID));
    }

    function test_syncBudgetTreasuries_enforcesCreditCapBeforeBudgetSync() public {
        bytes32 itemID = _registerDefaultListing();
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "ORDER_CHECK");

        vm.mockCallRevert(
            address(budgetStakeLedger),
            abi.encodeWithSelector(IBudgetStakeLedger.budgetTotalAllocatedStake.selector, budgetTreasury),
            reason
        );

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 missingLogIdx = type(uint256).max;
        uint256 enforcementLogIdx = missingLogIdx;
        uint256 syncAttemptLogIdx = missingLogIdx;
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.emitter != address(budgetTcr)) continue;
            if (logEntry.topics.length < 2) continue;
            if (logEntry.topics[0] == BUDGET_CREDIT_CAP_ENFORCEMENT_FAILED_SIG && logEntry.topics[1] == itemID) {
                if (enforcementLogIdx == missingLogIdx) enforcementLogIdx = i;
            }
            if (logEntry.topics[0] == BUDGET_TREASURY_BATCH_SYNC_ATTEMPTED_SIG && logEntry.topics[1] == itemID) {
                if (syncAttemptLogIdx == missingLogIdx) syncAttemptLogIdx = i;
            }
        }

        assertTrue(enforcementLogIdx != missingLogIdx);
        assertTrue(syncAttemptLogIdx != missingLogIdx);
        assertLt(enforcementLogIdx, syncAttemptLogIdx);
        assertEq(attempted, 1);
        assertEq(succeeded, 1);
    }

    function test_syncBudgetTreasuries_emitsCreditCapFailure_whenRunwayCapReadReverts_andFallsBackToInsuredLine()
        public
    {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "RUNWAY_READ_FAIL");

        _checkpointCoverage(itemID, requester, 1_000e18);
        vm.mockCallRevert(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.runwayCap.selector), reason);
        goalFlow.setTotalReceivedByMember(childFlow, 49e18);
        goalFlow.setRecipientEnabledState(itemID, false);

        vm.expectEmit(true, true, true, true, address(budgetTcr));
        emit BudgetCreditCapEnforcementFailed(
            itemID, budgetTreasury, budgetTreasury, IBudgetTreasury.runwayCap.selector, reason
        );

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(goalFlow.recipientEnabled(itemID));
    }

    function test_syncBudgetTreasuries_emitsCreditCapFailure_whenRunwayCapReadReverts_andFallbackStillDisablesAtInsuredLine()
        public
    {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "RUNWAY_READ_FAIL");

        _checkpointCoverage(itemID, requester, 1_000e18);
        vm.mockCallRevert(budgetTreasury, abi.encodeWithSelector(IBudgetTreasury.runwayCap.selector), reason);
        goalFlow.setTotalReceivedByMember(childFlow, 50e18);
        goalFlow.setRecipientEnabledState(itemID, true);

        vm.expectEmit(true, true, true, true, address(budgetTcr));
        emit BudgetCreditCapEnforcementFailed(
            itemID, budgetTreasury, budgetTreasury, IBudgetTreasury.runwayCap.selector, reason
        );

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = budgetTcr.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertFalse(goalFlow.recipientEnabled(itemID));
    }

    function _checkpointCoverage(bytes32 itemID, address account, uint256 weight) internal {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = itemID;

        uint32[] memory allocationPpm = new uint32[](1);
        allocationPpm[0] = 1_000_000;

        vm.prank(address(goalFlow));
        budgetStakeLedger.checkpointAllocation(
            account, 0, new bytes32[](0), new uint32[](0), weight, recipientIds, allocationPpm
        );
    }

    function _approveAddCost(address who) internal returns (uint256 addCost) {
        (addCost,,,,) = budgetTcr.getTotalCosts();
        vm.prank(who);
        depositToken.approve(address(budgetTcr), addCost);
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

    function _submitListing(address submitter, IBudgetTCR.BudgetListing memory listing)
        internal
        returns (bytes32 itemID)
    {
        vm.prank(submitter);
        itemID = budgetTcr.addItem(abi.encode(listing));
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
            budgetSuccessResolver: owner,
            budgetSpendPolicy: budgetSpendPolicy,
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
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        });
    }

    function _deployBudgetTcrDeployer() internal returns (BudgetTCRDeployer) {
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        BudgetTCRDeployer implementation = new BudgetTCRDeployer(
            address(new BudgetTreasury()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
        return BudgetTCRDeployer(Clones.clone(address(implementation)));
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

contract BudgetTCRCreditLineGoalFlow is MockGoalFlowForBudgetTCR {
    error ONLY_RECIPIENT_ADMIN();
    error RECIPIENT_NOT_FOUND_LOCAL();

    mapping(address member => uint256 totalReceived) private _totalReceivedByMember;
    mapping(bytes32 recipientId => bool enabled) private _recipientEnabled;

    constructor(address owner_, address recipientAdmin_, address managerRewardPool_, ISuperToken superToken_)
        MockGoalFlowForBudgetTCR(owner_, recipientAdmin_, managerRewardPool_, superToken_)
    {}

    function setTotalReceivedByMember(address member, uint256 amount) external {
        _totalReceivedByMember[member] = amount;
    }

    function getTotalReceivedByMember(address member) external view returns (uint256 totalReceived) {
        return _totalReceivedByMember[member];
    }

    function setRecipientEnabled(bytes32 recipientId, bool enabled) external {
        if (msg.sender != this.recipientAdmin()) revert ONLY_RECIPIENT_ADMIN();
        (address recipient, bool isRemoved) = this.recipients(recipientId);
        if (recipient == address(0) || isRemoved) revert RECIPIENT_NOT_FOUND_LOCAL();
        _recipientEnabled[recipientId] = enabled;
    }

    function setRecipientEnabledState(bytes32 recipientId, bool enabled) external {
        _recipientEnabled[recipientId] = enabled;
    }

    function recipientEnabled(bytes32 recipientId) external view returns (bool) {
        return _recipientEnabled[recipientId];
    }
}
