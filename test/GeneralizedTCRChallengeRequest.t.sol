// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";

contract GeneralizedTCRChallengeRequestTest is GeneralizedTCRTestBase {
    using stdStorage for StdStorage;

    function test_challengeRequest_reverts_without_pending_request_or_outside_time_limit() public {
        bytes32 fake = keccak256("nope");
        vm.expectRevert(IGeneralizedTCR.ITEM_MUST_HAVE_PENDING_REQUEST.selector);
        tcr.challengeRequest(fake, "");

        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-5");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        vm.expectRevert(IGeneralizedTCR.CHALLENGE_MUST_BE_WITHIN_TIME_LIMIT.selector);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");
    }

    function test_challengeRequest_uses_deploy_time_challengePeriodDuration() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-snapshot-challenge");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        _warpRoll(submissionTime + challengePeriodDuration);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (bool disputed,,,,,,,,,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(disputed);

        _warpRoll(submissionTime + challengePeriodDuration + 1);
        vm.expectRevert(IGeneralizedTCR.CHALLENGE_MUST_BE_WITHIN_TIME_LIMIT.selector);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");
    }

    function test_challengeRequest_uses_request_snapshot_when_global_storage_changes() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-snapshot-global-mutate");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        (, uint256 snapshotChallengePeriod,,,) = tcr.getRequestSnapshot(itemID, 0);
        assertEq(snapshotChallengePeriod, challengePeriodDuration);

        // Simulate a runtime/global mutation and ensure challenge checks still use request snapshot data.
        stdstore.target(address(tcr)).sig(tcr.challengePeriodDuration.selector).checked_write(1);
        assertEq(tcr.challengePeriodDuration(), 1);

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        _warpRoll(submissionTime + 2);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (bool disputed,,,,,,,,,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(disputed);
    }

    function test_challengeRequest_success_creates_dispute_and_adjusts_round_feeRewards() public {
        uint256 addCost = _approveAddItemCost(requester);

        bytes memory item = abi.encodePacked("item-6");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        uint256 challengeCost = _approveChallengeSubmissionCost(challenger);

        uint256 tcrBalBefore = token.balanceOf(address(tcr));
        assertEq(tcrBalBefore, addCost);

        uint256 arbBalBefore = token.balanceOf(address(arb));

        // challenge (creates dispute)
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "ipfs://challenge");

        // dispute created in arbitrator
        assertEq(arb.disputeCount(), 1);
        assertEq(tcr.arbitratorDisputeIDToItem(address(arb), 1), itemID);

        // arbitrator took exactly arbitrationCost from TCR
        assertEq(token.balanceOf(address(arb)) - arbBalBefore, arbitrationCost);

        // TCR balance: requester addCost + challenger challengeCost - arbitrationCost
        assertEq(token.balanceOf(address(tcr)), addCost + challengeCost - arbitrationCost);

        // feeRewards should have arbitrationCost removed once
        (uint256[3] memory amountPaid,, uint256 feeRewards) = tcr.getRoundInfo(itemID, 0, 0);
        assertEq(amountPaid[uint256(IArbitrable.Party.Requester)], arbitrationCost);
        assertEq(amountPaid[uint256(IArbitrable.Party.Challenger)], challengeCost);
        assertEq(feeRewards, challengeCost);

        // second challenge should revert REQUEST_ALREADY_DISPUTED
        vm.expectRevert(IGeneralizedTCR.REQUEST_ALREADY_DISPUTED.selector);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");
    }

    function test_challengeRequest_uses_snapshot_arbitrationCost_when_cost_changes() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-snapshot-cost");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        (, , , , , , , IArbitrator requestArbitrator, bytes memory requestExtraData,) =
            tcr.getRequestInfo(itemID, 0);
        assertEq(requestArbitrator.arbitrationCost(requestExtraData), arbitrationCost);

        vm.prank(address(tcr));
        arb.setArbitrationCost(arbitrationCost * 2);
        assertEq(requestArbitrator.arbitrationCost(requestExtraData), arbitrationCost);

        _approveChallengeSubmissionCost(challenger);
        uint256 arbBalBefore = token.balanceOf(address(arb));

        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        assertEq(token.balanceOf(address(arb)) - arbBalBefore, arbitrationCost);
    }

    function test_challengeRequest_resets_arbitrator_allowance() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-allowance");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        // Seed a pre-existing allowance to verify it doesn't linger after dispute creation.
        uint256 seedAllowance = 123;
        vm.prank(address(tcr));
        token.approve(address(arb), seedAllowance);
        assertEq(token.allowance(address(tcr), address(arb)), seedAllowance);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        assertEq(token.allowance(address(tcr), address(arb)), 0);
    }

    function test_challengeRequest_emits_disputed_status_change() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-disputed-event");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);

        vm.expectEmit(true, true, true, true, address(tcr));
        emit IGeneralizedTCR.ItemStatusChange(
            itemID,
            0,
            0,
            true,
            false,
            IGeneralizedTCR.Status.RegistrationRequested
        );

        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");
    }

    function test_executeRequest_reverts_when_request_is_disputed() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-disputed");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        vm.expectRevert(IGeneralizedTCR.REQUEST_MUST_NOT_BE_DISPUTED.selector);
        tcr.executeRequest(itemID);
    }

    function test_executeRequest_uses_request_snapshot_when_global_storage_changes() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-exec-snapshot-global-mutate");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        (, uint256 snapshotChallengePeriod,,,) = tcr.getRequestSnapshot(itemID, 0);
        uint256 bumpedChallengePeriod = snapshotChallengePeriod + 10 days;

        // Simulate a runtime/global mutation and ensure execution checks still use request snapshot data.
        stdstore
            .target(address(tcr))
            .sig(tcr.challengePeriodDuration.selector)
            .checked_write(bumpedChallengePeriod);
        assertEq(tcr.challengePeriodDuration(), bumpedChallengePeriod);

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        _warpRoll(submissionTime + snapshotChallengePeriod + 1);

        tcr.executeRequest(itemID);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));

        (, , , bool resolved, , , , , ,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(resolved);
    }

}
