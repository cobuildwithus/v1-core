// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";
import {
    MockNonERC20Votes,
    MockVotesToken6Decimals
} from "test/mocks/MockIncompatibleVotesToken.sol";

contract GeneralizedTCRInitSubmissionTest is GeneralizedTCRTestBase {
    function test_init_reverts_on_zero_addresses_and_token_mismatch() public {
        // 1) ADDRESS_ZERO on arbitrator
        {
            MockGeneralizedTCR impl = new MockGeneralizedTCR();
            vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        IArbitrator(address(0)),
                        bytes(""),
                        "reg",
                        "clear",
                        governor,
                        IVotes(address(token)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }

        // 1b) ADDRESS_ZERO on erc20
        {
            MockGeneralizedTCR impl = new MockGeneralizedTCR();
            vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        arb,
                        bytes(""),
                        "reg",
                        "clear",
                        governor,
                        IVotes(address(0)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }

        // 1c) ADDRESS_ZERO on governor
        {
            MockGeneralizedTCR impl = new MockGeneralizedTCR();
            vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        arb,
                        bytes(""),
                        "reg",
                        "clear",
                        address(0),
                        IVotes(address(token)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }

        // 2) ARBITRATOR_TOKEN_MISMATCH via no votingToken() implementation
        {
            MockArbitratorNoVotingToken bad = new MockArbitratorNoVotingToken();
            MockGeneralizedTCR impl = new MockGeneralizedTCR();
            vm.expectRevert(IGeneralizedTCR.ARBITRATOR_TOKEN_MISMATCH.selector);
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        IArbitrator(address(bad)),
                        bytes(""),
                        "reg",
                        "clear",
                        governor,
                        IVotes(address(token)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }

        // 3) ARBITRATOR_TOKEN_MISMATCH via mismatched token
        {
            MockVotesToken other = new MockVotesToken("Other", "OTH");
            MockMismatchedVotesArbitrator mismatched = new MockMismatchedVotesArbitrator(other);
            MockGeneralizedTCR impl = new MockGeneralizedTCR();

            vm.expectRevert(IGeneralizedTCR.ARBITRATOR_TOKEN_MISMATCH.selector);
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        mismatched,
                        bytes(""),
                        "reg",
                        "clear",
                        governor,
                        IVotes(address(token)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }
    }

    function test_init_reverts_on_incompatible_voting_tokens() public {
        // Non-ERC20 IVotes implementation.
        {
            MockGeneralizedTCR impl = new MockGeneralizedTCR();
            MockNonERC20Votes nonErc20Votes = new MockNonERC20Votes();
            uint256 nonce = vm.getNonce(address(this));
            address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);
            MockVotesArbitrator localArb = new MockVotesArbitrator(IVotes(address(nonErc20Votes)), tcrProxyAddr);

            vm.expectRevert(IGeneralizedTCR.INVALID_VOTING_TOKEN_COMPATIBILITY.selector);
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        IArbitrator(address(localArb)),
                        bytes(""),
                        "reg",
                        "clear",
                        governor,
                        IVotes(address(nonErc20Votes)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }

        // 18-decimal arbitration cost assumptions require 18-decimal voting token units.
        {
            MockGeneralizedTCR impl = new MockGeneralizedTCR();
            MockVotesToken6Decimals token6 = new MockVotesToken6Decimals("Six Decimals Votes", "SIX");
            uint256 nonce = vm.getNonce(address(this));
            address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);
            MockVotesArbitrator localArb = new MockVotesArbitrator(IVotes(address(token6)), tcrProxyAddr);

            vm.expectRevert(abi.encodeWithSelector(IGeneralizedTCR.INVALID_VOTING_TOKEN_DECIMALS.selector, 6));
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    MockGeneralizedTCR.initialize,
                    (
                        owner,
                        IArbitrator(address(localArb)),
                        bytes(""),
                        "reg",
                        "clear",
                        governor,
                        IVotes(address(token6)),
                        submissionBaseDeposit,
                        removalBaseDeposit,
                        submissionChallengeBaseDeposit,
                        removalChallengeBaseDeposit,
                        challengePeriodDuration,
                        defaultSubmissionDepositStrategy
                    )
                )
            );
        }
    }

    function test_addItem_invalid_item_data_reverts() public {
        _approveAddItemCost(requester);

        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        vm.prank(requester);
        tcr.addItem("");
    }

    function test_addItem_then_add_again_reverts_must_be_absent() public {
        _approveAddItemCost(requester);

        bytes memory item = abi.encodePacked("item-1");
        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);

        vm.expectRevert(IGeneralizedTCR.MUST_BE_ABSENT_TO_BE_ADDED.selector);
        vm.prank(requester);
        tcr.addItem(item);

        (, IGeneralizedTCR.Status status, uint256 reqLen) = tcr.getItemInfo(itemID);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.RegistrationRequested));
        assertEq(reqLen, 1);
    }

    function test_addItem_happyPath_transfers_deposit_and_sets_state() public {
        uint256 addCost = _approveAddItemCost(requester);

        bytes memory item = abi.encodePacked("item-xyz");
        bytes32 expectedID = keccak256(item);

        vm.prank(requester);
        bytes32 itemID = tcr.addItem(item);
        assertEq(itemID, expectedID);

        assertEq(token.balanceOf(address(tcr)), addCost);
        assertEq(tcr.itemCount(), 1);

        (bytes memory data, IGeneralizedTCR.Status status, uint256 reqCount) = tcr.getItemInfo(itemID);
        assertEq(keccak256(data), keccak256(item));
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.RegistrationRequested));
        assertEq(reqCount, 1);

        (bool disputed, uint256 disputeID,, bool resolved, address[3] memory parties,, , , , uint256 metaEvidenceID) =
            tcr.getRequestInfo(itemID, 0);
        assertFalse(disputed);
        assertEq(disputeID, 0);
        assertFalse(resolved);
        assertEq(parties[uint256(IArbitrable.Party.Requester)], requester);
        assertEq(metaEvidenceID, 0);

        (uint256[3] memory amountPaid, bool[3] memory hasPaid, uint256 feeRewards) = tcr.getRoundInfo(itemID, 0, 0);
        assertEq(amountPaid[uint256(IArbitrable.Party.Requester)], arbitrationCost);
        assertTrue(hasPaid[uint256(IArbitrable.Party.Requester)]);
        assertEq(feeRewards, arbitrationCost);
    }

    function test_contribute_pulls_from_contributor_not_sender() public {
        address payer = makeAddr("payer");
        address contributor = makeAddr("contributor");

        token.mint(contributor, 100e18);
        vm.prank(contributor);
        token.approve(address(tcr), 100e18);

        vm.prank(payer);
        uint256 contributed = tcr.exposedContribute(contributor, 60e18, 60e18);

        assertEq(contributed, 60e18);
        assertEq(token.balanceOf(address(tcr)), 60e18);
        assertEq(token.balanceOf(contributor), 40e18);
        assertEq(tcr.exposedContribution(contributor), 60e18);
    }

}
