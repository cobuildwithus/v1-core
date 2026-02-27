// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IRewardEscrow } from "src/interfaces/IRewardEscrow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { SharedMockFlow, SharedMockStakeVault } from "test/goals/helpers/TreasurySharedMocks.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract RewardEscrowDustRetentionTest is Test {
    uint8 internal constant GOAL_SUCCEEDED = 2;
    bytes32 internal constant RECIPIENT_A = bytes32(uint256(1));
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    RewardEscrowDustMockToken internal rewardToken;
    RewardEscrowDustMockToken internal cobuildToken;
    SharedMockStakeVault internal stakeVault;

    RewardEscrowDustMockGoalTreasury internal goalTreasury;
    SharedMockFlow internal goalFlow;

    SharedMockFlow internal budgetFlow;
    RewardEscrowDustMockBudgetTreasury internal budgetA;

    BudgetStakeLedger internal ledger;
    RewardEscrow internal escrow;

    function setUp() public {
        rewardToken = new RewardEscrowDustMockToken("Reward Token", "RWD");
        cobuildToken = new RewardEscrowDustMockToken("Cobuild Token", "COB");

        stakeVault = new SharedMockStakeVault();
        stakeVault.setGoalToken(IERC20(address(rewardToken)));
        stakeVault.setCobuildToken(IERC20(address(cobuildToken)));

        goalTreasury = new RewardEscrowDustMockGoalTreasury();
        goalFlow = new SharedMockFlow(ISuperToken(address(rewardToken)));
        goalTreasury.setFlow(address(goalFlow));

        budgetFlow = new SharedMockFlow(ISuperToken(address(rewardToken)));
        budgetFlow.setParent(address(goalFlow));

        budgetA = new RewardEscrowDustMockBudgetTreasury(address(budgetFlow));
        goalFlow.setRecipient(RECIPIENT_A, address(budgetA));

        ledger = new BudgetStakeLedger(address(goalTreasury));
        escrow = new RewardEscrow(
            address(goalTreasury),
            IERC20(address(rewardToken)),
            IStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );
        goalTreasury.setRewardEscrow(address(escrow));

        vm.mockCall(address(goalFlow), abi.encodeWithSignature("recipientAdmin()"), abi.encode(address(this)));
        budgetA.setFundingDeadline(200);
        ledger.registerBudget(RECIPIENT_A, address(budgetA));
    }

    function test_successSnapshotFlooring_leavesResidualDustLocked() public {
        bytes32[] memory ids = _ids1(RECIPIENT_A);
        uint32[] memory scaled = _scaled1(1_000_000);

        vm.warp(100);
        _checkpointInitial(alice, 1, ids, scaled);
        _checkpointInitial(bob, 2, ids, scaled);

        budgetA.setState(IBudgetTreasury.BudgetState.Succeeded);
        budgetA.setResolvedAt(200);

        rewardToken.mint(address(escrow), 2);

        vm.warp(250);
        _finalizeAsGoalTreasury(GOAL_SUCCEEDED);

        assertEq(escrow.totalPointsSnapshot(), 297 * UNIT_WEIGHT_SCALE);

        vm.prank(alice);
        (uint256 aliceClaim, ) = escrow.claim(alice);
        vm.prank(bob);
        (uint256 bobClaim, ) = escrow.claim(bob);

        assertEq(aliceClaim, 0);
        assertEq(bobClaim, 1);
        assertEq(escrow.totalClaimed(), 1);
        assertEq(rewardToken.balanceOf(address(escrow)), 1);

        vm.expectRevert(IRewardEscrow.INVALID_FINAL_STATE.selector);
        vm.prank(address(goalTreasury));
        escrow.releaseFailedAssetsToTreasury();
    }

    function _finalizeAsGoalTreasury(uint8 finalState) internal {
        vm.prank(address(goalTreasury));
        escrow.finalize(finalState, uint64(block.timestamp));
    }

    function _checkpointInitial(address account, uint256 newWeight, bytes32[] memory newIds, uint32[] memory newScaled)
        internal
    {
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);
        _checkpoint(account, 0, emptyIds, emptyScaled, newWeight, newIds, newScaled);
    }

    function _checkpoint(
        address account,
        uint256 prevWeight,
        bytes32[] memory prevIds,
        uint32[] memory prevScaled,
        uint256 newWeight,
        bytes32[] memory newIds,
        uint32[] memory newScaled
    ) internal {
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(
            account,
            _scaledWeight(prevWeight),
            prevIds,
            prevScaled,
            _scaledWeight(newWeight),
            newIds,
            newScaled
        );
    }

    function _scaledWeight(uint256 weight) internal pure returns (uint256) {
        return weight * UNIT_WEIGHT_SCALE;
    }

    function _ids1(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _scaled1(uint32 a) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](1);
        scaled[0] = a;
    }
}

contract RewardEscrowDustMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RewardEscrowDustMockGoalTreasury {
    address public flow;
    address public rewardEscrow;

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }
}

contract RewardEscrowDustMockBudgetTreasury {
    IBudgetTreasury.BudgetState public state;
    address public flow;
    uint64 public resolvedAt;
    uint64 public executionDuration = 10;
    uint64 public fundingDeadline = type(uint64).max;

    constructor(address flow_) {
        flow = flow_;
        state = IBudgetTreasury.BudgetState.Funding;
    }

    function setState(IBudgetTreasury.BudgetState state_) external {
        state = state_;
    }

    function setResolvedAt(uint64 resolvedAt_) external {
        resolvedAt = resolvedAt_;
    }

    function setExecutionDuration(uint64 executionDuration_) external {
        executionDuration = executionDuration_;
    }

    function setFundingDeadline(uint64 fundingDeadline_) external {
        fundingDeadline = fundingDeadline_;
    }
}
