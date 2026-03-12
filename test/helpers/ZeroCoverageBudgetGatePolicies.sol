// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IBudgetGatePolicy, IZeroCoverageBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";

contract NoopZeroCoverageBudgetGatePolicy is IBudgetGatePolicy, IZeroCoverageBudgetGatePolicy {
    function evaluateBudgetGate(SyncContext calldata) external pure returns (SyncResult memory result) {
        result.failures = new CallFailure[](0);
    }

    function supportsZeroCoverageBudgetGate() external pure returns (bool supported) {
        return true;
    }
}

contract AlwaysEnabledZeroCoverageBudgetGatePolicy is IBudgetGatePolicy, IZeroCoverageBudgetGatePolicy {
    function evaluateBudgetGate(SyncContext calldata) external pure returns (SyncResult memory result) {
        result.shouldSetRecipientEnabled = true;
        result.recipientEnabled = true;
    }

    function supportsZeroCoverageBudgetGate() external pure returns (bool supported) {
        return true;
    }
}
