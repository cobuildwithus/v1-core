// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { ISubmissionDepositStrategy } from "./interfaces/ISubmissionDepositStrategy.sol";
import { IGeneralizedTCR } from "./interfaces/IGeneralizedTCR.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title RoundSubmissionTCR
 * @notice A per-round TCR used to permissionlessly submit round entries while charging a bond.
 *         The bond is escrowed by the underlying GeneralizedTCR logic and can be routed to a
 *         prize pool via a submission-deposit strategy (e.g., PrizePoolSubmissionDepositStrategy).
 *
 *         This contract intentionally keeps submission data minimal and chain-agnostic: callers
 *         submit a compact reference to offchain content (e.g., Farcaster cast hash, X tweet id).
 */
contract RoundSubmissionTCR is GeneralizedTCR {
    /// @dev A compact, chain-agnostic submission reference.
    ///      `source` is an application-defined discriminator (e.g., 0=farcaster, 1=x).
    ///      `postId` is an application-defined identifier (e.g., cast hash, tweet id).
    struct SubmissionRef {
        uint8 source;
        bytes32 postId;
    }

    struct RoundConfig {
        /// @dev A round identifier (typically provided by the parent AllocationMechanismTCR itemID).
        bytes32 roundId;
        /// @dev Earliest time submissions are accepted (0 disables the lower bound).
        uint64 startAt;
        /// @dev Latest time submissions are accepted, inclusive (0 disables the upper bound).
        uint64 endAt;
        /// @dev Optional informational pointer for indexers/UI.
        address prizeVault;
    }

    struct RegistryConfig {
        IArbitrator arbitrator;
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        address governor;
        IVotes votingToken;
        uint256 submissionBaseDeposit;
        ISubmissionDepositStrategy submissionDepositStrategy;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
    }

    error INVALID_TIME_WINDOW(uint64 startAt, uint64 endAt);

    /// @notice Round identifier (for indexing / UI).
    bytes32 public roundId;
    /// @notice Earliest time submissions are accepted.
    uint64 public startAt;
    /// @notice Latest time submissions are accepted, inclusive.
    uint64 public endAt;
    /// @notice Optional prize vault pointer.
    address public prizeVault;

    constructor() {
        _disableInitializers();
    }

    function initialize(RoundConfig calldata roundConfig, RegistryConfig calldata registryConfig) external initializer {
        if (roundConfig.endAt != 0 && roundConfig.startAt != 0 && roundConfig.endAt < roundConfig.startAt) {
            revert INVALID_TIME_WINDOW(roundConfig.startAt, roundConfig.endAt);
        }

        roundId = roundConfig.roundId;
        startAt = roundConfig.startAt;
        endAt = roundConfig.endAt;
        prizeVault = roundConfig.prizeVault;

        __GeneralizedTCR_init(
            registryConfig.arbitrator,
            registryConfig.arbitratorExtraData,
            registryConfig.registrationMetaEvidence,
            registryConfig.clearingMetaEvidence,
            registryConfig.governor,
            registryConfig.votingToken,
            registryConfig.submissionBaseDeposit,
            registryConfig.removalBaseDeposit,
            registryConfig.submissionChallengeBaseDeposit,
            registryConfig.removalChallengeBaseDeposit,
            registryConfig.challengePeriodDuration,
            registryConfig.submissionDepositStrategy
        );
    }

    /// @notice Helper for offchain clients to construct the canonical submission payload.
    function encodeSubmission(SubmissionRef calldata ref) external pure returns (bytes memory) {
        return abi.encode(ref.source, ref.postId);
    }

    /// @notice Helper to decode the canonical submission payload.
    function decodeSubmission(bytes calldata itemData) public pure returns (SubmissionRef memory ref) {
        (ref.source, ref.postId) = abi.decode(itemData, (uint8, bytes32));
    }

    /// @notice Gas-efficient helper for prize vaults to fetch manager + status without returning item data.
    function itemManagerAndStatus(
        bytes32 itemID
    ) external view returns (address manager, IGeneralizedTCR.Status status) {
        Item storage it = items[itemID];
        return (it.manager, it.status);
    }

    /// @inheritdoc GeneralizedTCR
    function _verifyItemData(bytes calldata itemData) internal view override returns (bool valid) {
        // Enforce the submission window if configured.
        if (startAt != 0 && block.timestamp < startAt) return false;
        // `endAt` is inclusive: submissions at exactly `endAt` remain valid.
        if (endAt != 0 && block.timestamp > endAt) return false;

        // Canonical encoding: (uint8 source, bytes32 postId).
        // ABI encoding uses 2 words => 64 bytes.
        if (itemData.length != 64) return false;

        SubmissionRef memory submissionRef = decodeSubmission(itemData);
        if (submissionRef.postId == bytes32(0)) return false;

        return true;
    }

    /// @inheritdoc GeneralizedTCR
    function _constructNewItemID(bytes calldata itemData) internal pure override returns (bytes32 itemID) {
        // (roundId is implicit because this TCR is deployed per-round)
        SubmissionRef memory ref = decodeSubmission(itemData);
        return keccak256(abi.encodePacked(ref.source, ref.postId));
    }
}
