// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISpendPolicy } from "src/interfaces/ISpendPolicy.sol";

import { TreasuryBase } from "./TreasuryBase.sol";
import { TreasuryPostDeadlineFinalize } from "./library/TreasuryPostDeadlineFinalize.sol";
import { TreasuryReassertGrace } from "./library/TreasuryReassertGrace.sol";
import { TreasurySuccessAssertionLifecycle } from "./library/TreasurySuccessAssertionLifecycle.sol";
import { TreasurySuccessAssertions } from "./library/TreasurySuccessAssertions.sol";

abstract contract TreasurySuccessAssertionMixin is TreasuryBase {
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    enum PostDeadlineAction {
        None,
        FinalizeSucceeded,
        FinalizeExpired
    }

    function pendingSuccessAssertionId() public view virtual returns (bytes32) {
        return TreasurySuccessAssertions.pendingId(_successAssertionsState());
    }

    function pendingSuccessAssertionAt() public view virtual returns (uint64) {
        return TreasurySuccessAssertions.pendingAt(_successAssertionsState());
    }

    function reassertGraceDeadline() public view virtual returns (uint64) {
        return _reassertGraceState().deadline;
    }

    function reassertGraceUsed() public view virtual returns (bool) {
        return _reassertGraceState().used;
    }

    function isReassertGraceActive() public view virtual returns (bool) {
        return _reassertGraceState().isActive();
    }

    function resolved() public view virtual returns (bool) {
        return _isResolvedState();
    }

    function flow() public view virtual returns (address) {
        return _flowAddress();
    }

    function treasuryBalance() public view virtual returns (uint256) {
        return _treasuryBalance();
    }

    function _syncMode() internal view returns (ISpendPolicy.SyncMode) {
        return ISpendPolicy(_spendPolicy()).syncMode();
    }

    function _clearPendingSuccessAssertionAndResetGrace() internal {
        _emitSuccessAssertionCleared(
            TreasurySuccessAssertionLifecycle.clearPendingAndResetGrace(
                _successAssertionsState(),
                _reassertGraceState()
            )
        );
    }

    function _resolvePostDeadlineAction(uint64 reassertGraceDuration) internal returns (PostDeadlineAction action) {
        TreasurySuccessAssertionLifecycle.PostDeadlineResolution memory resolution = TreasurySuccessAssertionLifecycle
            .resolvePostDeadline(
                _successAssertionsState(),
                _reassertGraceState(),
                _successResolver(),
                _successAssertionLiveness(),
                _successAssertionBond(),
                _canActivateReassertGrace(),
                reassertGraceDuration
            );

        if (resolution.failClosedReason != TreasurySuccessAssertions.FailClosedReason.None) {
            _emitSuccessAssertionResolutionFailClosed(resolution.pendingAssertionId, resolution.failClosedReason);
        }

        if (resolution.decision == TreasuryPostDeadlineFinalize.Decision.ClearPendingAndActivateGrace) {
            _emitSuccessAssertionCleared(resolution.clearedAssertionId);
            if (resolution.finalizeFailureData.length != 0) {
                _emitSuccessAssertionFinalizeFailed(resolution.clearedAssertionId, resolution.finalizeFailureData);
            }
            if (resolution.graceActivated) {
                _emitReassertGraceActivated(resolution.clearedAssertionId, resolution.graceDeadline);
            }
            return PostDeadlineAction.None;
        }

        if (resolution.decision == TreasuryPostDeadlineFinalize.Decision.FinalizeSucceeded) {
            return PostDeadlineAction.FinalizeSucceeded;
        }
        if (resolution.decision == TreasuryPostDeadlineFinalize.Decision.FinalizeExpired) {
            return PostDeadlineAction.FinalizeExpired;
        }
        return PostDeadlineAction.None;
    }

    function _successAssertionsState() internal view virtual returns (TreasurySuccessAssertions.State storage state);

    function _reassertGraceState() internal view virtual returns (TreasuryReassertGrace.State storage state);

    function _spendPolicy() internal view virtual returns (address);
    function _successResolver() internal view virtual returns (address);
    function _successAssertionLiveness() internal view virtual returns (uint64);
    function _successAssertionBond() internal view virtual returns (uint256);
    function _canActivateReassertGrace() internal view virtual returns (bool);
    function _isResolvedState() internal view virtual returns (bool);
    function _emitSuccessAssertionCleared(bytes32 assertionId) internal virtual;
    function _emitSuccessAssertionResolutionFailClosed(
        bytes32 assertionId,
        TreasurySuccessAssertions.FailClosedReason reason
    ) internal virtual;
    function _emitSuccessAssertionFinalizeFailed(bytes32 assertionId, bytes memory revertData) internal virtual;
    function _emitReassertGraceActivated(bytes32 clearedAssertionId, uint64 graceDeadline) internal virtual;
}
