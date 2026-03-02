// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

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
