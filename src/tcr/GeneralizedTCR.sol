// SPDX-License-Identifier: GPL-3.0-or-later
// GeneralizedTCR.sol is a modified version of Kleros' GeneralizedTCR.sol:
// https://github.com/kleros/tcr
//
// GeneralizedTCR.sol source code Copyright Kleros licensed under the MIT license.
// With modifications by rocketman for the Nouns Flows project.

pragma solidity ^0.8.34;

import { IArbitrable } from "./interfaces/IArbitrable.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { IEvidence } from "./interfaces/IEvidence.sol";
import { IGeneralizedTCR } from "./interfaces/IGeneralizedTCR.sol";
import { ISubmissionDepositStrategy } from "./interfaces/ISubmissionDepositStrategy.sol";
import { IERC20VotesArbitrator } from "./interfaces/IERC20VotesArbitrator.sol";
import { IERC20Votes } from "./interfaces/IERC20Votes.sol";
import { CappedMath } from "./utils/CappedMath.sol";
import { ArbitrationCostExtraData } from "./utils/ArbitrationCostExtraData.sol";
import { VotingTokenCompatibility } from "./utils/VotingTokenCompatibility.sol";
import { GeneralizedTCRStorageV1 } from "./storage/GeneralizedTCRStorageV1.sol";
import { TCRRounds } from "./library/TCRRounds.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 *  @title GeneralizedTCR
 *  This contract is a curated registry for any types of items. Just like a TCR contract it features the request-challenge protocol.
 *  @dev Requires a standard ERC20Votes-compatible token. Fee-on-transfer, rebasing, or blacklisting tokens are unsupported.
 */
