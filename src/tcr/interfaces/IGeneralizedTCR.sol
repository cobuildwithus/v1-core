// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IArbitrable } from "./IArbitrable.sol";
import { IArbitrator } from "./IArbitrator.sol";

interface IGeneralizedTCR {
    /* Errors */

    /// @notice Thrown when attempting to add an item that is not in the 'Absent' state.
    /// @dev This error is used to ensure that only items not currently in the registry can be added.
    error MUST_BE_ABSENT_TO_BE_ADDED();

    /// @notice Thrown when the item data is invalid.
    /// @dev This error is used to ensure that only valid item data can be added to the registry.
    error INVALID_ITEM_DATA();

    /// @notice Thrown when attempting to remove an item that is not in the 'Registered' state.
    /// @dev This error is used to ensure that only items currently in the registry can be removed.
    error MUST_BE_REGISTERED_TO_BE_REMOVED();

    /// @notice The item must have a pending request to be challenged.
    /// @dev This error is used to ensure that only items with a pending request can be challenged.
    error ITEM_MUST_HAVE_PENDING_REQUEST();

    /// @notice Challenges must occur during the challenge period.
    /// @dev This error is used to ensure that only challenges within the specified time limit can be made.
    error CHALLENGE_MUST_BE_WITHIN_TIME_LIMIT();

    /// @notice The request should not have already been disputed.
    /// @dev This error is used to ensure that only requests that have not been disputed can be challenged.
    error REQUEST_ALREADY_DISPUTED();

    /// @notice The party must fully fund their side.
    error MUST_FULLY_FUND_YOUR_SIDE();

    /// @notice The request must be resolved before executing the ruling.
    error REQUEST_MUST_BE_RESOLVED();

    /// @notice The request must not be already resolved.
    error REQUEST_MUST_NOT_BE_RESOLVED();

    /// @notice The time to challenge the request must pass before execution.
    error CHALLENGE_PERIOD_MUST_PASS();

    /// @notice The request should not be disputed to be executed.
    error REQUEST_MUST_NOT_BE_DISPUTED();

    /// @notice There must be a request to execute the ruling.
    error MUST_BE_A_REQUEST();

    /// @notice The ruling option provided is invalid.
    error INVALID_RULING_OPTION();

    /// @notice Only the arbitrator can give a ruling.
    error ONLY_ARBITRATOR_CAN_RULE();

    /// @notice The mapped item has no requests to rule on.
    error NO_REQUESTS_FOR_ITEM(bytes32 itemID);

    /// @notice The dispute must not already be resolved.
    error DISPUTE_MUST_NOT_BE_RESOLVED();

    /// @notice If address 0 is passed as an argument, the function will revert.
    error ADDRESS_ZERO();

    /// @notice The arbitrator voting token must match the TCR deposit token.
    error ARBITRATOR_TOKEN_MISMATCH();

    /// @notice The voting token must expose ERC20-compatible reads.
    error INVALID_VOTING_TOKEN_COMPATIBILITY();

    /// @notice The voting token must use 18 decimals.
    error INVALID_VOTING_TOKEN_DECIMALS(uint8 decimals);

    /// @notice The arbitrator's arbitrable contract must be this TCR.
    error ARBITRATOR_ARBITRABLE_MISMATCH();

    /// @notice The submission deposit strategy is invalid.
    error INVALID_SUBMISSION_DEPOSIT_STRATEGY();

    /// @notice The submission deposit is already set for this item.
    error SUBMISSION_DEPOSIT_ALREADY_SET();

    /// @notice The submission deposit transfer did not receive the full amount.
    error SUBMISSION_DEPOSIT_TRANSFER_INCOMPLETE();

    /// @notice The submission deposit action is invalid.
    error INVALID_SUBMISSION_DEPOSIT_ACTION();

    /// @notice The submission deposit recipient is invalid.
    error INVALID_SUBMISSION_DEPOSIT_RECIPIENT();

    /// @notice The request must be disputed.
    error REQUEST_MUST_BE_DISPUTED();

    /// @notice The dispute ID does not match the latest request.
    error INVALID_DISPUTE_ID();

