// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import {TestUtils} from "test/utils/TestUtils.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {MockArbitrable} from "test/mocks/MockArbitrable.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {ArbitratorStorageV1} from "src/tcr/storage/ArbitratorStorageV1.sol";

contract ArbitratorHandler is Test {
    ERC20VotesArbitrator internal arb;
    MockVotesToken internal token;
    MockArbitrable internal arbitrable;
    address[] internal voters;

    struct CommitInfo {
        bool committed;
        bool revealed;
        uint256 choice;
        bytes32 salt;
    }

    uint256[] internal disputeIds;
    mapping(uint256 => mapping(address => CommitInfo)) internal commits;

    uint256 internal constant MAX_DISPUTES = 12;

    constructor(
        ERC20VotesArbitrator arb_,
        MockVotesToken token_,
        MockArbitrable arbitrable_,
        address[] memory voters_
    ) {
        arb = arb_;
        token = token_;
        arbitrable = arbitrable_;
        voters = voters_;
    }

    function createDispute(uint256 seed) external {
        if (disputeIds.length >= MAX_DISPUTES) return;
        uint256 id = arbitrable.createDispute(2, abi.encodePacked(seed));
        disputeIds.push(id);
    }

    function commitVote(uint256 seed) external {
        if (disputeIds.length == 0) return;
        uint256 disputeId = disputeIds[seed % disputeIds.length];

        if (arb.currentRoundState(disputeId) != ArbitratorStorageV1.DisputeState.Active) return;

        address voter = voters[(seed >> 8) % voters.length];
        CommitInfo storage info = commits[disputeId][voter];
        if (info.committed) return;

        uint256 choice = (seed % 2) + 1;
        bytes32 salt = bytes32(seed);
        bytes32 hash = keccak256(abi.encode(choice, "", salt));

        vm.prank(voter);
        try arb.commitVote(disputeId, hash) {
            info.committed = true;
            info.choice = choice;
            info.salt = salt;
        } catch {}
    }

    function revealVote(uint256 seed) external {
        if (disputeIds.length == 0) return;
        uint256 disputeId = disputeIds[seed % disputeIds.length];

        if (arb.currentRoundState(disputeId) != ArbitratorStorageV1.DisputeState.Reveal) return;

        address voter = voters[(seed >> 8) % voters.length];
        CommitInfo storage info = commits[disputeId][voter];
        if (!info.committed || info.revealed) return;

        vm.prank(voter);
        try arb.revealVote(disputeId, voter, info.choice, "", info.salt) {
            info.revealed = true;
        } catch {}
    }

    function executeRuling(uint256 seed) external {
        if (disputeIds.length == 0) return;
        uint256 disputeId = disputeIds[seed % disputeIds.length];

        (,, bool executed,,,) = arb.disputes(disputeId);
        if (executed) return;

        if (arb.currentRoundState(disputeId) != ArbitratorStorageV1.DisputeState.Solved) return;

        try arb.executeRuling(disputeId) {} catch {}
    }

    function warpTime(uint256 seed) external {
        uint256 jump = _bound(seed, 1 hours, 5 days);
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);
    }
}

contract ERC20VotesArbitratorInvariantTest is StdInvariant, TestUtils {
    MockVotesToken internal token;
    MockArbitrable internal arbitrable;
    ERC20VotesArbitrator internal arb;
    ArbitratorHandler internal handler;

    address internal owner = makeAddr("owner");

    uint256 internal votingPeriod = 40;
    uint256 internal votingDelay = 3;
    uint256 internal revealPeriod = 10;
    uint256 internal arbitrationCost = 20e18;

    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");
    address internal voter3 = makeAddr("voter3");

    function setUp() public {
        token = new MockVotesToken("MockVotes", "MV");
        arbitrable = new MockArbitrable(token);

        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(impl), initData));

        arbitrable.setArbitrator(arb);

        token.mint(address(arbitrable), 1_000_000e18);
        arbitrable.approveArbitrator(type(uint256).max);

        token.mint(voter1, 100e18);
        token.mint(voter2, 200e18);
        token.mint(voter3, 300e18);

        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);

        vm.roll(block.number + 1);

        address[] memory voters = new address[](3);
        voters[0] = voter1;
        voters[1] = voter2;
        voters[2] = voter3;

        handler = new ArbitratorHandler(arb, token, arbitrable, voters);
        targetContract(address(handler));
    }

    function invariant_totalVotesMatchesChoiceVotes() public view {
        uint256 disputes = arb.disputeCount();
        for (uint256 i = 1; i <= disputes; i++) {
            (,,, uint256 round, uint256 choices,) = arb.disputes(i);
            uint256 total = arb.getTotalVotesByRound(i, round);
            uint256 sum = 0;
            for (uint256 c = 1; c <= choices; c++) {
                sum += arb.getVotesByRound(i, round, c);
            }
            assertEq(total, sum);
        }
    }

    function invariant_revealImpliesCommit() public view {
        uint256 disputes = arb.disputeCount();
        for (uint256 i = 1; i <= disputes; i++) {
            (,,, uint256 round,,) = arb.disputes(i);

            ERC20VotesArbitrator.Receipt memory r1 = arb.getReceiptByRound(i, round, voter1);
            if (r1.hasRevealed) {
                assertTrue(r1.hasCommitted);
                assertGt(r1.votes, 0);
            }

            ERC20VotesArbitrator.Receipt memory r2 = arb.getReceiptByRound(i, round, voter2);
            if (r2.hasRevealed) {
                assertTrue(r2.hasCommitted);
                assertGt(r2.votes, 0);
            }

            ERC20VotesArbitrator.Receipt memory r3 = arb.getReceiptByRound(i, round, voter3);
            if (r3.hasRevealed) {
                assertTrue(r3.hasCommitted);
                assertGt(r3.votes, 0);
            }
        }
    }

    function invariant_executedDisputesAreSolvedAndRulingMatches() public {
        uint256 disputes = arb.disputeCount();
        for (uint256 i = 1; i <= disputes; i++) {
            (,, bool executed,,, uint256 winningChoice) = arb.disputes(i);
            if (!executed) continue;

            assertEq(uint256(arb.disputeStatus(i)), uint256(IArbitrator.DisputeStatus.Solved));
            assertEq(uint256(arb.currentRoundState(i)), uint256(ArbitratorStorageV1.DisputeState.Solved));

            IArbitrable.Party ruling = arb.currentRuling(i);
            if (winningChoice == 0) {
                assertEq(uint256(ruling), uint256(IArbitrable.Party.None));
            } else if (winningChoice == 1) {
                assertEq(uint256(ruling), uint256(IArbitrable.Party.Requester));
            } else if (winningChoice == 2) {
                assertEq(uint256(ruling), uint256(IArbitrable.Party.Challenger));
            } else {
                fail("winningChoice out of range");
            }
        }
    }
}
