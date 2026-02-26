// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

contract GeneralizedTCRTokenTransferEdgeCasesTest is GeneralizedTCRTestBase {
    function test_executeRequest_does_not_revert_with_reverting_token_and_withdraw_is_noop_when_reward_zero() public {
        MockRevertingERC20 badToken = new MockRevertingERC20();
        ISubmissionDepositStrategy strategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(badToken))))
        );
        uint256 nonce = vm.getNonce(address(this));
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 2);
        MockVotesArbitrator badArb = new MockVotesArbitrator(IVotes(address(badToken)), tcrProxyAddr);
        MockGeneralizedTCR impl = new MockGeneralizedTCR();

        bytes memory initData = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                IArbitrator(address(badArb)),
                bytes(""),
                "reg",
                "clear",
                governor,
                IVotes(address(badToken)),
                1,
                1,
                1,
                1,
                1 days,
                strategy
            )
        );
        MockGeneralizedTCR badTcr = MockGeneralizedTCR(_deployProxy(address(impl), initData));
        assertEq(address(badTcr), tcrProxyAddr);

        address user = makeAddr("user");
        badToken.mint(user, 10);

        vm.prank(user);
        badToken.approve(address(badTcr), 10);

        vm.prank(user);
        bytes32 itemID = badTcr.addItem(abi.encodePacked("item"));

        _warpRoll(block.timestamp + 1 days + 1);

        badTcr.executeRequest(itemID);

        uint256 userBefore = badToken.balanceOf(user);
        badTcr.withdrawFeesAndRewards(user, itemID, 0, 0);
        assertEq(badToken.balanceOf(user), userBefore);
    }

    function test_withdrawFeesAndRewards_skips_transfer_on_zero_reward() public {
        MockRevertingERC20 badToken = new MockRevertingERC20();
        ISubmissionDepositStrategy strategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(badToken))))
        );
        uint256 nonce = vm.getNonce(address(this));
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 2);
        MockVotesArbitrator badArb = new MockVotesArbitrator(IVotes(address(badToken)), tcrProxyAddr);
        MockGeneralizedTCR impl = new MockGeneralizedTCR();

        bytes memory initData = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                IArbitrator(address(badArb)),
                bytes(""),
                "reg",
                "clear",
                governor,
                IVotes(address(badToken)),
                1,
                1,
                1,
                1,
                1 days,
                strategy
            )
        );
        MockGeneralizedTCR badTcr = MockGeneralizedTCR(_deployProxy(address(impl), initData));
        assertEq(address(badTcr), tcrProxyAddr);

        address user = makeAddr("user");
        address nonContributor = makeAddr("nonContributor");
        badToken.mint(user, 10);

        vm.prank(user);
        badToken.approve(address(badTcr), 10);

        vm.prank(user);
        bytes32 itemID = badTcr.addItem(abi.encodePacked("item"));

        _warpRoll(block.timestamp + 1 days + 1);

        badTcr.executeRequest(itemID);

        // Non-contributor should have zero reward; transfer should be skipped.
        badTcr.withdrawFeesAndRewards(nonContributor, itemID, 0, 0);
    }

    function test_addItem_reverts_with_fee_on_transfer_token() public {
        MockFeeOnTransferVotesToken feeToken =
            new MockFeeOnTransferVotesToken("FeeToken", "FEE", 1000, makeAddr("feeRecipient"));
        address feeRequester = makeAddr("feeRequester");
        feeToken.mint(feeRequester, 1_000_000e18);
        ISubmissionDepositStrategy strategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(feeToken))))
        );

        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(feeToken), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        ERC20VotesArbitrator feeArb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(feeArb), arbProxyAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                feeArb,
                bytes(""),
                "ipfs://regMeta",
                "ipfs://clearMeta",
                governor,
                IVotes(address(feeToken)),
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                strategy
            )
        );
        MockGeneralizedTCR feeTcr = MockGeneralizedTCR(_deployProxy(address(tcrImpl), tcrInit));
        assertEq(address(feeTcr), tcrProxyAddr);

        uint256 addCost = submissionBaseDeposit + arbitrationCost;
        vm.prank(feeRequester);
        feeToken.approve(address(feeTcr), addCost);

        vm.prank(feeRequester);
        vm.expectRevert(IGeneralizedTCR.MUST_FULLY_FUND_YOUR_SIDE.selector);
        feeTcr.addItem(abi.encodePacked("fee-item"));
    }

    function test_challengeRequest_reverts_with_selective_fee_token() public {
        MockSelectiveFeeVotesToken feeToken =
            new MockSelectiveFeeVotesToken("SelFee", "SFE", 1000, makeAddr("feeRecipient"));
        address feeRequester = makeAddr("feeRequester");
        address feeChallenger = makeAddr("feeChallenger");
        feeToken.mint(feeRequester, 1_000_000e18);
        feeToken.mint(feeChallenger, 1_000_000e18);
        ISubmissionDepositStrategy strategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(feeToken))))
        );

        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(feeToken), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        ERC20VotesArbitrator feeArb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(feeArb), arbProxyAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                feeArb,
                bytes(""),
                "ipfs://regMeta",
                "ipfs://clearMeta",
                governor,
                IVotes(address(feeToken)),
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                strategy
            )
        );
        MockGeneralizedTCR feeTcr = MockGeneralizedTCR(_deployProxy(address(tcrImpl), tcrInit));
        assertEq(address(feeTcr), tcrProxyAddr);

        feeToken.setFeeFrom(feeChallenger);

        uint256 addCost = submissionBaseDeposit + arbitrationCost;
        vm.prank(feeRequester);
        feeToken.approve(address(feeTcr), addCost);
        vm.prank(feeRequester);
        bytes32 itemID = feeTcr.addItem(abi.encodePacked("fee-item-challenge"));

        uint256 challengeCost = submissionChallengeBaseDeposit + arbitrationCost;
        vm.prank(feeChallenger);
        feeToken.approve(address(feeTcr), challengeCost);

        vm.prank(feeChallenger);
        vm.expectRevert(IGeneralizedTCR.MUST_FULLY_FUND_YOUR_SIDE.selector);
        feeTcr.challengeRequest(itemID, "");
    }

}
