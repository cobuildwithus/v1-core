// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IArbitrable } from "../interfaces/IArbitrable.sol";
import { IArbitrator } from "../interfaces/IArbitrator.sol";
import { IGeneralizedTCR } from "../interfaces/IGeneralizedTCR.sol";
import { ISubmissionDepositStrategy } from "../interfaces/ISubmissionDepositStrategy.sol";
import { GeneralizedTCRStorageV1 } from "../storage/GeneralizedTCRStorageV1.sol";
import { ArbitrationCostExtraData } from "../utils/ArbitrationCostExtraData.sol";
import { CappedMath } from "../utils/CappedMath.sol";

library GeneralizedTCRRuntimeLib {
    using CappedMath for uint256;

    struct OpenRequestResult {
        uint256 requestIndex;
        uint256 evidenceGroupID;
        bool isRegistrationRequest;
        uint256 totalCost;
    }

    struct DepositResolution {
        bool shouldTransfer;
        address recipient;
        uint256 amount;
    }

    function openRequest(
        GeneralizedTCRStorageV1.Item storage item,
        bytes32[] storage itemList,
        mapping(bytes32 => uint256) storage itemIDtoIndex,
        bytes32 itemID,
        bytes memory itemData,
        bool setItemData,
        address manager,
        address requester,
        IArbitrator arbitrator,
        bytes memory baseExtraData,
        uint256 challengePeriodDuration,
        uint256 disputeTimeout,
        uint256 submissionChallengeBaseDeposit,
        uint256 removalChallengeBaseDeposit,
        uint256 baseDeposit
    ) external returns (OpenRequestResult memory result) {
        uint256 requestIndex = item.requests.length;
        result.requestIndex = requestIndex;
        result.evidenceGroupID = uint256(keccak256(abi.encodePacked(itemID, requestIndex)));

        if (setItemData) {
            item.data = itemData;
            item.manager = manager;

            if (requestIndex == 0) {
                itemList.push(itemID);
                itemIDtoIndex[itemID] = itemList.length - 1;
            }
        }

        GeneralizedTCRStorageV1.Request storage request = item.requests.push();
        if (item.status == IGeneralizedTCR.Status.Absent) {
            item.status = IGeneralizedTCR.Status.RegistrationRequested;
            request.metaEvidenceID = 0;
        } else if (item.status == IGeneralizedTCR.Status.Registered) {
            item.status = IGeneralizedTCR.Status.ClearingRequested;
            request.metaEvidenceID = 1;
        }

        request.parties[uint256(IArbitrable.Party.Requester)] = requester;
        request.submissionTime = block.timestamp;
        request.arbitrator = arbitrator;
        request.rounds.push();

        result.isRegistrationRequest = item.status == IGeneralizedTCR.Status.RegistrationRequested;
        uint256 arbitrationCost = arbitrator.arbitrationCost(baseExtraData);

        request.challengePeriodDuration = challengePeriodDuration;
        request.disputeTimeout = disputeTimeout;
        request.arbitrationCost = arbitrationCost;
        request.challengeBaseDeposit = result.isRegistrationRequest
            ? submissionChallengeBaseDeposit
            : removalChallengeBaseDeposit;
        request.arbitratorExtraData = ArbitrationCostExtraData.encode(arbitrationCost, baseExtraData);

        result.totalCost = result.isRegistrationRequest ? arbitrationCost : arbitrationCost.addCap(baseDeposit);
    }

    function applyUnchallengedStatusChange(
        GeneralizedTCRStorageV1.Item storage item
    ) external returns (IGeneralizedTCR.Status requestType) {
        requestType = item.status;

        if (item.status == IGeneralizedTCR.Status.RegistrationRequested) {
            item.status = IGeneralizedTCR.Status.Registered;
        } else if (item.status == IGeneralizedTCR.Status.ClearingRequested) {
            item.status = IGeneralizedTCR.Status.Absent;
        } else {
            revert IGeneralizedTCR.MUST_BE_A_REQUEST();
        }

        GeneralizedTCRStorageV1.Request storage request = item.requests[item.requests.length - 1];
        request.ruling = IArbitrable.Party.Requester;
    }

    function applyRulingStatus(
        GeneralizedTCRStorageV1.Item storage item,
        uint256 ruling
    ) external returns (IGeneralizedTCR.Status requestType, bool executed) {
        requestType = item.status;
        IArbitrable.Party winner = IArbitrable.Party(ruling);
        GeneralizedTCRStorageV1.Request storage request = item.requests[item.requests.length - 1];

        if (winner == IArbitrable.Party.Requester) {
            if (item.status == IGeneralizedTCR.Status.RegistrationRequested) {
                item.status = IGeneralizedTCR.Status.Registered;
                executed = true;
            } else if (item.status == IGeneralizedTCR.Status.ClearingRequested) {
                item.status = IGeneralizedTCR.Status.Absent;
                executed = true;
            }
        } else {
            if (item.status == IGeneralizedTCR.Status.RegistrationRequested) {
                item.status = IGeneralizedTCR.Status.Absent;
            } else if (item.status == IGeneralizedTCR.Status.ClearingRequested) {
                item.status = IGeneralizedTCR.Status.Registered;
            }
        }

        request.ruling = winner;
    }

    function resolveSubmissionDeposit(
        mapping(bytes32 => uint256) storage submissionDeposits,
        mapping(bytes32 => GeneralizedTCRStorageV1.Item) storage items,
        bytes32 itemID,
        ISubmissionDepositStrategy strategy,
        IGeneralizedTCR.Status requestType,
        GeneralizedTCRStorageV1.Request storage request
    ) external returns (DepositResolution memory resolution) {
        uint256 deposit = submissionDeposits[itemID];
        if (deposit == 0) return resolution;

        GeneralizedTCRStorageV1.Item storage item = items[itemID];
        (ISubmissionDepositStrategy.DepositAction action, address recipient) = strategy.getSubmissionDepositAction(
            itemID,
            requestType,
            request.ruling,
            item.manager,
            request.parties[uint256(IArbitrable.Party.Requester)],
            request.parties[uint256(IArbitrable.Party.Challenger)],
            deposit
        );

        if (
            action != ISubmissionDepositStrategy.DepositAction.Hold &&
            action != ISubmissionDepositStrategy.DepositAction.Transfer
        ) {
            revert IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_ACTION();
        }
        if (action == ISubmissionDepositStrategy.DepositAction.Hold && item.status == IGeneralizedTCR.Status.Absent) {
            revert IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_ACTION();
        }
        if (action == ISubmissionDepositStrategy.DepositAction.Transfer && recipient == address(0)) {
            revert IGeneralizedTCR.INVALID_SUBMISSION_DEPOSIT_RECIPIENT();
        }

        if (action == ISubmissionDepositStrategy.DepositAction.Hold) return resolution;

        delete submissionDeposits[itemID];

        resolution.shouldTransfer = true;
        resolution.recipient = recipient;
        resolution.amount = deposit;
    }

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