abstract contract GeneralizedTCR is
    IArbitrable,
    IEvidence,
    IGeneralizedTCR,
    ReentrancyGuardUpgradeable,
    GeneralizedTCRStorageV1
{
    using CappedMath for uint256;
    using SafeERC20 for IERC20;
    using TCRRounds for GeneralizedTCRStorageV1.Round;

    error NON_UPGRADEABLE();

    /**
     *  @dev Initialize the arbitrable curated registry.
     *  @param _arbitrator Arbitrator to resolve potential disputes.
     *  @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     *  @param _registrationMetaEvidence The URI of the meta evidence object for registration requests.
     *  @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     *  @param _governor The trusted governor of this contract.
     *  @param _votingToken The address of the ERC20Votes token used for deposits and vote snapshots.
     *  @param _submissionBaseDeposit The base deposit to submit an item.
     *  @param _removalBaseDeposit The base deposit to remove an item.
     *  @param _submissionChallengeBaseDeposit The base deposit to challenge a submission.
     *  @param _removalChallengeBaseDeposit The base deposit to challenge a removal request.
     *  @param _challengePeriodDuration The time in seconds parties have to challenge a request.
     *  @param _submissionDepositStrategy Strategy for handling submission deposits.
     */
    function __GeneralizedTCR_init(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        string memory _registrationMetaEvidence,
        string memory _clearingMetaEvidence,
        address _governor,
        IVotes _votingToken,
        uint256 _submissionBaseDeposit,
        uint256 _removalBaseDeposit,
        uint256 _submissionChallengeBaseDeposit,
        uint256 _removalChallengeBaseDeposit,
        uint256 _challengePeriodDuration,
        ISubmissionDepositStrategy _submissionDepositStrategy
    ) internal onlyInitializing {
        __ReentrancyGuard_init();

        emit MetaEvidence(0, _registrationMetaEvidence);
        emit MetaEvidence(1, _clearingMetaEvidence);
        if (address(_arbitrator) == address(0)) revert ADDRESS_ZERO();
        if (address(_votingToken) == address(0)) revert ADDRESS_ZERO();
        if (_governor == address(0)) revert ADDRESS_ZERO();

        IERC20Votes votingToken = IERC20Votes(address(_votingToken));

        _ensureVotingTokenCompatibility(votingToken);
        _ensureArbitratorTokenMatches(_arbitrator, _votingToken);
        _ensureArbitratorArbitrableMatches(_arbitrator);

        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        governor = _governor;
        erc20 = IERC20(address(votingToken));
        submissionBaseDeposit = _submissionBaseDeposit;
        removalBaseDeposit = _removalBaseDeposit;
        submissionChallengeBaseDeposit = _submissionChallengeBaseDeposit;
        removalChallengeBaseDeposit = _removalChallengeBaseDeposit;
        challengePeriodDuration = _challengePeriodDuration;
        IArbitrator.ArbitratorParams memory params = _arbitrator.getArbitratorParamsForFactory();
        disputeTimeout = params.votingDelay + params.votingPeriod + params.revealPeriod;
        registrationMetaEvidence = _registrationMetaEvidence;
        clearingMetaEvidence = _clearingMetaEvidence;

        if (address(_submissionDepositStrategy) == address(0)) revert INVALID_SUBMISSION_DEPOSIT_STRATEGY();
        if (address(_submissionDepositStrategy).code.length == 0) revert INVALID_SUBMISSION_DEPOSIT_STRATEGY();

        // Ensure strategy token matches TCR deposit token.
        try _submissionDepositStrategy.token() returns (IERC20 token_) {
            if (token_ != IERC20(address(votingToken))) revert INVALID_SUBMISSION_DEPOSIT_STRATEGY();
        } catch {
            revert INVALID_SUBMISSION_DEPOSIT_STRATEGY();
        }

        submissionDepositStrategy = _submissionDepositStrategy;
    }

    /// @notice Explicitly reject upgrades to keep this contract non-upgradeable.
    function upgradeToAndCall(address, bytes memory) external pure {
        revert NON_UPGRADEABLE();
    }

    /* External and Public */

    // ************************ //
    // *       Requests       * //
    // ************************ //

    /**
     * @dev Submit a request to register an item. Must have approved this contract to transfer at least `submissionBaseDeposit` + `arbitrationCost` ERC20 tokens.
     *  @param _item The data describing the item.
     */
    function addItem(bytes calldata _item) external nonReentrant returns (bytes32 itemID) {
        if (!_verifyItemData(_item)) revert INVALID_ITEM_DATA();

        itemID = _constructNewItemID(_item);
        _assertCanAddItem(itemID, _item);
        if (items[itemID].status != Status.Absent) revert MUST_BE_ABSENT_TO_BE_ADDED();
        _requestStatusChange(_item, itemID, submissionBaseDeposit);
    }

    /**
     * @dev Construct the itemID from the item data.
     *  @param _item The data describing the item.
     *  @return itemID The ID of the item.
     */
    function _constructNewItemID(bytes calldata _item) internal virtual returns (bytes32 itemID) {
        itemID = keccak256(_item);
    }

    /**
     * @dev Verifies the data of an item before it's added to the registry.
     *  @return valid True if the item data is valid, false otherwise.
     */
    function _verifyItemData(bytes calldata) internal virtual returns (bool valid) {
        return true;
    }

    /**
     * @dev Optional extension point for derived registries to reject add-item requests for specific itemIDs.
     */
    function _assertCanAddItem(bytes32, bytes calldata) internal view virtual {}

    /**
     * @dev Submit a request to remove an item from the list. Must have approved this contract to transfer at least `removalBaseDeposit` + `arbitrationCost` ERC20 tokens.
     *  @param _itemID The ID of the item to remove.
     *  @param _evidence A link to an evidence using its URI. Ignored if not provided.
     */
    function removeItem(bytes32 _itemID, string calldata _evidence) external nonReentrant {
        if (items[_itemID].status != Status.Registered) revert MUST_BE_REGISTERED_TO_BE_REMOVED();
        Item storage item = items[_itemID];

        // Emit evidence if it was provided.
        if (bytes(_evidence).length > 0) {
            // Using `length` instead of `length - 1` because a new request will be added on requestStatusChange().
            uint256 requestIndex = item.requests.length;
            uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(_itemID, requestIndex)));

            emit Evidence(arbitrator, evidenceGroupID, msg.sender, _evidence);
        }

        _requestStatusChange(item.data, _itemID, removalBaseDeposit);
    }

    /**
     * @dev Challenges the request of the item. Must have approved this contract to transfer at least `challengeBaseDeposit` + `arbitrationCost` ERC20 tokens.
     *  @param _itemID The ID of the item which request to challenge.
     *  @param _evidence A link to an evidence using its URI. Ignored if not provided.
     */
    function challengeRequest(bytes32 _itemID, string calldata _evidence) external nonReentrant {
        Item storage item = items[_itemID];

        if (item.status != Status.RegistrationRequested && item.status != Status.ClearingRequested) {
            revert ITEM_MUST_HAVE_PENDING_REQUEST();
        }

        Request storage request = item.requests[item.requests.length - 1];
        uint256 challengePeriod = request.challengePeriodDuration;
        if (block.timestamp - request.submissionTime > challengePeriod) {
            revert CHALLENGE_MUST_BE_WITHIN_TIME_LIMIT();
        }
        if (request.disputed) revert REQUEST_ALREADY_DISPUTED();

        request.parties[uint256(Party.Challenger)] = msg.sender;

        Round storage round = request.rounds[0];
        uint256 arbitrationCost = request.arbitrationCost;
        uint256 challengerBaseDeposit = request.challengeBaseDeposit;
        uint256 totalCost = arbitrationCost.addCap(challengerBaseDeposit);
        _contribute(round, Party.Challenger, msg.sender, totalCost, totalCost);
        if (round.amountPaid[uint256(Party.Challenger)] < totalCost) revert MUST_FULLY_FUND_YOUR_SIDE();
        round.hasPaid[uint256(Party.Challenger)] = true;

        // Raise a dispute.

        // approve arbitrator to spend the ERC20 tokens for the arbitration cost only, not for the challenger base deposit
        erc20.forceApprove(address(request.arbitrator), 0);
        erc20.forceApprove(address(request.arbitrator), arbitrationCost);

        // create dispute - arbitrator will transferFrom() the ERC20 tokens to itself
        // changed from Kleros' GeneralizedTCR.sol to not send ETH to arbitrator
        request.disputeID = request.arbitrator.createDispute(RULING_OPTIONS, request.arbitratorExtraData);

        // reset allowance to avoid lingering approvals
        erc20.forceApprove(address(request.arbitrator), 0);

        arbitratorDisputeIDToItem[address(request.arbitrator)][request.disputeID] = _itemID;
        request.disputed = true;
        round.feeRewards = round.feeRewards.subCap(arbitrationCost);

        emit ItemStatusChange(_itemID, item.requests.length - 1, 0, request.disputed, false, item.status);

        uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(_itemID, item.requests.length - 1)));
        emit Dispute(request.arbitrator, request.disputeID, request.metaEvidenceID, evidenceGroupID, _itemID);

        if (bytes(_evidence).length > 0) {
            emit Evidence(request.arbitrator, evidenceGroupID, msg.sender, _evidence);
        }
    }

    /**
     * @dev Reimburses contributions if no disputes were raised. If a dispute was raised, sends the fee stake rewards and reimbursements proportionally to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions to a request.
     *  @param _itemID The ID of the item submission to withdraw from.
     *  @param _request The request from which to withdraw from.
     *  @param _round The round from which to withdraw from.
     */
    function withdrawFeesAndRewards(
        address _beneficiary,
        bytes32 _itemID,
        uint256 _request,
        uint256 _round
    ) external nonReentrant {
        _withdrawFeesAndRewards(_beneficiary, _itemID, _request, _round);
    }

    /**
     * @dev Internal function to handle the logic of withdrawing fees and rewards.
     *  @param _beneficiary The address that made contributions to a request.
     *  @param _itemID The ID of the item submission to withdraw from.
     *  @param _request The request from which to withdraw from.
     *  @param _round The round from which to withdraw from.
     */
    function _withdrawFeesAndRewards(address _beneficiary, bytes32 _itemID, uint256 _request, uint256 _round) internal {
        Item storage item = items[_itemID];
        Request storage request = item.requests[_request];
        Round storage round = request.rounds[_round];
        if (!request.resolved) revert REQUEST_MUST_BE_RESOLVED();

        uint256 reward = round.calculateAndWithdrawRewards(request.ruling, _beneficiary);

        if (reward > 0) {
            // send ERC20 tokens to beneficiary
            erc20.safeTransfer(_beneficiary, reward);
        }
    }

    /**
     * @dev Executes an unchallenged request if the challenge period has passed.
     *  @param _itemID The ID of the item to execute.
     */
    function executeRequest(bytes32 _itemID) external nonReentrant {
        Item storage item = items[_itemID];
        if (item.requests.length == 0) revert MUST_BE_A_REQUEST();
        Request storage request = item.requests[item.requests.length - 1];
        uint256 challengePeriod = request.challengePeriodDuration;
        if (block.timestamp - request.submissionTime <= challengePeriod) revert CHALLENGE_PERIOD_MUST_PASS();
        if (request.disputed) revert REQUEST_MUST_NOT_BE_DISPUTED();

        Status requestType = item.status;

        if (item.status == Status.RegistrationRequested) {
            item.status = Status.Registered;
        } else if (item.status == Status.ClearingRequested) {
            item.status = Status.Absent;
        } else {
            revert MUST_BE_A_REQUEST();
        }

        request.ruling = Party.Requester;
        _handleSubmissionDepositOnResolution(_itemID, requestType, request);

        if (item.status == Status.Registered) {
            _onItemRegistered(_itemID, item.data);
        } else if (item.status == Status.Absent) {
            _onItemRemoved(_itemID);
        }

        request.resolved = true;
        emit ItemStatusChange(
            _itemID,
            item.requests.length - 1,
            request.rounds.length - 1,
            request.disputed,
            true,
            item.status
        );
    }

    /**
     * @dev Executes a disputed request after a timeout if the arbitrator never rules.
     *  @param _itemID The ID of the item to execute.
     */
    function executeRequestTimeout(bytes32 _itemID) external nonReentrant {
        Item storage item = items[_itemID];
        if (item.requests.length == 0) revert MUST_BE_A_REQUEST();
        Request storage request = item.requests[item.requests.length - 1];
        if (!request.disputed) revert REQUEST_MUST_BE_DISPUTED();
        if (request.resolved) revert REQUEST_MUST_NOT_BE_RESOLVED();
        uint256 challengePeriod = request.challengePeriodDuration;
        uint256 timeout = request.disputeTimeout;
        if (timeout == 0) revert DISPUTE_TIMEOUT_DISABLED();
        uint256 timeoutAt = request.submissionTime.addCap(challengePeriod);
        timeoutAt = timeoutAt.addCap(timeout);
        if (block.timestamp <= timeoutAt) {
            revert DISPUTE_TIMEOUT_NOT_PASSED();
        }
        if (request.arbitrator.disputeStatus(request.disputeID) != IArbitrator.DisputeStatus.Solved) {
            revert DISPUTE_NOT_SOLVED();
        }

        address arb = address(request.arbitrator);
        uint256 disputeID = request.disputeID;
        uint256 ruling = _getArbitratorRuling(request.arbitrator, request.disputeID);
        _executeRulingForItem(_itemID, ruling);
        delete arbitratorDisputeIDToItem[arb][disputeID];
    }

    /**
     * @dev Give a ruling for a dispute. Can only be called by the arbitrator. TRUSTED.
     *  @param _disputeID ID of the dispute in the arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) public nonReentrant {
        if (_ruling > RULING_OPTIONS) revert INVALID_RULING_OPTION();
        Party resultRuling = Party(_ruling);
        bytes32 itemID = arbitratorDisputeIDToItem[msg.sender][_disputeID];
        Item storage item = items[itemID];
        if (item.requests.length == 0) revert NO_REQUESTS_FOR_ITEM(itemID);
        Request storage request = item.requests[item.requests.length - 1];
        if (address(request.arbitrator) != msg.sender) revert ONLY_ARBITRATOR_CAN_RULE();
        if (request.resolved) revert REQUEST_MUST_NOT_BE_RESOLVED();
        if (request.disputeID != _disputeID) revert INVALID_DISPUTE_ID();
        if (!request.disputed) revert REQUEST_MUST_BE_DISPUTED();
        if (request.arbitrator.disputeStatus(_disputeID) != IArbitrator.DisputeStatus.Solved) {
            revert DISPUTE_NOT_SOLVED();
        }

        emit Ruling(IArbitrator(msg.sender), _disputeID, uint256(resultRuling));
        _executeRuling(_disputeID, uint256(resultRuling));
        delete arbitratorDisputeIDToItem[msg.sender][_disputeID];
    }

    /**
     * @dev Hook called when an item is registered. Can be overridden by derived contracts.
     *  @param _itemID The ID of the item that was registered.
     *  @param _item The data describing the item.
     */
    function _onItemRegistered(bytes32 _itemID, bytes memory _item) internal virtual {}

    /**
     * @dev Hook called when an item is removed. Can be overridden by derived contracts.
     *  @param _itemID The ID of the item that was removed.
     */
    function _onItemRemoved(bytes32 _itemID) internal virtual {}

    /**
     * @dev Submit a reference to evidence. EVENT.
     *  @param _itemID The ID of the item which the evidence is related to.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(bytes32 _itemID, string calldata _evidence) external nonReentrant {
        Item storage item = items[_itemID];
        if (item.requests.length == 0) revert MUST_BE_A_REQUEST();
        Request storage request = item.requests[item.requests.length - 1];
        if (request.resolved) revert DISPUTE_MUST_NOT_BE_RESOLVED();

        uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(_itemID, item.requests.length - 1)));
        emit Evidence(request.arbitrator, evidenceGroupID, msg.sender, _evidence);
    }

    /* Internal */

    /**
     * @dev Submit a request to change item's status. Accepts enough ERC20 tokens to cover the deposit.
     *  @param _item The data describing the item.
     *  @param _itemID The ID of the item.
     *  @param _baseDeposit The base deposit for the request.
     */
    function _requestStatusChange(bytes memory _item, bytes32 _itemID, uint256 _baseDeposit) internal {
        Item storage item = items[_itemID];

        // Using `length` instead of `length - 1` as index because a new request will be added.
        uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(_itemID, item.requests.length)));
        if (item.requests.length == 0) {
            item.data = _item;
            item.manager = msg.sender;
            itemList.push(_itemID);
            itemIDtoIndex[_itemID] = itemList.length - 1;

            emit ItemSubmitted(_itemID, msg.sender, evidenceGroupID, item.data);
        } else if (item.status == Status.Absent) {
            item.manager = msg.sender;
        }

        Request storage request = item.requests.push();
        if (item.status == Status.Absent) {
            item.status = Status.RegistrationRequested;
            request.metaEvidenceID = 0;
        } else if (item.status == Status.Registered) {
            item.status = Status.ClearingRequested;
            request.metaEvidenceID = 1;
        }

        request.parties[uint256(Party.Requester)] = msg.sender;
        request.submissionTime = block.timestamp;
        request.arbitrator = arbitrator;
        bytes memory baseExtraData = arbitratorExtraData;

        Round storage round = request.rounds.push();

        bool isRegistrationRequest = item.status == Status.RegistrationRequested;
        uint256 arbitrationCost = request.arbitrator.arbitrationCost(baseExtraData);

        // Snapshot parameters at submission time.
        request.challengePeriodDuration = challengePeriodDuration;
        request.disputeTimeout = disputeTimeout;
        request.arbitrationCost = arbitrationCost;
        request.challengeBaseDeposit = isRegistrationRequest
            ? submissionChallengeBaseDeposit
            : removalChallengeBaseDeposit;
        request.arbitratorExtraData = ArbitrationCostExtraData.encode(arbitrationCost, baseExtraData);

        uint256 totalCost = isRegistrationRequest ? arbitrationCost : arbitrationCost.addCap(_baseDeposit);
        _contribute(round, Party.Requester, msg.sender, totalCost, totalCost);
        if (round.amountPaid[uint256(Party.Requester)] < totalCost) revert MUST_FULLY_FUND_YOUR_SIDE();
        round.hasPaid[uint256(Party.Requester)] = true;

        // Collect the separated submission deposit for registration requests.
        if (isRegistrationRequest) {
            _collectSubmissionDeposit(_itemID, msg.sender, _baseDeposit);
        }

        emit ItemStatusChange(
            _itemID,
            item.requests.length - 1,
            request.rounds.length - 1,
            request.disputed,
            false,
            item.status
        );
        emit RequestSubmitted(_itemID, item.requests.length - 1, item.status);
        emit RequestEvidenceGroupID(_itemID, item.requests.length - 1, evidenceGroupID);
    }

    function _collectSubmissionDeposit(bytes32 itemID, address payer, uint256 amount) internal {
        if (amount == 0) return;

        if (submissionDeposits[itemID] != 0) revert SUBMISSION_DEPOSIT_ALREADY_SET();

        // Track actual received amount (fee-on-transfer unsupported).
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(payer, address(this), amount);
        uint256 balanceAfter = erc20.balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore;

        if (received != amount) revert SUBMISSION_DEPOSIT_TRANSFER_INCOMPLETE();

        submissionDeposits[itemID] = amount;
        emit SubmissionDepositPaid(itemID, payer, amount);
    }

    function _handleSubmissionDepositOnResolution(
        bytes32 itemID,
        Status requestType,
        Request storage request
    ) internal {
        uint256 deposit = submissionDeposits[itemID];
        if (deposit == 0) return;

        ISubmissionDepositStrategy strategy = submissionDepositStrategy;
        (ISubmissionDepositStrategy.DepositAction action, address recipient) = strategy.getSubmissionDepositAction(
            itemID,
            requestType,
            request.ruling,
            items[itemID].manager,
            request.parties[uint256(Party.Requester)],
            request.parties[uint256(Party.Challenger)],
            deposit
        );

        if (
            action != ISubmissionDepositStrategy.DepositAction.Hold &&
            action != ISubmissionDepositStrategy.DepositAction.Transfer
        ) {
            revert INVALID_SUBMISSION_DEPOSIT_ACTION();
        }
        if (action == ISubmissionDepositStrategy.DepositAction.Hold && items[itemID].status == Status.Absent) {
            revert INVALID_SUBMISSION_DEPOSIT_ACTION();
        }
        if (action == ISubmissionDepositStrategy.DepositAction.Transfer && recipient == address(0)) {
            revert INVALID_SUBMISSION_DEPOSIT_RECIPIENT();
        }

        if (action == ISubmissionDepositStrategy.DepositAction.Hold) return;

        // CEI: clear before transfer
        delete submissionDeposits[itemID];

        erc20.safeTransfer(recipient, deposit);
        emit SubmissionDepositTransferred(itemID, recipient, deposit, requestType, request.ruling);
    }

    function _ensureArbitratorTokenMatches(IArbitrator _arbitrator, IVotes _votingToken) internal view {
        try IERC20VotesArbitrator(address(_arbitrator)).votingToken() returns (IVotes token) {
            if (address(token) != address(_votingToken)) revert ARBITRATOR_TOKEN_MISMATCH();
        } catch {
            revert ARBITRATOR_TOKEN_MISMATCH();
        }
    }

    function _ensureArbitratorArbitrableMatches(IArbitrator _arbitrator) internal view {
        (bool ok, bytes memory data) = address(_arbitrator).staticcall(abi.encodeWithSignature("arbitrable()"));
        if (!ok || data.length < 32) revert ARBITRATOR_ARBITRABLE_MISMATCH();
        address arbitrableAddress = abi.decode(data, (address));
        if (arbitrableAddress != address(this)) revert ARBITRATOR_ARBITRABLE_MISMATCH();
    }

    function _ensureVotingTokenCompatibility(IERC20Votes _votingToken) internal view {
        address token = address(_votingToken);
        (bool isCompatible, uint8 tokenDecimals) = VotingTokenCompatibility.readErc20AndDecimals(token, address(this));
        if (!isCompatible) revert INVALID_VOTING_TOKEN_COMPATIBILITY();
        if (tokenDecimals != 18) revert INVALID_VOTING_TOKEN_DECIMALS(tokenDecimals);
    }

    /**
     * @dev Make a fee contribution.
     *  @param _round The round to contribute.
     *  @param _side The side for which to contribute.
     *  @param _contributor The contributor.
     *  @param _amount The amount contributed.
     *  @param _totalRequired The total amount required for this side.
     *  @return The amount contributed.
     */
    function _contribute(
        Round storage _round,
        Party _side,
        address _contributor,
        uint256 _amount,
        uint256 _totalRequired
    ) internal returns (uint256) {
        uint256 remainingRequired = _totalRequired.subCap(_round.amountPaid[uint256(_side)]);
        // slither-disable-next-line incorrect-equality
        if (remainingRequired == 0) return 0;

        uint256 amountToTransfer = _amount > remainingRequired ? remainingRequired : _amount;

        // Track actual received amount to avoid over-crediting on non-standard transfers.
        // Fee-on-transfer/rebasing tokens are unsupported because contributors must fully fund their side.
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(_contributor, address(this), amountToTransfer);
        uint256 balanceAfter = erc20.balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore;

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution = _round.contribute(_side, _contributor, received, _totalRequired);

        return contribution;
    }

    /**
     * @dev Execute the ruling of a dispute.
     *  @param _disputeID ID of the dispute in the arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function _executeRuling(uint256 _disputeID, uint256 _ruling) internal {
        bytes32 itemID = arbitratorDisputeIDToItem[msg.sender][_disputeID];
        _executeRulingForItem(itemID, _ruling);
    }

    function _getArbitratorRuling(IArbitrator _arbitrator, uint256 _disputeID) internal view returns (uint256) {
        (bool ok, bytes memory data) = address(_arbitrator).staticcall(
            abi.encodeWithSelector(IArbitrator.currentRuling.selector, _disputeID)
        );
        if (!ok || data.length < 32) revert INVALID_RULING_OPTION();
        return abi.decode(data, (uint256));
    }

    function _executeRulingForItem(bytes32 itemID, uint256 _ruling) internal {
        if (_ruling > RULING_OPTIONS) revert INVALID_RULING_OPTION();
        Item storage item = items[itemID];
        Request storage request = item.requests[item.requests.length - 1];

        Status requestType = item.status;

        Party winner = Party(_ruling);
        bool executed = false;

        if (winner == Party.Requester) {
            // Execute Request.
            if (item.status == Status.RegistrationRequested) {
                item.status = Status.Registered;
                executed = true;
            } else if (item.status == Status.ClearingRequested) {
                item.status = Status.Absent;
                executed = true;
            }
        } else {
            if (item.status == Status.RegistrationRequested) item.status = Status.Absent;
            else if (item.status == Status.ClearingRequested) item.status = Status.Registered;
        }

        request.ruling = Party(_ruling);
        _handleSubmissionDepositOnResolution(itemID, requestType, request);

        if (executed) {
            if (item.status == Status.Registered) {
                _onItemRegistered(itemID, item.data);
            } else if (item.status == Status.Absent) {
                _onItemRemoved(itemID);
            }
        }

        request.resolved = true;
        emit ItemStatusChange(
            itemID,
            item.requests.length - 1,
            request.rounds.length - 1,
            request.disputed,
            true,
            item.status
        );
    }

    // ************************ //
    // *       Getters        * //
    // ************************ //

    /**
     * @dev Returns the total costs for various actions in the registry.
     *      `addItemCost` includes the submission base deposit, but only arbitration cost is tracked in the Round;
     *      the submission base deposit is held separately and settled by submissionDepositStrategy.
     *  @return addItemCost The total cost in ERC20 tokens to add an item.
     *  @return removeItemCost The total cost in ERC20 tokens to remove an item.
     *  @return challengeSubmissionCost The total cost in ERC20 tokens to challenge a submission.
     *  @return challengeRemovalCost The total cost in ERC20 tokens to challenge a removal request.
     *  @return arbitrationCost The cost in ERC20 tokens to arbitrate a dispute.
     */
    function getTotalCosts()
        external
        view
        returns (
            uint256 addItemCost,
            uint256 removeItemCost,
            uint256 challengeSubmissionCost,
            uint256 challengeRemovalCost,
            uint256 arbitrationCost
        )
    {
        arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        addItemCost = submissionBaseDeposit.addCap(arbitrationCost);
        removeItemCost = removalBaseDeposit.addCap(arbitrationCost);
        challengeSubmissionCost = submissionChallengeBaseDeposit.addCap(arbitrationCost);
        challengeRemovalCost = removalChallengeBaseDeposit.addCap(arbitrationCost);
    }

    /**
     * @dev Returns the number of items that were submitted. Includes items that never made it to the list or were later removed.
     *  @return count The number of items on the list.
     */
    function itemCount() external view returns (uint256 count) {
        return itemList.length;
    }

    /**
     * @dev Gets the contributions made by a party for a given round of a request.
     *  @param _itemID The ID of the item.
     *  @param _request The request to query.
     *  @param _round The round to query.
     *  @param _contributor The address of the contributor.
     *  @return contributions The contributions.
     */
    function getContributions(
        bytes32 _itemID,
        uint256 _request,
        uint256 _round,
        address _contributor
    ) external view returns (uint256[3] memory contributions) {
        Item storage item = items[_itemID];
        Request storage request = item.requests[_request];
        Round storage round = request.rounds[_round];
        contributions = round.contributions[_contributor];
    }

    /**
     * @dev Returns item's information. Includes length of requests array.
     *  @param _itemID The ID of the queried item.
     *  @return data The data describing the item.
     *  @return status The current status of the item.
     *  @return numberOfRequests Length of list of status change requests made for the item.
     */
    function getItemInfo(
        bytes32 _itemID
    ) external view returns (bytes memory data, Status status, uint256 numberOfRequests) {
        Item storage item = items[_itemID];
        return (item.data, item.status, item.requests.length);
    }

    /**
     * @dev Gets information on a request made for the item.
     *  @param _itemID The ID of the queried item.
     *  @param _request The request to be queried.
     *  @return disputed True if a dispute was raised.
     *  @return disputeID ID of the dispute, if any..
     *  @return submissionTime Time when the request was made.
     *  @return resolved True if the request was executed and/or any raised disputes were resolved.
     *  @return parties Address of requester and challenger, if any.
     *  @return numberOfRounds Number of rounds of dispute.
     *  @return ruling The final ruling given, if any.
     *  @return arbitrator The arbitrator trusted to solve disputes for this request.
     *  @return arbitratorExtraData The extra data for the trusted arbitrator of this request.
     *  @return metaEvidenceID The meta evidence to be used in a dispute for this case.
     */
    function getRequestInfo(
        bytes32 _itemID,
        uint256 _request
    )
        external
        view
        returns (
            bool disputed,
            uint256 disputeID,
            uint256 submissionTime,
            bool resolved,
            address[3] memory parties,
            uint256 numberOfRounds,
            Party ruling,
            IArbitrator arbitrator,
            bytes memory arbitratorExtraData,
            uint256 metaEvidenceID
        )
    {
        Request storage request = items[_itemID].requests[_request];
        return (
            request.disputed,
            request.disputeID,
            request.submissionTime,
            request.resolved,
            request.parties,
            request.rounds.length,
            request.ruling,
            request.arbitrator,
            request.arbitratorExtraData,
            request.metaEvidenceID
        );
    }

    function getLatestRequestIndex(bytes32 _itemID) external view override returns (bool exists, uint256 requestIndex) {
        uint256 requestCount = items[_itemID].requests.length;
        if (requestCount == 0) return (false, 0);
        return (true, requestCount - 1);
    }

    function getRequestSnapshot(
        bytes32 _itemID,
        uint256 _request
    )
        external
        view
        override
        returns (
            Status requestType,
            uint256 challengePeriodDuration_,
            uint256 disputeTimeout_,
            uint256 arbitrationCost_,
            uint256 challengeBaseDeposit_
        )
    {
        Request storage request = items[_itemID].requests[_request];
        requestType = _requestTypeFromMetaEvidence(request.metaEvidenceID);
        challengePeriodDuration_ = request.challengePeriodDuration;
        disputeTimeout_ = request.disputeTimeout;
        arbitrationCost_ = request.arbitrationCost;
        challengeBaseDeposit_ = request.challengeBaseDeposit;
    }

    function getRequestState(
        bytes32 _itemID,
        uint256 _request
    )
        external
        view
        override
        returns (
            RequestPhase phase,
            uint256 challengeDeadline,
            uint256 timeoutAt,
            IArbitrator.DisputeStatus arbitratorStatus,
            bool canChallenge,
            bool canExecuteRequest,
            bool canExecuteTimeout
        )
    {
        Item storage item = items[_itemID];
        if (_request >= item.requests.length) {
            return (RequestPhase.None, 0, 0, IArbitrator.DisputeStatus.Waiting, false, false, false);
        }

        Request storage request = item.requests[_request];
        challengeDeadline = request.submissionTime.addCap(request.challengePeriodDuration);
        arbitratorStatus = IArbitrator.DisputeStatus.Waiting;

        if (request.resolved) {
            arbitratorStatus = request.disputed ? IArbitrator.DisputeStatus.Solved : IArbitrator.DisputeStatus.Waiting;
            phase = RequestPhase.Resolved;
            return (phase, challengeDeadline, 0, arbitratorStatus, false, false, false);
        }

        if (!request.disputed) {
            canChallenge = block.timestamp <= challengeDeadline;
            canExecuteRequest = block.timestamp > challengeDeadline;
            phase = canExecuteRequest ? RequestPhase.UnchallengedExecutable : RequestPhase.ChallengePeriod;
            return (phase, challengeDeadline, 0, arbitratorStatus, canChallenge, canExecuteRequest, false);
        }

        arbitratorStatus = request.arbitrator.disputeStatus(request.disputeID);
        timeoutAt = challengeDeadline.addCap(request.disputeTimeout);
        canExecuteTimeout =
            request.disputeTimeout != 0 &&
            block.timestamp > timeoutAt &&
            arbitratorStatus == IArbitrator.DisputeStatus.Solved;
        phase = arbitratorStatus == IArbitrator.DisputeStatus.Solved
            ? RequestPhase.DisputeSolvedAwaitingExecution
            : RequestPhase.DisputePending;
    }

    /**
     * @dev Gets the information of a round of a request.
     *  @param _itemID The ID of the queried item.
     *  @param _request The request to be queried.
     *  @param _round The round to be queried.
     *  @return amountPaid Tracks the sum paid for each Party in this round.
     *  @return hasPaid True if the Party has fully paid its fee in this round.
     *  @return feeRewards Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
     */
    function getRoundInfo(
        bytes32 _itemID,
        uint256 _request,
        uint256 _round
    ) external view returns (uint256[3] memory amountPaid, bool[3] memory hasPaid, uint256 feeRewards) {
        Item storage item = items[_itemID];
        Request storage request = item.requests[_request];
        Round storage round = request.rounds[_round];
        return (round.amountPaid, round.hasPaid, round.feeRewards);
    }

    function _requestTypeFromMetaEvidence(uint256 metaEvidenceID) internal pure returns (Status requestType) {
        return metaEvidenceID % 2 == 0 ? Status.RegistrationRequested : Status.ClearingRequested;
    }
}
