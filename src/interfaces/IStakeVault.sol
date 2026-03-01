// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStakeVault {
    error ADDRESS_ZERO();
    error DECIMALS_MISMATCH(uint8 goalDecimals, uint8 cobuildDecimals);
    error PAYMENT_TOKEN_DECIMALS_MISMATCH(uint8 tokenDecimals, uint8 paymentTokenDecimals);
    error INVALID_PAYMENT_TOKEN_DECIMALS(uint8 decimals);
    error GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address goalToken);
    error GOAL_TOKEN_REVNET_MISMATCH(address goalToken, uint256 expectedRevnetId, uint256 actualRevnetId);
    error INVALID_REVNET_CONTROLLER(address controller);
    error GOAL_ALREADY_RESOLVED();
    error INVALID_AMOUNT();
    error TRANSFER_AMOUNT_MISMATCH();
    error ZERO_WEIGHT_DELTA();
    error GOAL_NOT_RESOLVED();
    error INSUFFICIENT_STAKED_BALANCE();
    error GOAL_STAKING_CLOSED();
    error BLOCK_NOT_YET_MINED();
    error INVALID_JUROR_LOCK();
    error EXIT_NOT_READY();
    error JUROR_WITHDRAWAL_LOCKED();
    error ONLY_JUROR_SLASHER();
    error INVALID_JUROR_SLASHER();
    error JUROR_SLASHER_ALREADY_SET();
    error ONLY_UNDERWRITER_SLASHER();
    error INVALID_UNDERWRITER_SLASHER();
    error UNDERWRITER_SLASHER_ALREADY_SET();
    error UNAUTHORIZED();
    error INVALID_TREASURY_AUTHORITY_SURFACE(address treasury);

    event GoalStaked(address indexed user, uint256 amount, uint256 weightDelta);
    event CobuildStaked(address indexed user, uint256 amount, uint256 weightDelta);
    event GoalWithdrawn(address indexed user, address indexed to, uint256 amount);
    event CobuildWithdrawn(address indexed user, address indexed to, uint256 amount);
    event GoalResolved();
    event JurorOptedIn(
        address indexed juror,
        uint256 goalAmount,
        uint256 cobuildAmount,
        uint256 weightDelta,
        address indexed delegate
    );
    event JurorExitRequested(
        address indexed juror,
        uint256 goalAmount,
        uint256 cobuildAmount,
        uint64 requestedAt,
        uint64 availableAt
    );
    event JurorExitFinalized(address indexed juror, uint256 goalAmount, uint256 cobuildAmount, uint256 weightDelta);
    event JurorDelegateSet(address indexed juror, address indexed delegate);
    event JurorSlasherSet(address indexed slasher);
    event UnderwriterSlasherSet(address indexed slasher);
    event JurorSlashed(
        address indexed juror,
        uint256 requestedWeight,
        uint256 appliedWeight,
        uint256 goalAmount,
        uint256 cobuildAmount,
        address indexed recipient
    );
    event UnderwriterSlashed(
        address indexed underwriter,
        uint256 requestedWeight,
        uint256 appliedWeight,
        uint256 goalAmount,
        uint256 cobuildAmount,
        address indexed recipient
    );
    event AllocationSyncFailed(address indexed account, address indexed target, bytes4 indexed selector, bytes reason);

    function goalToken() external view returns (IERC20);
    function cobuildToken() external view returns (IERC20);
    function goalTreasury() external view returns (address);
    function paymentTokenDecimals() external view returns (uint8);
    function goalResolved() external view returns (bool);
    function goalResolvedAt() external view returns (uint64);
    function totalStakedGoal() external view returns (uint256);
    function totalStakedCobuild() external view returns (uint256);
    function totalJurorWeight() external view returns (uint256);
    function jurorSlasher() external view returns (address);
    function underwriterSlasher() external view returns (address);

    function depositGoal(uint256 amount) external;
    function depositCobuild(uint256 amount) external;
    function withdrawGoal(uint256 amount, address to) external;
    function withdrawCobuild(uint256 amount, address to) external;
    function markGoalResolved() external;
    function optInAsJuror(uint256 goalAmount, uint256 cobuildAmount, address delegate) external;
    function requestJurorExit(uint256 goalAmount, uint256 cobuildAmount) external;
    function finalizeJurorExit() external;
    function setJurorDelegate(address delegate) external;
    function setJurorSlasher(address slasher) external;
    function setUnderwriterSlasher(address slasher) external;
    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external;
    function slashUnderwriterStake(address underwriter, uint256 weightAmount, address recipient) external;

    function weightOf(address user) external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function stakedGoalOf(address user) external view returns (uint256);
    function stakedCobuildOf(address user) external view returns (uint256);
    function jurorLockedGoalOf(address user) external view returns (uint256);
    function jurorLockedCobuildOf(address user) external view returns (uint256);
    function jurorWeightOf(address user) external view returns (uint256);
    function jurorDelegateOf(address user) external view returns (address);
    function isAuthorizedJurorOperator(address juror, address operator) external view returns (bool);
    function getPastJurorWeight(address user, uint256 blockNumber) external view returns (uint256);
    function getPastTotalJurorWeight(uint256 blockNumber) external view returns (uint256);
    function allocationKey(address caller, bytes calldata aux) external view returns (uint256);
    function accountForAllocationKey(uint256 allocationKey) external view returns (address);
    function currentWeight(uint256 key) external view returns (uint256);
    function canAllocate(uint256 key, address caller) external view returns (bool);
    function canAccountAllocate(address account) external view returns (bool);
    function accountAllocationWeight(address account) external view returns (uint256);
    function strategyKey() external pure returns (string memory);
    function stakeVault() external view returns (address);

    function quoteGoalToCobuildWeightRatio(
        uint256 goalAmount
    ) external view returns (uint256 weightOut, uint112 goalWeight, uint256 weightRatio);
}
