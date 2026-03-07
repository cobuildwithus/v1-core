// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IUMATreasurySuccessResolver } from "src/interfaces/IUMATreasurySuccessResolver.sol";
import { TreasuryPostDeadlineFinalize } from "./TreasuryPostDeadlineFinalize.sol";
import { TreasuryReassertGrace } from "./TreasuryReassertGrace.sol";
import { TreasurySuccessAssertions } from "./TreasurySuccessAssertions.sol";

library TreasurySuccessAssertionLifecycle {
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;

    struct PostDeadlineResolution {
        bytes32 pendingAssertionId;
        bytes32 clearedAssertionId;
        TreasuryPostDeadlineFinalize.Decision decision;
        TreasurySuccessAssertions.FailClosedReason failClosedReason;
        bytes finalizeFailureData;
    }

    function resolvePostDeadline(
        TreasurySuccessAssertions.State storage successAssertions,
        TreasuryReassertGrace.State storage reassertGrace,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
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
    }

    function clearPending(
        TreasurySuccessAssertions.State storage successAssertions
    ) internal returns (bytes32 clearedAssertionId) {
        return successAssertions.clear();
    }

    function clearMatching(
        TreasurySuccessAssertions.State storage successAssertions,
        bytes32 assertionId
    ) internal returns (bytes32 clearedAssertionId) {
        return successAssertions.clearMatching(assertionId);
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
}
