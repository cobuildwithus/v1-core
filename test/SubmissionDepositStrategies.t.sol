// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";

contract SubmissionDepositStrategiesTest is Test {
    MockVotesToken internal token;

    address internal manager = makeAddr("manager");
    address internal requester = makeAddr("requester");
    address internal challenger = makeAddr("challenger");
    address internal prizePool = makeAddr("prizePool");

    function setUp() public {
        token = new MockVotesToken("MockVotes", "MV");
    }

    function test_prize_pool_strategy_reverts_on_zero_prize_pool() public {
        vm.expectRevert(PrizePoolSubmissionDepositStrategy.PRIZE_POOL_ZERO.selector);
        new PrizePoolSubmissionDepositStrategy(token, address(0));
    }

    function test_prize_pool_strategy_actions() public {
        PrizePoolSubmissionDepositStrategy strategy = new PrizePoolSubmissionDepositStrategy(token, prizePool);

        (ISubmissionDepositStrategy.DepositAction action, address recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.Requester,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, prizePool);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.Challenger,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, challenger);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.Challenger,
            manager,
            requester,
            address(0),
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, requester);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.None,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, requester);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.ClearingRequested,
            IArbitrable.Party.Requester,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Hold));
        assertEq(recipient, address(0));
    }

    function test_escrow_strategy_actions() public {
        EscrowSubmissionDepositStrategy strategy = new EscrowSubmissionDepositStrategy(token);

        (ISubmissionDepositStrategy.DepositAction action, address recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.Requester,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Hold));
        assertEq(recipient, address(0));

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.Challenger,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, challenger);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.RegistrationRequested,
            IArbitrable.Party.Challenger,
            manager,
            requester,
            address(0),
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, requester);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.ClearingRequested,
            IArbitrable.Party.Requester,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, requester);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.ClearingRequested,
            IArbitrable.Party.Requester,
            manager,
            manager,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Transfer));
        assertEq(recipient, manager);

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.ClearingRequested,
            IArbitrable.Party.None,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Hold));
        assertEq(recipient, address(0));

        (action, recipient) = strategy.getSubmissionDepositAction(
            bytes32("item"),
            IGeneralizedTCR.Status.Absent,
            IArbitrable.Party.None,
            manager,
            requester,
            challenger,
            100
        );
        assertEq(uint8(action), uint8(ISubmissionDepositStrategy.DepositAction.Hold));
        assertEq(recipient, address(0));
    }
}
