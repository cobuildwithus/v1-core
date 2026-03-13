// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "./IBudgetTreasury.sol";

interface IPremiumEscrowInitializer {
    function initialize(
        address budgetTreasury,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm
    ) external;
}

interface IPremiumEscrowManagerRewardPool {
    /// @notice Connects this escrow to the budget manager reward distribution pool.
    function connectManagerRewardPool(address managerRewardPool) external;
}

interface IPremiumEscrowCheckpoint {
    function checkpoint(address account) external;
}

interface IPremiumEscrowTerminal {
    function close(IBudgetTreasury.BudgetState state, uint64 activatedAt, uint64 closedAt) external;
}

interface IPremiumEscrowSlashAccounting {
    function slash(address underwriter) external returns (uint256 slashWeight);
    function userCov(address account) external view returns (uint256);
    function exposureIntegral(address account) external view returns (uint256);

    /// @notice Amount of goal-flow credit attributed to `account` while it provided coverage to this budget.
    /// @dev This value is used for failure slashing and is derived from Superfluid pool accounting
    ///      (goal flow receipts by the budget flow) indexed over time by total coverage.
    function creditDrawn(address account) external view returns (uint256);
}

interface IPremiumEscrow is
    IPremiumEscrowInitializer,
    IPremiumEscrowManagerRewardPool,
    IPremiumEscrowCheckpoint,
    IPremiumEscrowTerminal,
    IPremiumEscrowSlashAccounting
{
    function claim(address to) external returns (uint256 amount);

    /// @notice Sweeps any unclaimable premium to the goal flow once the goal has expired.
    /// @dev Intended to support "premium claimable only on goal success and budget success".
    ///      On goal expiry, underwriters should not be able to claim premium; instead, it can be
    ///      swept and burned via the goal treasury's residual settlement.
    function burnOnGoalFailure() external returns (uint256 amount);
}
