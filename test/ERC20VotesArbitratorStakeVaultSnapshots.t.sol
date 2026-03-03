// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness} from "test/ERC20VotesArbitrator.t.sol";

import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";

contract StakeVaultSnapshotGoalTreasuryMock {
    address public immutable budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
    }
}

contract StakeVaultSnapshotGoalTreasuryWithFlowMock {
    address public immutable budgetStakeLedger;
    address public immutable flow;

    constructor(address budgetStakeLedger_, address flow_) {
        budgetStakeLedger = budgetStakeLedger_;
        flow = flow_;
    }
}

contract StakeVaultSnapshotFlowMock {
    address public immutable parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract StakeVaultSnapshotBudgetTreasuryMock {
    address public immutable flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract StakeVaultSnapshotBudgetLedgerMock {
    struct Checkpoint {
        uint256 blockNumber;
        uint256 value;
    }

    mapping(address => Checkpoint[]) internal _allocationWeightCheckpoints;
    mapping(address => mapping(address => Checkpoint[])) internal _budgetStakeCheckpoints;

    function setUserAllocationWeight(address user, uint256 value) external {
        _setCheckpoint(_allocationWeightCheckpoints[user], value);
    }

    function setUserAllocatedStakeOnBudget(address user, address budgetTreasury, uint256 value) external {
        _setCheckpoint(_budgetStakeCheckpoints[user][budgetTreasury], value);
    }

    function getPastUserAllocatedStakeOnBudget(
        address user,
        address budgetTreasury,
        uint256 blockNumber
    ) external view returns (uint256) {
        return _getPastCheckpoint(_budgetStakeCheckpoints[user][budgetTreasury], blockNumber);
    }

    function getPastUserAllocationWeight(address user, uint256 blockNumber) external view returns (uint256) {
        return _getPastCheckpoint(_allocationWeightCheckpoints[user], blockNumber);
    }

    function _setCheckpoint(Checkpoint[] storage checkpoints, uint256 value) internal {
        uint256 length = checkpoints.length;
        if (length != 0 && checkpoints[length - 1].blockNumber == block.number) {
            checkpoints[length - 1].value = value;
            return;
        }
        checkpoints.push(Checkpoint({blockNumber: block.number, value: value}));
    }

    function _getPastCheckpoint(Checkpoint[] storage checkpoints, uint256 blockNumber) internal view returns (uint256) {
        if (blockNumber >= block.number) revert("BLOCK_NOT_YET_MINED");
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

contract StakeVaultSnapshotStakeVaultMock {
    struct Checkpoint {
        uint256 blockNumber;
        uint256 value;
    }

    mapping(address => Checkpoint[]) internal _jurorWeightCheckpoints;

    address public immutable goalTreasury;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
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

contract ERC20VotesArbitratorStakeVaultSnapshotsTest is ERC20VotesArbitratorTestBase {
    StakeVaultSnapshotStakeVaultMock internal stakeVault;

    function setUp() public override {
        super.setUp();

        StakeVaultSnapshotBudgetLedgerMock budgetStakeLedger = new StakeVaultSnapshotBudgetLedgerMock();
        StakeVaultSnapshotGoalTreasuryMock goalTreasury =
            new StakeVaultSnapshotGoalTreasuryMock(address(budgetStakeLedger));
        stakeVault = new StakeVaultSnapshotStakeVaultMock(address(goalTreasury));

        vm.prank(address(arbitrable));
        arb.configureStakeVault(address(stakeVault));
    }

    function test_createDispute_stakeVaultMode_excludesSameBlockWeightIncrease() public {
        address lateJuror = makeAddr("lateJuror");

        (uint256 disputeId, uint256 start,, uint256 revealEnd, uint256 creationBlock) = _createDispute("");
        assertEq(creationBlock, block.number - 1);

        // Juror stakes after dispute creation, still in the same block.
        stakeVault.setJurorWeight(lateJuror, 75e18);

        _warpRoll(start + 1);

        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(lateJuror);
        arb.commitVote(disputeId, bytes32(uint256(1)));

        // Keep lifecycle progressing to ensure no side effects in round state handling.
        _warpRoll(revealEnd + 1);
        arb.executeRuling(disputeId);
    }

    function test_createDispute_stakeVaultMode_usesPreviousBlockWeight_whenSameBlockReduced() public {
        address juror = makeAddr("stakeVaultJuror");

        stakeVault.setJurorWeight(juror, 90e18);
        vm.roll(block.number + 1);

        (uint256 disputeId, uint256 start,,, uint256 creationBlock) = _createDispute("");
        assertEq(creationBlock, block.number - 1);

        // Juror exits after dispute creation in the same block; creation snapshot should still retain prior weight.
        stakeVault.setJurorWeight(juror, 0);

        _warpRoll(start + 1);
        vm.prank(juror);
        arb.commitVote(disputeId, bytes32(uint256(2)));

        IERC20VotesArbitrator.VoterRoundStatus memory status = arb.getVoterRoundStatus(disputeId, 0, juror);
        assertTrue(status.hasCommitted);
    }

    function test_createDispute_fixedBudgetStakeVaultMode_excludesSameBlockStakeAndAllocationUpdates() public {
        address scopedJuror = makeAddr("scopedJuror");

        (
            ERC20VotesArbitrator scopedArb,
            StakeVaultSnapshotStakeVaultMock scopedStakeVault,
            StakeVaultSnapshotBudgetLedgerMock ledger,
            StakeVaultSnapshotBudgetTreasuryMock budgetTreasury
        ) = _deployFixedBudgetStakeVaultModeArbitrator();

        uint256 startTime = block.timestamp + votingDelay;
        uint256 disputeId = arbitrable.createDispute(2, "");

        // All weight/allocation updates happen after dispute creation but within the same block.
        scopedStakeVault.setJurorWeight(scopedJuror, 100e18);
        ledger.setUserAllocationWeight(scopedJuror, 100e18);
        ledger.setUserAllocatedStakeOnBudget(scopedJuror, address(budgetTreasury), 100e18);

        _warpRoll(startTime + 1);

        vm.expectRevert(IERC20VotesArbitrator.VOTER_HAS_NO_VOTES.selector);
        vm.prank(scopedJuror);
        scopedArb.commitVote(disputeId, bytes32(uint256(3)));
    }

    function test_createDispute_fixedBudgetStakeVaultMode_usesPreviousBlockInputs_whenSameBlockValuesDropToZero()
        public
    {
        address scopedJuror = makeAddr("scopedJurorDrop");

        (
            ERC20VotesArbitrator scopedArb,
            StakeVaultSnapshotStakeVaultMock scopedStakeVault,
            StakeVaultSnapshotBudgetLedgerMock ledger,
            StakeVaultSnapshotBudgetTreasuryMock budgetTreasury
        ) = _deployFixedBudgetStakeVaultModeArbitrator();

        scopedStakeVault.setJurorWeight(scopedJuror, 120e18);
        ledger.setUserAllocationWeight(scopedJuror, 120e18);
        ledger.setUserAllocatedStakeOnBudget(scopedJuror, address(budgetTreasury), 90e18);
        vm.roll(block.number + 1);

        uint256 startTime = block.timestamp + votingDelay;
        uint256 disputeId = arbitrable.createDispute(2, "");

        // Juror exits and clears budget/allocation after dispute creation in the same block.
        scopedStakeVault.setJurorWeight(scopedJuror, 0);
        ledger.setUserAllocationWeight(scopedJuror, 0);
        ledger.setUserAllocatedStakeOnBudget(scopedJuror, address(budgetTreasury), 0);

        (uint256 votingPower, bool canVote) = scopedArb.votingPowerInRound(disputeId, 0, scopedJuror);
        assertTrue(canVote);
        assertEq(votingPower, 90e18);

        _warpRoll(startTime + 1);
        vm.prank(scopedJuror);
        scopedArb.commitVote(disputeId, bytes32(uint256(4)));

        IERC20VotesArbitrator.VoterRoundStatus memory status = scopedArb.getVoterRoundStatus(disputeId, 0, scopedJuror);
        assertTrue(status.hasCommitted);
    }

    function _deployFixedBudgetStakeVaultModeArbitrator()
        internal
        returns (
            ERC20VotesArbitrator scopedArb,
            StakeVaultSnapshotStakeVaultMock scopedStakeVault,
            StakeVaultSnapshotBudgetLedgerMock ledger,
            StakeVaultSnapshotBudgetTreasuryMock budgetTreasury
        )
    {
        ledger = new StakeVaultSnapshotBudgetLedgerMock();

        StakeVaultSnapshotFlowMock goalFlow = new StakeVaultSnapshotFlowMock(address(0));
        StakeVaultSnapshotGoalTreasuryWithFlowMock goalTreasury =
            new StakeVaultSnapshotGoalTreasuryWithFlowMock(address(ledger), address(goalFlow));
        scopedStakeVault = new StakeVaultSnapshotStakeVaultMock(address(goalTreasury));

        StakeVaultSnapshotFlowMock budgetFlow = new StakeVaultSnapshotFlowMock(address(goalFlow));
        budgetTreasury = new StakeVaultSnapshotBudgetTreasuryMock(address(budgetFlow));

        ArbitratorHarness impl = new ArbitratorHarness();
        IERC20VotesArbitrator.InitConfig memory cfg = _defaultArbitratorInitConfig(
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );
        cfg.stakeVault = address(scopedStakeVault);
        cfg.fixedBudgetTreasury = address(budgetTreasury);

        scopedArb = ERC20VotesArbitrator(_deployProxy(address(impl), _arbitratorInitData(cfg)));
        arbitrable.setArbitrator(scopedArb);
        arbitrable.approveArbitrator(arbitrationCost * 10);
    }
}
