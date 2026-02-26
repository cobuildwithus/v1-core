// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IGoalStakeVault } from "src/interfaces/IGoalStakeVault.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract RewardEscrowInvariantHandler is Test {
    uint8 internal constant GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);
    uint8 internal constant GOAL_EXPIRED = uint8(IGoalTreasury.GoalState.Expired);
    uint256 internal constant MAX_AMOUNT = 1e24;
    uint32 internal constant FULL_SCALED = 1_000_000;
    bytes32 internal constant RECIPIENT_A = bytes32(uint256(1));

    RewardEscrowInvariantToken public rewardToken;
    RewardEscrowInvariantToken public cobuildToken;
    RewardEscrowInvariantStakeVault public stakeVault;
    BudgetStakeLedger public ledger;
    RewardEscrow public escrow;

    RewardEscrowInvariantGoalFlow public goalFlow;
    RewardEscrowInvariantBudgetFlow public budgetFlow;
    RewardEscrowInvariantBudget public budget;

    address[] internal _actors;
    mapping(address => uint256) internal _allocationWeight;
    mapping(address => uint256) internal _cumulativeGoalClaimed;
    mapping(address => uint256) internal _cumulativeCobuildClaimed;

    uint256 public totalGoalMintedToEscrow;
    uint256 public totalCobuildMintedToEscrow;
    bool private _bootstrapped;

    constructor() {
        rewardToken = new RewardEscrowInvariantToken("Invariant Reward", "iRWD");
        cobuildToken = new RewardEscrowInvariantToken("Invariant Cobuild", "iCBD");
        stakeVault = new RewardEscrowInvariantStakeVault(IERC20(address(rewardToken)), IERC20(address(cobuildToken)));
        ledger = new BudgetStakeLedger(address(this));
        escrow = new RewardEscrow(
            address(this),
            IERC20(address(rewardToken)),
            IGoalStakeVault(address(stakeVault)),
            ISuperToken(address(0)),
            ledger
        );

        goalFlow = new RewardEscrowInvariantGoalFlow();
        budgetFlow = new RewardEscrowInvariantBudgetFlow(address(goalFlow));
        budget = new RewardEscrowInvariantBudget(address(budgetFlow));
        goalFlow.setRecipient(RECIPIENT_A, address(budget));

        _actors.push(address(0xA11CE));
        _actors.push(address(0xB0B));
        _actors.push(address(0xCA11));
        _actors.push(address(0xD00D));
    }

    function bootstrap() external {
        if (_bootstrapped) return;
        _bootstrapped = true;
        ledger.registerBudget(RECIPIENT_A, address(budget));
        _checkpointAllocation(_actors[0], 1e18, 1);
    }

    function flow() external view returns (address) {
        return address(goalFlow);
    }

    function rewardEscrow() external view returns (address) {
        return address(escrow);
    }

    function checkpointAllocation(uint256 actorSeed, uint256 newWeight, uint64 advanceBy) external {
        if (escrow.finalized()) return;
        address actor = _actors[actorSeed % _actors.length];
        _checkpointAllocation(actor, bound(newWeight, 0, MAX_AMOUNT), uint64(bound(advanceBy, 1, 7 days)));
    }

    function mintGoalTokenToEscrow(uint256 amount) external {
        uint256 boundedAmount = bound(amount, 0, MAX_AMOUNT);
        rewardToken.mint(address(escrow), boundedAmount);
        totalGoalMintedToEscrow += boundedAmount;
    }

    function mintCobuildTokenToEscrow(uint256 amount) external {
        uint256 boundedAmount = bound(amount, 0, MAX_AMOUNT);
        cobuildToken.mint(address(escrow), boundedAmount);
        totalCobuildMintedToEscrow += boundedAmount;
    }

    function finalize(uint256 stateSeed) external {
        if (escrow.finalized()) return;
        uint8 finalState = uint8(bound(stateSeed, GOAL_SUCCEEDED, GOAL_EXPIRED));
        try escrow.finalize(finalState, uint64(block.timestamp)) { } catch { }
    }

    function claim(uint256 actorSeed) external {
        if (!escrow.finalized()) return;
        address actor = _actors[actorSeed % _actors.length];

        vm.prank(actor);
        try escrow.claim(actor) returns (uint256 goalAmount, uint256 cobuildAmount) {
            _cumulativeGoalClaimed[actor] += goalAmount;
            _cumulativeCobuildClaimed[actor] += cobuildAmount;
        } catch { }
    }

    function sweep(uint256 actorSeed) external {
        if (!escrow.finalized()) return;
        if (escrow.finalState() == GOAL_SUCCEEDED && escrow.totalPointsSnapshot() != 0) return;
        actorSeed;
        try escrow.releaseFailedAssetsToTreasury() returns (uint256) { } catch { }
    }

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return _actors[index];
    }

    function cumulativeGoalClaimed(address actor) external view returns (uint256) {
        return _cumulativeGoalClaimed[actor];
    }

    function cumulativeCobuildClaimed(address actor) external view returns (uint256) {
        return _cumulativeCobuildClaimed[actor];
    }

    function _checkpointAllocation(address actor, uint256 newWeight, uint64 advanceBy) internal {
        vm.warp(block.timestamp + advanceBy);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = RECIPIENT_A;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = FULL_SCALED;

        uint256 prevWeight = _allocationWeight[actor];
        vm.prank(address(goalFlow));
        ledger.checkpointAllocation(actor, prevWeight, ids, scaled, newWeight, ids, scaled);

        _allocationWeight[actor] = newWeight;
    }
}

