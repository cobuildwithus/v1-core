// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";

contract GeneralizedTCRRequestLifecycleTest is GeneralizedTCRTestBase {
    function test_getRequestState_returnsNone_forMissingRequest() public view {
        (
            IGeneralizedTCR.RequestPhase phase,
            uint256 challengeDeadline,
            uint256 timeoutAt,
            IArbitrator.DisputeStatus arbitratorStatus,
            bool canChallenge,
            bool canExecuteRequest,
            bool canExecuteTimeout
        ) = tcr.getRequestState(keccak256("missing-item"), 0);

        assertEq(uint256(phase), uint256(IGeneralizedTCR.RequestPhase.None));
        assertEq(challengeDeadline, 0);
        assertEq(timeoutAt, 0);
        assertEq(uint256(arbitratorStatus), uint256(IArbitrator.DisputeStatus.Waiting));
        assertFalse(canChallenge);
        assertFalse(canExecuteRequest);
        assertFalse(canExecuteTimeout);
    }

    function test_getRequestState_resolvedDisputed_reportsSolvedArbitratorStatus() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-resolved-disputed-state");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (, , uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        _warpRoll(revealEnd + 1);
        arb.executeRuling(1);

        (
            IGeneralizedTCR.RequestPhase phase,
            ,
            uint256 timeoutAt,
            IArbitrator.DisputeStatus arbitratorStatus,
            bool canChallenge,
            bool canExecuteRequest,
            bool canExecuteTimeout
        ) = tcr.getRequestState(itemID, 0);

        assertEq(uint256(phase), uint256(IGeneralizedTCR.RequestPhase.Resolved));
        assertEq(timeoutAt, 0);
        assertEq(uint256(arbitratorStatus), uint256(IArbitrator.DisputeStatus.Solved));
        assertFalse(canChallenge);
        assertFalse(canExecuteRequest);
        assertFalse(canExecuteTimeout);
    }

    function test_executeRequest_registers_item_when_unchallenged_and_refunds_requester() public {
        uint256 addCost = _approveAddItemCost(requester);

        bytes memory item = abi.encodePacked("item-2");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        // Too early
        vm.expectRevert(IGeneralizedTCR.CHALLENGE_PERIOD_MUST_PASS.selector);
        tcr.executeRequest(itemID);

        uint256 requesterBefore = token.balanceOf(requester);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        vm.expectEmit(true, false, false, true, address(tcr));
        emit MockGeneralizedTCR.HookItemRegistered(itemID, item);

        tcr.executeRequest(itemID);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));

        assertEq(token.balanceOf(address(tcr)), addCost);

        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);

        // With strategy-separated deposits, only arbitration cost is refunded via round rewards.
        assertEq(token.balanceOf(requester) - requesterBefore, arbitrationCost);
        // Submission deposit remains escrowed on accepted registration.
        assertEq(token.balanceOf(address(tcr)), submissionBaseDeposit);

        // After resolution, calling executeRequest again should hit MUST_BE_A_REQUEST (status is Registered)
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        vm.expectRevert(IGeneralizedTCR.MUST_BE_A_REQUEST.selector);
        tcr.executeRequest(itemID);
    }

    function test_executeRequest_reverts_when_no_request() public {
        bytes32 fake = keccak256("no-request");
        vm.expectRevert(IGeneralizedTCR.MUST_BE_A_REQUEST.selector);
        tcr.executeRequest(fake);
    }

    function test_executeRequest_sets_ruling_to_requester() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-ruling");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        (,,,,,, IArbitrable.Party ruling,,,) = tcr.getRequestInfo(itemID, 0);
        assertEq(uint256(ruling), uint256(IArbitrable.Party.Requester));
    }

    function test_executeRequest_reverts_when_item_has_no_requests() public {
        bytes32 missingItemID = keccak256("missing-item");
        vm.expectRevert(IGeneralizedTCR.MUST_BE_A_REQUEST.selector);
        tcr.executeRequest(missingItemID);
    }

    function test_removeItem_requires_registered_and_emits_evidence_if_provided() public {
        // Add + execute to registered
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-3");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);
        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);

        // remove requires approval for removal cost
        uint256 removeCost = _approveRemoveCost(requester);

        // Evidence should emit
        string memory evidence = "ipfs://evidence";
        vm.prank(requester);
        tcr.removeItem(itemID, evidence);

        // Accepted registration keeps the submission deposit escrowed.
        assertEq(token.balanceOf(address(tcr)), submissionBaseDeposit + removeCost);

        (, IGeneralizedTCR.Status status, uint256 reqCount) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.ClearingRequested));
        assertEq(reqCount, 2);
    }

    function test_executeRequest_removes_item_when_unchallenged_and_refunds_requester() public {
        // Add -> register
        uint256 addCost = _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-4");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);
        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);

        // Remove request
        uint256 removeCost = _approveRemoveCost(requester);
        vm.prank(requester);
        tcr.removeItem(itemID, "");

        uint256 requesterBefore = token.balanceOf(requester);

        // Execute removal after challenge period
        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        vm.expectEmit(true, false, false, true, address(tcr));
        emit MockGeneralizedTCR.HookItemRemoved(itemID);

        tcr.executeRequest(itemID);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));

        // On successful clearing, escrowed submission deposit is released immediately.
        assertEq(token.balanceOf(address(tcr)), removeCost);

        tcr.withdrawFeesAndRewards(requester, itemID, 1, 0);

        // Requester receives both the clearing round refund and released submission deposit.
        assertEq(token.balanceOf(requester) - requesterBefore, removeCost + submissionBaseDeposit);
        assertEq(token.balanceOf(address(tcr)), 0);

        // sanity: addCost was also refunded earlier
        assertEq(addCost, submissionBaseDeposit + arbitrationCost);
    }

    function test_manager_updates_on_resubmission() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-manager");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        _approveRemoveCost(requester);
        vm.prank(requester);
        tcr.removeItem(itemID, "");
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        address newRequester = makeAddr("newRequester");
        token.mint(newRequester, 1_000_000e18);
        uint256 addCost = submissionBaseDeposit + arbitrationCost;
        vm.prank(newRequester);
        token.approve(address(tcr), addCost);
        vm.prank(newRequester);
        tcr.addItem(item);

        (, address manager,) = tcr.items(itemID);
        assertEq(manager, newRequester);
    }

    function test_removeItem_reverts_when_item_not_registered() public {
        bytes32 fake = keccak256("fake-item");
        vm.expectRevert(IGeneralizedTCR.MUST_BE_REGISTERED_TO_BE_REMOVED.selector);
        tcr.removeItem(fake, "");
    }

    function test_withdrawFeesAndRewards_reverts_until_resolved() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-11");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        vm.expectRevert(IGeneralizedTCR.REQUEST_MUST_BE_RESOLVED.selector);
        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        uint256 requesterBefore = token.balanceOf(requester);

        tcr.withdrawFeesAndRewards(requester, itemID, 0, 0);

        assertEq(token.balanceOf(requester) - requesterBefore, arbitrationCost);
    }

    function test_getContributions_returns_expected_values() public {
        uint256 addCost = _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-contrib");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        uint256 challengeCost = _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        uint256[3] memory reqC = tcr.getContributions(itemID, 0, 0, requester);
        // Registration requester round contribution tracks arbitration cost only.
        assertEq(reqC[uint256(IArbitrable.Party.Requester)], arbitrationCost);
        assertEq(reqC[uint256(IArbitrable.Party.Challenger)], 0);

        uint256[3] memory chalC = tcr.getContributions(itemID, 0, 0, challenger);
        assertEq(chalC[uint256(IArbitrable.Party.Requester)], 0);
        assertEq(chalC[uint256(IArbitrable.Party.Challenger)], challengeCost);
    }

    function test_itemList_and_index_stable_across_remove_and_readd() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-stable");

        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        assertEq(tcr.itemCount(), 1);
        assertEq(tcr.itemIDtoIndex(itemID), 0);
        assertEq(tcr.itemList(0), itemID);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        _approveRemoveCost(requester);
        vm.prank(requester);
        tcr.removeItem(itemID, "");

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        // Re-add the same item; list should not duplicate.
        _approveAddItemCost(requester);
        vm.prank(requester);
        bytes32 itemID2 = tcr.addItem(item);

        assertEq(itemID2, itemID);
        assertEq(tcr.itemCount(), 1);
        assertEq(tcr.itemIDtoIndex(itemID), 0);
        assertEq(tcr.itemList(0), itemID);
    }

}
