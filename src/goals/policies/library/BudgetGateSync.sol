// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";

library BudgetGateSync {
    event BudgetGateEnforcementFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        address callTarget,
        bytes4 indexed selector,
        bytes reason
    );

    function applyBudgetGate(
        bytes32 itemID,
        address budgetTreasury,
        address childFlow,
        address coverageSource,
        uint32 coverageToCreditPpm,
        IFlow goalFlow,
        IBudgetGatePolicy gatePolicy
    ) external {
        IBudgetGatePolicy.SyncResult memory gateResult = BudgetGatePolicyHook.evaluateBudgetGate(
            gatePolicy,
            IBudgetGatePolicy.SyncContext({
                itemID: itemID,
                goalFlow: goalFlow,
                childFlow: childFlow,
                budgetTreasury: budgetTreasury,
                coverageSource: coverageSource,
                coverageToCreditPpm: coverageToCreditPpm
            })
        );

        uint256 count = gateResult.failures.length;
        for (uint256 i = 0; i < count; i++) {
            emit BudgetGateEnforcementFailed(
                itemID,
                budgetTreasury,
                gateResult.failures[i].callTarget,
                gateResult.failures[i].selector,
                gateResult.failures[i].reason
            );
        }

        if (gateResult.shouldSetRecipientEnabled) {
            try goalFlow.setRecipientEnabled(itemID, gateResult.recipientEnabled) {} catch (bytes memory reason) {
                emit BudgetGateEnforcementFailed(
                    itemID,
                    budgetTreasury,
                    address(goalFlow),
                    IFlow.setRecipientEnabled.selector,
                    reason
                );
            }
        }
    }
}
