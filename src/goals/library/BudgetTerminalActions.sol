// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

library BudgetTerminalActions {
    event BudgetTerminalizationStepFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bytes4 indexed selector,
        bytes reason
    );

    function resolveBudgetTerminalStateBestEffort(bytes32 itemID, IBudgetTreasury treasury) external returns (bool) {
        if (treasury.resolved()) return true;

        treasury.forceFlowRateToZero();
        if (treasury.resolved()) return true;

        try treasury.resolveFailure() {} catch (bytes memory reason) {
            emit BudgetTerminalizationStepFailed(
                itemID,
                address(treasury),
                IBudgetTreasury.resolveFailure.selector,
                reason
            );
        }
        return treasury.resolved();
    }

    function resolveBudgetTerminalStateStrict(IBudgetTreasury treasury) external returns (bool) {
        if (treasury.resolved()) return true;

        treasury.forceFlowRateToZero();
        if (treasury.resolved()) return true;

        treasury.resolveFailure();
        return treasury.resolved();
    }

    function removeRecipientFromGoalFlowIfPresent(
        IFlow goalFlow,
        bytes32 itemID,
        address childFlow
    ) external returns (bool) {
        if (childFlow == address(0) || !goalFlow.recipientExists(childFlow)) return false;

        goalFlow.removeRecipient(itemID);
        return true;
    }
}
