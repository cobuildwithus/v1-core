// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { RoundPrizeVault } from "src/rounds/RoundPrizeVault.sol";
import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    RoundTestSuperToken,
    RoundTestManagedFlow,
    RoundTestBudgetTreasury,
    RoundTestGoalTreasury,
    RoundTestStakeVault,
    RoundTestRewardEscrow,
    RoundTestBudgetStakeLedger,
    RoundTestJurorSlasher
} from "test/rounds/helpers/RoundTestMocks.sol";

contract RoundFactoryTest is Test {
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
    address internal juror = address(0xD00D);

    uint256 internal constant ARBITRATION_COST = 1e14;
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
    }

    function _deployRound(bytes32 roundId) internal returns (RoundFactory.DeployedRound memory deployed) {
        deployed = factory.createRoundForBudget(
            roundId,
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: uint64(block.timestamp - 1), endAt: uint64(block.timestamp + 30 days) }),
            roundOperator,
            RoundFactory.SubmissionTcrConfig({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                governor: governor,
                submissionBaseDeposit: 1e18,
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
    }

    function test_createRoundForBudget_revertsOnZeroInputs() public {
        vm.expectRevert(RoundFactory.ADDRESS_ZERO.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(0),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );

        vm.expectRevert(RoundFactory.ADDRESS_ZERO.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            address(0),
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_revertsOnInvalidBudgetContext() public {
        RoundTestManagedFlow badBudgetFlow = new RoundTestManagedFlow(address(0), address(0xB0), address(0x1234), address(0));
        RoundTestBudgetTreasury badBudgetTreasury = new RoundTestBudgetTreasury(address(badBudgetFlow));

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(badBudgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_deploysAndWiresStack() public {
        bytes32 roundId = keccak256("round-1");
        RoundFactory.DeployedRound memory deployed = _deployRound(roundId);

        assertTrue(deployed.submissionTCR.code.length > 0);
        assertTrue(deployed.prizeVault.code.length > 0);
        assertTrue(deployed.depositStrategy.code.length > 0);
        assertTrue(deployed.arbitrator.code.length > 0);

        assertEq(deployed.underlyingToken, address(underlying));
        assertEq(deployed.superToken, address(superToken));
        assertEq(deployed.stakeVault, address(stakeVault));
        assertEq(deployed.goalTreasury, address(goalTreasury));
        assertEq(deployed.goalFlow, address(goalFlow));
        assertEq(deployed.budgetFlow, address(budgetFlow));

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.submissionTCR);
        assertEq(tcr.roundId(), roundId);
        assertEq(tcr.prizeVault(), deployed.prizeVault);
        assertEq(address(tcr.erc20()), address(underlying));

        RoundPrizeVault vault = RoundPrizeVault(deployed.prizeVault);
        assertEq(address(vault.underlyingToken()), address(underlying));
        assertEq(address(vault.submissionsTCR()), deployed.submissionTCR);
        assertEq(vault.operator(), roundOperator);
        assertEq(address(vault.superToken()), address(superToken));

        PrizePoolSubmissionDepositStrategy strategy = PrizePoolSubmissionDepositStrategy(deployed.depositStrategy);
        assertEq(address(strategy.token()), address(underlying));
        assertEq(strategy.prizePool(), deployed.prizeVault);

        ERC20VotesArbitrator arb = ERC20VotesArbitrator(deployed.arbitrator);
        assertEq(address(arb.votingToken()), address(underlying));
        assertEq(address(arb.arbitrable()), deployed.submissionTCR);
        assertEq(arb.invalidRoundRewardsSink(), deployed.prizeVault);
        assertEq(arb.wrongOrMissedSlashBps(), 0);
        assertEq(arb.slashCallerBountyBps(), 0);
        assertEq(arb.fixedBudgetTreasury(), address(budgetTreasury));
        assertEq(arb.stakeVault(), address(stakeVault));
    }

    function test_budgetScopedVotingPower_isProportionalToAllocatedStake() public {
        RoundFactory.DeployedRound memory deployed = _deployRound(keccak256("round-2"));

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.submissionTCR);
        ERC20VotesArbitrator arb = ERC20VotesArbitrator(deployed.arbitrator);

        vm.roll(10);
        stakeVault.setPastJurorWeight(juror, 100);
        ledger.setUserAllocationWeight(juror, 200);
        ledger.setUserAllocatedStakeOnBudget(juror, address(budgetTreasury), 50);

        vm.roll(11);
        underlying.mint(alice, 1000e18);
        underlying.mint(challenger, 1000e18);

        vm.prank(alice);
        underlying.approve(address(tcr), type(uint256).max);
        vm.prank(challenger);
        underlying.approve(address(tcr), type(uint256).max);

        bytes memory item = abi.encode(uint8(0), DEFAULT_POST_ID);
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);

        vm.prank(challenger);
        tcr.challengeRequest(itemId, "");

        (bool exists, uint256 requestIndex) = tcr.getLatestRequestIndex(itemId);
        assertTrue(exists);

        (, uint256 disputeId,,,,,,,,) = tcr.getRequestInfo(itemId, requestIndex);
        assertGt(disputeId, 0);

        (uint256 power, bool canVote) = arb.votingPowerInRound(disputeId, 0, juror);
        assertTrue(canVote);
        assertEq(power, 25);
    }

    function _dummyTcrConfig() internal view returns (RoundFactory.SubmissionTcrConfig memory cfg) {
        cfg = RoundFactory.SubmissionTcrConfig({
            arbitratorExtraData: "",
            registrationMetaEvidence: "reg",
            clearingMetaEvidence: "clr",
            governor: governor,
            submissionBaseDeposit: 0,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            challengePeriodDuration: 1
        });
    }

    function _dummyArbConfig() internal view returns (RoundFactory.ArbitratorConfig memory cfg) {
        cfg = RoundFactory.ArbitratorConfig({
            votingPeriod: 1,
            votingDelay: 1,
            revealPeriod: 1,
            arbitrationCost: ARBITRATION_COST,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });
    }
}
