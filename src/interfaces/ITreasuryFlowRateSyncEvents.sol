// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface ITreasuryFlowRateSyncEvents {
    event FlowRateSyncManualInterventionRequired(
        address indexed flow,
        int96 targetRate,
        int96 fallbackRate,
        int96 currentRate
    );
    event FlowRateSyncCallFailed(address indexed flow, bytes4 indexed selector, int96 attemptedRate, bytes reason);
}
