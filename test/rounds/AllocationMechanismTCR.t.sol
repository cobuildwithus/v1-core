// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { MechanismFundingEscrow } from "src/escrow/MechanismFundingEscrow.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IAllocationMechanismFactory } from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    RoundTestSuperToken,
    RoundTestManagedFlow,
    RoundTestBudgetTreasury,
    RoundTestGoalTreasury,
    RoundTestStakeVault,
    RoundTestBudgetStakeLedger,
    RoundTestJurorSlasher,
    RoundTestArbitrator
} from "test/rounds/helpers/RoundTestMocks.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ISuperToken, ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract MockAllocationMechanismFactory is IAllocationMechanismFactory {
    DeployedMechanism internal nextDeployedMechanism;
    uint256 public createCalls;
    bytes32 public lastMechanismId;
    address public lastBudgetTreasury;
    address public lastRoundOperator;
    uint64 public lastStartAt;
    uint64 public lastEndAt;
    bytes public lastArbitratorExtraData;
    string public lastRegistrationMetaEvidence;
    string public lastClearingMetaEvidence;
    uint256 public lastSubmissionBaseDeposit;
    uint256 public lastRemovalBaseDeposit;
    uint256 public lastSubmissionChallengeBaseDeposit;
    uint256 public lastRemovalChallengeBaseDeposit;
    uint256 public lastChallengePeriodDuration;
    uint256 public lastVotingPeriod;
    uint256 public lastVotingDelay;
    uint256 public lastRevealPeriod;
    uint256 public lastArbitrationCost;
    uint256 public lastWrongOrMissedSlashBps;
    uint256 public lastSlashCallerBountyBps;

    function setNextDeployedMechanism(DeployedMechanism calldata next) external {
        nextDeployedMechanism = next;
    }

    function deployForBudget(
        bytes32 mechanismId,
        address budgetTreasury,
        bytes calldata mechanismConfig
    ) external returns (DeployedMechanism memory out) {
        RoundFactory.AllocationMechanismConfig memory cfg =
            abi.decode(mechanismConfig, (RoundFactory.AllocationMechanismConfig));
        createCalls += 1;
        lastMechanismId = mechanismId;
        lastBudgetTreasury = budgetTreasury;
        lastRoundOperator = cfg.roundOperator;
        lastStartAt = cfg.timing.startAt;
        lastEndAt = cfg.timing.endAt;
        lastArbitratorExtraData = cfg.tcrConfig.arbitratorExtraData;
        lastRegistrationMetaEvidence = cfg.tcrConfig.registrationMetaEvidence;
        lastClearingMetaEvidence = cfg.tcrConfig.clearingMetaEvidence;
        lastSubmissionBaseDeposit = cfg.tcrConfig.submissionBaseDeposit;
        lastRemovalBaseDeposit = cfg.tcrConfig.removalBaseDeposit;
        lastSubmissionChallengeBaseDeposit = cfg.tcrConfig.submissionChallengeBaseDeposit;
        lastRemovalChallengeBaseDeposit = cfg.tcrConfig.removalChallengeBaseDeposit;
        lastChallengePeriodDuration = cfg.tcrConfig.challengePeriodDuration;
        lastVotingPeriod = cfg.arbConfig.votingPeriod;
        lastVotingDelay = cfg.arbConfig.votingDelay;
        lastRevealPeriod = cfg.arbConfig.revealPeriod;
        lastArbitrationCost = cfg.arbConfig.arbitrationCost;
        lastWrongOrMissedSlashBps = cfg.arbConfig.wrongOrMissedSlashBps;
        lastSlashCallerBountyBps = cfg.arbConfig.slashCallerBountyBps;
        out = nextDeployedMechanism;
    }
}

contract MockOpaqueMechanismFactory is IAllocationMechanismFactory {
    DeployedMechanism internal nextDeployedMechanism;
    uint256 public deployCalls;
    bytes32 public lastMechanismId;
    address public lastBudgetTreasury;
    bytes public lastMechanismConfig;

    function setNextDeployedMechanism(DeployedMechanism calldata next) external {
        nextDeployedMechanism = next;
    }

    function deployForBudget(
        bytes32 mechanismId,
        address budgetTreasury,
        bytes calldata mechanismConfig
    ) external returns (DeployedMechanism memory out) {
        deployCalls += 1;
        lastMechanismId = mechanismId;
        lastBudgetTreasury = budgetTreasury;
        lastMechanismConfig = mechanismConfig;
        out = nextDeployedMechanism;
    }
}

