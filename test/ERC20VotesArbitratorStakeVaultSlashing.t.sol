// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

import {ArbitratorHarness, ERC20VotesArbitratorTestBase} from "test/ERC20VotesArbitrator.t.sol";

contract StakeVaultSlashingBudgetLedgerMock {}

contract StakeVaultSlashingGoalTreasuryMock {
    address public immutable budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
    }
}

contract StakeVaultSlashingStakeVaultMock {
    struct Checkpoint {
        uint256 blockNumber;
        uint256 value;
    }

    mapping(address => Checkpoint[]) internal _jurorWeightCheckpoints;

    address public immutable goalTreasury;
    IERC20 public immutable goalToken;
    IERC20 public immutable cobuildToken;
    address public immutable jurorSlasher;

    constructor(address goalTreasury_, IERC20 goalToken_, IERC20 cobuildToken_, address jurorSlasher_) {
        goalTreasury = goalTreasury_;
        goalToken = goalToken_;
        cobuildToken = cobuildToken_;
        jurorSlasher = jurorSlasher_;
    }

    function setJurorWeight(address juror, uint256 weight) external {
        Checkpoint[] storage checkpoints = _jurorWeightCheckpoints[juror];
        uint256 length = checkpoints.length;
        if (length != 0 && checkpoints[length - 1].blockNumber == block.number) {
            checkpoints[length - 1].value = weight;
            return;
        }

        checkpoints.push(Checkpoint({blockNumber: block.number, value: weight}));
    }

    function getPastJurorWeight(address juror, uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert("BLOCK_NOT_YET_MINED");

        Checkpoint[] storage checkpoints = _jurorWeightCheckpoints[juror];
        uint256 length = checkpoints.length;
        while (length != 0) {
            Checkpoint storage checkpoint = checkpoints[length - 1];
            if (checkpoint.blockNumber <= blockNumber) return checkpoint.value;
            unchecked {
                --length;
            }
        }

        return 0;
    }
}

contract StakeVaultSlashingJurorSlasherMock {
    IERC20 public immutable token;
    mapping(address => uint256) public availableSlashAmount;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setAvailableSlashAmount(address juror, uint256 amount) external {
        availableSlashAmount[juror] = amount;
    }

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external {
        uint256 available = availableSlashAmount[juror];
        uint256 slashAmount = weightAmount;
        if (slashAmount > available) slashAmount = available;
        if (slashAmount == 0) return;

        availableSlashAmount[juror] = available - slashAmount;
        token.transfer(recipient, slashAmount);
    }
}

contract ERC20VotesArbitratorStakeVaultSlashingTest is ERC20VotesArbitratorTestBase {
    StakeVaultSlashingJurorSlasherMock internal jurorSlasher;
    StakeVaultSlashingStakeVaultMock internal stakeVault;

    function setUp() public override {
        super.setUp();

        StakeVaultSlashingBudgetLedgerMock budgetStakeLedger = new StakeVaultSlashingBudgetLedgerMock();
        StakeVaultSlashingGoalTreasuryMock goalTreasury =
            new StakeVaultSlashingGoalTreasuryMock(address(budgetStakeLedger));
        jurorSlasher = new StakeVaultSlashingJurorSlasherMock(IERC20(address(token)));
        stakeVault = new StakeVaultSlashingStakeVaultMock(
            address(goalTreasury), IERC20(address(token)), IERC20(address(token)), address(jurorSlasher)
        );

        token.mint(address(jurorSlasher), 1_000_000e18);

        ArbitratorHarness impl = new ArbitratorHarness();
        IERC20VotesArbitrator.InitConfig memory cfg = _defaultArbitratorInitConfig(
            owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost
        );
        cfg.stakeVault = address(stakeVault);

        arb = ERC20VotesArbitrator(_deployProxy(address(impl), _arbitratorInitData(cfg)));
        arbitrable.setArbitrator(arb);
        arbitrable.approveArbitrator(arbitrationCost * 10);
    }

    function test_slashVoter_zeroAppliedSlash_keeps_voter_retryable() public {
        stakeVault.setJurorWeight(voter1, 200e18);
        vm.roll(block.number + 1);

        (uint256 disputeId,,, uint256 revealEnd,) = _createDispute("");
        _warpRoll(revealEnd + 1);

        vm.recordLogs();
        vm.prank(relayer);
        arb.slashVoter(disputeId, 0, voter1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertFalse(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));

        jurorSlasher.setAvailableSlashAmount(voter1, 1e18);

        uint256 relayerBefore = token.balanceOf(relayer);
        uint256 ownerBefore = token.balanceOf(owner);

        vm.expectEmit(true, true, true, true, address(arb));
        emit ERC20VotesArbitrator.VoterSlashed(disputeId, 0, voter1, 200e18, 1e18, true, owner);
        vm.prank(relayer);
        arb.slashVoter(disputeId, 0, voter1);

        assertTrue(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));
        assertEq(token.balanceOf(relayer) - relayerBefore, 1e16);
        assertEq(token.balanceOf(owner) - ownerBefore, 99e16);
    }

    function test_slashVoters_zeroAppliedSlash_does_not_revert_batch_or_block_other_voters() public {
        stakeVault.setJurorWeight(voter1, 200e18);
        stakeVault.setJurorWeight(voter2, 400e18);
        vm.roll(block.number + 1);

        (uint256 disputeId,,, uint256 revealEnd,) = _createDispute("");
        _warpRoll(revealEnd + 1);

        jurorSlasher.setAvailableSlashAmount(voter2, 2e18);

        address[] memory voters = new address[](2);
        voters[0] = voter1;
        voters[1] = voter2;

        uint256 relayerBefore = token.balanceOf(relayer);
        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(relayer);
        arb.slashVoters(disputeId, 0, voters);

        assertFalse(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));
        assertTrue(arb.isVoterSlashedOrProcessed(disputeId, 0, voter2));
        assertEq(token.balanceOf(relayer) - relayerBefore, 2e16);
        assertEq(token.balanceOf(owner) - ownerBefore, 198e16);
    }

    function test_slashVoter_zeroAppliedSlash_keeps_winner_pool_path_retryable() public {
        stakeVault.setJurorWeight(voter1, 200e18);
        stakeVault.setJurorWeight(voter2, 100e18);
        vm.roll(block.number + 1);

        (uint256 disputeId, uint256 start, uint256 end, uint256 revealEnd,) = _createDispute("");

        bytes32 salt = bytes32("winner");
        _warpRoll(start + 1);
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, 1, "", salt));

        _warpRoll(end + 1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, 1, "", salt);

        _warpRoll(revealEnd + 1);

        vm.prank(relayer);
        arb.slashVoter(disputeId, 0, voter1);

        assertFalse(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));
        (uint256 goalRewardBefore, uint256 cobuildRewardBefore) = arb.getSlashRewardsForRound(disputeId, 0, voter2);
        assertEq(goalRewardBefore, 0);
        assertEq(cobuildRewardBefore, 0);

        jurorSlasher.setAvailableSlashAmount(voter1, 1e18);

        uint256 relayerBefore = token.balanceOf(relayer);
        vm.prank(relayer);
        arb.slashVoter(disputeId, 0, voter1);

        (uint256 goalReward, uint256 cobuildReward) = arb.getSlashRewardsForRound(disputeId, 0, voter2);
        assertTrue(arb.isVoterSlashedOrProcessed(disputeId, 0, voter1));
        assertEq(token.balanceOf(relayer) - relayerBefore, 1e16);
        assertEq(goalReward, 99e16);
        assertEq(cobuildReward, 0);
    }
}
