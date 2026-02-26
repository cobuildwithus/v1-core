// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase} from "test/ERC20VotesArbitrator.t.sol";

import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

contract ERC20VotesArbitratorRulingTest is ERC20VotesArbitratorTestBase {
    function test_executeRuling_reverts_until_solved_and_then_executes() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, disputeId, start, end, voter1, 1, s1, "", voter2, 2, s2, "");

        // Not solved yet
        vm.expectRevert(IERC20VotesArbitrator.DISPUTE_NOT_SOLVED.selector);
        arb.executeRuling(disputeId);

        // Solved
        _warpRoll(revealEnd + 1);

        arb.executeRuling(disputeId);

        (,, bool executed,, uint256 choices, uint256 winningChoice) = arb.disputes(disputeId);
        assertTrue(executed);
        assertEq(choices, 2);
        assertEq(winningChoice, 2);

        assertEq(uint256(arb.currentRuling(disputeId)), uint256(IArbitrable.Party.Challenger));
        assertTrue(arbitrable.wasRuled());
        assertEq(arbitrable.lastDisputeID(), disputeId);
        assertEq(arbitrable.lastRuling(), uint256(IArbitrable.Party.Challenger));

        vm.expectRevert(IERC20VotesArbitrator.DISPUTE_ALREADY_EXECUTED.selector);
        arb.executeRuling(disputeId);
    }

    function test_currentRuling_reports_winner_after_solved_before_execution() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, disputeId, start, end, voter1, 2, s1, "", voter2, 2, s2, "");

        _warpRoll(revealEnd + 1);

        assertEq(uint256(arb.currentRuling(disputeId)), uint256(IArbitrable.Party.Challenger));
        assertFalse(arbitrable.wasRuled());
    }

    function test_executeRuling_tie_results_in_none() public {
        // Make votes equal by minting + delegating same amount to both.
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
        arb.executeRuling(disputeId);

        assertEq(uint256(arb.currentRuling(disputeId)), uint256(IArbitrable.Party.None));
    }

    function test_executeRuling_no_votes_results_in_none_and_calls_arbitrable() public {
        (uint256 disputeId,,, uint256 revealEnd,) = _createDispute("");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);

        assertEq(uint256(arb.currentRuling(disputeId)), uint256(IArbitrable.Party.None));
        assertTrue(arbitrable.wasRuled());
        assertEq(arbitrable.lastDisputeID(), disputeId);
        assertEq(arbitrable.lastRuling(), uint256(IArbitrable.Party.None));
    }
}
