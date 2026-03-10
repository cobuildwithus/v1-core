// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

import {ConcreteGeneralizedTCRSubmissionDepositsBase} from "test/GeneralizedTCRSubmissionDeposits.t.sol";
import {MockSubmissionDepositStrategy} from "test/mocks/MockSubmissionDepositStrategy.sol";

contract MockClearingRecipientInvalidStrategy is ISubmissionDepositStrategy {
    IERC20 public immutable override token;

    constructor(IERC20 token_) {
        token = token_;
    }

    function getSubmissionDepositAction(
        bytes32,
        IGeneralizedTCR.Status requestType,
        IArbitrable.Party,
        address,
        address,
        address,
        uint256
    ) external pure override returns (DepositAction action, address recipient) {
        if (requestType == IGeneralizedTCR.Status.RegistrationRequested) {
            return (DepositAction.Hold, address(0));
        }
        return (DepositAction.Transfer, address(0));
    }
}

    contract MockRevertOnClearingStrategy is ISubmissionDepositStrategy {
        IERC20 public immutable override token;

        constructor(IERC20 token_) {
            token = token_;
        }

        function getSubmissionDepositAction(
            bytes32,
            IGeneralizedTCR.Status requestType,
            IArbitrable.Party,
            address,
            address,
            address,
            uint256
        ) external pure override returns (DepositAction action, address recipient) {
            if (requestType == IGeneralizedTCR.Status.RegistrationRequested) {
                return (DepositAction.Hold, address(0));
            }
            revert("MOCK_STRATEGY_REVERT");
        }
    }

        contract GeneralizedTCRSubmissionDepositsFallbackBehaviorTest is ConcreteGeneralizedTCRSubmissionDepositsBase {
            function test_failClosed_reverts_on_accepted_registration_when_strategy_reverts() public {
                MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
                strategy.setShouldRevert(true);
                (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _warpRoll(block.timestamp + challengePeriodDuration + 1);
                vm.expectRevert();
                tcr.executeRequest(itemID);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }

            function test_failClosed_reverts_on_rejected_registration_when_strategy_reverts() public {
                MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
                strategy.setShouldRevert(true);
                (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _approveChallengeSubmissionCost(tcr, challenger);
                uint256 disputeCreationTs = block.timestamp;
                vm.prank(challenger);
                tcr.challengeRequest(itemID, "");

                (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
                bytes32 sa = bytes32("sa");
                bytes32 sb = bytes32("sb");
                _commitRevealTwoVotes(arb, 1, start, end, voter1, 2, sa, "", voter2, 2, sb, "");

                _warpRoll(revealEnd + 1);
                vm.expectRevert(bytes("MOCK_STRATEGY_REVERT"));
                arb.executeRuling(1);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }

            function test_failClosed_reverts_on_tie_when_strategy_reverts() public {
                MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
                strategy.setShouldRevert(true);
                (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _approveChallengeSubmissionCost(tcr, challenger);
                uint256 disputeCreationTs = block.timestamp;
                vm.prank(challenger);
                tcr.challengeRequest(itemID, "");

                (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
                bytes32 sa = bytes32("sa");
                bytes32 sb = bytes32("sb");
                _commitRevealTwoVotes(arb, 1, start, end, voter1, 1, sa, "", voter2, 2, sb, "");

                _warpRoll(revealEnd + 1);
                vm.expectRevert(bytes("MOCK_STRATEGY_REVERT"));
                arb.executeRuling(1);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }

            function test_failClosed_reverts_when_strategy_panics() public {
                MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
                strategy.setAction(2, makeAddr("recipient"));
                (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _warpRoll(block.timestamp + challengePeriodDuration + 1);
                vm.expectRevert();
                tcr.executeRequest(itemID);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }

            function test_failClosed_reverts_on_clearing_when_recipient_invalid() public {
                MockClearingRecipientInvalidStrategy strategy = new MockClearingRecipientInvalidStrategy(token);
                (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _acceptRequest(tcr, itemID);

                _approveRemoveCost(tcr, remover);
                vm.prank(remover);
                tcr.removeItem(itemID, "");

                _warpRoll(block.timestamp + challengePeriodDuration + 1);
                vm.expectRevert(IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_RECIPIENT.selector);
                tcr.executeRequest(itemID);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }

            function test_failClosed_reverts_on_clearing_when_hold_on_absent() public {
                MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
                strategy.setAction(uint8(ISubmissionDepositStrategy.DepositAction.Hold), address(0));
                (CommunityGoalRegistry tcr,) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _acceptRequest(tcr, itemID);

                _approveRemoveCost(tcr, remover);
                vm.prank(remover);
                tcr.removeItem(itemID, "");

                _warpRoll(block.timestamp + challengePeriodDuration + 1);
                vm.expectRevert(IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_ACTION.selector);
                tcr.executeRequest(itemID);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }

            function test_failClosed_reverts_on_failed_clearing_when_strategy_reverts() public {
                MockRevertOnClearingStrategy strategy = new MockRevertOnClearingStrategy(token);
                (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb) = _deployConcreteTCRWithStrategy(strategy);

                bytes32 itemID = _addItem(tcr, requester, _defaultCommunityGoalItem());
                _acceptRequest(tcr, itemID);

                _approveRemoveCost(tcr, remover);
                vm.prank(remover);
                tcr.removeItem(itemID, "");

                _approveChallengeRemovalCost(tcr, challenger);
                uint256 disputeCreationTs = block.timestamp;
                vm.prank(challenger);
                tcr.challengeRequest(itemID, "");

                (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
                bytes32 sa = bytes32("sa");
                bytes32 sb = bytes32("sb");
                _commitRevealTwoVotes(arb, 1, start, end, voter1, 2, sa, "", voter2, 2, sb, "");

                _warpRoll(revealEnd + 1);
                vm.expectRevert(bytes("MOCK_STRATEGY_REVERT"));
                arb.executeRuling(1);

                assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
            }
        }
