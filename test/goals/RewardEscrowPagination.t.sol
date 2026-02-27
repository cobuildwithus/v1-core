// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IRewardEscrow } from "src/interfaces/IRewardEscrow.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract RewardEscrowPaginationTest is Test {
    uint8 internal constant GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint8 internal constant GOAL_EXPIRED = uint8(IGoalTreasury.GoalState.Expired);
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;
    uint256 internal constant BUDGET_COUNT = 40;
    uint32 internal constant FULL_SCALED = 1_000_000;

    address internal constant ALICE = address(0xA11CE);

    RewardEscrowPaginationMockToken internal rewardToken;
    RewardEscrowPaginationMockStakeVault internal stakeVault;
    RewardEscrowPaginationMockGoalTreasury internal goalTreasury;
    RewardEscrowPaginationMockGoalFlow internal goalFlow;

    BudgetStakeLedger internal ledger;
    RewardEscrow internal escrow;

    RewardEscrowPaginationMockBudgetTreasury[] internal budgets;
    bytes32[] internal recipientIds;

    function setUp() public {
        rewardToken = new RewardEscrowPaginationMockToken();
        stakeVault = new RewardEscrowPaginationMockStakeVault(IERC20(address(rewardToken)));
        goalFlow = new RewardEscrowPaginationMockGoalFlow(address(this));
        goalTreasury = new RewardEscrowPaginationMockGoalTreasury(address(goalFlow));

        ledger = new BudgetStakeLedger(address(goalTreasury));
        escrow = new RewardEscrow(
            address(goalTreasury),
            IERC20(address(rewardToken)),
            IStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            IBudgetStakeLedger(address(ledger))
        );
        goalTreasury.setRewardEscrow(address(escrow));

        _registerBudgets(BUDGET_COUNT);
    }

    function test_finalizeStep_andPrepareClaim_enableLargeBudgetSetSettlement() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = recipientIds[0];
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        vm.warp(100);
        _checkpoint(ALICE, 0, emptyIds, emptyScaled, _scaledWeight(100), ids, scaled);

        vm.warp(200);
        _checkpoint(ALICE, _scaledWeight(100), ids, scaled, _scaledWeight(100), ids, scaled);

        vm.warp(300);
        budgets[0].setState(IBudgetTreasury.BudgetState.Succeeded);
        budgets[0].setResolvedAt(300);
        for (uint256 i = 1; i < BUDGET_COUNT; ) {
            budgets[i].setState(IBudgetTreasury.BudgetState.Failed);
            budgets[i].setResolvedAt(300);
            unchecked {
                ++i;
            }
        }

        rewardToken.mint(address(escrow), 100e18);

        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, 300);

        assertTrue(escrow.finalizationInProgress());
        assertFalse(escrow.finalized());

        vm.expectRevert(IRewardEscrow.NOT_FINALIZED.selector);
        vm.prank(ALICE);
        escrow.claim(ALICE);

        vm.expectRevert(IRewardEscrow.INVALID_STEP_SIZE.selector);
        escrow.finalizeStep(0);

        uint256 finalizeGuard;
        while (escrow.finalizationInProgress()) {
            escrow.finalizeStep(4);
            unchecked {
                ++finalizeGuard;
            }
            assertLe(finalizeGuard, 20);
        }

        assertTrue(escrow.finalized());
        assertFalse(escrow.finalizationInProgress());
        assertGt(escrow.totalPointsSnapshot(), 0);

        uint256 preparedPoints;
        bool done;
        uint256 nextCursor;
        uint256 prepGuard;
        while (!done) {
            (preparedPoints, done, nextCursor) = escrow.prepareClaim(ALICE, 5);
            unchecked {
                ++prepGuard;
            }
            assertLe(prepGuard, 20);
        }

        assertGt(preparedPoints, 0);
        assertEq(nextCursor, BUDGET_COUNT);

        IRewardEscrow.ClaimCursor memory cursor = escrow.claimCursor(ALICE);
        assertTrue(cursor.successfulPointsCached);
        assertEq(cursor.cachedSuccessfulPoints, preparedPoints);

        vm.prank(ALICE);
        (uint256 goalAmount, uint256 cobuildAmount) = escrow.claim(ALICE);
        assertEq(goalAmount, 100e18);
        assertEq(cobuildAmount, 0);
    }

    function test_finalize_inProgress_sameParamsContinue_andMismatchedParamsRevert() public {
        _seedSingleSuccessfulBudgetScenario();

        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, 300);
        assertTrue(escrow.finalizationInProgress());
        assertFalse(escrow.finalized());

        vm.prank(address(goalTreasury));
        vm.expectRevert(IRewardEscrow.ALREADY_FINALIZED.selector);
        escrow.finalize(GOAL_SUCCEEDED, 301);

        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, 300);
        assertTrue(escrow.finalized());
        assertFalse(escrow.finalizationInProgress());
        assertGt(escrow.totalPointsSnapshot(), 0);

        vm.expectRevert(IRewardEscrow.FINALIZATION_NOT_IN_PROGRESS.selector);
        escrow.finalizeStep(1);
    }

    function test_prepareClaim_partialProgress_doesNotCacheUntilDone() public {
        _seedSingleSuccessfulBudgetScenario();

        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_SUCCEEDED, 300);
        while (escrow.finalizationInProgress()) {
            escrow.finalizeStep(4);
        }
        assertTrue(escrow.finalized());

        (uint256 points, bool done, uint256 nextCursor) = escrow.prepareClaim(ALICE, 5);
        assertFalse(done);
        assertEq(nextCursor, 5);
        assertGt(points, 0);

        IRewardEscrow.ClaimCursor memory partialCursor = escrow.claimCursor(ALICE);
        assertFalse(partialCursor.successfulPointsCached);
        assertEq(partialCursor.cachedSuccessfulPoints, 0);

        while (!done) {
            (points, done, nextCursor) = escrow.prepareClaim(ALICE, 5);
        }
        assertTrue(done);
        assertEq(nextCursor, BUDGET_COUNT);

        IRewardEscrow.ClaimCursor memory doneCursor = escrow.claimCursor(ALICE);
        assertTrue(doneCursor.successfulPointsCached);
        assertEq(doneCursor.cachedSuccessfulPoints, points);
    }

    function test_prepareClaim_nonSuccessGoal_returnsDoneWithoutStepValidation() public {
        vm.warp(300);
        for (uint256 i = 0; i < BUDGET_COUNT; ) {
            budgets[i].setState(IBudgetTreasury.BudgetState.Failed);
            budgets[i].setResolvedAt(300);
            unchecked {
                ++i;
            }
        }

        vm.prank(address(goalTreasury));
        escrow.finalize(GOAL_EXPIRED, 300);
        assertTrue(escrow.finalized());
        assertFalse(escrow.finalizationInProgress());

        (uint256 points, bool done, uint256 nextCursor) = escrow.prepareClaim(ALICE, 0);
        assertEq(points, 0);
        assertTrue(done);
        assertEq(nextCursor, 0);
    }

    function _seedSingleSuccessfulBudgetScenario() internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = recipientIds[0];
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        vm.warp(100);
        _checkpoint(ALICE, 0, emptyIds, emptyScaled, _scaledWeight(100), ids, scaled);

        vm.warp(200);
        _checkpoint(ALICE, _scaledWeight(100), ids, scaled, _scaledWeight(100), ids, scaled);

        vm.warp(300);
        budgets[0].setState(IBudgetTreasury.BudgetState.Succeeded);
        budgets[0].setResolvedAt(300);
        for (uint256 i = 1; i < BUDGET_COUNT; ) {
            budgets[i].setState(IBudgetTreasury.BudgetState.Failed);
            budgets[i].setResolvedAt(300);
            unchecked {
                ++i;
            }
        }

        rewardToken.mint(address(escrow), 100e18);
    }

    function _registerBudgets(uint256 count) internal {
        for (uint256 i = 0; i < count; ) {
            bytes32 recipientId = bytes32(i + 1);
            RewardEscrowPaginationMockBudgetFlow budgetFlow = new RewardEscrowPaginationMockBudgetFlow(address(goalFlow));
            RewardEscrowPaginationMockBudgetTreasury budget = new RewardEscrowPaginationMockBudgetTreasury(address(budgetFlow));

            budgets.push(budget);
            recipientIds.push(recipientId);

            vm.prank(address(this));
            ledger.registerBudget(recipientId, address(budget));

            unchecked {
                ++i;
            }
        }
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
        ledger.checkpointAllocation(account, prevWeight, prevIds, prevScaled, newWeight, newIds, newScaled);
    }

    function _scaledWeight(uint256 weight) internal pure returns (uint256) {
        return weight * UNIT_WEIGHT_SCALE;
    }
}

contract RewardEscrowPaginationMockToken is ERC20 {
    constructor() ERC20("Reward Token", "RWD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RewardEscrowPaginationMockStakeVault {
    IERC20 private immutable _goalToken;

    constructor(IERC20 goalToken_) {
        _goalToken = goalToken_;
    }

    function goalToken() external view returns (IERC20) {
        return _goalToken;
    }

    function cobuildToken() external pure returns (IERC20) {
        return IERC20(address(0));
    }
}

contract RewardEscrowPaginationMockGoalTreasury {
    address public flow;
    address public rewardEscrow;

    constructor(address flow_) {
        flow = flow_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }
}

contract RewardEscrowPaginationMockGoalFlow {
    address private _recipientAdmin;

    constructor(address recipientAdmin_) {
        _recipientAdmin = recipientAdmin_;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }
}

contract RewardEscrowPaginationMockBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract RewardEscrowPaginationMockBudgetTreasury {
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
}