    /// @notice The dispute timeout must be enabled.
    error DISPUTE_TIMEOUT_DISABLED();

    /// @notice The dispute timeout period has not passed.
    error DISPUTE_TIMEOUT_NOT_PASSED();

    /// @notice The dispute is not yet solved by the arbitrator.
    error DISPUTE_NOT_SOLVED();

    /* Enums */

    /**
     * @notice Enum representing the status of an item in the registry
     */
    enum Status {
        Absent, // The item is not in the registry.
        Registered, // The item is in the registry.
        RegistrationRequested, // The item has a request to be added to the registry.
        ClearingRequested // The item has a request to be removed from the registry.
    }

    enum RequestPhase {
        None,
        ChallengePeriod,
        UnchallengedExecutable,
        DisputePending,
        DisputeSolvedAwaitingExecution,
        Resolved
    }

    /**
     * @notice Emitted when a party makes a request, raises a dispute or when a request is resolved
     * @param _itemID The ID of the affected item
     * @param _requestIndex The index of the request
     * @param _roundIndex The index of the round
     * @param _disputed Whether the request is disputed
     * @param _resolved Whether the request is executed
     * @param _itemStatus The new status of the item
     */
    event ItemStatusChange(
        bytes32 indexed _itemID,
        uint256 indexed _requestIndex,
        uint256 indexed _roundIndex,
        bool _disputed,
        bool _resolved,
        Status _itemStatus
    );

    /**
     * @notice Emitted when someone submits an item for the first time
     * @param _itemID The ID of the new item
     * @param _submitter The address of the requester
     * @param _evidenceGroupID Unique identifier of the evidence group the evidence belongs to
     * @param _data The item data
     */
    event ItemSubmitted(
        bytes32 indexed _itemID,
        address indexed _submitter,
        uint256 indexed _evidenceGroupID,
        bytes _data
    );

    /**
     * @notice Emitted when someone submits a request
     * @param _itemID The ID of the affected item
     * @param _requestIndex The index of the latest request
     * @param _requestType Whether it is a registration or a removal request
     */
    event RequestSubmitted(bytes32 indexed _itemID, uint256 indexed _requestIndex, Status indexed _requestType);

    /**
     * @notice Emitted when someone submits a request. This is useful to quickly find an item and request from an evidence event and vice-versa
     * @param _itemID The ID of the affected item
     * @param _requestIndex The index of the latest request
     * @param _evidenceGroupID The evidence group ID used for this request
     */
    event RequestEvidenceGroupID(
        bytes32 indexed _itemID,
        uint256 indexed _requestIndex,
        uint256 indexed _evidenceGroupID
    );

    /**
     * @notice Emitted when a submission deposit is paid.
     * @param itemID The ID of the affected item.
     * @param payer The address that paid the deposit.
     * @param amount The deposit amount.
     */
    event SubmissionDepositPaid(bytes32 indexed itemID, address indexed payer, uint256 amount);

    /**
     * @notice Emitted when a submission deposit is transferred.
     * @param itemID The ID of the affected item.
     * @param recipient The address receiving the deposit.
     * @param amount The deposit amount.
     * @param requestType The request type before resolution.
     * @param ruling The final ruling for the request.
     */
    event SubmissionDepositTransferred(
        bytes32 indexed itemID,
        address indexed recipient,
        uint256 amount,
        Status requestType,
        IArbitrable.Party ruling
    );

    function getLatestRequestIndex(bytes32 _itemID) external view returns (bool exists, uint256 requestIndex);
    function getRequestSnapshot(
        bytes32 _itemID,
        uint256 _request
    )
        external
        view
        returns (
            Status requestType,
            uint256 challengePeriodDuration_,
            uint256 disputeTimeout_,
            uint256 arbitrationCost_,
            uint256 challengeBaseDeposit_
        );
    function getRequestState(
        bytes32 _itemID,
        uint256 _request
    )
        external
        view
        returns (
            RequestPhase phase,
            uint256 challengeDeadline,
            uint256 timeoutAt,
            IArbitrator.DisputeStatus arbitratorStatus,
            bool canChallenge,
            bool canExecuteRequest,
            bool canExecuteTimeout
        );
}
