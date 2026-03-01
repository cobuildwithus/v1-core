// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { TestUtils } from "test/utils/TestUtils.sol";

import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { MockArbitrable } from "test/mocks/MockArbitrable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockGoalTreasuryForArbitratorSlash {
    address public rewardEscrow;

    constructor(address rewardEscrow_) {
        rewardEscrow = rewardEscrow_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }
}

contract MockRewardEscrowRecipient {}

contract MockGoalTreasuryRewardEscrowReverts {
    function rewardEscrow() external pure returns (address) {
        revert("REWARD_ESCROW_READ_FAILED");
    }
}

contract MockStakeVaultForArbitrator {
    struct SlashCall {
        address juror;
        uint256 weightAmount;
        address recipient;
    }

    address public immutable goalTreasury;
    IERC20 public immutable goalToken;
    IERC20 public immutable cobuildToken;

    mapping(address => uint256) public jurorVotes;
    mapping(address => mapping(address => bool)) public operatorAuth;
    address public jurorSlasher;

    SlashCall[] internal _slashCalls;

    constructor(address goalTreasury_, bool sharedStakeToken_) {
        goalTreasury = goalTreasury_;

        MockVotesToken goalToken_ = new MockVotesToken("MockGoalStake", "MGS");
        goalToken_.mint(address(this), 1_000_000e18);
        goalToken = IERC20(address(goalToken_));
        if (sharedStakeToken_) {
            cobuildToken = IERC20(address(goalToken_));
        } else {
            MockVotesToken cobuildToken_ = new MockVotesToken("MockCobuildStake", "MCS");
            cobuildToken_.mint(address(this), 1_000_000e18);
            cobuildToken = IERC20(address(cobuildToken_));
        }
    }

    function setJurorVotes(address juror, uint256 votes) external {
        jurorVotes[juror] = votes;
    }

    function setOperatorAuth(address juror, address operator, bool allowed) external {
        operatorAuth[juror][operator] = allowed;
    }

    function setJurorSlasher(address slasher) external {
        jurorSlasher = slasher;
    }

    function getPastJurorWeight(address juror, uint256) external view returns (uint256) {
        return jurorVotes[juror];
    }

    function isAuthorizedJurorOperator(address juror, address operator) external view returns (bool) {
        return operator == juror || operatorAuth[juror][operator];
    }

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external {
        _slashCalls.push(SlashCall({ juror: juror, weightAmount: weightAmount, recipient: recipient }));
        if (weightAmount == 0) return;

        if (!goalToken.transfer(recipient, weightAmount)) revert("GOAL_TRANSFER_FAILED");
        if (!cobuildToken.transfer(recipient, weightAmount)) revert("COBUILD_TRANSFER_FAILED");
    }

    function slashCallCount() external view returns (uint256) {
        return _slashCalls.length;
    }

    function slashCall(uint256 index) external view returns (SlashCall memory) {
        return _slashCalls[index];
    }
}

