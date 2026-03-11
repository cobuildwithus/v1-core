// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { NoopBudgetGatePolicy as SharedNoopBudgetGatePolicy } from "src/goals/policies/NoopBudgetGatePolicy.sol";

/// @notice Managed preset gate policy placeholder that never toggles child recipients.
contract NoopBudgetGatePolicy is SharedNoopBudgetGatePolicy {}
