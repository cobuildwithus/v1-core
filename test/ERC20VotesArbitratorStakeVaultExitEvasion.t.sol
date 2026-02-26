// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { TestUtils } from "test/utils/TestUtils.sol";

import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { GoalStakeVault } from "src/goals/GoalStakeVault.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { MockArbitrable } from "test/mocks/MockArbitrable.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";

contract StakeVaultExitEvasionRulesetsMock {
    mapping(uint256 => uint112) internal _weightOf;

    function setWeight(uint256 projectId, uint112 weight) external {
        _weightOf[projectId] = weight;
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        ruleset.weight = _weightOf[projectId];
    }
}

contract StakeVaultExitEvasionRewardEscrowMock {}

contract ERC20VotesArbitratorStakeVaultExitEvasionTest is TestUtils {
    uint256 internal constant GOAL_PROJECT_ID = 777;

    MockVotesToken internal votingToken;
    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    MockArbitrable internal arbitrable;
    GoalStakeVault internal vault;
    StakeVaultExitEvasionRulesetsMock internal rulesets;
    ERC20VotesArbitrator internal arb;

    address internal owner = makeAddr("owner");
    address internal juror1 = makeAddr("juror1");
    address internal juror2 = makeAddr("juror2");
    address internal _rewardEscrow;

    uint256 internal votingDelay = 2 days;
    uint256 internal votingPeriod = 2 days;
    uint256 internal revealPeriod = 2 days;
    uint256 internal arbitrationCost = 50e18;

    function rewardEscrow() external view returns (address) {
        return _rewardEscrow;
    }

    function setUp() public {
        _rewardEscrow = address(new StakeVaultExitEvasionRewardEscrowMock());
        votingToken = new MockVotesToken("Vote", "VOTE");
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        arbitrable = new MockArbitrable(IERC20(address(votingToken)));

        rulesets = new StakeVaultExitEvasionRulesetsMock();
        rulesets.setWeight(GOAL_PROJECT_ID, 2e18);

        vault = new GoalStakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(rulesets)),
            GOAL_PROJECT_ID,
            18,
            address(0),
            0
        );

        _seedJurorStake(juror1);
        _seedJurorStake(juror2);

        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initializeWithStakeVault,
            (
                owner,
                address(votingToken),
                address(arbitrable),
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost,
                address(vault)
            )
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(impl), initData));

        arbitrable.setArbitrator(arb);
        votingToken.mint(address(arbitrable), 1_000_000e18);
        arbitrable.approveArbitrator(arbitrationCost * 10);

        vault.setJurorSlasher(address(arb));
        vm.roll(block.number + 1);
    }

    function test_slashVoter_regression_exitFinalizationCannotBypassSlash() public {
        (uint256 disputeId, uint256 startTime, uint256 endTime,, uint256 creationBlock) =
            _createDispute();

        assertEq(vault.getPastJurorWeight(juror1, creationBlock), 120e18);

        vm.prank(juror1);
        vault.requestJurorExit(80e18, 80e18);

        bytes32 juror1Salt = bytes32("juror1-salt");
        bytes32 juror2Salt = bytes32("juror2-salt");

        _warpRoll(startTime + 1);
        vm.prank(juror1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, juror1, 1, "", juror1Salt));
        vm.prank(juror2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, juror2, 2, "", juror2Salt));

        _warpRoll(endTime + 1);
        vm.prank(juror2);
        arb.revealVote(disputeId, juror2, 2, "", juror2Salt);

        _warpRoll(block.timestamp + 3 days);
        vm.prank(juror1);
        vault.finalizeJurorExit();
        assertEq(vault.jurorWeightOf(juror1), 0);
        uint256 rewardGoalBefore = goalToken.balanceOf(_rewardEscrow);
        uint256 rewardCobuildBefore = cobuildToken.balanceOf(_rewardEscrow);

        arb.slashVoter(disputeId, 0, juror1);

        uint256 rewardGoalDelta = goalToken.balanceOf(_rewardEscrow) - rewardGoalBefore;
        uint256 rewardCobuildDelta = cobuildToken.balanceOf(_rewardEscrow) - rewardCobuildBefore;
        assertGt(rewardGoalDelta + rewardCobuildDelta, 0);
    }

    function _seedJurorStake(address juror) internal {
        goalToken.mint(juror, 200e18);
        cobuildToken.mint(juror, 200e18);

        vm.startPrank(juror);
        goalToken.approve(address(vault), type(uint256).max);
        cobuildToken.approve(address(vault), type(uint256).max);
        vault.depositGoal(100e18);
        vault.depositCobuild(100e18);
        vault.optInAsJuror(80e18, 80e18, address(0));
        vm.stopPrank();
    }

    function _createDispute()
        internal
        returns (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime, uint256 creationBlock)
    {
        startTime = block.timestamp + votingDelay;
        endTime = startTime + votingPeriod;
        revealEndTime = endTime + revealPeriod;
        creationBlock = block.number - 1;

        disputeId = arbitrable.createDispute(2, "");
    }
}
