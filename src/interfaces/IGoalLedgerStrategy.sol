// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalScopedAllocationStrategy } from "./IGoalScopedAllocationStrategy.sol";

/// @notice Legacy alias for the goal-scoped allocation strategy boundary used by goal ledger mode.
/// @dev Prefer `IGoalScopedAllocationStrategy` for new integrations.
interface IGoalLedgerStrategy is IGoalScopedAllocationStrategy {}
