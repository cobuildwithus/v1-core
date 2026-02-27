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

    mapping(address => uint256) public jurorVotes;
    uint256 public totalJurorVotes;
    mapping(address => mapping(address => bool)) public operatorAuth;
    address public jurorSlasher;

    SlashCall[] internal _slashCalls;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }

    function setJurorVotes(address juror, uint256 votes) external {
        totalJurorVotes = totalJurorVotes - jurorVotes[juror] + votes;
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

    function getPastTotalJurorWeight(uint256) external view returns (uint256) {
        return totalJurorVotes;
    }

    function isAuthorizedJurorOperator(address juror, address operator) external view returns (bool) {
        return operator == juror || operatorAuth[juror][operator];
    }

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
    mapping(address => mapping(address => uint256)) internal _userBudgetVotes;
    mapping(address => uint256) internal _budgetTotals;

    function setPastUserAllocatedStakeOnBudget(address account, address budgetTreasury, uint256 votes) external {
        _userBudgetVotes[account][budgetTreasury] = votes;
    }

    function setPastBudgetTotalAllocatedStake(address budgetTreasury, uint256 votes) external {
        _budgetTotals[budgetTreasury] = votes;
    }

    function getPastUserAllocatedStakeOnBudget(
        address account,
        address budgetTreasury,
        uint256
    ) external view returns (uint256) {
        return _userBudgetVotes[account][budgetTreasury];
    }

    function getPastBudgetTotalAllocatedStake(address budgetTreasury, uint256) external view returns (uint256) {
        return _budgetTotals[budgetTreasury];
    }
}

