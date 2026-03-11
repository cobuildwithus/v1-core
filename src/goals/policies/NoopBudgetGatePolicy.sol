// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";

contract NoopBudgetGatePolicy is IBudgetGatePolicy {
    function evaluateBudgetGate(SyncContext calldata) external pure override returns (SyncResult memory result) {
        result.failures = new CallFailure[](0);
    }
}
