// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness} from "test/ERC20VotesArbitrator.t.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

contract ERC20VotesArbitratorCommitRevealTest is ERC20VotesArbitratorTestBase {
    function test_commitVote_reverts_outside_active() public {
        (uint256 disputeId,,,,) = _createDispute("");
        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(voter1);
        arb.commitVote(disputeId, bytes32(uint256(1)));
    }

    function test_commitVote_reverts_if_no_votes() public {
        (uint256 disputeId, uint256 start,,,) = _createDispute("");

        _warpRoll(start + 1);

        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(noVotes);
        arb.commitVote(disputeId, bytes32(uint256(1)));
    }

    function test_commitVote_reverts_if_already_committed() public {
        (uint256 disputeId, uint256 start,,,) = _createDispute("");

        _warpRoll(start + 1);

        vm.prank(voter1);
        arb.commitVote(disputeId, bytes32(uint256(123)));

        vm.expectRevert(IERC20VotesArbitrator.VOTER_ALREADY_VOTED.selector);
        vm.prank(voter1);
        arb.commitVote(disputeId, bytes32(uint256(456)));
    }

    function test_commitVote_uses_creationBlock_snapshot() public {
        (uint256 disputeId, uint256 start,,, uint256 creationBlock) = _createDispute("");

        address late = makeAddr("late");
        vm.roll(block.number + 1);
        token.mint(late, 100e18);
        vm.prank(late);
        token.delegate(late);
        vm.roll(block.number + 1);

        assertEq(token.getPastVotes(late, creationBlock), 0);

        _warpRoll(start + 1);
        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(late);
        arb.commitVote(disputeId, bytes32(uint256(1)));
    }

    function test_commitVote_reverts_when_votes_gained_same_block_as_dispute_creation() public {
        (uint256 disputeId, uint256 start,,, uint256 creationBlock) = _createDispute("");

        address late = makeAddr("lateSameBlock");
        token.mint(late, 100e18);
        vm.prank(late);
        token.delegate(late);

        // Votes acquired in the same block as dispute creation should not count.
        assertEq(token.getPastVotes(late, creationBlock), 0);

        _warpRoll(start + 1);
        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(late);
        arb.commitVote(disputeId, bytes32(uint256(1)));
    }

    function test_revealVote_happyPath_and_receipts_and_tally() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        // Active phase
        _warpRoll(start + 1);

        bytes32 salt1 = bytes32("salt1");
        bytes32 salt2 = bytes32("salt2");
        bytes32 h1 = _voteHash(arb, disputeId, 0, voter1, 1, "reason", salt1);
        bytes32 h2 = _voteHash(arb, disputeId, 0, voter2, 2, "reason", salt2);

        vm.prank(voter1);
        arb.commitVote(disputeId, h1);

        vm.prank(voter2);
        arb.commitVote(disputeId, h2);

        // Reveal phase
        _warpRoll(end + 1);

        // custodial reveal: relayer reveals for voter1
        vm.expectEmit(true, true, false, true, address(arb));
        emit IERC20VotesArbitrator.VoteRevealed(
            voter1, disputeId, h1, 1, "reason", token.getPastVotes(voter1, block.number - 1)
        );

        vm.prank(relayer);
        arb.revealVote(disputeId, voter1, 1, "reason", salt1);

        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "reason", salt2);

        // Check receipts.
        ERC20VotesArbitrator.Receipt memory r1 = arb.getReceipt(disputeId, voter1);
        assertTrue(r1.hasCommitted);
        assertTrue(r1.hasRevealed);
        assertEq(r1.commitHash, h1);
        assertEq(r1.choice, 1);
        assertGt(r1.votes, 0);

        // Tally.
        uint256 c1 = arb.getVotesByRound(disputeId, 0, 1);
        uint256 c2 = arb.getVotesByRound(disputeId, 0, 2);
        uint256 total = arb.getTotalVotesByRound(disputeId, 0);

        assertEq(total, c1 + c2);
        assertGt(c1, 0);
        assertGt(c2, 0);
    }

    function test_revealVote_reverts_wrong_phase_invalid_choice_and_hash_mismatch() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        // Active
        _warpRoll(start + 1);

        bytes32 salt = bytes32("salt");
        bytes32 h = _voteHash(arb, disputeId, 0, voter1, 1, "r", salt);

        vm.prank(voter1);
        arb.commitVote(disputeId, h);

        // Reveal called while Active should revert
        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", salt);

        // Enter Reveal
        _warpRoll(end + 1);

        // Invalid choice 0
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTE_CHOICE.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 0, "r", salt);

        // Hash mismatch
        vm.expectRevert(IERC20VotesArbitrator.HASHES_DO_NOT_MATCH.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "different", salt);
    }

    function test_revealVote_reverts_when_commit_hash_uses_packed_encoding() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 salt = bytes32("salt");
        bytes32 packedHash = keccak256(abi.encodePacked(uint256(1), "r", salt));

        vm.prank(voter1);
        arb.commitVote(disputeId, packedHash);

        _warpRoll(end + 1);

        vm.expectRevert(IERC20VotesArbitrator.HASHES_DO_NOT_MATCH.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", salt);
    }

    function test_revealVote_reverts_when_commit_hash_domain_uses_different_voter() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 salt = bytes32("salt");
        bytes32 wrongDomainHash = _voteHash(arb, disputeId, 0, voter2, 1, "r", salt);

        vm.prank(voter1);
        arb.commitVote(disputeId, wrongDomainHash);

        _warpRoll(end + 1);

        vm.expectRevert(IERC20VotesArbitrator.HASHES_DO_NOT_MATCH.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", salt);
    }

    function test_revealVote_reverts_when_snapshot_has_no_votes() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 salt = bytes32("snap");
        bytes32 h = _voteHash(arb, disputeId, 0, voter1, 1, "r", salt);

        vm.prank(voter1);
        arb.commitVote(disputeId, h);

        ArbitratorHarness(address(arb)).exposed_setCreationBlock(disputeId, 0, 0);

        _warpRoll(end + 1);

        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", salt);
    }

    function test_revealVote_reverts_choice_above_max() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 salt = bytes32("salt");
        bytes32 h = _voteHash(arb, disputeId, 0, voter1, 1, "r", salt);

        vm.prank(voter1);
        arb.commitVote(disputeId, h);

        _warpRoll(end + 1);

        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTE_CHOICE.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 3, "r", salt);
    }

    function test_revealVote_reverts_if_no_commit_or_already_revealed() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        _warpRoll(start + 1);

        // no commit
        _warpRoll(end + 1);
        vm.expectRevert(IERC20VotesArbitrator.NO_COMMITTED_VOTE.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", bytes32("s"));

        // do proper commit+reveal, then reveal again
        _warpRoll(start + 1);

        bytes32 salt = bytes32("salt");
        bytes32 h = _voteHash(arb, disputeId, 0, voter1, 1, "r", salt);

        vm.prank(voter1);
        arb.commitVote(disputeId, h);

        _warpRoll(end + 1);

        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", salt);

        vm.expectRevert(IERC20VotesArbitrator.ALREADY_REVEALED_VOTE.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "r", salt);
    }

    function test_getReceiptByRound_success() public {
        (uint256 disputeId, uint256 start, uint256 end,,) = _createDispute("");

        _warpRoll(start + 1);

        bytes32 salt = bytes32("s");
        bytes32 h = _voteHash(arb, disputeId, 0, voter1, 1, "", salt);

        vm.prank(voter1);
        arb.commitVote(disputeId, h);

        _warpRoll(end + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt);

        ERC20VotesArbitrator.Receipt memory r = arb.getReceiptByRound(disputeId, 0, voter1);
        assertTrue(r.hasCommitted);
        assertTrue(r.hasRevealed);
        assertEq(r.commitHash, h);
        assertEq(r.choice, 1);
        assertGt(r.votes, 0);
    }
}
