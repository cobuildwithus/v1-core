// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { TreasurySuccessAssertions } from "src/goals/library/TreasurySuccessAssertions.sol";

interface ITreasurySuccessAssertionEvents {
    event SuccessAssertionRegistered(bytes32 indexed assertionId, uint64 indexed assertedAt);
    event SuccessAssertionCleared(bytes32 indexed assertionId);
    event SuccessAssertionResolutionFailClosed(
        bytes32 indexed assertionId,
        TreasurySuccessAssertions.FailClosedReason indexed reason
    );
    event SuccessAssertionFinalizeFailed(bytes32 indexed assertionId, bytes revertData);
    event ReassertGraceActivated(bytes32 indexed clearedAssertionId, uint64 indexed graceDeadline);
}
