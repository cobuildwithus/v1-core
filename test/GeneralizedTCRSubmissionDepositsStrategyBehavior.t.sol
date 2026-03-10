// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

import {ConcreteGeneralizedTCRSubmissionDepositsBase} from "test/GeneralizedTCRSubmissionDeposits.t.sol";
import {MockSubmissionDepositStrategy} from "test/mocks/MockSubmissionDepositStrategy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract GeneralizedTCRSubmissionDepositsStrategyBehaviorTest is ConcreteGeneralizedTCRSubmissionDepositsBase {
    function test_add_item_collects_submission_deposit_separately() public {
        MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
        strategy.setAction(uint8(ISubmissionDepositStrategy.DepositAction.Hold), address(0));

        (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb) = _deployConcreteTCRWithStrategy(strategy);

        (uint256 addCost,,,,) = tcr.getTotalCosts();
        uint256 expectedArbitrationCost = arb.arbitrationCost(bytes(""));
        assertEq(addCost, submissionBaseDeposit + expectedArbitrationCost);

        bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());

        assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);

        (uint256[3] memory amountPaid,,) = tcr.getRoundInfo(itemID, 0, 0);
        assertEq(amountPaid[uint256(IArbitrable.Party.Requester)], expectedArbitrationCost);

        assertEq(token.balanceOf(address(tcr)), submissionBaseDeposit + expectedArbitrationCost);
    }

    function test_prize_pool_strategy_transfers_on_accepted_registration() public {
        PrizePoolSubmissionDepositStrategy implementation = new PrizePoolSubmissionDepositStrategy();
        PrizePoolSubmissionDepositStrategy strategy =
            PrizePoolSubmissionDepositStrategy(Clones.clone(address(implementation)));
        strategy.initialize(token, prizePool);
        (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

        uint256 prizePoolBefore = token.balanceOf(prizePool);
        bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());

        _acceptRequest(tcr, itemID);

        assertEq(tcr.submissionDeposits(itemID), 0);
        assertEq(token.balanceOf(prizePool) - prizePoolBefore, submissionBaseDeposit);
    }

    function test_escrow_strategy_holds_on_accepted_registration() public {
        EscrowSubmissionDepositStrategy strategy = new EscrowSubmissionDepositStrategy(token);
        (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

        bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
        _acceptRequest(tcr, itemID);

        assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
        assertEq(token.balanceOf(address(tcr)), submissionBaseDeposit + arbitrationCost);
    }

    function test_escrow_strategy_transfers_on_rejected_registration() public {
        EscrowSubmissionDepositStrategy strategy = new EscrowSubmissionDepositStrategy(token);
        (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb) = _deployConcreteTCRWithStrategy(strategy);

        bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());

        (,, uint256 challengeCost,,) = tcr.getTotalCosts();
        uint256 challengerBefore = token.balanceOf(challenger);
        _disputeAndRule(tcr, arb, itemID, challenger, 1, 2, 2);

        assertEq(tcr.submissionDeposits(itemID), 0);
        uint256 challengerAfter = token.balanceOf(challenger);
        assertEq(challengerAfter + challengeCost, challengerBefore + submissionBaseDeposit);
    }

    function test_escrow_strategy_transfers_on_successful_clearing() public {
        EscrowSubmissionDepositStrategy strategy = new EscrowSubmissionDepositStrategy(token);
        (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

        bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
        _acceptRequest(tcr, itemID);

        _approveRemoveCost(tcr, remover);
        vm.prank(remover);
        tcr.removeItem(itemID, "");

        uint256 removerBefore = token.balanceOf(remover);
        _acceptRequest(tcr, itemID);

        assertEq(tcr.submissionDeposits(itemID), 0);
        assertEq(token.balanceOf(remover) - removerBefore, submissionBaseDeposit);
    }

    function test_escrow_strategy_holds_on_failed_clearing() public {
        EscrowSubmissionDepositStrategy strategy = new EscrowSubmissionDepositStrategy(token);
        (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb) = _deployConcreteTCRWithStrategy(strategy);

        bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
        _acceptRequest(tcr, itemID);

        _approveRemoveCost(tcr, remover);
        vm.prank(remover);
        tcr.removeItem(itemID, "");

        _disputeRemovalAndRule(tcr, arb, itemID, challenger, 1, 2, 2);

        assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
    }
}
