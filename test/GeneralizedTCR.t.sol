// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {MockGeneralizedTCR} from "test/mocks/MockGeneralizedTCR.sol";
import {
    MockArbitratorNoVotingToken,
    MockMismatchedVotesArbitrator,
    MockInvalidRulingVotesArbitrator
} from "test/mocks/MockBadArbitrators.sol";
import {MockFeeOnTransferVotesToken} from "test/mocks/MockFeeOnTransferVotesToken.sol";
import {MockSelectiveFeeVotesToken} from "test/mocks/MockSelectiveFeeVotesToken.sol";
import {MockRevertingERC20} from "test/mocks/MockRevertingERC20.sol";
import {MockVotesArbitrator} from "test/mocks/MockVotesArbitrator.sol";

/// @dev Upgrade mock used for upgrade authorization test.
contract MockGeneralizedTCRUpgradeMock is MockGeneralizedTCR {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockGeneralizedTCRHookOrder is MockGeneralizedTCR {
    error HOOK_STATUS_NOT_SET();

    function _onItemRegistered(bytes32 itemID, bytes memory data) internal override {
        if (items[itemID].status != Status.Registered) revert HOOK_STATUS_NOT_SET();
        super._onItemRegistered(itemID, data);
    }

    function _onItemRemoved(bytes32 itemID) internal override {
        if (items[itemID].status != Status.Absent) revert HOOK_STATUS_NOT_SET();
        super._onItemRemoved(itemID);
    }
}

contract MockGeneralizedTCRDisputeIdHarness is MockGeneralizedTCR {
    function setRequestDisputeId(bytes32 itemID, uint256 requestIndex, uint256 newDisputeId) external {
        items[itemID].requests[requestIndex].disputeID = newDisputeId;
    }
}

abstract contract GeneralizedTCRTestBase is TestUtils {
    MockVotesToken internal token;

    ERC20VotesArbitrator internal arb;
    MockGeneralizedTCR internal tcr;
    ISubmissionDepositStrategy internal defaultSubmissionDepositStrategy;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
    address internal requester = makeAddr("requester");
    address internal challenger = makeAddr("challenger");

    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");

    // Arbitrator params
    uint256 internal votingPeriod = 20;
    uint256 internal votingDelay = 2;
    uint256 internal revealPeriod = 15;
    uint256 internal arbitrationCost = 10e18;

    // TCR params
    uint256 internal submissionBaseDeposit = 100e18;
    uint256 internal removalBaseDeposit = 50e18;
    uint256 internal submissionChallengeBaseDeposit = 120e18;
    uint256 internal removalChallengeBaseDeposit = 70e18;
    uint256 internal challengePeriodDuration = 3 days;

    function setUp() public virtual {
        token = new MockVotesToken("MockVotes", "MV");
        defaultSubmissionDepositStrategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(IERC20(address(token))))
        );

        // Fund actors.
        token.mint(requester, 1_000_000e18);
        token.mint(challenger, 1_000_000e18);

        token.mint(voter1, 250e18);
        token.mint(voter2, 100e18);

        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);

        vm.roll(block.number + 1);

        // Deploy implementations first.
        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        // Break cyclic init by precomputing proxy addresses.
        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        // Deploy arbitrator proxy first, initialized with arbitrable = future tcr proxy address.
        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(arb), arbProxyAddr);

        // Deploy tcr proxy, referencing the already-initialized arbitrator proxy.
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
                defaultSubmissionDepositStrategy
            )
        );
        tcr = MockGeneralizedTCR(_deployProxy(address(tcrImpl), tcrInit));
        assertEq(address(tcr), tcrProxyAddr);
    }

    function _approveAddItemCost(address who) internal returns (uint256 addCost) {
        (addCost,,,,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), addCost);
    }

    function _approveChallengeSubmissionCost(address who) internal returns (uint256 challengeCost) {
        (, , challengeCost,,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), challengeCost);
    }

    function _approveRemoveCost(address who) internal returns (uint256 removeCost) {
        (, removeCost,,,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), removeCost);
    }

    function _approveChallengeRemovalCost(address who) internal returns (uint256 challengeRemoveCost) {
        (,,, challengeRemoveCost,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), challengeRemoveCost);
    }
}
