// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IArbitrator.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IERC20VotesArbitrator is IArbitrator {
    struct VotingRoundInfo {
        uint8 state;
        uint256 votingStartTime;
        uint256 votingEndTime;
        uint256 revealPeriodStartTime;
        uint256 revealPeriodEndTime;
        uint256 creationBlock;
        uint256 cost;
        uint256 totalVotes;
        uint256 requesterVotes;
        uint256 challengerVotes;
        IArbitrable.Party ruling;
    }

    struct VoterRoundStatus {
        bool hasCommitted;
        bool hasRevealed;
        bytes32 commitHash;
        uint256 choice;
        uint256 votes;
        bool rewardsClaimed;
        bool slashedOrProcessed;
        uint256 claimableReward;
        uint256 claimableGoalSlashReward;
        uint256 claimableCobuildSlashReward;
    }

    struct InitConfig {
        address invalidRoundRewardsSink;
        address votingToken;
        address arbitrable;
        uint256 votingPeriod;
        uint256 votingDelay;
        uint256 revealPeriod;
        uint256 arbitrationCost;
        address stakeVault;
        address fixedBudgetTreasury;
        uint256 wrongOrMissedSlashBps;
        uint256 slashCallerBountyBps;
    }

    /// @notice Error thrown when the voting token address is invalid (zero address)
    error INVALID_VOTING_TOKEN_ADDRESS();

    /// @notice Error thrown when the voting token does not expose ERC20-compatible reads.
    error INVALID_VOTING_TOKEN_COMPATIBILITY();

    /// @notice Error thrown when the voting token uses a non-blocknumber clock mode.

    /// @notice Error thrown when the voting token does not use 18 decimals.
    error INVALID_VOTING_TOKEN_DECIMALS(uint8 decimals);

    /// @notice Error thrown when the voting period is outside the allowed range
    error INVALID_VOTING_PERIOD();

    /// @notice Error thrown when the voting delay is outside the allowed range
    error INVALID_VOTING_DELAY();

    /// @notice Error thrown when the function is called by an address other than the arbitrable address
    error ONLY_ARBITRABLE();

    /// @notice Error thrown when a fixed budget context is invalid.
    error INVALID_FIXED_BUDGET_CONTEXT();

    /// @notice Error thrown when the reveal period is outside the allowed range
    error INVALID_REVEAL_PERIOD();

    /// @notice Error thrown when the dispute ID is invalid
    error INVALID_DISPUTE_ID();

    /// @notice Error thrown when trying to execute a dispute that is not in the Solved state
    error DISPUTE_NOT_SOLVED();

    /// @notice Error thrown when trying to execute a dispute that has already been executed
    error DISPUTE_ALREADY_EXECUTED();

    /// @notice Error thrown when the round is invalid
    error INVALID_ROUND();

    /// @notice Error thrown when there are no votes
    error NO_VOTES();

    /// @notice Error thrown when owner tries to withdraw rewards for a round that has votes
    error VOTES_WERE_CAST();

    /// @notice Error thrown when the arbitration cost is outside the allowed range
    error INVALID_ARBITRATION_COST();

    /// @notice Error thrown when slash bps is outside the allowed range.
    error INVALID_WRONG_OR_MISSED_SLASH_BPS();

    /// @notice Error thrown when caller bounty bps is outside the allowed range.
    error INVALID_SLASH_CALLER_BOUNTY_BPS();

    /// @notice Error thrown when the arbitrable address is invalid (zero address)
    error INVALID_ARBITRABLE_ADDRESS();

    /// @notice Error thrown when the voting is closed for a dispute
    error VOTING_CLOSED();

    /// @notice Error thrown when a voter has no votes
    error VOTER_HAS_NO_VOTES();

    /// @notice Error thrown when an invalid vote choice is selected
    error INVALID_VOTE_CHOICE();

    /// @notice Error thrown when a voter attempts to vote more than once on a dispute
    error VOTER_ALREADY_VOTED();

    /// @notice Error thrown when the number of choices for a dispute is invalid
    error INVALID_DISPUTE_CHOICES();

    /// @notice Error thrown when a voter has not voted
    error VOTER_HAS_NOT_VOTED();

    /// @notice Error thrown when invalid/no-vote reward sink is invalid (zero address)
    error INVALID_INVALID_ROUND_REWARD_SINK();

    /// @notice Error thrown when a reward has already been claimed
    error REWARD_ALREADY_CLAIMED();

    /// @notice Error thrown when a voter is on the losing side
    error VOTER_ON_LOSING_SIDE();

    /// @notice Error thrown when a voter has not committed a vote
    error NO_COMMITTED_VOTE();

    /// @notice Error thrown when a voter has already revealed a vote
    error ALREADY_REVEALED_VOTE();

    /// @notice Error thrown when the hashes do not match
    error HASHES_DO_NOT_MATCH();

    /**
     * @notice Returns the voting token used for arbitration costs and voting power.
     * @return token The ERC20 voting token address.
     */
    function votingToken() external view returns (IVotes token);
    function fixedBudgetTreasury() external view returns (address budgetTreasury);
    function invalidRoundRewardsSink() external view returns (address sink);

    /**
     * @notice Emitted when a voter withdraws their proportional share of the cost for a voting round
     * @param disputeId The ID of the dispute
     * @param round The round number
     * @param voter The address of the voter
     * @param amount The amount withdrawn
     */
    event RewardWithdrawn(uint256 indexed disputeId, uint256 indexed round, address indexed voter, uint256 amount);

    event WrongOrMissedSlashBpsSet(uint256 oldWrongOrMissedSlashBps, uint256 newWrongOrMissedSlashBps);
    event SlashCallerBountyBpsSet(uint256 oldSlashCallerBountyBps, uint256 newSlashCallerBountyBps);
    event SlashRewardsWithdrawn(
        uint256 indexed disputeId,
        uint256 indexed round,
        address indexed voter,
        uint256 goalAmount,
        uint256 cobuildAmount
    );

    /**
     * @notice Emitted when a vote has been cast on a dispute
     * @param voter The address of the voter
     * @param disputeId The ID of the dispute
     * @param commitHash The keccak256 hash of
     * `abi.encode(block.chainid, address(this), disputeId, round, voter, choice, reason, salt)`
     */
    event VoteCommitted(address indexed voter, uint256 disputeId, bytes32 commitHash);

    /**
     * @notice Emitted when a vote has been revealed for a dispute
     * @param voter The address of the voter
     * @param disputeId The ID of the dispute
     * @param commitHash The keccak256 hash of
     * `abi.encode(block.chainid, address(this), disputeId, round, voter, choice, reason, salt)`
     * @param choice The revealed choice of the voter
     * @param reason The reason for the vote
     * @param votes The number of votes cast
     */
    event VoteRevealed(
        address indexed voter,
        uint256 indexed disputeId,
        bytes32 commitHash,
        uint256 choice,
        string reason,
        uint256 votes
    );

    /**
     * @dev Emitted when a dispute is executed and a ruling is set
     * @param disputeId The ID of the executed dispute
     * @param ruling The final ruling for the dispute
     */
    event DisputeExecuted(uint256 indexed disputeId, IArbitrable.Party ruling);

    /**
     * @notice Emitted when a new dispute is created
     * @param id The ID of the newly created dispute
     * @param arbitrable The address of the arbitrable contract
     * @param votingStartTime The timestamp when voting starts
     * @param votingEndTime The timestamp when voting ends
     * @param revealPeriodEndTime The timestamp when the reveal period ends
     * @param creationBlock The block number when the dispute was created
     * @param arbitrationCost The cost paid by the arbitrable contract for this voting round.
     * @param extraData Additional data related to the dispute
     * @param choices The number of choices available for voting
     */
    event DisputeCreated(
        uint256 id,
        address indexed arbitrable,
        uint256 votingStartTime,
        uint256 votingEndTime,
        uint256 revealPeriodEndTime,
        uint256 creationBlock,
        uint256 arbitrationCost,
        bytes extraData,
        uint256 choices
    );

    function getVotingRoundInfo(uint256 disputeId, uint256 round) external view returns (VotingRoundInfo memory info);
    function getVoterRoundStatus(
        uint256 disputeId,
        uint256 round,
        address voter
    ) external view returns (VoterRoundStatus memory status);
    function getSlashRewardsForRound(
        uint256 disputeId,
        uint256 round,
        address voter
    ) external view returns (uint256 goalAmount, uint256 cobuildAmount);
    function isVoterSlashedOrProcessed(uint256 disputeId, uint256 round, address voter) external view returns (bool);
    function slashVoter(uint256 disputeId, uint256 round, address voter) external;
    function slashVoters(uint256 disputeId, uint256 round, address[] calldata voters) external;
    function withdrawVoterRewards(uint256 disputeId, uint256 round, address voter) external;
    function computeCommitHash(
        uint256 disputeId,
        uint256 round,
        address voter,
        uint256 choice,
        string calldata reason,
        bytes32 salt
    ) external view returns (bytes32 commitHash);

    /**
     * @notice Canonical initializer for all deployment modes.
     * @param config Initialization config.
     */
    function initializeWithConfig(InitConfig calldata config) external;
}
