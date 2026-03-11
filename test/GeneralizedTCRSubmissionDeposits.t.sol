// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";

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

        function _deployTCRWithStrategy(ISubmissionDepositStrategy strategy)
            internal
            returns (MockGeneralizedTCR tcr, ERC20VotesArbitrator arb)
        {
            MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
            ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

            uint256 nonce = vm.getNonce(address(this));
            address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
            address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

            bytes memory arbInit = _defaultArbitratorInitData(
                owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost
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

        function _approveChallengeSubmissionCost(MockGeneralizedTCR tcr, address who)
            internal
            returns (uint256 challengeCost)
        {
            (,, challengeCost,,) = tcr.getTotalCosts();
            vm.prank(who);
            token.approve(address(tcr), challengeCost);
        }

        function _approveRemoveCost(MockGeneralizedTCR tcr, address who) internal returns (uint256 removeCost) {
            (, removeCost,,,) = tcr.getTotalCosts();
            vm.prank(who);
            token.approve(address(tcr), removeCost);
        }

        function _approveChallengeRemovalCost(MockGeneralizedTCR tcr, address who)
            internal
            returns (uint256 challengeCost)
        {
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

    abstract contract ConcreteGeneralizedTCRSubmissionDepositsBase is GeneralizedTCRSubmissionDepositsBase {
        uint256 internal constant COMMUNITY_REVNET_ID = 77;
        uint256 internal constant DEFAULT_GOAL_ID = 101;

        function _deployConcreteTCRWithStrategy(ISubmissionDepositStrategy strategy)
            internal
            returns (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb)
        {
            return _deployConcreteTCRWithStrategy(IVotes(address(token)), strategy);
        }

        function _deployConcreteTCRWithStrategy(IVotes votingToken_, ISubmissionDepositStrategy strategy)
            internal
            returns (CommunityGoalRegistry tcr, ERC20VotesArbitrator arb)
        {
            SubmissionDepositsMockDirectory directory = new SubmissionDepositsMockDirectory();
            SubmissionDepositsMockTerminal terminal = new SubmissionDepositsMockTerminal();
            GoalDeploymentRegistry goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));

            goalDeploymentRegistry.registerGoal(
                DEFAULT_GOAL_ID,
                address(
                    new SubmissionDepositsMockGoalTreasury(
                        DEFAULT_GOAL_ID,
                        COMMUNITY_REVNET_ID,
                        address(new SubmissionDepositsMockStakeVault(address(votingToken_)))
                    )
                )
            );
            directory.setPrimaryTerminal(DEFAULT_GOAL_ID, address(votingToken_), IJBTerminal(address(terminal)));

            CommunityGoalRegistry tcrImpl = new CommunityGoalRegistry();
            tcr = CommunityGoalRegistry(Clones.clone(address(tcrImpl)));

            ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();
            bytes memory arbInit = _defaultArbitratorInitData(
                owner, address(votingToken_), address(tcr), votingPeriod, votingDelay, revealPeriod, arbitrationCost
            );
            arb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));

            tcr.initialize(
                CommunityGoalRegistry.InitConfig({
                    tcrConfig: IGeneralizedTCRConfig.RegistryConfig({
                        arbitrator: arb,
                        votingToken: votingToken_,
                        submissionDepositStrategy: strategy,
                        registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                            arbitratorExtraData: bytes(""),
                            registrationMetaEvidence: "ipfs://regMeta",
                            clearingMetaEvidence: "ipfs://clearMeta",
                            submissionBaseDeposit: submissionBaseDeposit,
                            removalBaseDeposit: removalBaseDeposit,
                            submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
                            removalChallengeBaseDeposit: removalChallengeBaseDeposit,
                            challengePeriodDuration: challengePeriodDuration
                        })
                    }),
                    directory: IJBDirectory(address(directory)),
                    goalDeploymentRegistry: goalDeploymentRegistry,
                    communityRevnetId: COMMUNITY_REVNET_ID,
                    communityToken: address(votingToken_),
                    owner: owner
                })
            );
        }

        function _defaultCommunityGoalItem() internal pure returns (bytes memory item) {
            item = abi.encode(
                ICommunityGoalRegistry.GoalItemData({goalId: DEFAULT_GOAL_ID, metadataURI: "ipfs://goal"})
            );
        }

        function _approveAddItemCost(CommunityGoalRegistry tcr, address who) internal returns (uint256 addCost) {
            (addCost,,,,) = tcr.getTotalCosts();
            IERC20 communityToken = IERC20(tcr.communityToken());
            vm.prank(who);
            communityToken.approve(address(tcr), addCost);
        }

        function _approveChallengeSubmissionCost(CommunityGoalRegistry tcr, address who)
            internal
            returns (uint256 challengeCost)
        {
            (,, challengeCost,,) = tcr.getTotalCosts();
            IERC20 communityToken = IERC20(tcr.communityToken());
            vm.prank(who);
            communityToken.approve(address(tcr), challengeCost);
        }

        function _approveRemoveCost(CommunityGoalRegistry tcr, address who) internal returns (uint256 removeCost) {
            (, removeCost,,,) = tcr.getTotalCosts();
            IERC20 communityToken = IERC20(tcr.communityToken());
            vm.prank(who);
            communityToken.approve(address(tcr), removeCost);
        }

        function _approveChallengeRemovalCost(CommunityGoalRegistry tcr, address who)
            internal
            returns (uint256 challengeCost)
        {
            (,,, challengeCost,) = tcr.getTotalCosts();
            IERC20 communityToken = IERC20(tcr.communityToken());
            vm.prank(who);
            communityToken.approve(address(tcr), challengeCost);
        }

        function _addItem(CommunityGoalRegistry tcr, address who, bytes memory item) internal returns (bytes32 itemID) {
            _approveAddItemCost(tcr, who);
            vm.prank(who);
            itemID = tcr.addItem(item);
        }

        function _acceptRequest(CommunityGoalRegistry tcr, bytes32 itemID) internal {
            _warpRoll(block.timestamp + challengePeriodDuration + 1);
            tcr.executeRequest(itemID);
        }

        function _disputeAndRule(
            CommunityGoalRegistry tcr,
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
            CommunityGoalRegistry tcr,
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

    contract SubmissionDepositsMockDirectory {
        mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _primaryTerminalOf;

        function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
            _primaryTerminalOf[projectId][token] = terminal;
        }

        function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
            return _primaryTerminalOf[projectId][token];
        }
    }

    contract SubmissionDepositsMockTerminal {}

    contract SubmissionDepositsMockGoalTreasury {
        uint256 public immutable goalRevnetId;
        uint256 public immutable cobuildRevnetId;
        address public immutable stakeVault;

        constructor(uint256 goalRevnetId_, uint256 cobuildRevnetId_, address stakeVault_) {
            goalRevnetId = goalRevnetId_;
            cobuildRevnetId = cobuildRevnetId_;
            stakeVault = stakeVault_;
        }
    }

    contract SubmissionDepositsMockStakeVault {
        IERC20 public immutable cobuildToken;

        constructor(address cobuildToken_) {
            cobuildToken = IERC20(cobuildToken_);
        }
    }
