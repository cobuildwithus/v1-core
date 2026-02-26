// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

import {
    GasGriefSubmissionDepositStrategy,
    GeneralizedTCRSubmissionDepositsBase,
    MockGeneralizedTCRHookMutatesManager
} from "test/GeneralizedTCRSubmissionDeposits.t.sol";
import {MockFeeOnTransferVotesToken} from "test/mocks/MockFeeOnTransferVotesToken.sol";
import {MockGeneralizedTCR} from "test/mocks/MockGeneralizedTCR.sol";
import {MockSubmissionDepositStrategy} from "test/mocks/MockSubmissionDepositStrategy.sol";
import {MockVotesArbitrator} from "test/mocks/MockVotesArbitrator.sol";

contract GeneralizedTCRSubmissionDepositsHardeningTest is GeneralizedTCRSubmissionDepositsBase {
    function test_executeRequest_with_gas_grief_strategy_reverts_fail_closed() public {
        GasGriefSubmissionDepositStrategy strategy = new GasGriefSubmissionDepositStrategy(token);
        (MockGeneralizedTCR tcr,) = _deployTCRWithStrategy(strategy);

        bytes32 itemID = _addItem(tcr, requester, abi.encodePacked("item"));
        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        vm.expectRevert();
        tcr.executeRequest{gas: 200_000}(itemID);
        assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
    }

    function test_executeRequest_does_not_brick_when_hook_mutates_manager() public {
        EscrowSubmissionDepositStrategy strategy = new EscrowSubmissionDepositStrategy(token);

        MockGeneralizedTCRHookMutatesManager tcrImpl = new MockGeneralizedTCRHookMutatesManager();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        ERC20VotesArbitrator arb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(arb), arbProxyAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                arb,
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
                strategy
            )
        );
        MockGeneralizedTCRHookMutatesManager tcr = MockGeneralizedTCRHookMutatesManager(
            _deployProxy(address(tcrImpl), tcrInit)
        );
        assertEq(address(tcr), tcrProxyAddr);

        bytes32 itemID = _addItem(tcr, requester, abi.encodePacked("item"));
        _warpRoll(block.timestamp + challengePeriodDuration + 1);

        tcr.executeRequest(itemID);
        assertEq(tcr.submissionDeposits(itemID), submissionBaseDeposit);
    }

    function test_submission_deposit_already_set_reverts() public {
        MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(token);
        (MockGeneralizedTCR tcr,) = _deployTCRWithStrategy(strategy);

        bytes memory item = abi.encodePacked("item");
        bytes32 itemID = keccak256(item);
        tcr.exposedSetSubmissionDeposit(itemID, submissionBaseDeposit);

        _approveAddItemCost(tcr, requester);
        vm.prank(requester);
        vm.expectRevert(IGeneralizedTCR.SUBMISSION_DEPOSIT_ALREADY_SET.selector);
        tcr.addItem(item);
    }

    function test_submission_deposit_transfer_incomplete_reverts_with_fee_token() public {
        MockFeeOnTransferVotesToken feeToken =
            new MockFeeOnTransferVotesToken("FeeToken", "FEE", 1_000, makeAddr("feeRecipient"));
        feeToken.mint(requester, 1_000_000e18);

        MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(feeToken);

        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();

        uint256 nonce = vm.getNonce(address(this));
        address arbAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        MockVotesArbitrator arb = new MockVotesArbitrator(feeToken, tcrProxyAddr);
        assertEq(address(arb), arbAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                IArbitrator(address(arb)),
                bytes(""),
                "reg",
                "clear",
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

        uint256 addCost = submissionBaseDeposit;
        vm.prank(requester);
        feeToken.approve(address(feeTcr), addCost);

        vm.prank(requester);
        vm.expectRevert(IGeneralizedTCR.SUBMISSION_DEPOSIT_TRANSFER_INCOMPLETE.selector);
        feeTcr.addItem(abi.encodePacked("fee-item"));
    }
}
