// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "./IAllocationKeyAccountResolver.sol";
import { IAllocationStrategy } from "./IAllocationStrategy.sol";

/// @notice Canonical goal-scoped strategy boundary for goal-flow allocation-ledger mode.
interface IGoalScopedAllocationStrategy is IAllocationStrategy, IAllocationKeyAccountResolver {
    function goalTreasury() external view returns (address);
}
