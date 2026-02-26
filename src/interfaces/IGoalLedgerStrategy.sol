// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationStrategy } from "./IAllocationStrategy.sol";
import { IAllocationKeyAccountResolver } from "./IAllocationKeyAccountResolver.sol";
import { IHasStakeVault } from "./IHasStakeVault.sol";

/// @notice Capability interface for strategies compatible with goal allocation-ledger mode.
interface IGoalLedgerStrategy is IAllocationStrategy, IAllocationKeyAccountResolver, IHasStakeVault {}
