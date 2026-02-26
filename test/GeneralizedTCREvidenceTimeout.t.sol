// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { MockGeneralizedTCR } from "test/mocks/MockGeneralizedTCR.sol";
import { MockVotesArbitrator } from "test/mocks/MockVotesArbitrator.sol";

contract MockInvalidRulingVotesArbitratorWithTimeout is IERC20VotesArbitrator {
    IVotes internal immutable _token;
    address public arbitrable;

    constructor(IVotes token_, address arbitrable_) {
        _token = token_;
        arbitrable = arbitrable_;
    }

    function votingToken() external view returns (IVotes token) {
        return _token;
    }

    function initialize(address, address, address, uint256, uint256, uint256, uint256) external pure {}

    function initializeWithSlashConfig(address, address, address, uint256, uint256, uint256, uint256, uint256, uint256)
        external
        pure
    { }

    function initializeWithStakeVaultAndSlashConfig(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256,
        uint256
    ) external pure {}

    function initializeWithStakeVault(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address
    ) external pure {}

    function createDispute(uint256, bytes calldata) external view returns (uint256) {
        if (msg.sender != arbitrable) revert ONLY_ARBITRABLE();
        return 1;
    }

    function arbitrationCost(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function disputeStatus(uint256) external pure returns (DisputeStatus) {
        return DisputeStatus.Solved;
    }

    function currentRuling(uint256) external pure returns (IArbitrable.Party) {
        return IArbitrable.Party(uint256(3));
    }

    function getVotingRoundInfo(uint256, uint256) external pure returns (VotingRoundInfo memory info) {
        info.state = 0;
    }

    function getVoterRoundStatus(uint256, uint256, address) external pure returns (VoterRoundStatus memory status) {
        status.hasCommitted = false;
    }

    function isVoterSlashedOrProcessed(uint256, uint256, address) external pure returns (bool) {
        return false;
    }

    function computeCommitHash(
        uint256,
        uint256,
        address,
        uint256,
        string calldata,
        bytes32
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function getArbitratorParamsForFactory() external pure returns (ArbitratorParams memory) {
        return ArbitratorParams({
            votingPeriod: 1,
            votingDelay: 1,
            revealPeriod: 1,
            arbitrationCost: 0,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });
    }
}

contract GeneralizedTCREvidenceTimeoutTest is GeneralizedTCRTestBase {
    using stdStorage for StdStorage;

    function test_submitEvidence_reverts_when_resolved_and_works_when_pending() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-10");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        // evidence allowed while pending
        vm.prank(requester);
        tcr.submitEvidence(itemID, "ipfs://more");

        // resolve request
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);

        vm.expectRevert(IGeneralizedTCR.DISPUTE_MUST_NOT_BE_RESOLVED.selector);
        vm.prank(requester);
        tcr.submitEvidence(itemID, "ipfs://nope");
    }

    function test_submitEvidence_reverts_when_no_request() public {
        bytes32 fake = keccak256("no-request");
        vm.expectRevert(IGeneralizedTCR.MUST_BE_A_REQUEST.selector);
        tcr.submitEvidence(fake, "ipfs://evidence");
    }

    function test_executeRequestTimeout_reverts_when_no_request() public {
        bytes32 fake = keccak256("no-request-timeout");
        vm.expectRevert(IGeneralizedTCR.MUST_BE_A_REQUEST.selector);
        tcr.executeRequestTimeout(fake);
    }

    function test_executeRequestTimeout_reverts_when_not_disputed() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-none");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        vm.expectRevert(IGeneralizedTCR.REQUEST_MUST_BE_DISPUTED.selector);
        tcr.executeRequestTimeout(itemID);
    }

    function test_executeRequestTimeout_reverts_when_timeout_disabled() public {
        uint256 nonce = vm.getNonce(address(this));
        // _deployTcrWithArbitrator deploys an implementation then a proxy.
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 2);
        MockVotesArbitrator zeroTimeoutArb = new MockVotesArbitrator(IVotes(address(token)), tcrProxyAddr);
        MockGeneralizedTCR localTcr = _deployTcrWithArbitrator(IArbitrator(address(zeroTimeoutArb)));
        assertEq(address(localTcr), tcrProxyAddr);
        assertEq(localTcr.disputeTimeout(), 0);

        (uint256 addCost,,,,) = localTcr.getTotalCosts();
        vm.prank(requester);
        token.approve(address(localTcr), addCost);
        bytes memory item = abi.encodePacked("item-timeout-disabled");
        vm.prank(requester);
        bytes32 itemID = localTcr.addItem(item);

        (, , uint256 challengeCost,,) = localTcr.getTotalCosts();
        vm.prank(challenger);
        token.approve(address(localTcr), challengeCost);
        vm.prank(challenger);
        localTcr.challengeRequest(itemID, "");

        vm.expectRevert(IGeneralizedTCR.DISPUTE_TIMEOUT_DISABLED.selector);
        localTcr.executeRequestTimeout(itemID);
    }

    function test_executeRequestTimeout_uses_snapshot_disputeTimeout() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-snapshot-timeout");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            IArbitrator requestArbitratorBefore,
            bytes memory requestArbitratorExtraDataBefore,
            uint256 requestMetaEvidenceIDBefore
        ) = tcr.getRequestInfo(itemID, 0);
        assertEq(address(requestArbitratorBefore), address(tcr.arbitrator()));

        MockVotesArbitrator newArb = new MockVotesArbitrator(IVotes(address(token)), address(tcr));
        vm.prank(governor);
        (bool success, bytes memory revertData) = address(tcr).call(
            abi.encodeWithSignature("setArbitrator(address,bytes)", address(newArb), bytes(""))
        );
        assertFalse(success);
        assertEq(revertData.length, 0);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            IArbitrator requestArbitratorAfter,
            bytes memory requestArbitratorExtraDataAfter,
            uint256 requestMetaEvidenceIDAfter
        ) = tcr.getRequestInfo(itemID, 0);
        assertEq(address(requestArbitratorAfter), address(requestArbitratorBefore));
        assertEq(requestArbitratorExtraDataAfter, requestArbitratorExtraDataBefore);
        assertEq(requestMetaEvidenceIDAfter, requestMetaEvidenceIDBefore);

        (, , uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        (, uint256 snapshotChallengePeriod, uint256 snapshotDisputeTimeout,,) = tcr.getRequestSnapshot(itemID, 0);
        assertGt(snapshotDisputeTimeout, 0);
        assertEq(snapshotDisputeTimeout, tcr.disputeTimeout());
        uint256 timeoutAt = submissionTime + snapshotChallengePeriod + snapshotDisputeTimeout + 1;
        if (timeoutAt <= revealEnd + 1) {
            timeoutAt = revealEnd + 1;
        }
        _warpRoll(timeoutAt);

        tcr.executeRequestTimeout(itemID);

        (, , , bool resolved, , , , , ,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(resolved);
    }

    function test_executeRequestTimeout_uses_request_snapshot_when_global_storage_changes() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-snapshot-global-mutate");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (, uint256 snapshotChallengePeriod, uint256 snapshotDisputeTimeout,,) = tcr.getRequestSnapshot(itemID, 0);
        (, , uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);

        uint256 bumpedChallengePeriod = snapshotChallengePeriod + 10 days;
        // Simulate a runtime/global mutation and ensure timeout checks still use request snapshot data.
        stdstore
            .target(address(tcr))
            .sig(tcr.challengePeriodDuration.selector)
            .checked_write(bumpedChallengePeriod);
        assertEq(tcr.challengePeriodDuration(), bumpedChallengePeriod);

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        uint256 timeoutAt = submissionTime + snapshotChallengePeriod + snapshotDisputeTimeout + 1;
        if (timeoutAt <= revealEnd + 1) {
            timeoutAt = revealEnd + 1;
        }
        _warpRoll(timeoutAt);

        tcr.executeRequestTimeout(itemID);

        (, , , bool resolved, , , , , ,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(resolved);
    }

    function test_executeRequestTimeout_avoids_overflow_on_large_params() public {
        _warpRoll(type(uint256).max - 40);

        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-overflow");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        vm.expectRevert(IGeneralizedTCR.DISPUTE_TIMEOUT_NOT_PASSED.selector);
        tcr.executeRequestTimeout(itemID);
    }

    function test_executeRequestTimeout_reverts_when_request_already_resolved() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-resolved");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, 1, start, end, voter1, 1, s1, "", voter2, 2, s2, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(1);

        vm.expectRevert(IGeneralizedTCR.REQUEST_MUST_NOT_BE_RESOLVED.selector);
        tcr.executeRequestTimeout(itemID);
    }

    function test_executeRequestTimeout_resolves_after_timeout() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        vm.expectRevert(IGeneralizedTCR.DISPUTE_TIMEOUT_NOT_PASSED.selector);
        tcr.executeRequestTimeout(itemID);

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        _warpRoll(submissionTime + challengePeriodDuration + tcr.disputeTimeout() + 1);

        tcr.executeRequestTimeout(itemID);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));

        (, , , bool resolved, , , , , ,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(resolved);
    }

    function test_executeRequestTimeout_uses_current_ruling() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-ruling");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        _commitRevealTwoVotes(arb, 1, start, end, voter1, 1, s1, "", voter2, 2, s2, "");

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        uint256 timeoutAt = submissionTime + challengePeriodDuration + tcr.disputeTimeout() + 1;
        if (timeoutAt <= revealEnd + 1) {
            timeoutAt = revealEnd + 1;
        }
        _warpRoll(timeoutAt);

        tcr.executeRequestTimeout(itemID);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));

        (, , , bool resolved, , , IArbitrable.Party ruling, , ,) = tcr.getRequestInfo(itemID, 0);
        assertTrue(resolved);
        assertEq(uint256(ruling), uint256(IArbitrable.Party.Requester));
    }

    function test_executeRequestTimeout_reverts_on_invalid_ruling() public {
        uint256 nonce = vm.getNonce(address(this));
        // _deployTcrWithArbitrator deploys an implementation then a proxy.
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 2);
        MockInvalidRulingVotesArbitratorWithTimeout badArb = new MockInvalidRulingVotesArbitratorWithTimeout(
            IVotes(address(token)),
            tcrProxyAddr
        );
        MockGeneralizedTCR localTcr = _deployTcrWithArbitrator(IArbitrator(address(badArb)));
        assertEq(address(localTcr), tcrProxyAddr);

        (uint256 addCost,,,,) = localTcr.getTotalCosts();
        vm.prank(requester);
        token.approve(address(localTcr), addCost);

        bytes memory item = abi.encodePacked("item-timeout-invalid-ruling");
        vm.prank(requester);
        bytes32 itemID = localTcr.addItem(item);

        (, , uint256 challengeCost,,) = localTcr.getTotalCosts();
        vm.prank(challenger);
        token.approve(address(localTcr), challengeCost);

        vm.prank(challenger);
        localTcr.challengeRequest(itemID, "");

        (, , uint256 submissionTime, , , , , , ,) = localTcr.getRequestInfo(itemID, 0);
        _warpRoll(submissionTime + localTcr.challengePeriodDuration() + localTcr.disputeTimeout() + 1);

        vm.expectRevert(IGeneralizedTCR.INVALID_RULING_OPTION.selector);
        localTcr.executeRequestTimeout(itemID);
    }

    function test_executeRequestTimeout_reverts_when_arbitrator_not_solved() public {
        vm.startPrank(address(tcr));
        arb.setVotingDelay(2 days);
        arb.setVotingPeriod(2 days);
        vm.stopPrank();

        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-unsolved");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        _warpRoll(submissionTime + tcr.challengePeriodDuration() + tcr.disputeTimeout() + 1);

        vm.expectRevert(IGeneralizedTCR.DISPUTE_NOT_SOLVED.selector);
        tcr.executeRequestTimeout(itemID);
    }

    function test_timeout_clears_mapping_and_old_dispute_cannot_affect_new_request() public {
        _approveAddItemCost(requester);
        bytes memory item = abi.encodePacked("item-timeout-stale");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        _approveChallengeSubmissionCost(challenger);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challenger);
        tcr.challengeRequest(itemID, "");

        (, , uint256 submissionTime, , , , , , ,) = tcr.getRequestInfo(itemID, 0);
        (, , uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);

        uint256 timeoutAt = submissionTime + challengePeriodDuration + tcr.disputeTimeout() + 1;
        uint256 warpTo = timeoutAt > revealEnd + 1 ? timeoutAt : revealEnd + 1;
        _warpRoll(warpTo);

        tcr.executeRequestTimeout(itemID);
        assertEq(tcr.arbitratorDisputeIDToItem(address(arb), 1), bytes32(0));

        _approveAddItemCost(requester);
        vm.prank(requester);
        tcr.addItem(item);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.RegistrationRequested));

        vm.expectRevert(abi.encodeWithSelector(IGeneralizedTCR.NO_REQUESTS_FOR_ITEM.selector, bytes32(0)));
        arb.executeRuling(1);

        (, IGeneralizedTCR.Status statusAfter,) = tcr.getItemInfo(itemID);
        assertEq(uint256(statusAfter), uint256(IGeneralizedTCR.Status.RegistrationRequested));
    }

    function _deployTcrWithArbitrator(IArbitrator arbitrator_) internal returns (MockGeneralizedTCR localTcr) {
        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                arbitrator_,
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
        localTcr = MockGeneralizedTCR(_deployProxy(address(tcrImpl), tcrInit));
    }

}
