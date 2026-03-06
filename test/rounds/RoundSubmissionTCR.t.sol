// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { RoundTestArbitrator } from "test/rounds/helpers/RoundTestMocks.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract RoundSubmissionTCRTest is Test {
    MockVotesToken internal token;
    RoundSubmissionTCR internal tcr;
    EscrowSubmissionDepositStrategy internal depositStrategy;
    RoundTestArbitrator internal arbitrator;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant CHALLENGE_PERIOD = 7 days;
    uint256 internal constant SUBMISSION_DEPOSIT = 1e18;
    bytes32 internal constant DEFAULT_POST_ID = bytes32("post");

    function setUp() public {
        token = new MockVotesToken("Goal", "GOAL");
        depositStrategy = new EscrowSubmissionDepositStrategy(token);

        RoundSubmissionTCR implementation = new RoundSubmissionTCR();
        tcr = RoundSubmissionTCR(Clones.clone(address(implementation)));

        arbitrator = new RoundTestArbitrator(IVotes(address(token)), address(tcr), 1, 1, 1, ARBITRATION_COST);

        RoundSubmissionTCR.RoundConfig memory roundCfg =
            _roundConfig(keccak256("round"), uint64(block.timestamp), uint64(block.timestamp + 30 days));
        IGeneralizedTCRConfig.RegistryConfig memory regCfg = _registryConfig(arbitrator, SUBMISSION_DEPOSIT);

        tcr.initialize(roundCfg, regCfg);

        token.mint(alice, 1000e18);
        vm.prank(alice);
        token.approve(address(tcr), type(uint256).max);
        token.mint(bob, 1000e18);
        vm.prank(bob);
        token.approve(address(tcr), type(uint256).max);
    }

    function _encode(uint8 source, bytes32 postId, address recipient) internal pure returns (bytes memory) {
        return abi.encode(source, postId, recipient);
    }

    function _assertAcceptsAt(uint256 timestamp) internal {
        vm.warp(timestamp);
        bytes memory item = _encode(0, DEFAULT_POST_ID, alice);

        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);
        assertTrue(itemId != bytes32(0));
    }

    function _roundConfig(
        bytes32 roundId,
        uint64 startAt,
        uint64 endAt
    ) internal pure returns (RoundSubmissionTCR.RoundConfig memory cfg) {
        cfg = RoundSubmissionTCR.RoundConfig({ roundId: roundId, startAt: startAt, endAt: endAt, prizeVault: address(0) });
    }

    function _registryConfig(
        RoundTestArbitrator arbitrator_,
        uint256 submissionBaseDeposit
    ) internal view returns (IGeneralizedTCRConfig.RegistryConfig memory cfg) {
        cfg = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: arbitrator_,
            votingToken: IVotes(address(token)),
            submissionDepositStrategy: depositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                submissionBaseDeposit: submissionBaseDeposit,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: CHALLENGE_PERIOD
            })
        });
    }

    function test_initialize_revertsOnInvalidTimeWindow() public {
        RoundSubmissionTCR implementation = new RoundSubmissionTCR();
        RoundSubmissionTCR tcr2 = RoundSubmissionTCR(Clones.clone(address(implementation)));
        RoundTestArbitrator arb2 = new RoundTestArbitrator(IVotes(address(token)), address(tcr2), 1, 1, 1, ARBITRATION_COST);

        RoundSubmissionTCR.RoundConfig memory roundCfg = _roundConfig(bytes32("id"), 100, 99);
        IGeneralizedTCRConfig.RegistryConfig memory regCfg = _registryConfig(arb2, 0);

        vm.expectRevert(abi.encodeWithSelector(RoundSubmissionTCR.INVALID_TIME_WINDOW.selector, uint64(100), uint64(99)));
        tcr2.initialize(roundCfg, regCfg);
    }

    function test_verifyItemData_rejectsWrongLength() public {
        bytes memory bad = abi.encode(uint8(0));
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr.addItem(bad);
    }

    function test_verifyItemData_rejectsZeroPostId() public {
        bytes memory item = _encode(0, bytes32(0), alice);
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr.addItem(item);
    }

    function test_verifyItemData_rejectsZeroRecipient() public {
        bytes memory item = _encode(0, DEFAULT_POST_ID, address(0));
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr.addItem(item);
    }

    function test_verifyItemData_rejectsBeforeStartAt() public {
        uint256 startAt = uint256(tcr.startAt());
        vm.warp(startAt == 0 ? 0 : startAt - 1);

        bytes memory item = _encode(0, DEFAULT_POST_ID, alice);
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr.addItem(item);
    }

    function test_verifyItemData_rejectsAfterEndAt() public {
        vm.warp(uint256(tcr.endAt()) + 1);

        bytes memory item = _encode(0, DEFAULT_POST_ID, alice);
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr.addItem(item);
    }

    function test_verifyItemData_acceptsAtExactStartAt() public {
        _assertAcceptsAt(uint256(tcr.startAt()));
    }

    function test_verifyItemData_acceptsAtExactEndAt() public {
        _assertAcceptsAt(uint256(tcr.endAt()));
    }

    function test_verifyItemData_singleTimestampWindow_semantics() public {
        RoundSubmissionTCR implementation = new RoundSubmissionTCR();
        RoundSubmissionTCR tcr2 = RoundSubmissionTCR(Clones.clone(address(implementation)));
        RoundTestArbitrator arb2 = new RoundTestArbitrator(IVotes(address(token)), address(tcr2), 1, 1, 1, ARBITRATION_COST);

        uint64 exactTs = 1000;
        tcr2.initialize(_roundConfig(bytes32("single-ts"), exactTs, exactTs), _registryConfig(arb2, 0));
        vm.prank(alice);
        token.approve(address(tcr2), type(uint256).max);

        bytes memory item = _encode(0, DEFAULT_POST_ID, alice);

        vm.warp(uint256(exactTs) - 1);
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr2.addItem(item);

        vm.warp(uint256(exactTs));
        vm.prank(alice);
        tcr2.addItem(item);

        vm.warp(uint256(exactTs) + 1);
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr2.addItem(_encode(0, bytes32("new-post"), alice));
    }

    function test_constructItemId_isKeccakSourceAndPostId() public {
        bytes32 postId = keccak256("hello");
        bytes memory item = _encode(7, postId, alice);
        bytes32 expected = keccak256(abi.encodePacked(uint8(7), postId));

        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);
        assertEq(itemId, expected);
    }

    function test_decodeEncodeRoundTrip() public {
        RoundSubmissionTCR.Submission memory submission =
            RoundSubmissionTCR.Submission({ source: 3, postId: bytes32("abc"), recipient: alice });

        bytes memory encoded = tcr.encodeSubmission(submission);
        RoundSubmissionTCR.Submission memory decoded = tcr.decodeSubmission(encoded);

        assertEq(decoded.source, submission.source);
        assertEq(decoded.postId, submission.postId);
        assertEq(decoded.recipient, submission.recipient);
    }

    function test_itemManagerAndStatus_usesPayloadRecipient_notRequester() public {
        bytes memory item = _encode(0, DEFAULT_POST_ID, alice);

        vm.prank(bob);
        bytes32 itemId = tcr.addItem(item);

        (address managerBefore, IGeneralizedTCR.Status statusBefore) = tcr.itemManagerAndStatus(itemId);
        assertEq(managerBefore, alice);
        assertEq(uint256(statusBefore), uint256(IGeneralizedTCR.Status.RegistrationRequested));

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        (address managerAfter, IGeneralizedTCR.Status statusAfter) = tcr.itemManagerAndStatus(itemId);
        assertEq(managerAfter, alice);
        assertEq(uint256(statusAfter), uint256(IGeneralizedTCR.Status.Registered));
    }

    function test_itemManagerAndData_updateWhenReAddedAfterRemoval() public {
        bytes memory initial = _encode(0, DEFAULT_POST_ID, alice);
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(initial);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        vm.prank(alice);
        tcr.removeItem(itemId, "");
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        bytes memory corrected = _encode(0, DEFAULT_POST_ID, bob);
        vm.prank(alice);
        bytes32 readdedId = tcr.addItem(corrected);
        assertEq(readdedId, itemId);

        (bytes memory storedData, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemId);
        assertEq(keccak256(storedData), keccak256(corrected));
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.RegistrationRequested));

        (address managerAfter,) = tcr.itemManagerAndStatus(itemId);
        assertEq(managerAfter, bob);
    }

    function test_verifyItemData_allowsReAddAfterEndAt_onlyForExistingItem() public {
        bytes memory existingItem = _encode(0, DEFAULT_POST_ID, alice);
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(existingItem);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        vm.prank(alice);
        tcr.removeItem(itemId, "");
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        vm.warp(uint256(tcr.endAt()) + 1);

        vm.prank(alice);
        bytes32 readdId = tcr.addItem(existingItem);
        assertEq(readdId, itemId);

        bytes memory newItemAfterEnd = _encode(0, bytes32("new-post"), alice);
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        tcr.addItem(newItemAfterEnd);
    }

    function test_verifyItemData_allowsRecipientCorrectionAfterEndAt() public {
        bytes memory originalItem = _encode(0, DEFAULT_POST_ID, bob);
        vm.prank(bob);
        bytes32 itemId = tcr.addItem(originalItem);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        vm.prank(bob);
        tcr.removeItem(itemId, "");
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        vm.warp(uint256(tcr.endAt()) + 1);

        bytes memory correctedItem = _encode(0, DEFAULT_POST_ID, alice);
        vm.prank(alice);
        bytes32 readdId = tcr.addItem(correctedItem);
        assertEq(readdId, itemId);

        (bytes memory storedData, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemId);
        assertEq(keccak256(storedData), keccak256(correctedItem));
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.RegistrationRequested));

        (address manager,) = tcr.itemManagerAndStatus(itemId);
        assertEq(manager, alice);
    }

    function test_copyCalldataFrontRun_cannotHijackManager() public {
        bytes memory item = _encode(0, DEFAULT_POST_ID, alice);

        vm.prank(bob);
        bytes32 itemId = tcr.addItem(item);

        (address manager, IGeneralizedTCR.Status status) = tcr.itemManagerAndStatus(itemId);
        assertEq(manager, alice);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.RegistrationRequested));
    }

    function test_addItem_revertsOnDuplicateAfterRegistered() public {
        bytes memory item = _encode(1, DEFAULT_POST_ID, alice);

        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        tcr.executeRequest(itemId);

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.MUST_BE_ABSENT_TO_BE_ADDED.selector);
        tcr.addItem(item);
    }
}
