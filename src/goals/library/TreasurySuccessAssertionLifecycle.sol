// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IUMATreasurySuccessResolver } from "src/interfaces/IUMATreasurySuccessResolver.sol";
import { TreasuryPostDeadlineFinalize } from "./TreasuryPostDeadlineFinalize.sol";
import { TreasuryReassertGrace } from "./TreasuryReassertGrace.sol";
import { TreasurySuccessAssertions } from "./TreasurySuccessAssertions.sol";

library TreasurySuccessAssertionLifecycle {
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    struct ClearResult {
        bytes32 clearedAssertionId;
        bool graceActivated;
        uint64 graceDeadline;
    }

    struct PostDeadlineResolution {
        bytes32 pendingAssertionId;
        bytes32 clearedAssertionId;
        TreasuryPostDeadlineFinalize.Decision decision;
        TreasurySuccessAssertions.FailClosedReason failClosedReason;
        bytes finalizeFailureData;
        bool graceActivated;
        uint64 graceDeadline;
    }

    function resolvePostDeadline(
        TreasurySuccessAssertions.State storage successAssertions,
        TreasuryReassertGrace.State storage reassertGrace,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond,
        bool canActivateGrace,
        uint64 reassertGraceDuration
    ) internal returns (PostDeadlineResolution memory resolution) {
        (resolution.pendingAssertionId, resolution.decision, resolution.failClosedReason) = TreasuryPostDeadlineFinalize
            .evaluate(
                successAssertions,
                reassertGrace,
                successResolver,
                successAssertionLiveness,
                successAssertionBond
            );

        if (resolution.decision != TreasuryPostDeadlineFinalize.Decision.ClearPendingAndActivateGrace) {
            return resolution;
        }

        (resolution.clearedAssertionId, resolution.finalizeFailureData) = clearPendingAndTryFinalize(
            successAssertions,
            successResolver
        );
        (resolution.graceActivated, resolution.graceDeadline) = tryActivateGrace(
            reassertGrace,
            canActivateGrace,
            reassertGraceDuration
        );
    }

    function clearPending(
        TreasurySuccessAssertions.State storage successAssertions
    ) internal returns (bytes32 clearedAssertionId) {
        return successAssertions.clear();
    }

    function clearPendingAndResetGrace(
        TreasurySuccessAssertions.State storage successAssertions,
        TreasuryReassertGrace.State storage reassertGrace
    ) internal returns (bytes32 clearedAssertionId) {
        reassertGrace.clearDeadline();
        return clearPending(successAssertions);
    }

    function clearMatching(
        TreasurySuccessAssertions.State storage successAssertions,
        bytes32 assertionId
    ) internal returns (bytes32 clearedAssertionId) {
        return successAssertions.clearMatching(assertionId);
    }

    function clearMatchingAndTryActivateGrace(
        TreasurySuccessAssertions.State storage successAssertions,
        TreasuryReassertGrace.State storage reassertGrace,
        bytes32 assertionId,
        bool canActivateGrace,
        uint64 reassertGraceDuration
    ) internal returns (ClearResult memory result) {
        result.clearedAssertionId = clearMatching(successAssertions, assertionId);
        (result.graceActivated, result.graceDeadline) = tryActivateGrace(
            reassertGrace,
            canActivateGrace,
            reassertGraceDuration
        );
    }

    function clearPendingAndTryFinalize(
        TreasurySuccessAssertions.State storage successAssertions,
        address successResolver
    ) internal returns (bytes32 clearedAssertionId, bytes memory finalizeFailureData) {
        clearedAssertionId = clearPending(successAssertions);
        if (clearedAssertionId == bytes32(0)) return (bytes32(0), bytes(""));

        try IUMATreasurySuccessResolver(successResolver).finalize(clearedAssertionId) {} catch (
            bytes memory revertData
        ) {
            finalizeFailureData = revertData;
        }
    }

    function tryActivateGrace(
        TreasuryReassertGrace.State storage reassertGrace,
        bool canActivateGrace,
        uint64 reassertGraceDuration
    ) internal returns (bool graceActivated, uint64 graceDeadline) {
        if (!canActivateGrace) return (false, 0);
        return reassertGrace.activateOnce(reassertGraceDuration);
    }
}
