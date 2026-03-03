// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { TreasurySuccessAssertions } from "./TreasurySuccessAssertions.sol";
import { TreasuryReassertGrace } from "./TreasuryReassertGrace.sol";

library TreasuryPostDeadlineFinalize {
    enum Decision {
        Wait,
        FinalizeSucceeded,
        FinalizeExpired,
        ClearPendingAndActivateGrace
    }

    struct Inputs {
        bytes32 pendingAssertionId;
        bool reassertGraceActive;
        bool assertionResolved;
        bool assertionTruthful;
        bool reassertGraceUsed;
    }

    function evaluate(
        TreasurySuccessAssertions.State storage successAssertions,
        TreasuryReassertGrace.State storage reassertGrace,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    )
        internal
        view
        returns (
            bytes32 pendingAssertionId,
            Decision decision,
            TreasurySuccessAssertions.FailClosedReason failClosedReason
        )
    {
        bool assertionResolved;
        bool assertionTruthful;

        pendingAssertionId = TreasurySuccessAssertions.pendingId(successAssertions);
        if (pendingAssertionId != bytes32(0)) {
            (assertionResolved, assertionTruthful, failClosedReason) = TreasurySuccessAssertions
                .pendingSuccessAssertionResolutionWithReason(
                successAssertions,
                pendingAssertionId,
                successResolver,
                successAssertionLiveness,
                successAssertionBond
            );
        }

        decision = decide(
            Inputs({
                pendingAssertionId: pendingAssertionId,
                reassertGraceActive: TreasuryReassertGrace.isActive(reassertGrace),
                assertionResolved: assertionResolved,
                assertionTruthful: assertionTruthful,
                reassertGraceUsed: reassertGrace.used
            })
        );
    }

    function decide(Inputs memory inputs) internal pure returns (Decision) {
        if (inputs.pendingAssertionId == bytes32(0)) {
            if (inputs.reassertGraceActive) return Decision.Wait;
            return Decision.FinalizeExpired;
        }

        if (!inputs.assertionResolved) return Decision.Wait;
        if (inputs.assertionTruthful) return Decision.FinalizeSucceeded;
        if (!inputs.reassertGraceUsed) return Decision.ClearPendingAndActivateGrace;

        return Decision.FinalizeExpired;
    }
}
