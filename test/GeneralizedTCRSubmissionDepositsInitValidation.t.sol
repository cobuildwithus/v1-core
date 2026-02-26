// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

import {GeneralizedTCRSubmissionDepositsBase} from "test/GeneralizedTCRSubmissionDeposits.t.sol";
import {MockGeneralizedTCR} from "test/mocks/MockGeneralizedTCR.sol";
import {MockSubmissionDepositStrategy} from "test/mocks/MockSubmissionDepositStrategy.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";

contract GeneralizedTCRSubmissionDepositsInitValidationTest is GeneralizedTCRSubmissionDepositsBase {
    function test_init_reverts_when_strategy_has_no_code() public {
        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
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

        address noCode = makeAddr("noCode");
        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                arb,
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
                ISubmissionDepositStrategy(noCode)
            )
        );
        vm.expectRevert(IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_STRATEGY.selector);
        _deployProxy(address(tcrImpl), tcrInit);
    }

    function test_init_reverts_when_strategy_token_mismatch() public {
        MockVotesToken otherToken = new MockVotesToken("Other", "OTH");
        MockSubmissionDepositStrategy strategy = new MockSubmissionDepositStrategy(otherToken);

        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
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
                "reg",
                "clear",
                governor,
                IVotes(address(token)),
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                ISubmissionDepositStrategy(strategy)
            )
        );
        vm.expectRevert(IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_STRATEGY.selector);
        _deployProxy(address(tcrImpl), tcrInit);
    }
}