contract RewardEscrowInvariantTest is StdInvariant, Test {
    uint8 internal constant GOAL_SUCCEEDED = uint8(IGoalTreasury.GoalState.Succeeded);

    RewardEscrowInvariantHandler internal handler;
    RewardEscrow internal escrow;
    RewardEscrowInvariantToken internal rewardToken;
    RewardEscrowInvariantToken internal cobuildToken;

    function setUp() public {
        handler = new RewardEscrowInvariantHandler();
        handler.bootstrap();
        escrow = handler.escrow();
        rewardToken = handler.rewardToken();
        cobuildToken = handler.cobuildToken();

        targetContract(address(handler));
    }

    function invariant_snapshotClaimsNeverExceedSnapshots() public view {
        assertLe(escrow.totalClaimed(), escrow.rewardPoolSnapshot());
        assertLe(escrow.totalCobuildClaimed(), escrow.cobuildPoolSnapshot());
    }

    function invariant_preFinalizeClaimAndRentCountersAreZero() public view {
        if (escrow.finalized()) return;

        assertEq(escrow.totalClaimed(), 0);
        assertEq(escrow.totalCobuildClaimed(), 0);
        assertEq(escrow.totalGoalRentClaimed(), 0);
        assertEq(escrow.totalCobuildRentClaimed(), 0);
        assertEq(escrow.goalRentPerPointStored(), 0);
        assertEq(escrow.cobuildRentPerPointStored(), 0);
    }

    function invariant_goalTokenAccountingConservesMass() public view {
        uint256 tracked = rewardToken.balanceOf(address(escrow)) + escrow.totalClaimed() + escrow.totalGoalRentClaimed();
        assertLe(tracked, handler.totalGoalMintedToEscrow());

        if (escrow.finalized() && escrow.finalState() == GOAL_SUCCEEDED && escrow.totalPointsSnapshot() != 0) {
            assertEq(tracked, handler.totalGoalMintedToEscrow());
        }
    }

    function invariant_cobuildTokenAccountingConservesMass() public view {
        uint256 tracked =
            cobuildToken.balanceOf(address(escrow)) + escrow.totalCobuildClaimed() + escrow.totalCobuildRentClaimed();
        assertLe(tracked, handler.totalCobuildMintedToEscrow());

        if (escrow.finalized() && escrow.finalState() == GOAL_SUCCEEDED && escrow.totalPointsSnapshot() != 0) {
            assertEq(tracked, handler.totalCobuildMintedToEscrow());
        }
    }

    function invariant_nonSuccessCannotClaimRewardsOrRent() public view {
        if (!escrow.finalized()) return;
        if (escrow.finalState() == GOAL_SUCCEEDED) return;

        assertEq(escrow.totalClaimed(), 0);
        assertEq(escrow.totalCobuildClaimed(), 0);
        assertEq(escrow.totalGoalRentClaimed(), 0);
        assertEq(escrow.totalCobuildRentClaimed(), 0);
        assertEq(escrow.goalRentPerPointStored(), 0);
        assertEq(escrow.cobuildRentPerPointStored(), 0);
    }

    function invariant_actorBalancesBoundedByEscrowInflows() public view {
        uint256 count = handler.actorCount();
        uint256 goalInflows = handler.totalGoalMintedToEscrow();
        uint256 cobuildInflows = handler.totalCobuildMintedToEscrow();

        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actorAt(i);
            assertLe(rewardToken.balanceOf(actor), goalInflows);
            assertLe(cobuildToken.balanceOf(actor), cobuildInflows);
        }
    }

    function invariant_actorCumulativeClaimsBoundedByProRataEntitlement() public view {
        if (!escrow.finalized()) return;
        if (escrow.finalState() != GOAL_SUCCEEDED) return;

        uint256 snapshotPoints = escrow.totalPointsSnapshot();
        if (snapshotPoints == 0) return;

        uint256 count = handler.actorCount();
        uint256 goalInflows = handler.totalGoalMintedToEscrow();
        uint256 cobuildInflows = handler.totalCobuildMintedToEscrow();

        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actorAt(i);
            uint256 userPoints = escrow.userSuccessfulPoints(actor);
            uint256 maxGoalEntitlement = Math.mulDiv(goalInflows, userPoints, snapshotPoints);
            uint256 maxCobuildEntitlement = Math.mulDiv(cobuildInflows, userPoints, snapshotPoints);

            assertLe(handler.cumulativeGoalClaimed(actor), maxGoalEntitlement);
            assertLe(handler.cumulativeCobuildClaimed(actor), maxCobuildEntitlement);
        }
    }
}