contract MockRewardEscrowWithBudgetStakeLedger {
    address public budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
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
        stakeVault = new MockStakeVaultForArbitrator(address(goalTreasury));

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
        stakeVault.setJurorSlasher(address(arb));

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
        assertEq(call2.recipient, rewardEscrow);

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
        assertEq(call4.recipient, rewardEscrow);
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
        assertEq(call2.recipient, rewardEscrow);
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
        vm.expectRevert(ERC20VotesArbitrator.JUROR_SLASHER_NOT_CONFIGURED.selector);
        arb.slashVoter(disputeId, 0, voter2);
    }

    function test_slashVoter_budgetScope_capsSnapshotVotesByBudgetAllocation() public {
        MockBudgetStakeLedgerForArbitratorBudgetScope budgetStakeLedger = new MockBudgetStakeLedgerForArbitratorBudgetScope();
        MockRewardEscrowWithBudgetStakeLedger rewardEscrowWithLedger =
            new MockRewardEscrowWithBudgetStakeLedger(address(budgetStakeLedger));
        MockFlowForArbitratorBudgetScope goalFlow = new MockFlowForArbitratorBudgetScope(address(0));
        MockGoalTreasuryForArbitratorBudgetScope scopedGoalTreasury =
            new MockGoalTreasuryForArbitratorBudgetScope(address(rewardEscrowWithLedger), address(goalFlow));
        MockFlowForArbitratorBudgetScope budgetFlow = new MockFlowForArbitratorBudgetScope(address(goalFlow));
        MockBudgetTreasuryForArbitratorBudgetScope budgetTreasury =
            new MockBudgetTreasuryForArbitratorBudgetScope(address(budgetFlow));
        MockStakeVaultForArbitrator scopedStakeVault = new MockStakeVaultForArbitrator(address(scopedGoalTreasury));
        scopedStakeVault.setJurorVotes(voter1, 100e18);
        scopedStakeVault.setJurorVotes(voter2, 200e18);

        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter1, address(budgetTreasury), 40e18);
        budgetStakeLedger.setPastUserAllocatedStakeOnBudget(voter2, address(budgetTreasury), 200e18);
        budgetStakeLedger.setPastBudgetTotalAllocatedStake(address(budgetTreasury), 240e18);

        MockArbitrable scopedArbitrable = new MockArbitrable(IERC20(address(token)));
        ERC20VotesArbitrator scopedArb = _deployBudgetScopedArbitrator(
            scopedArbitrable,
            address(scopedStakeVault),
            address(budgetTreasury)
        );
        scopedStakeVault.setJurorSlasher(address(scopedArb));

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
        assertTrue(canVote);
        assertEq(voterPower, 40e18);

        _warpRoll(revealEndTime + 1);
        uint256 expectedSlashWeight = (40e18 * scopedArb.wrongOrMissedSlashBps()) / 10_000;
        uint256 expectedCallerBounty = (expectedSlashWeight * scopedArb.slashCallerBountyBps()) / 10_000;
        vm.expectEmit(true, true, true, true, address(scopedArb));
        emit ERC20VotesArbitrator.VoterSlashed(
            disputeId,
            0,
            voter1,
            40e18,
            expectedSlashWeight,
            false,
            address(rewardEscrowWithLedger)
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
        assertEq(call2.recipient, address(rewardEscrowWithLedger));
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
        emit ERC20VotesArbitrator.VoterSlashed(disputeId, 0, voter1, snapshotVotes, 0, false, rewardEscrow);
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

        MockStakeVaultForArbitrator badVault = new MockStakeVaultForArbitrator(address(0));
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
        MockStakeVaultForArbitrator revertingEscrowVault = new MockStakeVaultForArbitrator(address(revertingEscrowTreasury));
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
        MockStakeVaultForArbitrator eoaEscrowVault = new MockStakeVaultForArbitrator(address(eoaEscrowTreasury));
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
        MockStakeVaultForArbitrator noEscrowVault = new MockStakeVaultForArbitrator(address(emptyEscrowTreasury));
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

        MockStakeVaultForArbitrator badVault = new MockStakeVaultForArbitrator(address(0));
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        arb2.configureStakeVault(address(badVault));

        MockGoalTreasuryRewardEscrowReverts revertingEscrowTreasury = new MockGoalTreasuryRewardEscrowReverts();
        MockStakeVaultForArbitrator revertingEscrowVault = new MockStakeVaultForArbitrator(address(revertingEscrowTreasury));
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        arb2.configureStakeVault(address(revertingEscrowVault));

        MockGoalTreasuryForArbitratorSlash eoaEscrowTreasury =
            new MockGoalTreasuryForArbitratorSlash(makeAddr("eoaRewardEscrow"));
        MockStakeVaultForArbitrator eoaEscrowVault = new MockStakeVaultForArbitrator(address(eoaEscrowTreasury));
        vm.prank(address(arbitrable2));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_REWARD_ESCROW.selector);
        arb2.configureStakeVault(address(eoaEscrowVault));

        MockGoalTreasuryForArbitratorSlash emptyEscrowTreasury = new MockGoalTreasuryForArbitratorSlash(address(0));
        MockStakeVaultForArbitrator noEscrowVault = new MockStakeVaultForArbitrator(address(emptyEscrowTreasury));
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
        MockStakeVaultForArbitrator stakeVault2 = new MockStakeVaultForArbitrator(address(emptyEscrowTreasury));
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

    function test_slashVoter_reverts_whenRewardEscrowClearedAfterConfiguration() public {
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
        vm.expectRevert(ERC20VotesArbitrator.INVALID_SLASH_RECIPIENT.selector);
        arb.slashVoter(disputeId, 0, voter2);

        goalTreasury.setRewardEscrow(makeAddr("eoaRewardEscrow"));
        vm.expectRevert(ERC20VotesArbitrator.INVALID_SLASH_RECIPIENT.selector);
        arb.slashVoter(disputeId, 0, voter2);
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
        emit ERC20VotesArbitrator.VoterSlashed(disputeId, 0, voter1, snapshotVotes, expectedSlashWeight, true, rewardEscrow);
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
                assertEq(rewardEscrowCall.recipient, rewardEscrow);
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