contract AllocationMechanismTCRTest is Test {
    MockVotesToken internal underlying;
    RoundTestSuperToken internal superToken;

    RoundTestBudgetStakeLedger internal ledger;
    RoundTestJurorSlasher internal jurorSlasher;

    RoundTestManagedFlow internal goalFlow;
    RoundTestManagedFlow internal budgetFlow;
    RoundTestGoalTreasury internal goalTreasury;
    RoundTestStakeVault internal stakeVault;
    RoundTestBudgetTreasury internal budgetTreasury;

    RoundFactory internal roundFactory;

    AllocationMechanismTCR internal mechanism;
    EscrowSubmissionDepositStrategy internal mechanismDepositStrategy;
    RoundTestArbitrator internal mechanismArbitrator;

    address internal roundOperator = address(0x0F00);
    address internal factoryManager = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal constant MOCK_DISTRIBUTION_POOL = address(0xD157);
    address internal constant ALT_DISTRIBUTION_POOL = address(0xD158);
    address internal constant MOCK_SUPERFLUID_HOST = address(0xF0057);
    address internal constant MOCK_GDA = address(0x6DA);
    bytes4 internal constant CALL_AGREEMENT_SELECTOR = bytes4(keccak256("callAgreement(address,bytes,bytes)"));
    bytes32 internal constant GDA_AGREEMENT_CLASS =
        keccak256("org.superfluid-finance.agreements.GeneralDistributionAgreement.v1");

    uint256 internal constant ARBITRATION_COST = 1e14;

    function test_constructor_revertsWhenEscrowImplementationIsZero() public {
        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        new AllocationMechanismTCR(address(0));
    }

    function test_constructor_revertsWhenEscrowImplementationHasNoCode() public {
        address noCode = makeAddr("no-code-escrow-implementation");
        vm.expectRevert(abi.encodeWithSelector(AllocationMechanismTCR.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new AllocationMechanismTCR(noCode);
    }

    function test_constructor_setsEscrowImplementation() public {
        MechanismFundingEscrow escrowImplementation = new MechanismFundingEscrow();
        AllocationMechanismTCR mechanismImplementation = new AllocationMechanismTCR(address(escrowImplementation));
        assertEq(mechanismImplementation.mechanismFundingEscrowImplementation(), address(escrowImplementation));
    }

    function setUp() public {
        underlying = new MockVotesToken("Goal", "GOAL");
        superToken = new RoundTestSuperToken("SuperGoal", "sGOAL", underlying);

        ledger = new RoundTestBudgetStakeLedger();
        jurorSlasher = new RoundTestJurorSlasher();

        goalFlow = new RoundTestManagedFlow(address(0xDEAD), address(0), address(0), address(0));
        stakeVault = new RoundTestStakeVault(underlying, address(0), address(jurorSlasher));
        goalTreasury = new RoundTestGoalTreasury(address(goalFlow), address(ledger), address(stakeVault));
        stakeVault.setGoalTreasury(address(goalTreasury));
        goalFlow.setFlowOperator(address(goalTreasury));

        budgetFlow = new RoundTestManagedFlow(address(0), address(0xB0), address(goalFlow), address(superToken));
        budgetTreasury = new RoundTestBudgetTreasury(address(budgetFlow));

        roundFactory = new RoundFactory();

        vm.mockCall(address(superToken), abi.encodeWithSignature("getHost()"), abi.encode(MOCK_SUPERFLUID_HOST));
        vm.mockCall(
            MOCK_SUPERFLUID_HOST,
            abi.encodeWithSignature("getAgreementClass(bytes32)", GDA_AGREEMENT_CLASS),
            abi.encode(MOCK_GDA)
        );
        vm.mockCall(MOCK_SUPERFLUID_HOST, abi.encodeWithSelector(CALL_AGREEMENT_SELECTOR), abi.encode(bytes("")));
        vm.mockCall(address(budgetFlow), abi.encodeWithSignature("distributionPool()"), abi.encode(MOCK_DISTRIBUTION_POOL));

        mechanismDepositStrategy = new EscrowSubmissionDepositStrategy(underlying);
        AllocationMechanismTCR mechanismImplementation =
            new AllocationMechanismTCR(address(new MechanismFundingEscrow()));
        mechanism = AllocationMechanismTCR(Clones.clone(address(mechanismImplementation)));

        budgetFlow.setRecipientAdmin(address(mechanism));

        mechanismArbitrator = new RoundTestArbitrator(
            IVotes(address(underlying)),
            address(mechanism),
            1,
            1,
            1,
            ARBITRATION_COST
        );

        AllocationMechanismTCR.RegistryConfig memory mechanismTcrCfg = _mechanismRegistryConfig(mechanismArbitrator);

        mechanism.initialize(address(budgetTreasury), address(roundFactory), mechanismTcrCfg);

        underlying.mint(alice, 1000e18);
        vm.prank(alice);
        underlying.approve(address(mechanism), type(uint256).max);
    }

    function _validListing(
        uint64 roundStartAt,
        uint64 roundEndAt
    ) internal view returns (AllocationMechanismTCR.MechanismListing memory listing) {
        uint64 duration = roundEndAt > roundStartAt ? roundEndAt - roundStartAt : 0;
        listing = AllocationMechanismTCR.MechanismListing({
            metadata: FlowTypes.RecipientMetadata({
                title: "Test Round",
                description: "Desc",
                image: "ipfs://image",
                tagline: "tag",
                url: "https://example.com"
            }),
            duration: duration,
            fundingDeadline: 0,
            minBudgetFunding: 0,
            maxBudgetFunding: 0,
            deploymentConfig: _mechanismDeploymentConfig(
                address(roundFactory), _encodedRoundMechanismConfig(roundStartAt, roundEndAt, _defaultRoundFactoryConfig())
            )
        });
    }

    function _validListingWithDefaultMinFundingPolicy()
        internal
        view
        returns (AllocationMechanismTCR.MechanismListing memory listing)
    {
        listing = _validListing(uint64(block.timestamp + 1), uint64(block.timestamp + 30 days));
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 7 days);
    }

    function _defaultRoundFactoryConfig() internal view returns (RoundFactory.AllocationMechanismConfig memory cfg) {
        cfg = RoundFactory.AllocationMechanismConfig({
            timing: RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator: roundOperator,
            tcrConfig: RoundFactory.SubmissionTcrConfig({
                arbitratorExtraData: "",
                registrationMetaEvidence: "round-reg",
                clearingMetaEvidence: "round-clr",
                submissionBaseDeposit: 1e18,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 1 days
            }),
            arbConfig: RoundFactory.ArbitratorConfig({
                votingPeriod: 1,
                votingDelay: 1,
                revealPeriod: 1,
                arbitrationCost: ARBITRATION_COST,
                wrongOrMissedSlashBps: 0,
                slashCallerBountyBps: 0
            })
        });
    }

    function _encodedRoundMechanismConfig(
        uint64 startAt,
        uint64 endAt,
        RoundFactory.AllocationMechanismConfig memory cfg
    ) internal pure returns (bytes memory encoded) {
        cfg.timing = RoundFactory.RoundTiming({ startAt: startAt, endAt: endAt });
        encoded = abi.encode(cfg);
    }

    function _mechanismDeploymentConfig(
        address mechanismFactory,
        bytes memory mechanismConfig
    )
        internal
        pure
        returns (AllocationMechanismTCR.MechanismDeploymentConfig memory cfg)
    {
        cfg = AllocationMechanismTCR.MechanismDeploymentConfig({
            mechanismFactory: mechanismFactory,
            mechanismConfig: mechanismConfig
        });
    }

    function _mechanismRegistryConfig(
        RoundTestArbitrator arbitrator_
    ) internal view returns (AllocationMechanismTCR.RegistryConfig memory cfg) {
        cfg = AllocationMechanismTCR.RegistryConfig({
            arbitrator: arbitrator_,
            arbitratorExtraData: "",
            registrationMetaEvidence: "mech-reg",
            clearingMetaEvidence: "mech-clr",
            factoryManager: factoryManager,
            votingToken: IVotes(address(underlying)),
            submissionBaseDeposit: 0,
            submissionDepositStrategy: mechanismDepositStrategy,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            challengePeriodDuration: 1 days
        });
    }

    function _warpPastChallengePeriod() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
    }

    function _registerAndActivate(
        AllocationMechanismTCR.MechanismListing memory listing
    ) internal returns (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) {
        vm.prank(alice);
        itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        mechanism.activateMechanism(itemId);

        deployment = mechanism.mechanismDeployment(itemId);
    }

    function _mockEscrowTotalReceived(address escrow, uint256 totalReceived) internal {
        address escrowPool = address(MechanismFundingEscrow(escrow).distributionPool());
        vm.mockCall(
            escrowPool,
            abi.encodeWithSignature("getTotalAmountReceivedByMember(address)", escrow),
            abi.encode(totalReceived)
        );
    }

    function test_initialize_revertsWhenBudgetFlowRecipientAdminMismatch() public {
        AllocationMechanismTCR mechanismImplementation =
            new AllocationMechanismTCR(address(new MechanismFundingEscrow()));
        AllocationMechanismTCR mechanism2 = AllocationMechanismTCR(Clones.clone(address(mechanismImplementation)));
        RoundTestArbitrator arbitrator2 = new RoundTestArbitrator(
            IVotes(address(underlying)),
            address(mechanism2),
            1,
            1,
            1,
            ARBITRATION_COST
        );

        AllocationMechanismTCR.RegistryConfig memory mechanismTcrCfg = _mechanismRegistryConfig(arbitrator2);

        vm.expectRevert(AllocationMechanismTCR.BUDGET_FLOW_MISMATCH.selector);
        mechanism2.initialize(address(budgetTreasury), address(roundFactory), mechanismTcrCfg);
    }

    function test_initialize_revertsWhenRoundFactoryIsNotContract() public {
        AllocationMechanismTCR mechanismImplementation =
            new AllocationMechanismTCR(address(new MechanismFundingEscrow()));
        AllocationMechanismTCR mechanism2 = AllocationMechanismTCR(Clones.clone(address(mechanismImplementation)));
        RoundTestArbitrator arbitrator2 = new RoundTestArbitrator(
            IVotes(address(underlying)),
            address(mechanism2),
            1,
            1,
            1,
            ARBITRATION_COST
        );

        AllocationMechanismTCR.RegistryConfig memory mechanismTcrCfg = _mechanismRegistryConfig(arbitrator2);

        vm.expectRevert(abi.encodeWithSelector(AllocationMechanismTCR.INVALID_FACTORY.selector, alice));
        mechanism2.initialize(address(budgetTreasury), alice, mechanismTcrCfg);
    }

    function test_initialize_revertsWhenFactoryManagerIsZero() public {
        AllocationMechanismTCR mechanismImplementation =
            new AllocationMechanismTCR(address(new MechanismFundingEscrow()));
        AllocationMechanismTCR mechanism2 = AllocationMechanismTCR(Clones.clone(address(mechanismImplementation)));
        RoundTestArbitrator arbitrator2 = new RoundTestArbitrator(
            IVotes(address(underlying)),
            address(mechanism2),
            1,
            1,
            1,
            ARBITRATION_COST
        );

        AllocationMechanismTCR.RegistryConfig memory mechanismTcrCfg = _mechanismRegistryConfig(arbitrator2);
        mechanismTcrCfg.factoryManager = address(0);
        budgetFlow.setRecipientAdmin(address(mechanism2));

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        mechanism2.initialize(address(budgetTreasury), address(roundFactory), mechanismTcrCfg);
    }

    function test_initialize_setsFactoryManager() public view {
        assertEq(mechanism.factoryManager(), factoryManager);
    }

    function test_mechanismFundingEscrowImplementation_initializeReverts() public {
        address implementation = mechanism.mechanismFundingEscrowImplementation();
        address superToken_ = address(MechanismFundingEscrow(implementation).superToken());
        address distributionPool_ = address(MechanismFundingEscrow(implementation).distributionPool());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MechanismFundingEscrow(implementation).initialize(
            ISuperToken(superToken_),
            ISuperfluidPool(distributionPool_),
            address(mechanism),
            address(budgetFlow),
            alice
        );
    }

    function test_verifyItemData_rejectsBadMetadata() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp),
            uint64(block.timestamp + 1)
        );
        listing.metadata.title = "";

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_verifyItemData_rejectsMalformedListingPayload() public {
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(hex"1234");
    }

    function test_verifyItemData_acceptsListingWithoutAbsoluteTimeWindowValidation() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(200, 100);

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        assertTrue(itemId != bytes32(0));
    }

    function test_verifyItemData_rejectsInvalidFundingPolicy_maxBelowMin() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(100, 200);
        listing.minBudgetFunding = 10e18;
        listing.maxBudgetFunding = 9e18;

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_verifyItemData_rejectsInvalidFundingPolicy_minWithoutDeadline() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(100, 200);
        listing.minBudgetFunding = 10e18;

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function testFuzz_verifyItemData_rejectsMalformedShortPayloads(bytes calldata payload) public {
        // Valid encoded listings are significantly larger than this bound.
        vm.assume(payload.length < 224);

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(payload);
    }

    function test_registerQueuesActivation() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.activationQueued(itemId));
        assertFalse(mechanism.removalQueued(itemId));

        (, IGeneralizedTCR.Status status,) = mechanism.getItemInfo(itemId);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));
    }

    function test_removeBeforeActivationDoesNotQueueRemoval() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertFalse(mechanism.activationQueued(itemId));
        assertFalse(mechanism.removalQueued(itemId));
    }

    function test_initialize_setsInitialMechanismFactoryAsAllowlisted() public view {
        assertTrue(mechanism.mechanismFactoryAllowed(address(roundFactory)));
    }

    function test_setMechanismFactoryAllowed_onlyFactoryManager() public {
        address altFactory = address(new RoundFactory());

        vm.prank(alice);
        vm.expectRevert(AllocationMechanismTCR.ONLY_FACTORY_MANAGER.selector);
        mechanism.setMechanismFactoryAllowed(altFactory, true);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(altFactory, true);
        assertTrue(mechanism.mechanismFactoryAllowed(altFactory));

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(altFactory, false);
        assertFalse(mechanism.mechanismFactoryAllowed(altFactory));
    }

    function test_setMechanismFactoryAllowed_revertsForZeroOrNonContractWhenAllowing() public {
        vm.prank(factoryManager);
        vm.expectRevert(abi.encodeWithSignature("ADDRESS_ZERO()"));
        mechanism.setMechanismFactoryAllowed(address(0), true);

        vm.prank(factoryManager);
        vm.expectRevert(abi.encodeWithSelector(AllocationMechanismTCR.INVALID_FACTORY.selector, alice));
        mechanism.setMechanismFactoryAllowed(alice, true);
    }

    function test_verifyItemData_rejectsUnallowlistedFactory() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2)
        );
        listing.deploymentConfig.mechanismFactory = address(new RoundFactory());

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_verifyItemData_rejectsInvalidMechanismDeploymentConfigFields() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2)
        );
        listing.deploymentConfig.mechanismFactory = address(0);

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_activateMechanism_routesDeploymentThroughFactoryInListing() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xAAA1),
            mechanism: address(roundFactory),
            arbitrator: address(0xAAA3),
            auxiliary: address(0xAAA4)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.deploymentConfig.mechanismFactory = address(mockFactory);
        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        IAllocationMechanismFactory.DeployedMechanism memory deployed = mechanism.activateMechanism(itemId);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);

        assertEq(mockFactory.createCalls(), 1);
        assertEq(mockFactory.lastMechanismId(), itemId);
        assertEq(mockFactory.lastBudgetTreasury(), address(budgetTreasury));
        assertEq(mockFactory.lastRoundOperator(), roundOperator);

        assertEq(deployed.payoutRecipient, fakeDeployment.payoutRecipient);
        assertEq(deployment.payoutRecipient, fakeDeployment.payoutRecipient);
        assertEq(deployment.mechanism, fakeDeployment.mechanism);
        assertEq(deployment.arbitrator, fakeDeployment.arbitrator);
        assertEq(deployment.auxiliary, fakeDeployment.auxiliary);
    }

    function test_activateMechanism_revertsWhenActiveRecipientCapReached() public {
        uint256 maxRecipients = mechanism.MAX_ACTIVE_MECHANISM_RECIPIENTS();

        for (uint256 i = 0; i < maxRecipients; ) {
            uint64 startAt = uint64(block.timestamp + 1 days);
            uint64 endAt = startAt + 30 days;
            AllocationMechanismTCR.MechanismListing memory listing = _validListing(startAt, endAt);
            listing.metadata.title = string.concat("Round ", vm.toString(i));

            vm.prank(alice);
            bytes32 itemId = mechanism.addItem(abi.encode(listing));
            _warpPastChallengePeriod();
            mechanism.executeRequest(itemId);
            mechanism.activateMechanism(itemId);

            assertEq(mechanism.activeMechanismRecipientCount(), i + 1);
            unchecked {
                ++i;
            }
        }

        AllocationMechanismTCR.MechanismListing memory overCapListing =
            _validListing(uint64(block.timestamp + 1 days), uint64(block.timestamp + 40 days));
        overCapListing.metadata.title = "Round over cap";

        vm.prank(alice);
        bytes32 overCapItemId = mechanism.addItem(abi.encode(overCapListing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(overCapItemId);

        vm.expectRevert(
            abi.encodeWithSelector(
                AllocationMechanismTCR.ACTIVE_MECHANISM_RECIPIENT_CAP_REACHED.selector,
                maxRecipients
            )
        );
        mechanism.activateMechanism(overCapItemId);
    }

    function test_finalizeRemovedMechanism_decrementsActiveRecipientCountAndFreesCapSlot() public {
        uint256 maxRecipients = mechanism.MAX_ACTIVE_MECHANISM_RECIPIENTS();
        bytes32[] memory itemIds = new bytes32[](maxRecipients);

        for (uint256 i = 0; i < maxRecipients; ) {
            AllocationMechanismTCR.MechanismListing memory listing =
                _validListing(uint64(block.timestamp + 1 days), uint64(block.timestamp + 40 days));
            listing.metadata.title = string.concat("Round ", vm.toString(i));

            vm.prank(alice);
            itemIds[i] = mechanism.addItem(abi.encode(listing));
            _warpPastChallengePeriod();
            mechanism.executeRequest(itemIds[i]);
            mechanism.activateMechanism(itemIds[i]);

            unchecked {
                ++i;
            }
        }

        assertEq(mechanism.activeMechanismRecipientCount(), maxRecipients);

        bytes32 removedItemId = itemIds[0];
        vm.prank(alice);
        mechanism.removeItem(removedItemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(removedItemId);
        mechanism.finalizeRemovedMechanism(removedItemId);

        assertEq(mechanism.activeMechanismRecipientCount(), maxRecipients - 1);

        AllocationMechanismTCR.MechanismListing memory replacementListing =
            _validListing(uint64(block.timestamp + 1 days), uint64(block.timestamp + 40 days));
        replacementListing.metadata.title = "Replacement round";

        vm.prank(alice);
        bytes32 replacementItemId = mechanism.addItem(abi.encode(replacementListing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(replacementItemId);
        mechanism.activateMechanism(replacementItemId);

        assertEq(mechanism.activeMechanismRecipientCount(), maxRecipients);
    }

    function test_syncMechanismFunding_durationStop_decrementsActiveRecipientCount() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 2 days)
        );
        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 25e18);

        assertEq(mechanism.activeMechanismRecipientCount(), 1);

        vm.warp(block.timestamp + uint256(listing.duration) + 1);
        mechanism.syncMechanismFunding(itemId);

        assertEq(mechanism.activeMechanismRecipientCount(), 0);
    }

    function test_activateMechanism_forwardsImmutableListingDeploymentConfig() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xFA01),
            mechanism: address(roundFactory),
            arbitrator: address(0xFA03),
            auxiliary: address(0xFA04)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        uint64 roundStartAt = uint64(block.timestamp + 5);
        uint64 roundEndAt = uint64(block.timestamp + 40 days);
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(roundStartAt, roundEndAt);
        RoundFactory.AllocationMechanismConfig memory cfg = RoundFactory.AllocationMechanismConfig({
            timing: RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator: address(0x2222),
            tcrConfig: RoundFactory.SubmissionTcrConfig({
                arbitratorExtraData: hex"deadbeef",
                registrationMetaEvidence: "custom-round-reg",
                clearingMetaEvidence: "custom-round-clr",
                submissionBaseDeposit: 123,
                removalBaseDeposit: 456,
                submissionChallengeBaseDeposit: 789,
                removalChallengeBaseDeposit: 321,
                challengePeriodDuration: 3 days
            }),
            arbConfig: RoundFactory.ArbitratorConfig({
                votingPeriod: 10,
                votingDelay: 11,
                revealPeriod: 12,
                arbitrationCost: ARBITRATION_COST + 42,
                wrongOrMissedSlashBps: 1337,
                slashCallerBountyBps: 777
            })
        });
        listing.deploymentConfig = _mechanismDeploymentConfig(
            address(mockFactory), _encodedRoundMechanismConfig(roundStartAt, roundEndAt, cfg)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.createCalls(), 1);
        assertEq(mockFactory.lastStartAt(), roundStartAt);
        assertEq(mockFactory.lastEndAt(), roundEndAt);
        assertEq(mockFactory.lastRoundOperator(), cfg.roundOperator);
        assertEq(mockFactory.lastSubmissionBaseDeposit(), cfg.tcrConfig.submissionBaseDeposit);
        assertEq(mockFactory.lastRemovalBaseDeposit(), cfg.tcrConfig.removalBaseDeposit);
        assertEq(mockFactory.lastSubmissionChallengeBaseDeposit(), cfg.tcrConfig.submissionChallengeBaseDeposit);
        assertEq(mockFactory.lastRemovalChallengeBaseDeposit(), cfg.tcrConfig.removalChallengeBaseDeposit);
        assertEq(mockFactory.lastChallengePeriodDuration(), cfg.tcrConfig.challengePeriodDuration);
        assertEq(mockFactory.lastVotingPeriod(), cfg.arbConfig.votingPeriod);
        assertEq(mockFactory.lastVotingDelay(), cfg.arbConfig.votingDelay);
        assertEq(mockFactory.lastRevealPeriod(), cfg.arbConfig.revealPeriod);
        assertEq(mockFactory.lastArbitrationCost(), cfg.arbConfig.arbitrationCost);
        assertEq(mockFactory.lastWrongOrMissedSlashBps(), cfg.arbConfig.wrongOrMissedSlashBps);
        assertEq(mockFactory.lastSlashCallerBountyBps(), cfg.arbConfig.slashCallerBountyBps);
        assertEq(keccak256(mockFactory.lastArbitratorExtraData()), keccak256(cfg.tcrConfig.arbitratorExtraData));
        assertEq(
            keccak256(bytes(mockFactory.lastRegistrationMetaEvidence())),
            keccak256(bytes(cfg.tcrConfig.registrationMetaEvidence))
        );
        assertEq(
            keccak256(bytes(mockFactory.lastClearingMetaEvidence())),
            keccak256(bytes(cfg.tcrConfig.clearingMetaEvidence))
        );
    }

    function test_activateMechanism_forwardsOpaqueMechanismConfigBytesUnchanged() public {
        MockOpaqueMechanismFactory mockFactory = new MockOpaqueMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xCE01),
            mechanism: address(roundFactory),
            arbitrator: address(0xCE03),
            auxiliary: address(0xCE04)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 3),
            uint64(block.timestamp + 31 days)
        );
        bytes memory opaqueConfig = abi.encodePacked(bytes2(0xCAFE), bytes32(uint256(0xBEEF)), "opaque-config-v1");
        listing.deploymentConfig = _mechanismDeploymentConfig(address(mockFactory), opaqueConfig);

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.deployCalls(), 1);
        assertEq(mockFactory.lastMechanismId(), itemId);
        assertEq(mockFactory.lastBudgetTreasury(), address(budgetTreasury));
        assertEq(keccak256(mockFactory.lastMechanismConfig()), keccak256(opaqueConfig));

        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.payoutRecipient, fakeDeployment.payoutRecipient);
        assertEq(deployment.mechanism, fakeDeployment.mechanism);
        assertEq(deployment.arbitrator, fakeDeployment.arbitrator);
        assertEq(deployment.auxiliary, fakeDeployment.auxiliary);
    }

    function test_activateMechanism_revertsWhenFactoryReturnsZeroMechanismAddress() public {
        MockOpaqueMechanismFactory mockFactory = new MockOpaqueMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xDE01),
            mechanism: address(0),
            arbitrator: address(0xDE03),
            auxiliary: address(0xDE04)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 10 days)
        );
        listing.deploymentConfig = _mechanismDeploymentConfig(address(mockFactory), hex"010203");

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.expectRevert(AllocationMechanismTCR.INVALID_MECHANISM_CONFIG.selector);
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.deployCalls(), 0);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.mechanism, address(0));
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_revertsWhenFactoryReturnsZeroPayoutRecipient() public {
        MockOpaqueMechanismFactory mockFactory = new MockOpaqueMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0),
            mechanism: address(roundFactory),
            arbitrator: address(0xDF03),
            auxiliary: address(0xDF04)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 10 days)
        );
        listing.deploymentConfig = _mechanismDeploymentConfig(address(mockFactory), hex"010203");

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.expectRevert(AllocationMechanismTCR.INVALID_MECHANISM_CONFIG.selector);
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.deployCalls(), 0);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.mechanism, address(0));
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_revertsWhenFactoryReturnsEOAMechanismAddress() public {
        MockOpaqueMechanismFactory mockFactory = new MockOpaqueMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xE001),
            mechanism: alice,
            arbitrator: address(0xE003),
            auxiliary: address(0xE004)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 10 days)
        );
        listing.deploymentConfig = _mechanismDeploymentConfig(address(mockFactory), hex"102030");

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.expectRevert(AllocationMechanismTCR.INVALID_MECHANISM_CONFIG.selector);
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.deployCalls(), 0);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.mechanism, address(0));
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_revertsWhenFactoryReturnsRegistryAsPayoutRecipient() public {
        MockOpaqueMechanismFactory mockFactory = new MockOpaqueMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(mechanism),
            mechanism: address(roundFactory),
            arbitrator: address(0xE103),
            auxiliary: address(0xE104)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 10 days)
        );
        listing.deploymentConfig = _mechanismDeploymentConfig(address(mockFactory), hex"405060");

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.expectRevert(AllocationMechanismTCR.INVALID_MECHANISM_CONFIG.selector);
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.deployCalls(), 0);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.mechanism, address(0));
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_revertsWhenRoundFactoryMechanismConfigMalformed() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 20 days)
        );
        // Opaque mechanism payload is only validated by the selected factory at activation time.
        listing.deploymentConfig = _mechanismDeploymentConfig(address(roundFactory), hex"1234");

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.expectRevert();
        mechanism.activateMechanism(itemId);

        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.mechanism, address(0));
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_revertsWhenListingFactoryIsNoLongerAllowlisted() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.deploymentConfig.mechanismFactory = address(mockFactory);
        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), false);

        vm.expectRevert(abi.encodeWithSelector(AllocationMechanismTCR.FACTORY_NOT_ALLOWED.selector, address(mockFactory)));
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.createCalls(), 0);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_usesFactoryFromListingAtActivationTime() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xAB01),
            mechanism: address(roundFactory),
            arbitrator: address(0xAB03),
            auxiliary: address(0xAB04)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.deploymentConfig.mechanismFactory = address(mockFactory);
        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.createCalls(), 1);
        assertEq(mockFactory.lastMechanismId(), itemId);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.payoutRecipient, fakeDeployment.payoutRecipient);
        assertEq(deployment.mechanism, fakeDeployment.mechanism);
    }

    function test_activateMechanism_allowsActivationAfterPriorAbsoluteRoundWindow() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xAB11),
            mechanism: address(roundFactory),
            arbitrator: address(0xAB13),
            auxiliary: address(0xAB14)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);
        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        uint64 roundStartAt = uint64(block.timestamp + 1);
        uint64 roundEndAt = uint64(block.timestamp + 2 days);
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            roundStartAt,
            roundEndAt
        );
        listing.deploymentConfig.mechanismFactory = address(mockFactory);

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.warp(uint256(roundEndAt) + 1);
        mechanism.activateMechanism(itemId);

        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(mockFactory.createCalls(), 1);
        assertFalse(mechanism.activationQueued(itemId));
        assertTrue(deployment.active);
        assertEq(deployment.mechanism, fakeDeployment.mechanism);
    }

    function test_activateMechanism_revertsWhenListingExpiredUnderfundedBeforeActivation() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();
        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 3 days)
        );
        listing.deploymentConfig.mechanismFactory = address(mockFactory);
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 2 days);

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.warp(uint256(listing.fundingDeadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AllocationMechanismTCR.MECHANISM_EXPIRED_UNDERFUNDED.selector,
                listing.fundingDeadline,
                listing.minBudgetFunding,
                0
            )
        );
        mechanism.activateMechanism(itemId);

        assertEq(mockFactory.createCalls(), 0);
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_activateMechanism_allowsActivationAtFundingDeadlineBoundary() public {
        MockAllocationMechanismFactory mockFactory = new MockAllocationMechanismFactory();
        IAllocationMechanismFactory.DeployedMechanism memory fakeDeployment = IAllocationMechanismFactory.DeployedMechanism({
            payoutRecipient: address(0xAB21),
            mechanism: address(roundFactory),
            arbitrator: address(0xAB23),
            auxiliary: address(0xAB24)
        });
        mockFactory.setNextDeployedMechanism(fakeDeployment);

        vm.prank(factoryManager);
        mechanism.setMechanismFactoryAllowed(address(mockFactory), true);

        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 3 days)
        );
        listing.deploymentConfig.mechanismFactory = address(mockFactory);
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 2 days);

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.warp(uint256(listing.fundingDeadline));
        mechanism.activateMechanism(itemId);

        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(mockFactory.createCalls(), 1);
        assertFalse(mechanism.activationQueued(itemId));
        assertTrue(deployment.active);
        assertEq(deployment.mechanism, fakeDeployment.mechanism);
    }

    function test_activateAndFinalizeRemoval_endToEnd() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        IAllocationMechanismFactory.DeployedMechanism memory deployed = mechanism.activateMechanism(itemId);
        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);

        assertTrue(deployment.active);
        assertTrue(deployed.payoutRecipient.code.length > 0);
        assertTrue(deployed.mechanism.code.length > 0);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertTrue(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(MechanismFundingEscrow(deployment.fundingEscrow).recipient(), deployed.payoutRecipient);
        assertEq(MechanismFundingEscrow(deployment.fundingEscrow).refundRecipient(), address(budgetFlow));
        assertEq(MechanismFundingEscrow(deployment.fundingEscrow).controller(), address(mechanism));
        assertEq(address(MechanismFundingEscrow(deployment.fundingEscrow).distributionPool()), MOCK_DISTRIBUTION_POOL);

        uint256 escrowedBeforeRemoval = 7e18;
        superToken.mint(deployment.fundingEscrow, escrowedBeforeRemoval);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.removalQueued(itemId));

        mechanism.finalizeRemovedMechanism(itemId);
        AllocationMechanismTCR.MechanismDeployment memory afterDeployment = mechanism.mechanismDeployment(itemId);
        assertFalse(afterDeployment.active);
        assertFalse(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowedBeforeRemoval);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
    }

    function test_activateMechanism_escrowClone_reinitializeReverts() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        (, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);

        MechanismFundingEscrow escrow = MechanismFundingEscrow(deployment.fundingEscrow);
        address recipientBefore = escrow.recipient();
        address refundRecipientBefore = escrow.refundRecipient();
        address controllerBefore = escrow.controller();
        address escrowSuperToken = address(escrow.superToken());
        address escrowDistributionPool = address(escrow.distributionPool());

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(
            ISuperToken(escrowSuperToken),
            ISuperfluidPool(escrowDistributionPool),
            address(mechanism),
            address(budgetFlow),
            alice
        );

        assertEq(escrow.recipient(), recipientBefore);
        assertEq(escrow.refundRecipient(), refundRecipientBefore);
        assertEq(escrow.controller(), controllerBefore);
    }

    function test_escrowReleaseRefund_onlyController() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        MechanismFundingEscrow escrow = MechanismFundingEscrow(deployment.fundingEscrow);

        uint256 escrowed = 3e18;
        superToken.mint(deployment.fundingEscrow, escrowed);

        vm.prank(alice);
        vm.expectRevert(MechanismFundingEscrow.ONLY_CONTROLLER.selector);
        escrow.release(1e18);

        vm.prank(alice);
        vm.expectRevert(MechanismFundingEscrow.ONLY_CONTROLLER.selector);
        escrow.refund(1e18);

        _mockEscrowTotalReceived(deployment.fundingEscrow, 0);
        uint256 released = mechanism.releaseMechanismFunds(itemId, 1e18);
        assertEq(released, 1e18);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), 1e18);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed - released);
    }

    function test_activateMechanism_revertsWhenBudgetFlowDistributionPoolIsZero() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.mockCall(address(budgetFlow), abi.encodeWithSignature("distributionPool()"), abi.encode(address(0)));

        vm.expectRevert(AllocationMechanismTCR.BUDGET_FLOW_MISMATCH.selector);
        mechanism.activateMechanism(itemId);
    }

    function test_activateMechanism_revertsWhenEscrowPoolConnectFails() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        bytes memory connectFailure = abi.encodeWithSignature("Error(string)", "CONNECT_FAIL");
        vm.mockCallRevert(MOCK_SUPERFLUID_HOST, abi.encodeWithSelector(CALL_AGREEMENT_SELECTOR), connectFailure);

        vm.expectRevert(connectFailure);
        mechanism.activateMechanism(itemId);

        AllocationMechanismTCR.MechanismDeployment memory deployment = mechanism.mechanismDeployment(itemId);
        assertEq(deployment.payoutRecipient, address(0));
        assertEq(deployment.fundingEscrow, address(0));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertTrue(mechanism.activationQueued(itemId));
    }

    function test_addItem_revertsWhileRemovalFinalizationPending() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        mechanism.activateMechanism(itemId);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.removalQueued(itemId));

        vm.prank(alice);
        vm.expectRevert(AllocationMechanismTCR.REMOVAL_FINALIZATION_PENDING.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_releaseMechanismFunds_revertsBelowMinBudgetFunding() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);

        vm.expectRevert(
            abi.encodeWithSelector(AllocationMechanismTCR.MECHANISM_BELOW_MIN_FUNDING.selector, listing.minBudgetFunding, 99e18)
        );
        mechanism.releaseMechanismFunds(itemId, 0);
    }

    function test_releaseMechanismFunds_allowsDirectEscrowBalanceWhenPoolBelowMin() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = listing.minBudgetFunding;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding - 1);

        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);
        assertEq(released, escrowed);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), escrowed);
    }

    function test_releaseMechanismFunds_allowsDirectEscrowBalanceAfterFundingDeadlineWhenPoolBelowMin() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = listing.minBudgetFunding;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding - 1);
        vm.warp(uint256(listing.fundingDeadline) + 1);

        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);
        AllocationMechanismTCR.MechanismDeployment memory afterRelease = mechanism.mechanismDeployment(itemId);

        assertEq(released, escrowed);
        assertTrue(afterRelease.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
    }

    function test_syncMechanismFunding_doesNotExpireAfterReleaseWhenMinWasMetByDirectEscrowBalance() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = listing.minBudgetFunding;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding - 1);

        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);
        assertEq(released, escrowed);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);

        vm.warp(uint256(listing.fundingDeadline) + 1);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding - 1);
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertTrue(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
    }

    function test_releaseMechanismFunds_revertsWhenEscrowTransferReturnsFalse() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 4e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 0);

        vm.mockCall(
            address(superToken),
            abi.encodeWithSignature("transfer(address,uint256)", deployment.payoutRecipient, escrowed),
            abi.encode(false)
        );

        vm.expectRevert(MechanismFundingEscrow.TRANSFER_FAILED.selector);
        mechanism.releaseMechanismFunds(itemId, 0);

        AllocationMechanismTCR.MechanismDeployment memory afterRelease = mechanism.mechanismDeployment(itemId);
        assertTrue(afterRelease.active);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), 0);
    }

    function test_releaseMechanismFunds_callsSyncAndRefundsWhenExpiredUnderfunded() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 3 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 2 days);

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 3e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        vm.warp(uint256(listing.fundingDeadline) + 1);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);

        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);

        AllocationMechanismTCR.MechanismDeployment memory afterRelease = mechanism.mechanismDeployment(itemId);
        assertEq(released, 0);
        assertFalse(afterRelease.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertFalse(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowed);
    }

    function test_releaseMechanismFunds_revertsBelowMinAtFundingDeadlineBoundary() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 underMinFunding = listing.minBudgetFunding - 1;
        _mockEscrowTotalReceived(deployment.fundingEscrow, underMinFunding);

        vm.warp(uint256(listing.fundingDeadline));
        vm.expectRevert(
            abi.encodeWithSelector(
                AllocationMechanismTCR.MECHANISM_BELOW_MIN_FUNDING.selector, listing.minBudgetFunding, underMinFunding
            )
        );
        mechanism.releaseMechanismFunds(itemId, 0);

        AllocationMechanismTCR.MechanismDeployment memory afterRelease = mechanism.mechanismDeployment(itemId);
        assertTrue(afterRelease.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
    }

    function test_releaseMechanismFunds_sweepsEscrowToPrizeVaultWhenMinMet() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 5e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding);

        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);
        assertEq(released, escrowed);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), escrowed);
    }

    function test_releaseMechanismFunds_afterFundingTicks_balanceIncreases_andReleasesNonZero() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertTrue(budgetFlow.recipientExists(deployment.fundingEscrow));

        uint256 balanceBefore = superToken.balanceOf(deployment.fundingEscrow);
        assertEq(balanceBefore, 0);

        superToken.mint(deployment.fundingEscrow, 2e18);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 40e18);
        uint256 balanceAfterFirstTick = superToken.balanceOf(deployment.fundingEscrow);
        assertGt(balanceAfterFirstTick, balanceBefore);

        superToken.mint(deployment.fundingEscrow, 3e18);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding);
        uint256 balanceAfterSecondTick = superToken.balanceOf(deployment.fundingEscrow);
        assertGt(balanceAfterSecondTick, balanceAfterFirstTick);

        uint256 vaultBefore = superToken.balanceOf(deployment.payoutRecipient);
        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);
        AllocationMechanismTCR.MechanismDeployment memory afterRelease = mechanism.mechanismDeployment(itemId);

        assertGt(released, 0);
        assertEq(released, balanceAfterSecondTick);
        // Releasing funds does not stop future funding; stop conditions are enforced by syncMechanismFunding.
        assertTrue(afterRelease.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertTrue(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), vaultBefore + released);
    }

    function test_totalReceived_usesEscrowPool_notBudgetFlowPool_afterPoolChange() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();
        listing.maxBudgetFunding = 200e18;

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        address escrowPool = address(MechanismFundingEscrow(deployment.fundingEscrow).distributionPool());
        assertEq(escrowPool, MOCK_DISTRIBUTION_POOL);

        vm.mockCall(address(budgetFlow), abi.encodeWithSignature("distributionPool()"), abi.encode(ALT_DISTRIBUTION_POOL));
        vm.mockCallRevert(
            ALT_DISTRIBUTION_POOL,
            abi.encodeWithSignature("getTotalAmountReceivedByMember(address)", deployment.fundingEscrow),
            abi.encodeWithSignature("Error(string)", "UNEXPECTED_NEW_POOL_READ")
        );

        uint256 escrowed = 5e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding);

        uint256 released = mechanism.releaseMechanismFunds(itemId, 0);
        assertEq(released, escrowed);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), escrowed);

        superToken.mint(deployment.fundingEscrow, 1e18);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.maxBudgetFunding);
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
    }

    function test_syncMechanismFunding_refundsEscrowWhenExpiredUnderfundedEvenAfterDurationElapsed() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 2 days);

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 3e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        assertEq(mechanism.activeMechanismRecipientCount(), 1);

        vm.warp(uint256(deployment.activatedAt) + uint256(listing.duration) + 1);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertFalse(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowed);
        assertEq(mechanism.activeMechanismRecipientCount(), 0);

        mechanism.syncMechanismFunding(itemId);
        assertEq(mechanism.activeMechanismRecipientCount(), 0);
    }

    function test_syncMechanismFunding_keepsActiveWhenPoolBelowMinButEscrowBalanceMeetsMinAfterDeadline() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListingWithDefaultMinFundingPolicy();

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = listing.minBudgetFunding;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding - 1);
        vm.warp(uint256(listing.fundingDeadline) + 1);

        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertTrue(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
    }

    function test_syncMechanismFunding_stopsAtCapWithoutRefundingEscrow() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.maxBudgetFunding = 250e18;

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 2e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.maxBudgetFunding);
        assertEq(mechanism.activeMechanismRecipientCount(), 1);

        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
        assertEq(mechanism.activeMechanismRecipientCount(), 0);

        mechanism.syncMechanismFunding(itemId);
        assertEq(mechanism.activeMechanismRecipientCount(), 0);
    }

    function test_syncMechanismFunding_stopsAtCapWhenEscrowBalanceHitsCapAndPoolBelowCap() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.maxBudgetFunding = 250e18;

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = listing.maxBudgetFunding;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.maxBudgetFunding - 1);

        vm.expectEmit(true, true, false, true, address(mechanism));
        emit AllocationMechanismTCR.MechanismFundingStopped(
            itemId,
            AllocationMechanismTCR.FundingStopReason.Capped,
            escrowed
        );
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
    }

    function test_syncMechanismFunding_doesNotStopAtExactDurationBoundary() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2 days)
        );

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 25e18);

        vm.warp(uint256(deployment.activatedAt) + uint256(listing.duration));
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertTrue(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
    }

    function test_syncMechanismFunding_stopsOnDurationElapsed_reasonEnded() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2 days)
        );

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 2e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 25e18);

        vm.warp(uint256(deployment.activatedAt) + uint256(listing.duration) + 1);
        vm.expectEmit(true, true, false, true, address(mechanism));
        emit AllocationMechanismTCR.MechanismFundingStopped(
            itemId,
            AllocationMechanismTCR.FundingStopReason.Ended,
            25e18
        );
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
    }

    function test_syncMechanismFunding_doesNotStopWhenDurationUnset() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2 days)
        );
        listing.duration = 0;

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 1e18);

        vm.warp(uint256(deployment.activatedAt) + 365 days);
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertTrue(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
    }

    function test_syncMechanismFunding_refundsAfterDurationStopWhenDeadlinePassesLater() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 4 days);

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 3e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);

        vm.warp(uint256(deployment.activatedAt) + uint256(listing.duration) + 1);
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterDurationStop = mechanism.mechanismDeployment(itemId);
        assertFalse(afterDurationStop.active);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);

        vm.warp(uint256(listing.fundingDeadline) + 1);
        mechanism.syncMechanismFunding(itemId);

        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowed);
    }

    function test_finalizeRemovedMechanism_refundsEscrowAfterFundingAlreadyStopped() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.maxBudgetFunding = 250e18;

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 4e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.maxBudgetFunding);

        mechanism.syncMechanismFunding(itemId);
        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        assertTrue(mechanism.removalQueued(itemId));

        mechanism.finalizeRemovedMechanism(itemId);
        assertFalse(mechanism.removalQueued(itemId));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowed);
    }

    function test_finalizeRemovedMechanism_recoversEscrowAfterReleaseTransferFailure() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 6e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 0);

        vm.mockCall(
            address(superToken),
            abi.encodeWithSignature("transfer(address,uint256)", deployment.payoutRecipient, escrowed),
            abi.encode(false)
        );

        vm.expectRevert(MechanismFundingEscrow.TRANSFER_FAILED.selector);
        mechanism.releaseMechanismFunds(itemId, 0);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        assertTrue(mechanism.removalQueued(itemId));

        mechanism.finalizeRemovedMechanism(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterFinalize = mechanism.mechanismDeployment(itemId);
        assertFalse(afterFinalize.active);
        assertFalse(mechanism.removalQueued(itemId));
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowed);
        assertEq(superToken.balanceOf(deployment.payoutRecipient), 0);
    }

    function test_syncMechanismFunding_noopWhileRemovalFinalizationQueued() public {
        AllocationMechanismTCR.MechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.maxBudgetFunding = 250e18;

        (bytes32 itemId, AllocationMechanismTCR.MechanismDeployment memory deployment) = _registerAndActivate(listing);
        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        assertTrue(mechanism.removalQueued(itemId));

        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.maxBudgetFunding);
        mechanism.syncMechanismFunding(itemId);

        AllocationMechanismTCR.MechanismDeployment memory afterSync = mechanism.mechanismDeployment(itemId);
        assertTrue(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);

        mechanism.finalizeRemovedMechanism(itemId);
        assertFalse(mechanism.removalQueued(itemId));
        AllocationMechanismTCR.MechanismDeployment memory afterFinalize = mechanism.mechanismDeployment(itemId);
        assertFalse(afterFinalize.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
    }
}
