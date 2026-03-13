// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { StakeCoverageGateActions } from "src/goals/policies/library/StakeCoverageGateActions.sol";

contract StakeCoverageGatePolicy is IBudgetGatePolicy {
    function evaluateBudgetGate(
        SyncContext calldata context
    ) external view override returns (SyncResult memory result) {
        return StakeCoverageGateActions.evaluateStakeCoverageGate(context);
    }
}
