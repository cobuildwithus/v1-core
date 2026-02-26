// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness} from "test/ERC20VotesArbitrator.t.sol";

import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

contract ERC20VotesArbitratorGetterGuardsTest is ERC20VotesArbitratorTestBase {
    function test_getters_require_guards() public {
        // require-based getters
        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        arb.getReceipt(999, voter1);

        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        arb.getReceiptByRound(999, 0, voter1);

        (uint256 disputeId,,,,) = _createDispute("");

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.getReceiptByRound(disputeId, 1, voter1);

        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTE_CHOICE.selector);
        arb.getVotesByRound(disputeId, 0, 3);
    }

    function test_getVotesByRound_reverts_on_invalid_dispute_and_round() public {
        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        arb.getVotesByRound(999, 0, 1);

        (uint256 disputeId,,,,) = _createDispute("");

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.getVotesByRound(disputeId, 1, 1);
    }

    function test_getTotalVotesByRound_reverts_on_invalid_dispute_and_round() public {
        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        arb.getTotalVotesByRound(999, 0);

        (uint256 disputeId,,,,) = _createDispute("");

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.getTotalVotesByRound(disputeId, 1);
    }

    function test_votingPowerInRound_reverts_on_invalid_round() public {
        (uint256 disputeId,,,,) = _createDispute("");

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ROUND.selector);
        arb.votingPowerInRound(disputeId, 1, voter1);
    }

    function test_validDisputeID_reverts_on_zero() public {
        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        ArbitratorHarness(address(arb)).exposed_validDisputeID(0);
    }
}
