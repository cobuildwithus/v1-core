// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { BudgetTCRCreditCapActions } from "src/tcr/library/BudgetTCRCreditCapActions.sol";

contract StakeCoverageGatePolicy is IBudgetGatePolicy {
    function evaluateBudgetGate(
        SyncContext calldata context
    ) external view override returns (SyncResult memory result) {
        return BudgetTCRCreditCapActions.evaluateStakeCoverageGate(context);
    }
}
