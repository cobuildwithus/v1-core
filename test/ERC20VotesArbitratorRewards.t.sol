// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness} from "test/ERC20VotesArbitrator.t.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

contract ERC20VotesArbitratorRewardsTest is ERC20VotesArbitratorTestBase {
    function test_getRewardsForRound_returns_0_when_not_solved() public {
        (uint256 disputeId, uint256 start,,,) = _createDispute("");

        _warpRoll(start + 1);
        uint256 r = arb.getRewardsForRound(disputeId, 0, voter1);
        assertEq(r, 0);
    }

    function test_getRewardsForRound_reverts_on_invalid_round() public {
        (uint256 disputeId,,,,) = _createDispute("");

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.getRewardsForRound(disputeId, 1, voter1);
    }

    function test_getRewardsForRound_returns_0_when_no_votes_even_if_solved() public {
        (uint256 disputeId,,, uint256 revealEnd,) = _createDispute("");

        _warpRoll(revealEnd + 1);
        uint256 r = arb.getRewardsForRound(disputeId, 0, voter1);
        assertEq(r, 0);
    }

    function test_getRewardsForRound_returns_0_when_voter_did_not_reveal() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");

        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", s1));

        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", s2));

        _warpRoll(end + 1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", s2);

        _warpRoll(revealEnd + 1);

        assertEq(arb.getRewardsForRound(disputeId, 0, voter1), 0);
        assertGt(arb.getRewardsForRound(disputeId, 0, voter2), 0);
    }

    function test_getRewardsForRound_and_withdrawVoterRewards_winner_only() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        // voter2 wins (200 votes) on choice 2
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, disputeId, start, end, voter1, 1, s1, "", voter2, 2, s2, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);

        // Winner gets full cost if sole winner.
        uint256 estWinner = arb.getRewardsForRound(disputeId, 0, voter2);
        assertEq(estWinner, arbitrationCost);

        // Loser gets 0
        uint256 estLoser = arb.getRewardsForRound(disputeId, 0, voter1);
        assertEq(estLoser, 0);

        uint256 before = token.balanceOf(voter2);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(token.balanceOf(voter2) - before, arbitrationCost);

        // double claim revert
        vm.expectRevert(IERC20VotesArbitrator.REWARD_ALREADY_CLAIMED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter2);

        // losing side revert
        vm.expectRevert(IERC20VotesArbitrator.VOTER_ON_LOSING_SIDE.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
    }

    function test_reward_distribution_leaves_dust_in_arbitrator() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        token.mint(a, 1e18);
        token.mint(b, 2e18);

        vm.prank(a);
        token.delegate(a);
        vm.prank(b);
        token.delegate(b);
        vm.roll(block.number + 1);

        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 sa = bytes32("sa");
        bytes32 sb = bytes32("sb");
        _commitRevealTwoVotes(arb, disputeId, start, end, a, 1, sa, "", b, 1, sb, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);

        uint256 ra = arb.getRewardsForRound(disputeId, 0, a);
        uint256 rb = arb.getRewardsForRound(disputeId, 0, b);

        arb.withdrawVoterRewards(disputeId, 0, a);
        arb.withdrawVoterRewards(disputeId, 0, b);

        uint256 leftover = token.balanceOf(address(arb));
        assertEq(leftover, arbitrationCost - (ra + rb));
        assertGt(leftover, 0);
    }

    function test_commit_without_reveal_only_loses_rewards() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");

        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", s1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 1, "", s2));

        _warpRoll(end + 1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 1, "", s2);

        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);

        uint256 before = token.balanceOf(voter1);
        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NOT_VOTED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
        assertEq(token.balanceOf(voter1), before);
    }

    function test_rewards_tie_path_and_claimed_path() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        token.mint(a, 123e18);
        token.mint(b, 123e18);

        vm.prank(a);
        token.delegate(a);
        vm.prank(b);
        token.delegate(b);
        vm.roll(block.number + 1);

        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 sa = bytes32("sa");
        bytes32 sb = bytes32("sb");
        _commitRevealTwoVotes(arb, disputeId, start, end, a, 1, sa, "", b, 2, sb, "");

        _warpRoll(revealEnd + 1);

        uint256 ra = arb.getRewardsForRound(disputeId, 0, a);
        uint256 rb = arb.getRewardsForRound(disputeId, 0, b);
        assertEq(ra + rb, arbitrationCost);

        uint256 balA = token.balanceOf(a);
        arb.withdrawVoterRewards(disputeId, 0, a);
        assertEq(token.balanceOf(a) - balA, ra);
        assertEq(arb.getRewardsForRound(disputeId, 0, a), 0);
    }

    function test_withdrawVoterRewards_reverts_not_voted_and_invalid_round() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        _warpRoll(start + 1);
        vm.prank(voter1);
        arb.commitVote(disputeId, bytes32(uint256(123)));

        _warpRoll(end + 1);
        _warpRoll(revealEnd + 1);

        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NOT_VOTED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter1);

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.withdrawVoterRewards(disputeId, 1, voter2);
    }

    function test_withdrawVoterRewards_reverts_when_no_votes_cast() public {
        (uint256 disputeId,,, uint256 revealEnd,) = _createDispute("");

        _warpRoll(revealEnd + 1);

        ArbitratorHarness(address(arb)).exposed_setReceiptRevealed(disputeId, 0, voter1, true);
        ArbitratorHarness(address(arb)).exposed_setRoundVotes(disputeId, 0, 0);

        vm.expectRevert(IERC20VotesArbitrator.NO_VOTES.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
    }

    function test_withdrawInvalidRoundRewards_permissionless_routes_to_sink_and_no_votes() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        // Move through phases without any votes
        _warpRoll(start + 1);
        _warpRoll(end + 1);
        _warpRoll(revealEnd + 1);

        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(voter1);
        arb.withdrawInvalidRoundRewards(disputeId, 0);

        assertEq(token.balanceOf(owner) - ownerBefore, arbitrationCost);
    }

    function test_withdrawInvalidRoundRewards_only_once() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        _warpRoll(start + 1);
        _warpRoll(end + 1);
        _warpRoll(revealEnd + 1);

        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(owner);
        arb.withdrawInvalidRoundRewards(disputeId, 0);
        uint256 afterFirst = token.balanceOf(owner);

        vm.prank(owner);
        arb.withdrawInvalidRoundRewards(disputeId, 0);
        uint256 afterSecond = token.balanceOf(owner);

        assertEq(afterFirst - ownerBefore, arbitrationCost);
        assertEq(afterSecond - afterFirst, 0);
    }

    function test_withdrawInvalidRoundRewards_reverts_not_solved_invalid_round_and_votes_cast() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        vm.prank(owner);
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.withdrawInvalidRoundRewards(disputeId, 1);

        vm.prank(owner);
        vm.expectRevert(IERC20VotesArbitrator.DISPUTE_NOT_SOLVED.selector);
        arb.withdrawInvalidRoundRewards(disputeId, 0);

        _warpRoll(start + 1);
        bytes32 s = bytes32("s");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", s));

        _warpRoll(end + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", s);

        _warpRoll(revealEnd + 1);

        vm.prank(owner);
        vm.expectRevert(IERC20VotesArbitrator.VOTES_WERE_CAST.selector);
        arb.withdrawInvalidRoundRewards(disputeId, 0);
    }

    function test_withdrawVoterRewards_reverts_if_not_solved() public {
        (uint256 disputeId, uint256 start,,,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 s1 = bytes32("s1");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", s1));

        vm.expectRevert(IERC20VotesArbitrator.DISPUTE_NOT_SOLVED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
    }

    function test_getRewardsForRound_winner_branch_and_withdraws_proportional() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, disputeId, start, end, voter1, 1, s1, "", voter2, 1, s2, "");

        _warpRoll(revealEnd + 1);

        ERC20VotesArbitrator.Receipt memory r1 = arb.getReceiptByRound(disputeId, 0, voter1);
        ERC20VotesArbitrator.Receipt memory r2 = arb.getReceiptByRound(disputeId, 0, voter2);
        uint256 totalWinningVotes = r1.votes + r2.votes;

        uint256 expected1 = (r1.votes * arbitrationCost) / totalWinningVotes;
        uint256 expected2 = (r2.votes * arbitrationCost) / totalWinningVotes;

        assertEq(arb.getRewardsForRound(disputeId, 0, voter1), expected1);
        assertEq(arb.getRewardsForRound(disputeId, 0, voter2), expected2);

        uint256 before = token.balanceOf(voter1);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
        assertEq(token.balanceOf(voter1) - before, expected1);
    }
}
