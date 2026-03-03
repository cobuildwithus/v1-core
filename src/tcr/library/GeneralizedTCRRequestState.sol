// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IArbitrator } from "../interfaces/IArbitrator.sol";
import { IGeneralizedTCR } from "../interfaces/IGeneralizedTCR.sol";
import { GeneralizedTCRStorageV1 } from "../storage/GeneralizedTCRStorageV1.sol";
import { CappedMath } from "../utils/CappedMath.sol";

library GeneralizedTCRRequestState {
    using CappedMath for uint256;

    function getRequestState(
        mapping(bytes32 => GeneralizedTCRStorageV1.Item) storage items,
        bytes32 itemID,
        uint256 requestIndex
    )
        external
        view
        returns (
            IGeneralizedTCR.RequestPhase phase,
            uint256 challengeDeadline,
            uint256 timeoutAt,
            IArbitrator.DisputeStatus arbitratorStatus,
            bool canChallenge,
            bool canExecuteRequest,
            bool canExecuteTimeout
        )
    {
        GeneralizedTCRStorageV1.Item storage item = items[itemID];
        if (requestIndex >= item.requests.length) {
            return (IGeneralizedTCR.RequestPhase.None, 0, 0, IArbitrator.DisputeStatus.Waiting, false, false, false);
        }

        GeneralizedTCRStorageV1.Request storage request = item.requests[requestIndex];
        challengeDeadline = request.submissionTime.addCap(request.challengePeriodDuration);
        arbitratorStatus = IArbitrator.DisputeStatus.Waiting;

        if (request.resolved) {
            arbitratorStatus = request.disputed ? IArbitrator.DisputeStatus.Solved : IArbitrator.DisputeStatus.Waiting;
            phase = IGeneralizedTCR.RequestPhase.Resolved;
            return (phase, challengeDeadline, 0, arbitratorStatus, false, false, false);
        }

        if (!request.disputed) {
            canChallenge = block.timestamp <= challengeDeadline;
            canExecuteRequest = block.timestamp > challengeDeadline;
            phase = canExecuteRequest
                ? IGeneralizedTCR.RequestPhase.UnchallengedExecutable
                : IGeneralizedTCR.RequestPhase.ChallengePeriod;
            return (phase, challengeDeadline, 0, arbitratorStatus, canChallenge, canExecuteRequest, false);
        }

        arbitratorStatus = request.arbitrator.disputeStatus(request.disputeID);
        timeoutAt = challengeDeadline.addCap(request.disputeTimeout);
        canExecuteTimeout =
            request.disputeTimeout != 0 &&
            block.timestamp > timeoutAt &&
            arbitratorStatus == IArbitrator.DisputeStatus.Solved;
        phase = arbitratorStatus == IArbitrator.DisputeStatus.Solved
            ? IGeneralizedTCR.RequestPhase.DisputeSolvedAwaitingExecution
            : IGeneralizedTCR.RequestPhase.DisputePending;
    }

    function requestTypeFromMetaEvidence(
        uint256 metaEvidenceID
    ) external pure returns (IGeneralizedTCR.Status requestType) {
        return metaEvidenceID % 2 == 0 ? IGeneralizedTCR.Status.RegistrationRequested : IGeneralizedTCR.Status.ClearingRequested;
    }
}
