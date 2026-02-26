// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";

contract GeneralizedTCRArbitrationOutcomesRuleTest is GeneralizedTCRTestBase {
    function test_full_dispute_flow_registration_requester_wins_item_registered_and_balances() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-7");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);

        uint256 requesterBefore = token.balanceOf(requester);
        uint256 challengerBefore = token.balanceOf(challenger);

        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        // Vote: both voters support Requester (choice 1)
        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, 1, start, end, voter1, 1, s1, "", voter2, 1, s2, "");

        _warpRoll(revealEnd + 1);

        // Execute ruling (arb calls into tcr.rule internally)
        arb.executeRuling(1);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));

        // Withdraw feeRewards for the requester after resolution.
        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);
        assertEq(token.balanceOf(address(tcr)), submissionBaseDeposit);

        // Net effect for requester: gained challenger's base deposit (submissionChallengeBaseDeposit),
        // but arbitrationCost is spent to arbitrator/voters.
        int256 requesterDelta = int256(token.balanceOf(requester)) - int256(requesterBefore);
        int256 challengerDelta = int256(token.balanceOf(challenger)) - int256(challengerBefore);

        int256 expectedRequesterDelta = int256(submissionChallengeBaseDeposit + arbitrationCost);
        int256 expectedChallengerDelta = -int256(submissionChallengeBaseDeposit + arbitrationCost);

        assertEq(requesterDelta, expectedRequesterDelta); // requester captures full feeRewards for the round
        assertEq(challengerDelta, expectedChallengerDelta); // loses arbitrationCost + base
    }

    function test_arbitrated_registration_hook_observes_updated_status() public {
        MockGeneralizedTCRHookOrder hookImpl = new MockGeneralizedTCRHookOrder();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        ERC20VotesArbitrator hookArb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(hookArb), arbProxyAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                hookArb,
                bytes(""),
                "ipfs://regMeta",
                "ipfs://clearMeta",
                governor,
                IVotes(address(token)),
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                defaultSubmissionDepositStrategy
            )
        );
        MockGeneralizedTCRHookOrder hookTcr = MockGeneralizedTCRHookOrder(_deployProxy(address(hookImpl), tcrInit));
        assertEq(address(hookTcr), tcrProxyAddr);

        uint256 addCost = submissionBaseDeposit + arbitrationCost;
        vm.prank(requester);
        token.approve(address(hookTcr), addCost);

        bytes memory item = abi.encodePacked("item-hook");
        vm.prank(requester);
        bytes32 itemID = hookTcr.addItem(item);

        uint256 challengeCost = submissionChallengeBaseDeposit + arbitrationCost;
        vm.prank(challenger);
        token.approve(address(hookTcr), challengeCost);

        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        hookTcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(hookArb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(hookArb, 1, start, end, voter1, 1, s1, "", voter2, 1, s2, "");

        _warpRoll(revealEnd + 1);
        hookArb.executeRuling(1);

        (, IGeneralizedTCR.Status status,) = hookTcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));
    }

    function test_full_dispute_flow_clearing_request_requester_wins_item_absent() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-clear-req-wins");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        _approveRemoveCost(requester);
        vm.prank(requester);
        tcr.removeItem(itemID, "");

        _approveChallengeRemovalCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, 1, start, end, voter1, 1, s1, "", voter2, 1, s2, "");

        _warpRoll(revealEnd + 1);

        arb.executeRuling(1);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));
    }

    function test_full_dispute_flow_registration_challenger_wins_item_absent() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-8");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);

        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        // voter1 supports challenger (choice 2), voter2 also supports challenger
        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, 1, start, end, voter1, 2, s1, "", voter2, 2, s2, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(1);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));
    }

    function test_full_dispute_flow_clearing_request_challenger_wins_item_stays_registered() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-clear-chal-wins");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        _approveRemoveCost(requester);
        vm.prank(requester);
        tcr.removeItem(itemID, "");

        _approveChallengeRemovalCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, 1, start, end, voter1, 2, s1, "", voter2, 2, s2, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(1);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));
    }

    function test_rule_emits_disputed_item_status_change() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-rule-event");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (, , uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        _warpRoll(revealEnd + 1);

        vm.expectEmit(true, true, false, true, address(tcr));
        emit IArbitrable.Ruling(IArbitrator(address(arb)), 1, 1);

        vm.expectEmit(true, true, true, true, address(tcr));
        emit IGeneralizedTCR.ItemStatusChange(
            itemID,
            0,
            0,
            true,
            true,
            IGeneralizedTCR.Status.Registered
        );

        vm.prank(address(arb));
        tcr.rule(1, 1);
    }

    function test_rule_reverts_invalid_ruling_and_reverts_if_already_resolved() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-9");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        // invalid ruling option ( > 2 )
        vm.expectRevert(IGeneralizedTCR.INVALID_RULING_OPTION.selector);
        vm.prank(address(arb));
        tcr.rule(1, 3);

        // Resolve via arbitrator with no votes (tie/no votes => Party.None)
        uint256 start = block.timestamp + arb._votingDelay();
        uint256 end = start + arb._votingPeriod();
        uint256 revealEnd = end + arb._revealPeriod();

        _warpRoll(start + 1);
        _warpRoll(end + 1);
        _warpRoll(revealEnd + 1);
        arb.executeRuling(1);

        // calling rule again should revert after mapping cleanup
        vm.expectRevert(abi.encodeWithSelector(IGeneralizedTCR.NO_REQUESTS_FOR_ITEM.selector, bytes32(0)));
        vm.prank(address(arb));
        tcr.rule(1, 0);
    }

    function test_rule_reverts_when_mapping_present_but_not_disputed() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-rule-not-disputed");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        tcr.exposedSetArbitratorDisputeIDToItem(address(arb), 0, itemID);

        vm.expectRevert(IGeneralizedTCR.REQUEST_MUST_BE_DISPUTED.selector);
        vm.prank(address(arb));
        tcr.rule(0, 1);
    }

    function test_rule_reverts_when_mapping_present_but_request_resolved() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-rule-resolved");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        tcr.exposedSetRequestResolved(itemID, 0, true);
        tcr.exposedSetArbitratorDisputeIDToItem(address(arb), 0, itemID);

        vm.expectRevert(IGeneralizedTCR.REQUEST_MUST_NOT_BE_RESOLVED.selector);
        vm.prank(address(arb));
        tcr.rule(0, 1);
    }

    function test_rule_reverts_when_mapping_present_but_sender_not_arbitrator() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-rule-bad-arb");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        address fakeArb = makeAddr("fakeArb");
        tcr.exposedSetArbitratorDisputeIDToItem(fakeArb, 1, itemID);

        vm.expectRevert(IGeneralizedTCR.ONLY_ARBITRATOR_CAN_RULE.selector);
        vm.prank(fakeArb);
        tcr.rule(1, 1);
    }

    function test_rule_reverts_when_mapping_points_to_missing_item() public {
        bytes32 fakeItem = keccak256("missing-item");
        tcr.exposedSetArbitratorDisputeIDToItem(address(arb), 42, fakeItem);

        vm.expectRevert(abi.encodeWithSelector(IGeneralizedTCR.NO_REQUESTS_FOR_ITEM.selector, fakeItem));
        vm.prank(address(arb));
        tcr.rule(42, 1);
    }

    function test_rule_reverts_when_dispute_not_solved() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-rule-unsolved");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        vm.expectRevert(IGeneralizedTCR.DISPUTE_NOT_SOLVED.selector);
        vm.prank(address(arb));
        tcr.rule(1, 1);
    }

    function test_rule_reverts_when_dispute_mapping_missing() public {
        vm.expectRevert(abi.encodeWithSelector(IGeneralizedTCR.NO_REQUESTS_FOR_ITEM.selector, bytes32(0)));
        tcr.rule(1, 1);
    }

    function test_rule_reverts_when_dispute_id_mismatch() public {
        MockGeneralizedTCRDisputeIdHarness tcrImpl = new MockGeneralizedTCRDisputeIdHarness();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        ERC20VotesArbitrator localArb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(localArb), arbProxyAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                localArb,
                bytes(""),
                "ipfs://regMeta",
                "ipfs://clearMeta",
                governor,
                IVotes(address(token)),
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                defaultSubmissionDepositStrategy
            )
        );
        MockGeneralizedTCRDisputeIdHarness localTcr =
            MockGeneralizedTCRDisputeIdHarness(_deployProxy(address(tcrImpl), tcrInit));
        assertEq(address(localTcr), tcrProxyAddr);

        uint256 addCost = submissionBaseDeposit + arbitrationCost;
        vm.prank(requester);
        token.approve(address(localTcr), addCost);

        bytes memory item = abi.encodePacked("item-mismatch");
        vm.prank(requester);
        bytes32 itemID = localTcr.addItem(item);

        uint256 challengeCost = submissionChallengeBaseDeposit + arbitrationCost;
        vm.prank(challenger);
        token.approve(address(localTcr), challengeCost);

        vm.prank(challenger);
        localTcr.challengeRequest(itemID, "");

        localTcr.setRequestDisputeId(itemID, 0, 999);

        vm.expectRevert(IGeneralizedTCR.INVALID_DISPUTE_ID.selector);
        vm.prank(address(localArb));
        localTcr.rule(1, 1);
    }

    function test_tie_ruling_keeps_status_quo_and_refunds_both_sides() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-tie");

        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        // Create a tie with equal voting power.
        address a = makeAddr("tie-a");
        address b = makeAddr("tie-b");
        token.mint(a, 123e18);
        token.mint(b, 123e18);
        vm.prank(a);
        token.delegate(a);
        vm.prank(b);
        token.delegate(b);
        vm.roll(block.number + 1);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 sa = bytes32("sa");
        bytes32 sb = bytes32("sb");
        _commitRevealTwoVotes(arb, 1, start, end, a, 1, sa, "", b, 2, sb, "");

        _warpRoll(revealEnd + 1);

        uint256 requesterBefore = token.balanceOf(requester);
        uint256 challengerBefore = token.balanceOf(challenger);

        arb.executeRuling(1);

        // Status quo: registration request rejected.
        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));

        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);
        tcr.withdrawFeesAndRewards(challenger, itemID, 0, 0);

        // Round rewards are refunded proportionally, and requester also receives the submission deposit on tie.
        uint256 challengeCost = submissionChallengeBaseDeposit + arbitrationCost;
        uint256 requesterRoundCost = arbitrationCost;
        uint256 feeRewards = challengeCost;
        uint256 expectedRequesterReward = (requesterRoundCost * feeRewards) / (requesterRoundCost + challengeCost);
        uint256 expectedChallengerReward = (challengeCost * feeRewards) / (requesterRoundCost + challengeCost);

        assertEq(token.balanceOf(requester) - requesterBefore, expectedRequesterReward + submissionBaseDeposit);
        assertEq(token.balanceOf(challenger) - challengerBefore, expectedChallengerReward);

        uint256 expectedRemainder = feeRewards - expectedRequesterReward - expectedChallengerReward;
        assertEq(token.balanceOf(address(tcr)), expectedRemainder);
    }

}
