// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

library BudgetControllerSyncLib {
    struct SyncAttempt {
        bool success;
        bool terminal;
    }

    event BudgetTreasuryCallFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        bytes4 indexed selector,
        bytes reason
    );

    function trySyncBudgetTreasury(
        bytes32 itemID,
        address budgetTreasury
    ) internal returns (SyncAttempt memory attempt) {
        IBudgetTreasury treasury = IBudgetTreasury(budgetTreasury);
        try treasury.sync() {
            attempt.success = true;
            attempt.terminal = treasury.resolved();
        } catch (bytes memory reason) {
            emit BudgetTreasuryCallFailed(itemID, budgetTreasury, IBudgetTreasury.sync.selector, reason);
        }
    }

    function pruneTerminalRecipientAndSyncGoal(
        IFlow goalFlow,
        IGoalTreasury goalTreasury,
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        bool detachParentRecipient
    ) internal returns (bool removedFromParent, bool goalSynced) {
        if (detachParentRecipient && childFlow != address(0) && goalFlow.recipientExists(childFlow)) {
            goalFlow.removeRecipient(itemID);
            removedFromParent = true;
        }

        try goalTreasury.sync() {
            goalSynced = true;
        } catch (bytes memory reason) {
            emit BudgetTreasuryCallFailed(itemID, budgetTreasury, IGoalTreasury.sync.selector, reason);
        }
    }
}
