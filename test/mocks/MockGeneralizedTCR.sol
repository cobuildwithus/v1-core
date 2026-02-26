// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GeneralizedTCR} from "src/tcr/GeneralizedTCR.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

/// @dev Concrete implementation for testing the abstract GeneralizedTCR.
contract MockGeneralizedTCR is GeneralizedTCR {
    event HookItemRegistered(bytes32 indexed itemID, bytes data);
    event HookItemRemoved(bytes32 indexed itemID);

    Round internal testRound;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address,
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
    ) external initializer {
        _initializeInternal(
            _arbitrator,
            _arbitratorExtraData,
            _registrationMetaEvidence,
            _clearingMetaEvidence,
            _governor,
            _votingToken,
            _submissionBaseDeposit,
            _removalBaseDeposit,
            _submissionChallengeBaseDeposit,
            _removalChallengeBaseDeposit,
            _challengePeriodDuration,
            _submissionDepositStrategy
        );
    }

    function _initializeInternal(
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
    ) internal {
        __GeneralizedTCR_init(
            _arbitrator,
            _arbitratorExtraData,
            _registrationMetaEvidence,
            _clearingMetaEvidence,
            _governor,
            _votingToken,
            _submissionBaseDeposit,
            _removalBaseDeposit,
            _submissionChallengeBaseDeposit,
            _removalChallengeBaseDeposit,
            _challengePeriodDuration,
            _submissionDepositStrategy
        );
    }

    /// @dev For branch coverage: treat empty items as invalid.
    function _verifyItemData(bytes calldata item) internal pure override returns (bool) {
        return item.length > 0;
    }

    function _onItemRegistered(bytes32 itemID, bytes memory data) internal virtual override {
        emit HookItemRegistered(itemID, data);
    }

    function _onItemRemoved(bytes32 itemID) internal virtual override {
        emit HookItemRemoved(itemID);
    }

    function exposedContribute(
        address contributor,
        uint256 amount,
        uint256 totalRequired
    ) external returns (uint256 contribution) {
        contribution = _contribute(testRound, Party.Requester, contributor, amount, totalRequired);
    }

    function exposedContribution(address contributor) external view returns (uint256) {
        return testRound.contributions[contributor][uint256(Party.Requester)];
    }

    function exposedSetArbitratorDisputeIDToItem(address arb, uint256 disputeID, bytes32 itemID) external {
        arbitratorDisputeIDToItem[arb][disputeID] = itemID;
    }

    function exposedSetRequestResolved(bytes32 itemID, uint256 requestIndex, bool resolved) external {
        items[itemID].requests[requestIndex].resolved = resolved;
    }

    function exposedSetSubmissionDeposit(bytes32 itemID, uint256 amount) external {
        submissionDeposits[itemID] = amount;
    }
}
