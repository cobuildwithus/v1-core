// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness} from "test/ERC20VotesArbitrator.t.sol";

import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import {ArbitratorStorageV1} from "src/tcr/storage/ArbitratorStorageV1.sol";
import {ArbitrationCostExtraData} from "src/tcr/utils/ArbitrationCostExtraData.sol";

contract ERC20VotesArbitratorDisputeLifecycleTest is ERC20VotesArbitratorTestBase {
    function test_createDispute_onlyArbitrable_reverts() public {
        vm.expectRevert(IERC20VotesArbitrator.ONLY_ARBITRABLE.selector);
        arb.createDispute(2, "");
    }

    function test_createDispute_invalidChoices_reverts() public {
        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_CHOICES.selector);
        arbitrable.createDispute(3, "");
    }

    function test_createDispute_transfersCost_and_emits() public {
        uint256 balBefore = token.balanceOf(address(arb));
        uint256 arbBalBefore = token.balanceOf(address(arbitrable));

        bytes memory extraData = hex"deadbeef";
        uint256 expectedStart = block.timestamp + votingDelay;
        uint256 expectedEnd = expectedStart + votingPeriod;
        uint256 expectedRevealEnd = expectedEnd + revealPeriod;
        uint256 expectedCreationBlock = block.number - 1;

        vm.expectEmit(true, true, true, true, address(arb));
        emit IERC20VotesArbitrator.DisputeCreated(
            1,
            address(arbitrable),
            expectedStart,
            expectedEnd,
            expectedRevealEnd,
            expectedCreationBlock,
            arbitrationCost,
            extraData,
            2
        );

        // IArbitrator event from arbitrator contract address (proxy)
        vm.expectEmit(true, true, false, true, address(arb));
        emit IArbitrator.DisputeCreation(1, IArbitrable(address(arbitrable)));

        uint256 id = arbitrable.createDispute(2, extraData);
        assertEq(id, 1);

        // Cost transferred from arbitrable -> arbitrator
        assertEq(token.balanceOf(address(arb)) - balBefore, arbitrationCost);
        assertEq(arbBalBefore - token.balanceOf(address(arbitrable)), arbitrationCost);

        (uint256 storedId, address storedArbitrable, bool executed, uint256 currentRound, uint256 choices, uint256 winningChoice) =
            arb.disputes(1);

        assertEq(storedId, 1);
        assertEq(storedArbitrable, address(arbitrable));
        assertEq(executed, false);
        assertEq(currentRound, 0);
        assertEq(choices, 2);
        assertEq(winningChoice, 0);
    }

    function test_createDispute_uses_creationBlock_snapshot() public {
        uint256 expectedStart = block.timestamp + votingDelay;
        uint256 expectedEnd = expectedStart + votingPeriod;
        uint256 expectedRevealEnd = expectedEnd + revealPeriod;
        uint256 expectedCreationBlock = block.number - 1;

        vm.expectEmit(true, true, true, true, address(arb));
        emit IERC20VotesArbitrator.DisputeCreated(
            1,
            address(arbitrable),
            expectedStart,
            expectedEnd,
            expectedRevealEnd,
            expectedCreationBlock,
            arbitrationCost,
            "",
            2
        );

        uint256 id = arbitrable.createDispute(2, "");
        assertEq(id, 1);
    }

    function test_createDispute_uses_snapshot_cost_from_extraData() public {
        uint256 snapshotCost = arbitrationCost / 2;
        bytes memory extraData = ArbitrationCostExtraData.encode(snapshotCost, hex"deadbeef");

        vm.prank(address(arbitrable));
        arb.setArbitrationCost(arbitrationCost * 2);

        uint256 balBefore = token.balanceOf(address(arb));
        uint256 arbBalBefore = token.balanceOf(address(arbitrable));

        uint256 expectedStart = block.timestamp + votingDelay;
        uint256 expectedEnd = expectedStart + votingPeriod;
        uint256 expectedRevealEnd = expectedEnd + revealPeriod;
        uint256 expectedCreationBlock = block.number - 1;

        vm.expectEmit(true, true, true, true, address(arb));
        emit IERC20VotesArbitrator.DisputeCreated(
            1,
            address(arbitrable),
            expectedStart,
            expectedEnd,
            expectedRevealEnd,
            expectedCreationBlock,
            snapshotCost,
            extraData,
            2
        );

        uint256 id = arbitrable.createDispute(2, extraData);
        assertEq(id, 1);

        assertEq(token.balanceOf(address(arb)) - balBefore, snapshotCost);
        assertEq(arbBalBefore - token.balanceOf(address(arbitrable)), snapshotCost);
    }

    function test_arbitrationCost_uses_extraData_snapshot() public {
        uint256 snapshotCost = arbitrationCost / 3;
        bytes memory extraData = ArbitrationCostExtraData.encode(snapshotCost, hex"1234");

        vm.prank(address(arbitrable));
        arb.setArbitrationCost(arbitrationCost * 2);

        assertEq(arb.arbitrationCost(extraData), snapshotCost);
        assertEq(arb.arbitrationCost(""), arbitrationCost * 2);
    }

    function test_arbitrationCost_snapshot_out_of_range_reverts() public {
        bytes memory extraData = ArbitrationCostExtraData.encode(arb.MIN_ARBITRATION_COST() - 1, "");
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        arb.arbitrationCost(extraData);
    }

    function test_createDispute_sets_revealPeriodStartTime() public {
        uint256 expectedStart = block.timestamp + votingDelay;
        uint256 expectedEnd = expectedStart + votingPeriod;

        uint256 id = arbitrable.createDispute(2, "");

        (uint256 votingStart, uint256 votingEnd, uint256 revealStart, uint256 revealEnd) =
            ArbitratorHarness(address(arb)).exposed_roundTimes(id, 0);

        assertEq(votingStart, expectedStart);
        assertEq(votingEnd, expectedEnd);
        assertEq(revealStart, expectedEnd);
        assertEq(revealEnd, expectedEnd + revealPeriod);
    }

    function test_roundStateTransitions_and_disputeStatus_mapping() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        // Pending
        assertEq(uint256(arb.currentRoundState(disputeId)), uint256(ArbitratorStorageV1.DisputeState.Pending));
        assertEq(uint256(arb.disputeStatus(disputeId)), uint256(IArbitrator.DisputeStatus.Waiting));

        // Active
        _warpRoll(start + 1);
        assertEq(uint256(arb.currentRoundState(disputeId)), uint256(ArbitratorStorageV1.DisputeState.Active));
        assertEq(uint256(arb.disputeStatus(disputeId)), uint256(IArbitrator.DisputeStatus.Waiting));

        // Reveal
        _warpRoll(end + 1);
        assertEq(uint256(arb.currentRoundState(disputeId)), uint256(ArbitratorStorageV1.DisputeState.Reveal));
        assertEq(uint256(arb.disputeStatus(disputeId)), uint256(IArbitrator.DisputeStatus.Waiting));

        // Solved
        _warpRoll(revealEnd + 1);
        assertEq(uint256(arb.currentRoundState(disputeId)), uint256(ArbitratorStorageV1.DisputeState.Solved));
        assertEq(uint256(arb.disputeStatus(disputeId)), uint256(IArbitrator.DisputeStatus.Solved));
    }

    function testFuzz_lifecycleActionsRespectPhaseBoundaries_withoutBlockRolls(
        uint256 pendingDelta,
        uint256 activeDelta,
        uint256 revealDelta
    ) public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        // L2-style ordering: advance timestamp without incrementing block number.
        pendingDelta = bound(pendingDelta, 0, votingDelay - 1);
        vm.warp((start - votingDelay) + pendingDelta);
        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(voter1);
        arb.commitVote(disputeId, bytes32(uint256(1)));

        activeDelta = bound(activeDelta, 0, votingPeriod - 1);
        vm.warp(start + activeDelta);

        bytes32 salt = keccak256(abi.encode(activeDelta, revealDelta));
        bytes32 commitHash = _voteHash(arb, disputeId, 0, voter1, 1, "", salt);
        vm.prank(voter1);
        arb.commitVote(disputeId, commitHash);

        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt);

        revealDelta = bound(revealDelta, 0, revealPeriod - 1);
        vm.warp(end + revealDelta);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt);

        vm.expectRevert(IERC20VotesArbitrator.DISPUTE_NOT_SOLVED.selector);
        arb.executeRuling(disputeId);

        vm.warp(revealEnd);
        arb.executeRuling(disputeId);

        assertEq(uint256(arb.currentRoundState(disputeId)), uint256(ArbitratorStorageV1.DisputeState.Solved));
        assertEq(uint256(arb.disputeStatus(disputeId)), uint256(IArbitrator.DisputeStatus.Solved));
    }

    function test_lifecycleActionsAtExactBoundaryTimestamps_withoutBlockRolls() public {
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 voter1Salt = bytes32("voter1-boundary");
        bytes32 voter2Salt = bytes32("voter2-boundary");
        bytes32 voter1Commit = _voteHash(arb, disputeId, 0, voter1, 1, "", voter1Salt);
        bytes32 voter2Commit = _voteHash(arb, disputeId, 0, voter2, 2, "", voter2Salt);

        vm.warp(start - 1);
        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(voter1);
        arb.commitVote(disputeId, voter1Commit);

        vm.warp(start);
        vm.prank(voter1);
        arb.commitVote(disputeId, voter1Commit);
        vm.prank(voter2);
        arb.commitVote(disputeId, voter2Commit);

        vm.warp(end);
        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(noVotes);
        arb.commitVote(disputeId, bytes32(uint256(999)));

        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", voter1Salt);

        vm.warp(revealEnd);
        vm.expectRevert(IERC20VotesArbitrator.VOTING_CLOSED.selector);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", voter2Salt);

        arb.executeRuling(disputeId);
    }

    function test_createDispute_l2NoRoll_snapshotUses_previousBlock() public {
        uint256 expectedCreationBlock = block.number - 1;
        uint256 expectedVotes = token.getPastVotes(voter1, expectedCreationBlock);

        // Simulate timestamp movement without block increments.
        vm.warp(block.timestamp + 1 days);

        uint256 disputeId = arbitrable.createDispute(2, "");
        IERC20VotesArbitrator.VotingRoundInfo memory info = arb.getVotingRoundInfo(disputeId, 0);

        assertEq(info.creationBlock, expectedCreationBlock);

        (uint256 votingPower, bool canVote) = arb.votingPowerInRound(disputeId, 0, voter1);
        assertTrue(canVote);
        assertEq(votingPower, expectedVotes);
    }

    function test_createDispute_l2NoRoll_sameBlockDelegationStillExcluded() public {
        (uint256 disputeId, uint256 start,,, uint256 creationBlock) = _createDispute("");

        address late = makeAddr("lateL2");
        token.mint(late, 100e18);
        vm.prank(late);
        token.delegate(late);

        // Votes gained in the same L2 block as dispute creation remain excluded from creationBlock snapshots.
        assertEq(token.getPastVotes(late, creationBlock), 0);

        vm.warp(start + 1);
        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(late);
        arb.commitVote(disputeId, bytes32(uint256(123)));
    }

    function test_validDisputeID_modifier_reverts() public {
        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        arb.currentRoundState(0);

        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        arb.currentRuling(999);
    }

    function test_validDisputeID_modifier_harness() public {
        (uint256 disputeId,,,,) = _createDispute("");

        assertTrue(ArbitratorHarness(address(arb)).exposed_validDisputeID(disputeId));

        vm.expectRevert(IERC20VotesArbitrator.INVALID_DISPUTE_ID.selector);
        ArbitratorHarness(address(arb)).exposed_validDisputeID(0);
    }
}
