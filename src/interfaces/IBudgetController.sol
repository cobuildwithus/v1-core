// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetStackTopologyReader } from "./IBudgetStackTopologyReader.sol";

/// @notice Shared runtime controller surface for budget topology owners, terminal pruning, and sync orchestration.
interface IBudgetController is IBudgetStackTopologyReader {
    function pruneTerminalBudget(address budgetTreasury) external returns (bool removedFromParent, bool goalSynced);

    function syncBudgetTreasuries(bytes32[] calldata itemIDs) external returns (uint256 attempted, uint256 succeeded);
}