contract RewardEscrowInvariantToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RewardEscrowInvariantStakeVault {
    IERC20 private immutable _goalToken;
    IERC20 private immutable _cobuildToken;

    constructor(IERC20 goalToken_, IERC20 cobuildToken_) {
        _goalToken = goalToken_;
        _cobuildToken = cobuildToken_;
    }

    function goalToken() external view returns (IERC20) {
        return _goalToken;
    }

    function cobuildToken() external view returns (IERC20) {
        return _cobuildToken;
    }

    function weightOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalWeight() external pure returns (uint256) {
        return 0;
    }
}

contract RewardEscrowInvariantGoalFlow {
    error RECIPIENT_NOT_FOUND();

    mapping(bytes32 => address) private _recipients;
    address public manager;

    constructor() {
        manager = msg.sender;
    }

    function setRecipient(bytes32 recipientId, address recipient) external {
        _recipients[recipientId] = recipient;
    }

    function recipientAdmin() external view returns (address) {
        return manager;
    }

    function getRecipientById(bytes32 recipientId) external view returns (FlowTypes.FlowRecipient memory recipient) {
        address recipientAddress = _recipients[recipientId];
        if (recipientAddress == address(0)) revert RECIPIENT_NOT_FOUND();

        recipient.recipient = recipientAddress;
        recipient.recipientType = FlowTypes.RecipientType.FlowContract;
    }
}

contract RewardEscrowInvariantBudgetFlow {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract RewardEscrowInvariantBudget {
    address public flow;
    IBudgetTreasury.BudgetState public state = IBudgetTreasury.BudgetState.Succeeded;
    uint64 public fundingDeadline = 1;
    uint64 public executionDuration = 10;

    constructor(address flow_) {
        flow = flow_;
    }

    function resolvedAt() external view returns (uint64) {
        return uint64(block.timestamp);
    }
}