contract MockFlowForArbitratorBudgetScope {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract MockBudgetTreasuryForArbitratorBudgetScope {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract MockBudgetStakeLedgerForArbitratorBudgetScope {
    struct Checkpoint {
        uint32 blockNumber;
        uint224 value;
    }

    mapping(address => mapping(address => Checkpoint[])) internal _userBudgetVotes;
    mapping(address => Checkpoint[]) internal _userAllocationWeights;

    function setPastUserAllocatedStakeOnBudget(address account, address budgetTreasury, uint256 votes) external {
        _writeCheckpoint(_userBudgetVotes[account][budgetTreasury], votes);
    }

    function setPastUserAllocationWeight(address account, uint256 weight) external {
        _writeCheckpoint(_userAllocationWeights[account], weight);
    }

    function getPastUserAllocatedStakeOnBudget(
        address account,
        address budgetTreasury,
        uint256 blockNumber
    ) external view returns (uint256) {
        return _lookupCheckpoint(_userBudgetVotes[account][budgetTreasury], blockNumber);
    }

    function getPastUserAllocationWeight(address account, uint256 blockNumber) external view returns (uint256) {
        return _lookupCheckpoint(_userAllocationWeights[account], blockNumber);
    }

    function _writeCheckpoint(Checkpoint[] storage checkpoints, uint256 value) internal {
        uint32 blockNumber = uint32(block.number);
        uint224 boundedValue = uint224(value);
        uint256 len = checkpoints.length;
        if (len != 0 && checkpoints[len - 1].blockNumber == blockNumber) {
            checkpoints[len - 1].value = boundedValue;
            return;
        }

        checkpoints.push(Checkpoint({ blockNumber: blockNumber, value: boundedValue }));
    }

    function _lookupCheckpoint(Checkpoint[] storage checkpoints, uint256 blockNumber) internal view returns (uint256) {
        uint256 len = checkpoints.length;
        while (len != 0) {
            unchecked {
                --len;
            }
            Checkpoint storage checkpoint = checkpoints[len];
            if (checkpoint.blockNumber <= blockNumber) return checkpoint.value;
        }
        return 0;
    }
}

contract MockRewardEscrowWithBudgetStakeLedger {
    address public budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
    }
}

contract MockRewardEscrowBudgetStakeLedgerReadReverts {
    function budgetStakeLedger() external pure returns (address) {
        revert("BUDGET_STAKE_LEDGER_READ_FAILED");
    }
}

contract MockGoalTreasuryForArbitratorBudgetScope {
    address public rewardEscrow;
    address public flow;

    constructor(address rewardEscrow_, address flow_) {
        rewardEscrow = rewardEscrow_;
        flow = flow_;
    }
}

contract MockExternalJurorSlasherForArbitrator {
    struct SlashCall {
        address juror;
        uint256 weightAmount;
        address recipient;
    }

    SlashCall[] internal _slashCalls;

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external {
        _slashCalls.push(SlashCall({ juror: juror, weightAmount: weightAmount, recipient: recipient }));
    }

    function slashCallCount() external view returns (uint256) {
        return _slashCalls.length;
    }

    function slashCall(uint256 index) external view returns (SlashCall memory) {
        return _slashCalls[index];
    }
}

contract MockForwardingJurorSlasherForArbitrator {
    MockStakeVaultForArbitrator public immutable stakeVault;

    constructor(MockStakeVaultForArbitrator stakeVault_) {
        stakeVault = stakeVault_;
    }

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external {
        stakeVault.slashJurorStake(juror, weightAmount, recipient);
    }
}

contract ERC20VotesArbitratorStakeVaultModeTest is TestUtils {
    MockVotesToken internal token;
    MockArbitrable internal arbitrable;
    MockGoalTreasuryForArbitratorSlash internal goalTreasury;
    MockStakeVaultForArbitrator internal stakeVault;
    ERC20VotesArbitrator internal arb;

    address internal owner = makeAddr("owner");
    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");
    address internal relayer = makeAddr("relayer");
    address internal rewardEscrow;

    uint256 internal votingPeriod = 100;
    uint256 internal votingDelay = 10;
    uint256 internal revealPeriod = 25;
    uint256 internal arbitrationCost = 50e18;

    function setUp() public {
        token = new MockVotesToken("MockVotes", "MV");
        arbitrable = new MockArbitrable(IERC20(address(token)));
        rewardEscrow = address(new MockRewardEscrowRecipient());
        goalTreasury = new MockGoalTreasuryForArbitratorSlash(rewardEscrow);
        stakeVault = new MockStakeVaultForArbitrator(address(goalTreasury), false);

        stakeVault.setJurorVotes(voter1, 100e18);
        stakeVault.setJurorVotes(voter2, 200e18);
        stakeVault.setOperatorAuth(voter1, relayer, true);

        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initializeWithStakeVault,
            (
                owner,
                address(token),
                address(arbitrable),
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost,
                address(stakeVault)
            )
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(impl), initData));
        stakeVault.setJurorSlasher(address(new MockForwardingJurorSlasherForArbitrator(stakeVault)));

        arbitrable.setArbitrator(arb);
        token.mint(address(arbitrable), 1_000_000e18);
        arbitrable.approveArbitrator(arbitrationCost * 10);
    }

    function test_commitVoteFor_usesJurorOperatorAuthorizationAndVaultVotingPower() public {
        (uint256 disputeId, uint256 startTime,,,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt = bytes32("salt");
        bytes32 commitHash = _voteHash(arb, disputeId, 0, voter1, 1, "r", salt);

        vm.prank(relayer);
        arb.commitVoteFor(disputeId, voter1, commitHash);

        vm.expectRevert(ERC20VotesArbitrator.UNAUTHORIZED_DELEGATE.selector);
        vm.prank(voter2);
        arb.commitVoteFor(disputeId, voter1, commitHash);
    }

    function test_revealVote_usesStakeVaultSnapshot_notTokenVotes() public {
        (uint256 disputeId, uint256 startTime, uint256 endTime,,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt = bytes32("salt");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt);

        (uint256 power, bool canVote) = arb.votingPowerInCurrentRound(disputeId, voter1);
        assertTrue(canVote);
        assertEq(power, 100e18);
    }

    function test_slashVoter_permissionless_forMissedReveal_andWrongVote() public {
        // Round 1: voter2 misses reveal => slash.
        (uint256 disputeId1, uint256 start1, uint256 end1, uint256 revealEnd1,) = _createDispute();
        _warpRoll(start1 + 1);

        bytes32 s1 = bytes32("s1");
        bytes32 s2 = bytes32("s2");
        vm.prank(voter1);
        arb.commitVote(disputeId1, _voteHash(arb, disputeId1, 0, voter1, 1, "", s1));
        vm.prank(voter2);
        arb.commitVote(disputeId1, _voteHash(arb, disputeId1, 0, voter2, 2, "", s2));

        _warpRoll(end1 + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId1, voter1, 1, "", s1);

        _warpRoll(revealEnd1 + 1);
        arb.slashVoter(disputeId1, 0, voter2);

        uint256 slashWeight1 = (200e18 * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty1 = (slashWeight1 * arb.slashCallerBountyBps()) / 10_000;
        assertEq(stakeVault.slashCallCount(), 2);
        MockStakeVaultForArbitrator.SlashCall memory call1 = stakeVault.slashCall(0);
        assertEq(call1.juror, voter2);
        assertEq(call1.weightAmount, callerBounty1);
        assertEq(call1.recipient, address(this));

        MockStakeVaultForArbitrator.SlashCall memory call2 = stakeVault.slashCall(1);
        assertEq(call2.juror, voter2);
        assertEq(call2.weightAmount, slashWeight1 - callerBounty1);
        assertEq(call2.recipient, address(arb));

        // Idempotent.
        arb.slashVoter(disputeId1, 0, voter2);
        assertEq(stakeVault.slashCallCount(), 2);

        // Round 2: voter1 reveals on losing side => slash.
        (uint256 disputeId2, uint256 start2, uint256 end2, uint256 revealEnd2,) = _createDispute();
        _warpRoll(start2 + 1);

        bytes32 s3 = bytes32("s3");
        bytes32 s4 = bytes32("s4");
        vm.prank(voter1);
        arb.commitVote(disputeId2, _voteHash(arb, disputeId2, 0, voter1, 1, "", s3));
        vm.prank(voter2);
        arb.commitVote(disputeId2, _voteHash(arb, disputeId2, 0, voter2, 2, "", s4));

        _warpRoll(end2 + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId2, voter1, 1, "", s3);
        vm.prank(voter2);
        arb.revealVote(disputeId2, voter2, 2, "", s4);

        _warpRoll(revealEnd2 + 1);
        arb.slashVoter(disputeId2, 0, voter1);

        uint256 slashWeight2 = (100e18 * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty2 = (slashWeight2 * arb.slashCallerBountyBps()) / 10_000;
        assertEq(stakeVault.slashCallCount(), 4);
        MockStakeVaultForArbitrator.SlashCall memory call3 = stakeVault.slashCall(2);
        assertEq(call3.juror, voter1);
        assertEq(call3.weightAmount, callerBounty2);
        assertEq(call3.recipient, address(this));

        MockStakeVaultForArbitrator.SlashCall memory call4 = stakeVault.slashCall(3);
        assertEq(call4.juror, voter1);
        assertEq(call4.weightAmount, slashWeight2 - callerBounty2);
        assertEq(call4.recipient, address(arb));
    }

    function test_slashVoter_routesThroughConfiguredExternalSlasher() public {
        MockExternalJurorSlasherForArbitrator externalSlasher = new MockExternalJurorSlasherForArbitrator();
        stakeVault.setJurorSlasher(address(externalSlasher));

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("external-slash-1");
        bytes32 salt2 = bytes32("external-slash-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);

        _warpRoll(revealEndTime + 1);
        arb.slashVoter(disputeId, 0, voter2);

        uint256 slashWeight = (200e18 * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty = (slashWeight * arb.slashCallerBountyBps()) / 10_000;

        assertEq(stakeVault.slashCallCount(), 0);
        assertEq(externalSlasher.slashCallCount(), 2);

        MockExternalJurorSlasherForArbitrator.SlashCall memory call1 = externalSlasher.slashCall(0);
        assertEq(call1.juror, voter2);
        assertEq(call1.weightAmount, callerBounty);
        assertEq(call1.recipient, address(this));

        MockExternalJurorSlasherForArbitrator.SlashCall memory call2 = externalSlasher.slashCall(1);
        assertEq(call2.juror, voter2);
        assertEq(call2.weightAmount, slashWeight - callerBounty);
        assertEq(call2.recipient, address(arb));
    }

    function test_slashVoter_reverts_whenJurorSlasherNotConfigured() public {
        stakeVault.setJurorSlasher(address(0));

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("no-slasher-1");
        bytes32 salt2 = bytes32("no-slasher-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);

        _warpRoll(revealEndTime + 1);
        vm.expectRevert();
        arb.slashVoter(disputeId, 0, voter2);
    }

    function test_slashVoter_reverts_whenJurorSlasherPointsToArbitrator() public {
        stakeVault.setJurorSlasher(address(arb));

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("self-slasher-1");
        bytes32 salt2 = bytes32("self-slasher-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);

        _warpRoll(revealEndTime + 1);
        vm.expectRevert();
        arb.slashVoter(disputeId, 0, voter2);

        assertFalse(arb.isVoterSlashedOrProcessed(disputeId, 0, voter2));
        assertEq(stakeVault.slashCallCount(), 0);
    }

    function test_slashVoter_noWinnerRound_routesRemainderToInvalidRoundRewardsSink() public {
        address abstainer = makeAddr("abstainer");
        stakeVault.setJurorVotes(voter1, 100e18);
        stakeVault.setJurorVotes(voter2, 100e18);
        stakeVault.setJurorVotes(abstainer, 100e18);

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("tie-route-1");
        bytes32 salt2 = bytes32("tie-route-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", salt2);

        _warpRoll(revealEndTime + 1);
        arb.slashVoter(disputeId, 0, abstainer);

        uint256 slashWeight = (100e18 * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty = (slashWeight * arb.slashCallerBountyBps()) / 10_000;

        assertEq(stakeVault.slashCallCount(), 2);
        MockStakeVaultForArbitrator.SlashCall memory bountyCall = stakeVault.slashCall(0);
        assertEq(bountyCall.juror, abstainer);
        assertEq(bountyCall.weightAmount, callerBounty);
        assertEq(bountyCall.recipient, address(this));

        MockStakeVaultForArbitrator.SlashCall memory sinkCall = stakeVault.slashCall(1);
        assertEq(sinkCall.juror, abstainer);
        assertEq(sinkCall.weightAmount, slashWeight - callerBounty);
        assertEq(sinkCall.recipient, owner);
    }

    function test_slashVoters_batchesAndSkipsProcessed() public {
        address voter3 = makeAddr("voter3");
        stakeVault.setJurorVotes(voter1, 100e18);
        stakeVault.setJurorVotes(voter2, 200e18);
        stakeVault.setJurorVotes(voter3, 150e18);

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("batch-1");
        bytes32 salt2 = bytes32("batch-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);

        _warpRoll(revealEndTime + 1);

        address[] memory voters = new address[](3);
        voters[0] = voter2;
        voters[1] = voter3;
        voters[2] = voter2; // duplicate should be ignored after first processing.
        arb.slashVoters(disputeId, 0, voters);

        assertEq(stakeVault.slashCallCount(), 4);
        assertEq(stakeVault.slashCall(1).recipient, address(arb));
        assertEq(stakeVault.slashCall(3).recipient, address(arb));

        arb.slashVoters(disputeId, 0, voters);
        assertEq(stakeVault.slashCallCount(), 4);
    }

    function test_withdrawVoterRewards_claimsSlashPoolsCumulatively_usingSingleEntryPoint() public {
        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("claim-cumulative-1");
        bytes32 salt2 = bytes32("claim-cumulative-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", salt2);

        _warpRoll(revealEndTime + 1);

        IERC20 goalStakeToken = stakeVault.goalToken();
        IERC20 cobuildStakeToken = stakeVault.cobuildToken();

        uint256 votingBefore = token.balanceOf(voter2);
        uint256 goalBefore = goalStakeToken.balanceOf(voter2);
        uint256 cobuildBefore = cobuildStakeToken.balanceOf(voter2);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(token.balanceOf(voter2) - votingBefore, arbitrationCost);
        assertEq(goalStakeToken.balanceOf(voter2) - goalBefore, 0);
        assertEq(cobuildStakeToken.balanceOf(voter2) - cobuildBefore, 0);

        uint256 slashWeight = (100e18 * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty = (slashWeight * arb.slashCallerBountyBps()) / 10_000;
        uint256 pooledSlashAmount = slashWeight - callerBounty;
        arb.slashVoter(disputeId, 0, voter1);

        uint256 votingBeforeSecond = token.balanceOf(voter2);
        uint256 goalBeforeSecond = goalStakeToken.balanceOf(voter2);
        uint256 cobuildBeforeSecond = cobuildStakeToken.balanceOf(voter2);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(token.balanceOf(voter2) - votingBeforeSecond, 0);
        assertEq(goalStakeToken.balanceOf(voter2) - goalBeforeSecond, pooledSlashAmount);
        assertEq(cobuildStakeToken.balanceOf(voter2) - cobuildBeforeSecond, pooledSlashAmount);

        vm.expectRevert(IERC20VotesArbitrator.REWARD_ALREADY_CLAIMED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
    }

    function test_getVoterRoundStatus_reportsIncrementalSlashClaimability() public {
        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("status-slasher-1");
        bytes32 salt2 = bytes32("status-slasher-2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", salt2);
        _warpRoll(revealEndTime + 1);

        arb.withdrawVoterRewards(disputeId, 0, voter2);

        IERC20VotesArbitrator.VoterRoundStatus memory status = arb.getVoterRoundStatus(disputeId, 0, voter2);
        assertEq(status.claimableReward, 0);
        assertEq(status.claimableGoalSlashReward, 0);
        assertEq(status.claimableCobuildSlashReward, 0);

        uint256 slashWeight = (100e18 * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty = (slashWeight * arb.slashCallerBountyBps()) / 10_000;
        uint256 expectedSlashReward = slashWeight - callerBounty;

        arb.slashVoter(disputeId, 0, voter1);
        status = arb.getVoterRoundStatus(disputeId, 0, voter2);
        assertEq(status.claimableReward, 0);
        assertEq(status.claimableGoalSlashReward, expectedSlashReward);
        assertEq(status.claimableCobuildSlashReward, expectedSlashReward);

        (uint256 goalClaimable, uint256 cobuildClaimable) = arb.getSlashRewardsForRound(disputeId, 0, voter2);
        assertEq(goalClaimable, expectedSlashReward);
        assertEq(cobuildClaimable, expectedSlashReward);

        arb.withdrawVoterRewards(disputeId, 0, voter2);
        status = arb.getVoterRoundStatus(disputeId, 0, voter2);
        assertEq(status.claimableGoalSlashReward, 0);
        assertEq(status.claimableCobuildSlashReward, 0);
    }

    function test_withdrawVoterRewards_sameStakeToken_collapsesIntoSingleSlashPool() public {
        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        MockGoalTreasuryForArbitratorSlash scopedGoalTreasury = new MockGoalTreasuryForArbitratorSlash(rewardEscrow);
        MockStakeVaultForArbitrator sharedTokenStakeVault =
            new MockStakeVaultForArbitrator(address(scopedGoalTreasury), true);
        sharedTokenStakeVault.setJurorVotes(voter1, 100e18);
        sharedTokenStakeVault.setJurorVotes(voter2, 200e18);

        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initializeWithStakeVault,
            (
                owner,
                address(token),
                address(scopedArbitrable),
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost,
                address(sharedTokenStakeVault)
            )
        );
        ERC20VotesArbitrator scopedArb = ERC20VotesArbitrator(_deployProxy(address(impl), initData));
        sharedTokenStakeVault.setJurorSlasher(address(new MockForwardingJurorSlasherForArbitrator(sharedTokenStakeVault)));

        scopedArbitrable.setArbitrator(scopedArb);
        token.mint(address(scopedArbitrable), 1_000_000e18);
        scopedArbitrable.approveArbitrator(arbitrationCost * 10);

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDisputeWith(scopedArbitrable);
        _warpRoll(startTime + 1);

        bytes32 loserSalt = bytes32("same-token-loser");
        bytes32 winnerSalt = bytes32("same-token-winner");
        vm.prank(voter1);
        scopedArb.commitVote(disputeId, _voteHash(scopedArb, disputeId, 0, voter1, 1, "", loserSalt));
        vm.prank(voter2);
        scopedArb.commitVote(disputeId, _voteHash(scopedArb, disputeId, 0, voter2, 2, "", winnerSalt));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        scopedArb.revealVote(disputeId, voter1, 1, "", loserSalt);
        vm.prank(voter2);
        scopedArb.revealVote(disputeId, voter2, 2, "", winnerSalt);
        _warpRoll(revealEndTime + 1);

        scopedArb.withdrawVoterRewards(disputeId, 0, voter2);

        uint256 slashWeight = (100e18 * scopedArb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty = (slashWeight * scopedArb.slashCallerBountyBps()) / 10_000;
        uint256 pooledPerToken = slashWeight - callerBounty;
        uint256 expectedSingleTokenSlashReward = pooledPerToken * 2;

        scopedArb.slashVoter(disputeId, 0, voter1);
        (uint256 goalClaimable, uint256 cobuildClaimable) = scopedArb.getSlashRewardsForRound(disputeId, 0, voter2);
        assertEq(goalClaimable, expectedSingleTokenSlashReward);
        assertEq(cobuildClaimable, 0);

        IERC20 sharedToken = sharedTokenStakeVault.goalToken();
        uint256 sharedTokenBefore = sharedToken.balanceOf(voter2);
        scopedArb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(sharedToken.balanceOf(voter2) - sharedTokenBefore, expectedSingleTokenSlashReward);
    }

    function test_withdrawVoterRewards_distributesSlashPoolsProRataAcrossWinners_andTracksIncrementalClaims() public {
        address loser1 = makeAddr("loser1");
        address loser2 = makeAddr("loser2");
        uint256 loserVotes = 100e18;

        stakeVault.setJurorVotes(voter1, 100e18);
        stakeVault.setJurorVotes(voter2, 300e18);
        stakeVault.setJurorVotes(loser1, loserVotes);
        stakeVault.setJurorVotes(loser2, loserVotes);

        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 winner1Salt = bytes32("pro-rata-winner-1");
        bytes32 winner2Salt = bytes32("pro-rata-winner-2");
        bytes32 loser1Salt = bytes32("pro-rata-loser-1");
        bytes32 loser2Salt = bytes32("pro-rata-loser-2");

        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", winner1Salt));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 1, "", winner2Salt));
        vm.prank(loser1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, loser1, 2, "", loser1Salt));
        vm.prank(loser2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, loser2, 2, "", loser2Salt));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", winner1Salt);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 1, "", winner2Salt);
        vm.prank(loser1);
        arb.revealVote(disputeId, loser1, 2, "", loser1Salt);
        vm.prank(loser2);
        arb.revealVote(disputeId, loser2, 2, "", loser2Salt);

        _warpRoll(revealEndTime + 1);

        // Claim arbitration-cost rewards first, then claim slash rewards as losers are processed.
        uint256 winnerVotes1 = 100e18;
        uint256 winnerVotes2 = 300e18;
        uint256 totalWinningVotes = winnerVotes1 + winnerVotes2;

        uint256 expectedArbReward1 = (winnerVotes1 * arbitrationCost) / totalWinningVotes;
        uint256 expectedArbReward2 = (winnerVotes2 * arbitrationCost) / totalWinningVotes;

        uint256 votingBeforeWinner1 = token.balanceOf(voter1);
        uint256 votingBeforeWinner2 = token.balanceOf(voter2);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(token.balanceOf(voter1) - votingBeforeWinner1, expectedArbReward1);
        assertEq(token.balanceOf(voter2) - votingBeforeWinner2, expectedArbReward2);

        uint256 slashWeight = (loserVotes * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 callerBounty = (slashWeight * arb.slashCallerBountyBps()) / 10_000;
        uint256 pooledPerLoser = slashWeight - callerBounty;

        uint256 expectedSlashReward1PerLoser = (winnerVotes1 * pooledPerLoser) / totalWinningVotes;
        uint256 expectedSlashReward2PerLoser = (winnerVotes2 * pooledPerLoser) / totalWinningVotes;

        IERC20 goalStakeToken = stakeVault.goalToken();
        IERC20 cobuildStakeToken = stakeVault.cobuildToken();

        // First loser slash -> first slash claim delta for both winners.
        arb.slashVoter(disputeId, 0, loser1);

        uint256 goalBeforeWinner1 = goalStakeToken.balanceOf(voter1);
        uint256 cobuildBeforeWinner1 = cobuildStakeToken.balanceOf(voter1);
        uint256 votingBeforeWinner1SlashClaim = token.balanceOf(voter1);
        vm.expectEmit(true, true, true, true, address(arb));
        emit IERC20VotesArbitrator.SlashRewardsWithdrawn(
            disputeId, 0, voter1, expectedSlashReward1PerLoser, expectedSlashReward1PerLoser
        );
        arb.withdrawVoterRewards(disputeId, 0, voter1);
        assertEq(token.balanceOf(voter1) - votingBeforeWinner1SlashClaim, 0);
        assertEq(goalStakeToken.balanceOf(voter1) - goalBeforeWinner1, expectedSlashReward1PerLoser);
        assertEq(cobuildStakeToken.balanceOf(voter1) - cobuildBeforeWinner1, expectedSlashReward1PerLoser);

        uint256 goalBeforeWinner2 = goalStakeToken.balanceOf(voter2);
        uint256 cobuildBeforeWinner2 = cobuildStakeToken.balanceOf(voter2);
        uint256 votingBeforeWinner2SlashClaim = token.balanceOf(voter2);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(token.balanceOf(voter2) - votingBeforeWinner2SlashClaim, 0);
        assertEq(goalStakeToken.balanceOf(voter2) - goalBeforeWinner2, expectedSlashReward2PerLoser);
        assertEq(cobuildStakeToken.balanceOf(voter2) - cobuildBeforeWinner2, expectedSlashReward2PerLoser);

        // Second loser slash -> only incremental deltas should be claimable.
        arb.slashVoter(disputeId, 0, loser2);

        goalBeforeWinner1 = goalStakeToken.balanceOf(voter1);
        cobuildBeforeWinner1 = cobuildStakeToken.balanceOf(voter1);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
        assertEq(goalStakeToken.balanceOf(voter1) - goalBeforeWinner1, expectedSlashReward1PerLoser);
        assertEq(cobuildStakeToken.balanceOf(voter1) - cobuildBeforeWinner1, expectedSlashReward1PerLoser);

        goalBeforeWinner2 = goalStakeToken.balanceOf(voter2);
        cobuildBeforeWinner2 = cobuildStakeToken.balanceOf(voter2);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
        assertEq(goalStakeToken.balanceOf(voter2) - goalBeforeWinner2, expectedSlashReward2PerLoser);
        assertEq(cobuildStakeToken.balanceOf(voter2) - cobuildBeforeWinner2, expectedSlashReward2PerLoser);

        vm.expectRevert(IERC20VotesArbitrator.REWARD_ALREADY_CLAIMED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter1);
        vm.expectRevert(IERC20VotesArbitrator.REWARD_ALREADY_CLAIMED.selector);
        arb.withdrawVoterRewards(disputeId, 0, voter2);
    }

    function test_createDispute_budgetScope_succeeds_whenBudgetLedgerReadReverts() public {
        MockRewardEscrowBudgetStakeLedgerReadReverts rewardEscrowWithRevertingLedger =
            new MockRewardEscrowBudgetStakeLedgerReadReverts();
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithRevertingLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury), false);
        scopedStakeVault.setJurorVotes(voter1, 100e18);
        scopedStakeVault.setJurorVotes(voter2, 200e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );

        vm.roll(block.number + 1);
        (uint256 disputeId,,,, uint256 creationBlock) = _createDisputeWith(scopedArbitrable);
        IERC20VotesArbitrator.VotingRoundInfo memory info = scopedArb.getVotingRoundInfo(disputeId, 0);

        assertEq(info.creationBlock, creationBlock);
    }

    function test_slashVoter_budgetScope_scalesSnapshotVotesByBudgetAllocationShare() public {
        MockBudgetStakeLedgerForArbitratorBudgetScope budgetStakeLedger = new MockBudgetStakeLedgerForArbitratorBudgetScope();
        MockRewardEscrowWithBudgetStakeLedger rewardEscrowWithLedger =
            new MockRewardEscrowWithBudgetStakeLedger(address(budgetStakeLedger));
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury), false);
        scopedStakeVault.setJurorVotes(voter1, 100e18);
        scopedStakeVault.setJurorVotes(voter2, 200e18);

        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 40e18);
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter2, address(budgetTreasury), 200e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 160e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter2, 200e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );
        scopedStakeVault.setJurorSlasher(address(new MockForwardingJurorSlasherForArbitrator(scopedStakeVault)));

        vm.roll(block.number + 1);
        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDisputeWith(scopedArbitrable);
        _warpRoll(startTime + 1);

        bytes32 salt1 = bytes32("budget-scope-v1");
        bytes32 salt2 = bytes32("budget-scope-v2");
        vm.prank(voter1);
        scopedArb.commitVote(disputeId, _voteHash(scopedArb, disputeId, 0, voter1, 1, "", salt1));
        vm.prank(voter2);
        scopedArb.commitVote(disputeId, _voteHash(scopedArb, disputeId, 0, voter2, 2, "", salt2));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        scopedArb.revealVote(disputeId, voter1, 1, "", salt1);
        vm.prank(voter2);
        scopedArb.revealVote(disputeId, voter2, 2, "", salt2);

        (uint256 voterPower, bool canVote) = scopedArb.votingPowerInCurrentRound(disputeId, voter1);
        uint256 expectedSnapshotVotes = 25e18;
        assertTrue(canVote);
        assertEq(voterPower, expectedSnapshotVotes);

        _warpRoll(revealEndTime + 1);
        uint256 expectedSlashWeight = (expectedSnapshotVotes * scopedArb.wrongOrMissedSlashBps()) / 10_000;
        uint256 expectedCallerBounty = (expectedSlashWeight * scopedArb.slashCallerBountyBps()) / 10_000;
        vm.expectEmit(true, true, true, true, address(scopedArb));
        emit ERC20VotesArbitrator.VoterSlashed(
            disputeId,
            0,
            voter1,
            expectedSnapshotVotes,
            expectedSlashWeight,
            false,
            address(scopedArb)
        );
        scopedArb.slashVoter(disputeId, 0, voter1);

        assertEq(scopedStakeVault.slashCallCount(), 2);
        MockStakeVaultForArbitrator.SlashCall memory call1 = scopedStakeVault.slashCall(0);
        assertEq(call1.juror, voter1);
        assertEq(call1.weightAmount, expectedCallerBounty);
        assertEq(call1.recipient, address(this));

        MockStakeVaultForArbitrator.SlashCall memory call2 = scopedStakeVault.slashCall(1);
        assertEq(call2.juror, voter1);
        assertEq(call2.weightAmount, expectedSlashWeight - expectedCallerBounty);
        assertEq(call2.recipient, address(scopedArb));
    }

    function test_votingPower_budgetScope_failClosedCapsSnapshotVotes() public {
        MockBudgetStakeLedgerForArbitratorBudgetScope budgetStakeLedger = new MockBudgetStakeLedgerForArbitratorBudgetScope();
        MockRewardEscrowWithBudgetStakeLedger rewardEscrowWithLedger =
            new MockRewardEscrowWithBudgetStakeLedger(address(budgetStakeLedger));
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury), false);

        scopedStakeVault.setJurorVotes(voter1, 7e18);
        scopedStakeVault.setJurorVotes(voter2, 100e18);

        // voter1: proportional path returns > juror votes, so fail-closed cap must clamp to juror votes.
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 100e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 2e18);

        // voter2: proportional path returns > budget votes, so fail-closed cap must clamp to budget votes.
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter2, address(budgetTreasury), 9e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter2, 2e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );

        vm.roll(block.number + 1);
        (uint256 disputeId,,,,) = _createDisputeWith(scopedArbitrable);
        (uint256 voter1Power, bool voter1CanVote) = scopedArb.votingPowerInCurrentRound(disputeId, voter1);
        (uint256 voter2Power, bool voter2CanVote) = scopedArb.votingPowerInCurrentRound(disputeId, voter2);

        assertTrue(voter1CanVote);
        assertEq(voter1Power, 7e18);
        assertTrue(voter2CanVote);
        assertEq(voter2Power, 9e18);
    }

    function test_votingPower_budgetScope_usesDisputeCreationBlockSnapshots() public {
        MockBudgetStakeLedgerForArbitratorBudgetScope budgetStakeLedger = new MockBudgetStakeLedgerForArbitratorBudgetScope();
        MockRewardEscrowWithBudgetStakeLedger rewardEscrowWithLedger =
            new MockRewardEscrowWithBudgetStakeLedger(address(budgetStakeLedger));
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury), false);
        scopedStakeVault.setJurorVotes(voter1, 100e18);

        // Initial snapshot data prior to dispute creation.
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 40e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 100e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );

        vm.roll(block.number + 1);
        (uint256 disputeId,,,,) = _createDisputeWith(scopedArbitrable);

        // Mutate ledger values in a later block; voting power must still use creation-block snapshots.
        vm.roll(block.number + 1);
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 90e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 100e18);

        (uint256 voterPower, bool canVote) = scopedArb.votingPowerInCurrentRound(disputeId, voter1);
        assertTrue(canVote);
        assertEq(voterPower, 40e18);
    }

    function test_votingPower_budgetScope_sameBlockSnapshotWritesAreExcluded() public {
        MockBudgetStakeLedgerForArbitratorBudgetScope budgetStakeLedger = new MockBudgetStakeLedgerForArbitratorBudgetScope();
        MockRewardEscrowWithBudgetStakeLedger rewardEscrowWithLedger =
            new MockRewardEscrowWithBudgetStakeLedger(address(budgetStakeLedger));
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury), false);
        scopedStakeVault.setJurorVotes(voter1, 100e18);

        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 40e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 100e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );

        // No roll: dispute creation snapshots block.number - 1, so same-block checkpoint writes are excluded.
        (uint256 disputeId,,,,) = _createDisputeWith(scopedArbitrable);

        (uint256 voterPower, bool canVote) = scopedArb.votingPowerInCurrentRound(disputeId, voter1);
        assertEq(voterPower, 0);
        assertFalse(canVote);
    }

    function test_slashVoter_budgetScope_zeroAllocationWeight_marksProcessedWithoutSlash() public {
        MockBudgetStakeLedgerForArbitratorBudgetScope budgetStakeLedger = new MockBudgetStakeLedgerForArbitratorBudgetScope();
        MockRewardEscrowWithBudgetStakeLedger rewardEscrowWithLedger =
            new MockRewardEscrowWithBudgetStakeLedger(address(budgetStakeLedger));
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury), false);
        scopedStakeVault.setJurorVotes(voter1, 100e18);
        scopedStakeVault.setJurorVotes(voter2, 200e18);

        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 40e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 0);
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter2, address(budgetTreasury), 200e18);
        budgetStakeLedger.setPastUserAllocationWeight(voter2, 200e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );
        scopedStakeVault.setJurorSlasher(address(new MockForwardingJurorSlasherForArbitrator(scopedStakeVault)));

        vm.roll(block.number + 1);
        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDisputeWith(scopedArbitrable);
        _warpRoll(startTime + 1);

        bytes32 voter2Salt = bytes32("budget-scope-zero-allocation-v2");
        vm.prank(voter2);
        scopedArb.commitVote(disputeId, _voteHash(scopedArb, disputeId, 0, voter2, 2, "", voter2Salt));

        _warpRoll(endTime + 1);
        vm.prank(voter2);
        scopedArb.revealVote(disputeId, voter2, 2, "", voter2Salt);

        (uint256 voterPower, bool canVote) = scopedArb.votingPowerInCurrentRound(disputeId, voter1);
        assertEq(voterPower, 0);
        assertFalse(canVote);

        _warpRoll(revealEndTime + 1);
        scopedArb.slashVoter(disputeId, 0, voter1);
        assertTrue(scopedArb.isVoterSlashedOrProcessed(disputeId, 0, voter1));
        assertEq(scopedStakeVault.slashCallCount(), 0);

        // Once processed under zero snapshot power, this voter remains non-slashable for the same round.
        budgetStakeLedger.setPastUserAllocationWeight(voter1, 100e18);
        scopedArb.slashVoter(disputeId, 0, voter1);
        assertEq(scopedStakeVault.slashCallCount(), 0);
    }

    function test_slashVoter_doesNotSlash_forTieOrCorrectVote() public {
        // Tie path: equal voting power and opposite reveals.
        stakeVault.setJurorVotes(voter1, 100e18);
        stakeVault.setJurorVotes(voter2, 100e18);
        (uint256 disputeId1, uint256 start1, uint256 end1, uint256 revealEnd1,) = _createDispute();

        _warpRoll(start1 + 1);
        bytes32 s1 = bytes32("tie-v1");
        bytes32 s2 = bytes32("tie-v2");
        vm.prank(voter1);
        arb.commitVote(disputeId1, _voteHash(arb, disputeId1, 0, voter1, 1, "", s1));
        vm.prank(voter2);
        arb.commitVote(disputeId1, _voteHash(arb, disputeId1, 0, voter2, 2, "", s2));

        _warpRoll(end1 + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId1, voter1, 1, "", s1);
        vm.prank(voter2);
        arb.revealVote(disputeId1, voter2, 2, "", s2);

        _warpRoll(revealEnd1 + 1);
        arb.slashVoter(disputeId1, 0, voter1);
        arb.slashVoter(disputeId1, 0, voter2);
        assertEq(stakeVault.slashCallCount(), 0);

        // Correct-vote path: voter1 reveals on winning side.
        stakeVault.setJurorVotes(voter2, 200e18);
        (uint256 disputeId2, uint256 start2, uint256 end2, uint256 revealEnd2,) = _createDispute();

        _warpRoll(start2 + 1);
        bytes32 s3 = bytes32("correct-v1");
        bytes32 s4 = bytes32("correct-v2");
        vm.prank(voter1);
        arb.commitVote(disputeId2, _voteHash(arb, disputeId2, 0, voter1, 2, "", s3));
        vm.prank(voter2);
        arb.commitVote(disputeId2, _voteHash(arb, disputeId2, 0, voter2, 2, "", s4));

        _warpRoll(end2 + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId2, voter1, 2, "", s3);
        vm.prank(voter2);
        arb.revealVote(disputeId2, voter2, 2, "", s4);

        _warpRoll(revealEnd2 + 1);
        arb.slashVoter(disputeId2, 0, voter1);
        assertEq(stakeVault.slashCallCount(), 0);
    }

    function test_slashVoter_snapshotZero_marksProcessedWithoutSlash() public {
        stakeVault.setJurorVotes(voter1, 0);
        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute();

        _warpRoll(start + 1);
        bytes32 salt = bytes32("snapshot-zero");
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", salt));

        _warpRoll(end + 1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", salt);

        _warpRoll(revealEnd + 1);
        arb.slashVoter(disputeId, 0, voter1);
        assertEq(stakeVault.slashCallCount(), 0);

        // If processed flag is set, later vote changes should not allow slashing.
        stakeVault.setJurorVotes(voter1, 100e18);
        arb.slashVoter(disputeId, 0, voter1);
        assertEq(stakeVault.slashCallCount(), 0);
    }

    function test_slashVoter_wrongVoteWithZeroFloor_marksProcessedWithoutVaultSlash() public {
        uint256 snapshotVotes = 199;
        stakeVault.setJurorVotes(voter1, snapshotVotes);
        stakeVault.setJurorVotes(voter2, 1_000_000);

        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute();

        _warpRoll(start + 1);
        bytes32 voter1Salt = bytes32("wrong-zero-v1");
        bytes32 voter2Salt = bytes32("wrong-zero-v2");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", voter1Salt));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", voter2Salt));

        _warpRoll(end + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", voter1Salt);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", voter2Salt);

        _warpRoll(revealEnd + 1);
        uint256 slashCallsBefore = stakeVault.slashCallCount();

        vm.expectEmit(true, true, true, true, address(arb));
        emit ERC20VotesArbitrator.VoterSlashed(disputeId, 0, voter1, snapshotVotes, 0, false, address(arb));
        arb.slashVoter(disputeId, 0, voter1);

        assertTrue(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));
        assertEq(stakeVault.slashCallCount(), slashCallsBefore);

        arb.slashVoter(disputeId, 0, voter1);
        assertEq(stakeVault.slashCallCount(), slashCallsBefore);
    }

    function test_slashVoter_checkpointWeightBoundaries_roundDownAt50Bps() public {
        _assertSlashWeightForSnapshot(199);
        _assertSlashWeightForSnapshot(200);
        _assertSlashWeightForSnapshot(201);
        _assertSlashWeightForSnapshot(1_999);
        _assertSlashWeightForSnapshot(2_000);
        _assertSlashWeightForSnapshot(2_001);
    }

    function testFuzz_slashVoter_checkpointWeightBpsFloor(uint64 snapshotVotesSeed) public {
        uint256 snapshotVotes = bound(uint256(snapshotVotesSeed), 1, 1e18);
        _assertSlashWeightForSnapshot(snapshotVotes);
    }

    function test_initializeWithStakeVaultAndSlashConfig_setsExplicitSlashConfig() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        uint256 customSlashBps = 777;
        uint256 customBountyBps = impl.MAX_SLASH_CALLER_BOUNTY_BPS();

        ERC20VotesArbitrator configured = ERC20VotesArbitrator(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    ERC20VotesArbitrator.initializeWithStakeVaultAndSlashConfig,
                    (
                        owner,
                        address(token),
                        address(arbitrable),
                        votingPeriod,
                        votingDelay,
                        revealPeriod,
                        arbitrationCost,
                        address(stakeVault),
                        customSlashBps,
                        customBountyBps
                    )
                )
            )
        );

        assertEq(configured.stakeVault(), address(stakeVault));
        assertEq(configured.wrongOrMissedSlashBps(), customSlashBps);
        assertEq(configured.slashCallerBountyBps(), customBountyBps);
    }

    function test_initializeWithStakeVaultAndSlashConfig_reverts_on_invalidSlashConfig() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();

        vm.expectRevert(IERC20VotesArbitrator.INVALID_WRONG_OR_MISSED_SLASH_BPS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVaultAndSlashConfig,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    address(stakeVault),
                    10_001,
                    0
                )
            )
        );

        uint256 invalidBountyBps = impl.MAX_SLASH_CALLER_BOUNTY_BPS() + 1;
        vm.expectRevert(IERC20VotesArbitrator.INVALID_SLASH_CALLER_BOUNTY_BPS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVaultAndSlashConfig,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    address(stakeVault),
                    10_000,
                    invalidBountyBps
                )
            )
        );
    }

    function test_initializeWithStakeVault_reverts_on_invalidVaultInputs() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();

        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_ADDRESS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVault,
                (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost, address(0))
            )
        );

        MockStakeVaultForArbitrator badVault = new MockStakeVaultForArbitrator(address(0), false);
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVault,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    address(badVault)
                )
            )
        );

        MockGoalTreasuryRewardEscrowReverts revertingEscrowTreasury = new MockGoalTreasuryRewardEscrowReverts();
        MockStakeVaultForArbitrator revertingEscrowVault = new MockStakeVaultForArbitrator(address(revertingEscrowTreasury), false);
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVault,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    address(revertingEscrowVault)
                )
            )
        );

        MockGoalTreasuryForArbitratorSlash eoaEscrowTreasury =
            new MockGoalTreasuryForArbitratorSlash(makeAddr("eoaRewardEscrow"));
        MockStakeVaultForArbitrator eoaEscrowVault = new MockStakeVaultForArbitrator(address(eoaEscrowTreasury), false);
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_REWARD_ESCROW.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVault,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    address(eoaEscrowVault)
                )
            )
        );

        MockGoalTreasuryForArbitratorSlash emptyEscrowTreasury = new MockGoalTreasuryForArbitratorSlash(address(0));
        MockStakeVaultForArbitrator noEscrowVault = new MockStakeVaultForArbitrator(address(emptyEscrowTreasury), false);
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_REWARD_ESCROW.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVault,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    address(noEscrowVault)
                )
            )
        );
    }

    function test_configureStakeVault_authAndOneTimeSetup() public {
        MockArbitrable arbitrable2 = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator arb2 = _deployTokenModeArbitrator(arbitrable2);
        assertEq(arb2.stakeVault(), address(0));

        vm.expectRevert(IERC20VotesArbitrator.ONLY_ARBITRABLE.selector);
        vm.prank(relayer);
        arb2.configureStakeVault(address(stakeVault));

        vm.prank(address(arbitrable2));
        arb2.configureStakeVault(address(stakeVault));
        assertEq(arb2.stakeVault(), address(stakeVault));

        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.STAKE_VAULT_ALREADY_SET.selector);
        arb2.configureStakeVault(address(stakeVault));

        // Arbitrable can configure when not yet set.
        MockArbitrable arbitrable3 = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator arb3 = _deployTokenModeArbitrator(arbitrable3);
        vm.prank(address(arbitrable3));
        arb3.configureStakeVault(address(stakeVault));
        assertEq(arb3.stakeVault(), address(stakeVault));
    }

    function test_configureStakeVault_reverts_on_invalidVaultInputs() public {
        MockArbitrable arbitrable2 = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator arb2 = _deployTokenModeArbitrator(arbitrable2);

        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_ADDRESS.selector);
        arb2.configureStakeVault(address(0));

        MockStakeVaultForArbitrator badVault = new MockStakeVaultForArbitrator(address(0), false);
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        arb2.configureStakeVault(address(badVault));

        MockGoalTreasuryRewardEscrowReverts revertingEscrowTreasury = new MockGoalTreasuryRewardEscrowReverts();
        MockStakeVaultForArbitrator revertingEscrowVault = new MockStakeVaultForArbitrator(address(revertingEscrowTreasury), false);
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        arb2.configureStakeVault(address(revertingEscrowVault));

        MockGoalTreasuryForArbitratorSlash eoaEscrowTreasury =
            new MockGoalTreasuryForArbitratorSlash(makeAddr("eoaRewardEscrow"));
        MockStakeVaultForArbitrator eoaEscrowVault = new MockStakeVaultForArbitrator(address(eoaEscrowTreasury), false);
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_REWARD_ESCROW.selector);
        arb2.configureStakeVault(address(eoaEscrowVault));

        MockGoalTreasuryForArbitratorSlash emptyEscrowTreasury = new MockGoalTreasuryForArbitratorSlash(address(0));
        MockStakeVaultForArbitrator noEscrowVault = new MockStakeVaultForArbitrator(address(emptyEscrowTreasury), false);
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_REWARD_ESCROW.selector);
        arb2.configureStakeVault(address(noEscrowVault));
    }

    function test_commitVoteFor_and_slashVoter_revert_whenStakeVaultNotConfigured() public {
        MockArbitrable arbitrable2 = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator arb2 = _deployTokenModeArbitrator(arbitrable2);

        (uint256 disputeId, uint256 startTime,,,) = _createDisputeWith(arbitrable2);
        _warpRoll(startTime + 1);

        bytes32 salt = bytes32("no-vault");
        bytes32 commitHash = _voteHash(arb2, disputeId, 0, voter1, 1, "", salt);

        vm.expectRevert(ERC20VotesArbitrator.STAKE_VAULT_NOT_SET.selector);
        vm.prank(relayer);
        arb2.commitVoteFor(disputeId, voter1, commitHash);

        vm.expectRevert(ERC20VotesArbitrator.STAKE_VAULT_NOT_SET.selector);
        arb2.slashVoter(disputeId, 0, voter1);
    }

    function test_initializeWithStakeVault_reverts_whenRewardEscrowMissing() public {
        MockGoalTreasuryForArbitratorSlash emptyEscrowTreasury = new MockGoalTreasuryForArbitratorSlash(address(0));
        MockStakeVaultForArbitrator stakeVault2 = new MockStakeVaultForArbitrator(address(emptyEscrowTreasury), false);
        stakeVault2.setJurorVotes(voter1, 100e18);
        stakeVault2.setJurorVotes(voter2, 200e18);

        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_REWARD_ESCROW.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithStakeVault,
                (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost, address(stakeVault2))
            )
        );
    }

    function test_slashVoter_succeeds_whenRewardEscrowClearedAfterConfiguration() public {
        (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime,) = _createDispute();
        _warpRoll(startTime + 1);

        bytes32 salt = bytes32("missing-escrow-after-init");
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", salt));

        _warpRoll(endTime + 1);
        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, 1, "", salt);

        goalTreasury.setRewardEscrow(address(0));

        _warpRoll(revealEndTime + 1);
        arb.slashVoter(disputeId, 0, voter2);
        assertEq(stakeVault.slashCallCount(), 2);
        MockStakeVaultForArbitrator.SlashCall memory rewardCall = stakeVault.slashCall(1);
        assertEq(rewardCall.recipient, address(arb));

        goalTreasury.setRewardEscrow(makeAddr("eoaRewardEscrow"));
        arb.slashVoter(disputeId, 0, voter2);
        assertEq(stakeVault.slashCallCount(), 2);
    }

    function _assertSlashWeightForSnapshot(uint256 snapshotVotes) internal {
        uint256 expectedSlashWeight = (snapshotVotes * arb.wrongOrMissedSlashBps()) / 10_000;
        uint256 expectedCallerBountyWeight = (expectedSlashWeight * arb.slashCallerBountyBps()) / 10_000;
        uint256 expectedRewardEscrowWeight = expectedSlashWeight - expectedCallerBountyWeight;
        stakeVault.setJurorVotes(voter1, snapshotVotes);
        stakeVault.setJurorVotes(voter2, 1_000_000);

        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute();

        _warpRoll(start + 1);
        bytes32 voter1Salt = keccak256(abi.encodePacked("voter1-snapshot", disputeId, snapshotVotes));
        bytes32 voter2Salt = keccak256(abi.encodePacked("voter2-snapshot", disputeId, snapshotVotes));
        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, 1, "", voter1Salt));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 2, "", voter2Salt));

        _warpRoll(end + 1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 2, "", voter2Salt);

        _warpRoll(revealEnd + 1);

        uint256 slashCallsBefore = stakeVault.slashCallCount();
        vm.expectEmit(true, true, true, true, address(arb));
        emit ERC20VotesArbitrator.VoterSlashed(disputeId, 0, voter1, snapshotVotes, expectedSlashWeight, true, address(arb));
        arb.slashVoter(disputeId, 0, voter1);
        assertTrue(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));

        uint256 slashCallsAfter = stakeVault.slashCallCount();
        if (expectedSlashWeight == 0) {
            assertEq(slashCallsAfter, slashCallsBefore);
        } else {
            uint256 expectedCallIncrease = 0;
            if (expectedCallerBountyWeight != 0) expectedCallIncrease += 1;
            if (expectedRewardEscrowWeight != 0) expectedCallIncrease += 1;

            assertEq(slashCallsAfter, slashCallsBefore + expectedCallIncrease);

            uint256 callIndex = slashCallsBefore;
            if (expectedCallerBountyWeight != 0) {
                MockStakeVaultForArbitrator.SlashCall memory callerBountyCall = stakeVault.slashCall(callIndex);
                assertEq(callerBountyCall.juror, voter1);
                assertEq(callerBountyCall.weightAmount, expectedCallerBountyWeight);
                assertEq(callerBountyCall.recipient, address(this));
                callIndex += 1;
            }
            if (expectedRewardEscrowWeight != 0) {
                MockStakeVaultForArbitrator.SlashCall memory rewardEscrowCall = stakeVault.slashCall(callIndex);
                assertEq(rewardEscrowCall.juror, voter1);
                assertEq(rewardEscrowCall.weightAmount, expectedRewardEscrowWeight);
                assertEq(rewardEscrowCall.recipient, address(arb));
            }
        }

        // Processed voters cannot be slashed twice.
        arb.slashVoter(disputeId, 0, voter1);
        assertEq(stakeVault.slashCallCount(), slashCallsAfter);
    }

    function _createDispute()
        internal
        returns (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime, uint256 creationBlock)
    {
        startTime = block.timestamp + votingDelay;
        endTime = startTime + votingPeriod;
        revealEndTime = endTime + revealPeriod;
        creationBlock = block.number - 1;

        disputeId = arbitrable.createDispute(2, "");
    }

    function _createDisputeWith(
        MockArbitrable arbitrable_
    )
        internal
        returns (uint256 disputeId, uint256 startTime, uint256 endTime, uint256 revealEndTime, uint256 creationBlock)
    {
        startTime = block.timestamp + votingDelay;
        endTime = startTime + votingPeriod;
        revealEndTime = endTime + revealPeriod;
        creationBlock = block.number - 1;

        disputeId = arbitrable_.createDispute(2, "");
    }

    function _deployTokenModeArbitrator(
        MockArbitrable arbitrable_
    ) internal returns (ERC20VotesArbitrator deployed) {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), address(arbitrable_), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        deployed = ERC20VotesArbitrator(_deployProxy(address(impl), initData));
        arbitrable_.setArbitrator(deployed);
        token.mint(address(arbitrable_), 1_000_000e18);
        arbitrable_.approveArbitrator(arbitrationCost * 10);
    }

    function _deployStakeVaultModeArbitrator(
        MockArbitrable arbitrable_,
        address stakeVault_
    ) internal returns (ERC20VotesArbitrator deployed) {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initializeWithStakeVault,
            (owner, address(token), address(arbitrable_), votingPeriod, votingDelay, revealPeriod, arbitrationCost, stakeVault_)
        );
        deployed = ERC20VotesArbitrator(_deployProxy(address(impl), initData));
        arbitrable_.setArbitrator(deployed);
        token.mint(address(arbitrable_), 1_000_000e18);
        arbitrable_.approveArbitrator(arbitrationCost * 10);
    }

    function _deployBudgetScopedArbitrator(
        MockArbitrable arbitrable_,
        address stakeVault_,
        address fixedBudgetTreasury_
    ) internal returns (ERC20VotesArbitrator deployed) {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initializeWithStakeVaultAndBudgetScope,
            (
                owner,
                address(token),
                address(arbitrable_),
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost,
                stakeVault_,
                fixedBudgetTreasury_
            )
        );
        deployed = ERC20VotesArbitrator(_deployProxy(address(impl), initData));
        arbitrable_.setArbitrator(deployed);
        token.mint(address(arbitrable_), 1_000_000e18);
        arbitrable_.approveArbitrator(arbitrationCost * 10);
    }
}
