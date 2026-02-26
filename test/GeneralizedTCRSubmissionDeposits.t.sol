// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

import {MockGeneralizedTCR} from "test/mocks/MockGeneralizedTCR.sol";
import {MockVotesToken} from "test/mocks/MockVotesToken.sol";

contract GasGriefSubmissionDepositStrategy is ISubmissionDepositStrategy {
    IERC20 public immutable override token;

    constructor(IERC20 token_) {
        token = token_;
    }

    function getSubmissionDepositAction(
        bytes32,
        IGeneralizedTCR.Status,
        IArbitrable.Party,
        address,
        address,
        address,
        uint256
    ) external view override returns (DepositAction action, address recipient) {
        uint256 target = gasleft() / 64;
        uint256 i = 0;
        while (gasleft() > target) {
            unchecked {
                i++;
            }
        }
        if (i == type(uint256).max) {
            return (DepositAction.Hold, address(0));
        }
        action = DepositAction.Hold;
        recipient = address(0);
    }
}

contract MockGeneralizedTCRHookMutatesManager is MockGeneralizedTCR {
    function _onItemRegistered(bytes32 itemID, bytes memory data) internal override {
        items[itemID].manager = address(0);
        items[itemID].status = Status.Absent;
        super._onItemRegistered(itemID, data);
    }
}

abstract contract GeneralizedTCRSubmissionDepositsBase is TestUtils {
    MockVotesToken internal token;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
    address internal requester = makeAddr("requester");
    address internal challenger = makeAddr("challenger");
    address internal remover = makeAddr("remover");
    address internal prizePool = makeAddr("prizePool");

    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");

    uint256 internal votingPeriod = 20;
    uint256 internal votingDelay = 2;
    uint256 internal revealPeriod = 15;
    uint256 internal arbitrationCost = 10e18;

    uint256 internal submissionBaseDeposit = 100e18;
    uint256 internal removalBaseDeposit = 50e18;
    uint256 internal submissionChallengeBaseDeposit = 120e18;
    uint256 internal removalChallengeBaseDeposit = 70e18;
    uint256 internal challengePeriodDuration = 3 days;

    function setUp() public virtual {
        token = new MockVotesToken("MockVotes", "MV");

        token.mint(requester, 1_000_000e18);
        token.mint(challenger, 1_000_000e18);
        token.mint(remover, 1_000_000e18);

        token.mint(voter1, 100e18);
        token.mint(voter2, 100e18);

        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);

        vm.roll(block.number + 1);
    }

    function _deployTCRWithStrategy(
        ISubmissionDepositStrategy strategy
    ) internal returns (MockGeneralizedTCR tcr, ERC20VotesArbitrator arb) {
        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
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
        tcr = MockGeneralizedTCR(_deployProxy(address(tcrImpl), tcrInit));
        assertEq(address(tcr), tcrProxyAddr);
    }

    function _approveAddItemCost(MockGeneralizedTCR tcr, address who) internal returns (uint256 addCost) {
        (addCost,,,,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), addCost);
    }

    function _approveChallengeSubmissionCost(
        MockGeneralizedTCR tcr,
        address who
    ) internal returns (uint256 challengeCost) {
        (, , challengeCost,,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), challengeCost);
    }

    function _approveRemoveCost(MockGeneralizedTCR tcr, address who) internal returns (uint256 removeCost) {
        (, removeCost,,,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), removeCost);
    }

    function _approveChallengeRemovalCost(
        MockGeneralizedTCR tcr,
        address who
    ) internal returns (uint256 challengeCost) {
        (,,, challengeCost,) = tcr.getTotalCosts();
        vm.prank(who);
        token.approve(address(tcr), challengeCost);
    }

    function _addItem(MockGeneralizedTCR tcr, address who, bytes memory item) internal returns (bytes32 itemID) {
        _approveAddItemCost(tcr, who);
        vm.prank(who);
        itemID = tcr.addItem(item);
    }

    function _acceptRequest(MockGeneralizedTCR tcr, bytes32 itemID) internal {
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID);
    }

    function _disputeAndRule(
        MockGeneralizedTCR tcr,
        ERC20VotesArbitrator arb,
        bytes32 itemID,
        address challengeActor,
        uint256 disputeId,
        uint256 choice1,
        uint256 choice2
    ) internal {
        _approveChallengeSubmissionCost(tcr, challengeActor);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challengeActor);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 sa = bytes32("sa");
        bytes32 sb = bytes32("sb");
        _commitRevealTwoVotes(arb, disputeId, start, end, voter1, choice1, sa, "", voter2, choice2, sb, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);
    }

    function _disputeRemovalAndRule(
        MockGeneralizedTCR tcr,
        ERC20VotesArbitrator arb,
        bytes32 itemID,
        address challengeActor,
        uint256 disputeId,
        uint256 choice1,
        uint256 choice2
    ) internal {
        _approveChallengeRemovalCost(tcr, challengeActor);
        uint256 disputeCreationTs = block.timestamp;
        vm.prank(challengeActor);
        tcr.challengeRequest(itemID, "");

        (uint256 start, uint256 end, uint256 revealEnd) = _scheduleVoting(arb, disputeCreationTs);
        bytes32 sa = bytes32("sa");
        bytes32 sb = bytes32("sb");
        _commitRevealTwoVotes(arb, disputeId, start, end, voter1, choice1, sa, "", voter2, choice2, sb, "");

        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);
    }
}
