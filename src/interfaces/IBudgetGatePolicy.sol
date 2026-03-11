// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFlow } from "./IFlow.sol";

interface IBudgetGatePolicy {
    struct SyncContext {
        bytes32 itemID;
        IFlow goalFlow;
        address childFlow;
        address budgetTreasury;
        address coverageSource;
        uint32 coverageToCreditPpm;
    }

    struct CallFailure {
        address callTarget;
        bytes4 selector;
        bytes reason;
    }

    struct SyncResult {
        bool shouldSetRecipientEnabled;
        bool recipientEnabled;
        CallFailure[] failures;
    }

    function evaluateBudgetGate(SyncContext calldata context) external view returns (SyncResult memory result);
}
