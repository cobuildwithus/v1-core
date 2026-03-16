// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISpendPolicy } from "src/interfaces/ISpendPolicy.sol";
import { ITreasuryFlowRateSyncEvents } from "src/interfaces/ITreasuryFlowRateSyncEvents.sol";
import { ITreasurySuccessAssertionEvents } from "src/interfaces/ITreasurySuccessAssertionEvents.sol";

import { TreasuryFlowRateSync } from "./library/TreasuryFlowRateSync.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";
import { TreasurySuccessAssertionMixin } from "./TreasurySuccessAssertionMixin.sol";

abstract contract TreasuryFlowRateAssertionBase is
    TreasurySuccessAssertionMixin,
    ITreasurySuccessAssertionEvents,
    ITreasuryFlowRateSyncEvents
{
    function pendingSuccessAssertionId() public view virtual override(TreasurySuccessAssertionMixin) returns (bytes32) {
        return super.pendingSuccessAssertionId();
    }

    function pendingSuccessAssertionAt() public view virtual override(TreasurySuccessAssertionMixin) returns (uint64) {
        return super.pendingSuccessAssertionAt();
    }

    function reassertGraceDeadline() public view virtual override(TreasurySuccessAssertionMixin) returns (uint64) {
        return super.reassertGraceDeadline();
    }

    function reassertGraceUsed() public view virtual override(TreasurySuccessAssertionMixin) returns (bool) {
        return super.reassertGraceUsed();
    }

    function isReassertGraceActive() public view virtual override(TreasurySuccessAssertionMixin) returns (bool) {
        return super.isReassertGraceActive();
    }

    function resolved() public view virtual override(TreasurySuccessAssertionMixin) returns (bool) {
        return super.resolved();
    }

    function flow() public view virtual override(TreasurySuccessAssertionMixin) returns (address) {
        return super.flow();
    }

    function treasuryBalance() public view virtual override(TreasurySuccessAssertionMixin) returns (uint256) {
        return super.treasuryBalance();
    }

    function targetFlowRate() public view virtual returns (int96) {
        uint256 balance = _treasuryBalance();
        uint256 remaining = timeRemaining();
        return _computeTargetFlowRate(balance, remaining);
    }

    function _syncFlowRate() internal {
        uint256 balance = _treasuryBalance();
        uint256 remaining = timeRemaining();
        int96 targetRate = _computeTargetFlowRate(balance, remaining);
        int96 appliedRate;
        if (_syncMode() == ISpendPolicy.SyncMode.LinearSpendDownFallback) {
            appliedRate = TreasuryFlowRateSync.applyLinearSpendDownWithFallback(
                _flowContract(),
                targetRate,
                balance,
                remaining
            );
        } else {
            appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(_flowContract(), targetRate);
        }

        emit FlowRateSynced(targetRate, appliedRate, balance, remaining);
    }

    function _emitSuccessAssertionCleared(bytes32 assertionId) internal virtual override {
        if (assertionId == bytes32(0)) return;
        emit SuccessAssertionCleared(assertionId);
    }

    function _emitSuccessAssertionResolutionFailClosed(
        bytes32 assertionId,
        TreasurySuccessAssertions.FailClosedReason reason
    ) internal virtual override {
        emit SuccessAssertionResolutionFailClosed(assertionId, reason);
    }

    function _emitSuccessAssertionFinalizeFailed(
        bytes32 assertionId,
        bytes memory revertData
    ) internal virtual override {
        emit SuccessAssertionFinalizeFailed(assertionId, revertData);
    }

    function _emitReassertGraceActivated(bytes32 clearedAssertionId, uint64 graceDeadline) internal virtual override {
        emit ReassertGraceActivated(clearedAssertionId, graceDeadline);
    }

    function timeRemaining() public view virtual returns (uint256);
    function _computeTargetFlowRate(uint256 balance, uint256 remaining) internal view virtual returns (int96);
}
