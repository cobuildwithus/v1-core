// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { RoundPrizeVault } from "src/rounds/RoundPrizeVault.sol";
import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    RoundTestSuperToken,
    RoundTestManagedFlow,
    RoundTestBudgetTreasury,
    RoundTestGoalTreasury,
    RoundTestStakeVault,
    RoundTestRewardEscrow,
    RoundTestBudgetStakeLedger,
    RoundTestJurorSlasher,
    RoundTestArbitrator
} from "test/rounds/helpers/RoundTestMocks.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract SubmissionDepositRoutingTest is Test {
    MockVotesToken internal underlying;
    RoundTestSuperToken internal superToken;

    RoundTestBudgetStakeLedger internal ledger;
    RoundTestRewardEscrow internal rewardEscrow;
    RoundTestJurorSlasher internal jurorSlasher;
    RoundTestManagedFlow internal goalFlow;
    RoundTestManagedFlow internal budgetFlow;
    RoundTestGoalTreasury internal goalTreasury;
    RoundTestStakeVault internal stakeVault;
    RoundTestBudgetTreasury internal budgetTreasury;

    RoundFactory internal factory;

    address internal roundOperator = address(0x0F00);
    address internal governor = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal challenger = address(0xC0FFEE);

    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant SUBMISSION_DEPOSIT = 1e18;
    bytes32 internal constant DEFAULT_POST_ID = bytes32("post");

    function setUp() public {
        underlying = new MockVotesToken("Goal", "GOAL");
        superToken = new RoundTestSuperToken("SuperGoal", "sGOAL", underlying);

        ledger = new RoundTestBudgetStakeLedger();
        rewardEscrow = new RoundTestRewardEscrow(address(ledger));
        jurorSlasher = new RoundTestJurorSlasher();

        goalFlow = new RoundTestManagedFlow(address(0xDEAD), address(0), address(0), address(0));
        stakeVault = new RoundTestStakeVault(underlying, address(0), address(jurorSlasher));
        goalTreasury = new RoundTestGoalTreasury(address(goalFlow), address(rewardEscrow), address(stakeVault));
        stakeVault.setGoalTreasury(address(goalTreasury));
        goalFlow.setFlowOperator(address(goalTreasury));

        budgetFlow = new RoundTestManagedFlow(address(0), address(0xB0), address(goalFlow), address(superToken));
        budgetTreasury = new RoundTestBudgetTreasury(address(budgetFlow));

        factory = new RoundFactory();

        underlying.mint(alice, 1000e18);
        underlying.mint(challenger, 1000e18);
    }

    function test_uncontestedRegistration_movesSubmissionDepositIntoPrizeVault() public {
        RoundFactory.DeployedRound memory deployed = factory.createRoundForBudget(
            bytes32("round"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: uint64(block.timestamp - 1), endAt: uint64(block.timestamp + 30 days) }),
            roundOperator,
            RoundFactory.SubmissionTcrConfig({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                governor: governor,
                submissionBaseDeposit: SUBMISSION_DEPOSIT,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 1 days
            }),
            RoundFactory.ArbitratorConfig({
                votingPeriod: 1,
                votingDelay: 1,
                revealPeriod: 1,
                arbitrationCost: ARBITRATION_COST,
                wrongOrMissedSlashBps: 0,
                slashCallerBountyBps: 0
            })
        );

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.submissionTCR);
        RoundPrizeVault vault = RoundPrizeVault(deployed.prizeVault);

        vm.prank(alice);
        underlying.approve(address(tcr), type(uint256).max);

        bytes memory item = _submissionItem();
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);

        assertEq(tcr.submissionDeposits(itemId), SUBMISSION_DEPOSIT);

        vm.warp(block.timestamp + 1 days + 1);
        tcr.executeRequest(itemId);

        assertEq(underlying.balanceOf(address(vault)), SUBMISSION_DEPOSIT);
        assertEq(tcr.submissionDeposits(itemId), 0);
    }

    function test_challengerRuling_transfersSubmissionDepositToChallenger() public {
        address prizePool = address(0xBADA55);
        PrizePoolSubmissionDepositStrategy strategy = new PrizePoolSubmissionDepositStrategy(underlying, prizePool);

        RoundSubmissionTCR implementation = new RoundSubmissionTCR();
        RoundSubmissionTCR tcr = RoundSubmissionTCR(Clones.clone(address(implementation)));
        RoundTestArbitrator arb = new RoundTestArbitrator(IVotes(address(underlying)), address(tcr), 1, 1, 1, ARBITRATION_COST);

        tcr.initialize(
            RoundSubmissionTCR.RoundConfig({
                roundId: bytes32("r"),
                startAt: uint64(block.timestamp - 1),
                endAt: uint64(block.timestamp + 30 days),
                prizeVault: prizePool
            }),
            RoundSubmissionTCR.RegistryConfig({
                arbitrator: arb,
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                governor: governor,
                votingToken: IVotes(address(underlying)),
                submissionBaseDeposit: SUBMISSION_DEPOSIT,
                submissionDepositStrategy: strategy,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 1 days
            })
        );

        vm.prank(alice);
        underlying.approve(address(tcr), type(uint256).max);
        vm.prank(challenger);
        underlying.approve(address(tcr), type(uint256).max);

        bytes memory item = _submissionItem();
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);

        vm.prank(challenger);
        tcr.challengeRequest(itemId, "");

        (bool exists, uint256 requestIndex) = tcr.getLatestRequestIndex(itemId);
        assertTrue(exists);
        (, uint256 disputeId,,,,,,,,) = tcr.getRequestInfo(itemId, requestIndex);
        assertGt(disputeId, 0);

        uint256 challengerBefore = underlying.balanceOf(challenger);

        arb.giveRuling(address(tcr), disputeId, 2);

        assertEq(underlying.balanceOf(challenger) - challengerBefore, SUBMISSION_DEPOSIT);
        assertEq(underlying.balanceOf(prizePool), 0);
        assertEq(tcr.submissionDeposits(itemId), 0);
    }

    function test_noneRuling_refundsSubmissionDepositToRequester() public {
        address prizePool = address(0xBADA55);
        PrizePoolSubmissionDepositStrategy strategy = new PrizePoolSubmissionDepositStrategy(underlying, prizePool);

        RoundSubmissionTCR implementation = new RoundSubmissionTCR();
        RoundSubmissionTCR tcr = RoundSubmissionTCR(Clones.clone(address(implementation)));
        RoundTestArbitrator arb = new RoundTestArbitrator(IVotes(address(underlying)), address(tcr), 1, 1, 1, ARBITRATION_COST);

        tcr.initialize(
            RoundSubmissionTCR.RoundConfig({
                roundId: bytes32("r"),
                startAt: uint64(block.timestamp - 1),
                endAt: uint64(block.timestamp + 30 days),
                prizeVault: prizePool
            }),
            RoundSubmissionTCR.RegistryConfig({
                arbitrator: arb,
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                governor: governor,
                votingToken: IVotes(address(underlying)),
                submissionBaseDeposit: SUBMISSION_DEPOSIT,
                submissionDepositStrategy: strategy,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 1 days
            })
        );

        vm.prank(alice);
        underlying.approve(address(tcr), type(uint256).max);
        vm.prank(challenger);
        underlying.approve(address(tcr), type(uint256).max);

        bytes memory item = _submissionItem();
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);

        vm.prank(challenger);
        tcr.challengeRequest(itemId, "");

        (bool exists, uint256 requestIndex) = tcr.getLatestRequestIndex(itemId);
        assertTrue(exists);

        (, uint256 disputeId,,,,,,,,) = tcr.getRequestInfo(itemId, requestIndex);
        assertGt(disputeId, 0);

        uint256 requesterBefore = underlying.balanceOf(alice);

        arb.giveRuling(address(tcr), disputeId, 0);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemId);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));
        assertEq(underlying.balanceOf(alice) - requesterBefore, SUBMISSION_DEPOSIT);
        assertEq(underlying.balanceOf(prizePool), 0);
        assertEq(tcr.submissionDeposits(itemId), 0);
    }

    function _submissionItem() internal pure returns (bytes memory) {
        return abi.encode(uint8(0), DEFAULT_POST_ID);
    }
}
