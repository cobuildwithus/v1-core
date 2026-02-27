// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20VotesArbitrator } from "./interfaces/IERC20VotesArbitrator.sol";
import { IArbitrable } from "./interfaces/IArbitrable.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { IERC20Votes } from "./interfaces/IERC20Votes.sol";
import { ArbitratorStorageV1 } from "./storage/ArbitratorStorageV1.sol";
import { ArbitrationCostExtraData } from "./utils/ArbitrationCostExtraData.sol";
import { VotingTokenCompatibility } from "./utils/VotingTokenCompatibility.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IRewardEscrow } from "src/interfaces/IRewardEscrow.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IJurorSlasher } from "src/interfaces/IJurorSlasher.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract ERC20VotesArbitrator is IERC20VotesArbitrator, ReentrancyGuardUpgradeable, ArbitratorStorageV1 {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_WRONG_OR_MISSED_SLASH_BPS = 50;
    uint256 public constant DEFAULT_SLASH_CALLER_BOUNTY_BPS = 100;
    uint256 public constant MAX_SLASH_CALLER_BOUNTY_BPS = 500;

    uint256 public wrongOrMissedSlashBps;
    uint256 public slashCallerBountyBps;
    address public invalidRoundRewardsSink;

    error INVALID_STAKE_VAULT_ADDRESS();
    error INVALID_STAKE_VAULT_GOAL_TREASURY();
    error INVALID_STAKE_VAULT_REWARD_ESCROW();
    error INVALID_SLASH_RECIPIENT();
    error NON_UPGRADEABLE();
    error UNAUTHORIZED_DELEGATE();
    error STAKE_VAULT_NOT_SET();
    error STAKE_VAULT_ALREADY_SET();

    event StakeVaultConfigured(address indexed stakeVault);
    event VoterSlashed(
        uint256 indexed disputeId,
        uint256 indexed round,
        address indexed voter,
        uint256 snapshotVotes,
        uint256 slashWeight,
        bool missedReveal,
        address recipient
    );

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Used to initialize the contract
     * @param invalidRoundRewardsSink_ The sink address for unresolved/no-vote round rewards
     * @param votingToken_ The address of the ERC20 voting token
     * @param arbitrable_ The address of the arbitrable contract
     * @param votingPeriod_ The initial voting period
     * @param votingDelay_ The initial voting delay
     * @param revealPeriod_ The initial reveal period to reveal committed votes
     * @param arbitrationCost_ The initial arbitration cost
     */
    function initialize(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_
    ) public initializer {
        _initialize(
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            invalidRoundRewardsSink_,
            DEFAULT_WRONG_OR_MISSED_SLASH_BPS,
            DEFAULT_SLASH_CALLER_BOUNTY_BPS
        );
    }

    /**
     * @notice Used to initialize the contract with explicit slash configuration.
     * @param invalidRoundRewardsSink_ The sink address for unresolved/no-vote round rewards
     * @param votingToken_ The address of the ERC20 voting token
     * @param arbitrable_ The address of the arbitrable contract
     * @param votingPeriod_ The initial voting period
     * @param votingDelay_ The initial voting delay
     * @param revealPeriod_ The initial reveal period to reveal committed votes
     * @param arbitrationCost_ The initial arbitration cost
     * @param wrongOrMissedSlashBps_ The slash bps for wrong vote or missed reveal
     * @param slashCallerBountyBps_ The caller bounty bps paid from slashed amount
     */
    function initializeWithSlashConfig(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        uint256 wrongOrMissedSlashBps_,
        uint256 slashCallerBountyBps_
    ) public initializer {
        _initialize(
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            invalidRoundRewardsSink_,
            wrongOrMissedSlashBps_,
            slashCallerBountyBps_
        );
    }

    /**
     * @notice Used to initialize the contract with stake-vault-backed voting power.
     * @param invalidRoundRewardsSink_ The sink address for unresolved/no-vote round rewards
     * @param votingToken_ The address of the ERC20 token used for arbitration costs/rewards
     * @param arbitrable_ The address of the arbitrable contract
     * @param votingPeriod_ The initial voting period
     * @param votingDelay_ The initial voting delay
     * @param revealPeriod_ The initial reveal period to reveal committed votes
     * @param arbitrationCost_ The initial arbitration cost
     * @param stakeVault_ The stake vault used for juror voting power snapshots
     */
    function initializeWithStakeVault(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        address stakeVault_
    ) public initializer {
        _initializeWithStakeVaultAndSlashConfig(
            invalidRoundRewardsSink_,
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            stakeVault_,
            address(0),
            DEFAULT_WRONG_OR_MISSED_SLASH_BPS,
            DEFAULT_SLASH_CALLER_BOUNTY_BPS
        );
    }

    /**
     * @notice Used to initialize the contract with stake-vault-backed voting power and explicit slash config.
     * @param invalidRoundRewardsSink_ The sink address for unresolved/no-vote round rewards
     * @param votingToken_ The address of the ERC20 token used for arbitration costs/rewards
     * @param arbitrable_ The address of the arbitrable contract
     * @param votingPeriod_ The initial voting period
     * @param votingDelay_ The initial voting delay
     * @param revealPeriod_ The initial reveal period to reveal committed votes
     * @param arbitrationCost_ The initial arbitration cost
     * @param stakeVault_ The stake vault used for juror voting power snapshots
     * @param wrongOrMissedSlashBps_ The slash bps for wrong vote or missed reveal
     * @param slashCallerBountyBps_ The caller bounty bps paid from slashed amount
     */
    function initializeWithStakeVaultAndSlashConfig(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        address stakeVault_,
        uint256 wrongOrMissedSlashBps_,
        uint256 slashCallerBountyBps_
    ) public initializer {
        _initializeWithStakeVaultAndSlashConfig(
            invalidRoundRewardsSink_,
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            stakeVault_,
            address(0),
            wrongOrMissedSlashBps_,
            slashCallerBountyBps_
        );
    }

    function initializeWithStakeVaultAndBudgetScope(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        address stakeVault_,
        address fixedBudgetTreasury_
    ) public initializer {
        _initializeWithStakeVaultAndSlashConfig(
            invalidRoundRewardsSink_,
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            stakeVault_,
            fixedBudgetTreasury_,
            DEFAULT_WRONG_OR_MISSED_SLASH_BPS,
            DEFAULT_SLASH_CALLER_BOUNTY_BPS
        );
    }

    function initializeWithStakeVaultAndBudgetScopeAndSlashConfig(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        address stakeVault_,
        address fixedBudgetTreasury_,
        uint256 wrongOrMissedSlashBps_,
        uint256 slashCallerBountyBps_
    ) public initializer {
        _initializeWithStakeVaultAndSlashConfig(
            invalidRoundRewardsSink_,
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            stakeVault_,
            fixedBudgetTreasury_,
            wrongOrMissedSlashBps_,
            slashCallerBountyBps_
        );
    }

    function _initializeWithStakeVaultAndSlashConfig(
        address invalidRoundRewardsSink_,
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        address stakeVault_,
        address fixedBudgetTreasury_,
        uint256 wrongOrMissedSlashBps_,
        uint256 slashCallerBountyBps_
    ) internal {
        _initialize(
            votingToken_,
            arbitrable_,
            votingPeriod_,
            votingDelay_,
            revealPeriod_,
            arbitrationCost_,
            invalidRoundRewardsSink_,
            wrongOrMissedSlashBps_,
            slashCallerBountyBps_
        );
        _setStakeVault(stakeVault_);
        _setFixedBudgetTreasury(fixedBudgetTreasury_);
    }

    function _initialize(
        address votingToken_,
        address arbitrable_,
        uint256 votingPeriod_,
        uint256 votingDelay_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_,
        address invalidRoundRewardsSink_,
        uint256 wrongOrMissedSlashBps_,
        uint256 slashCallerBountyBps_
    ) internal {
        if (arbitrable_ == address(0)) revert INVALID_ARBITRABLE_ADDRESS();
        if (votingToken_ == address(0)) revert INVALID_VOTING_TOKEN_ADDRESS();
        if (invalidRoundRewardsSink_ == address(0)) revert INVALID_INVALID_ROUND_REWARD_SINK();
        _ensureVotingTokenCompatibility(votingToken_);
        if (votingPeriod_ < MIN_VOTING_PERIOD || votingPeriod_ > MAX_VOTING_PERIOD) revert INVALID_VOTING_PERIOD();
        if (votingDelay_ < MIN_VOTING_DELAY || votingDelay_ > MAX_VOTING_DELAY) revert INVALID_VOTING_DELAY();
        if (revealPeriod_ < MIN_REVEAL_PERIOD || revealPeriod_ > MAX_REVEAL_PERIOD) revert INVALID_REVEAL_PERIOD();
        if (arbitrationCost_ < MIN_ARBITRATION_COST || arbitrationCost_ > MAX_ARBITRATION_COST) {
            revert INVALID_ARBITRATION_COST();
        }
        if (wrongOrMissedSlashBps_ > BPS_DENOMINATOR) revert INVALID_WRONG_OR_MISSED_SLASH_BPS();
        if (slashCallerBountyBps_ > MAX_SLASH_CALLER_BOUNTY_BPS) revert INVALID_SLASH_CALLER_BOUNTY_BPS();
        __ReentrancyGuard_init();

        emit VotingPeriodSet(_votingPeriod, votingPeriod_);
        emit VotingDelaySet(_votingDelay, votingDelay_);
        emit RevealPeriodSet(_revealPeriod, revealPeriod_);
        emit ArbitrationCostSet(_arbitrationCost, arbitrationCost_);
        emit WrongOrMissedSlashBpsSet(wrongOrMissedSlashBps, wrongOrMissedSlashBps_);
        emit SlashCallerBountyBpsSet(slashCallerBountyBps, slashCallerBountyBps_);

        _votingToken = IERC20Votes(votingToken_);
        arbitrable = IArbitrable(arbitrable_);
        _votingPeriod = votingPeriod_;
        _votingDelay = votingDelay_;
        _revealPeriod = revealPeriod_;
        _arbitrationCost = arbitrationCost_;
        wrongOrMissedSlashBps = wrongOrMissedSlashBps_;
        slashCallerBountyBps = slashCallerBountyBps_;
        invalidRoundRewardsSink = invalidRoundRewardsSink_;
    }

    function configureStakeVault(address stakeVault_) external {
        if (msg.sender != address(arbitrable)) revert ONLY_ARBITRABLE();
        _setStakeVault(stakeVault_);
    }

    function setVotingPeriod(uint256 votingPeriod_) external onlyArbitrable {
        if (votingPeriod_ < MIN_VOTING_PERIOD || votingPeriod_ > MAX_VOTING_PERIOD) revert INVALID_VOTING_PERIOD();

        emit VotingPeriodSet(_votingPeriod, votingPeriod_);
        _votingPeriod = votingPeriod_;
    }

    function setVotingDelay(uint256 votingDelay_) external onlyArbitrable {
        if (votingDelay_ < MIN_VOTING_DELAY || votingDelay_ > MAX_VOTING_DELAY) revert INVALID_VOTING_DELAY();

        emit VotingDelaySet(_votingDelay, votingDelay_);
        _votingDelay = votingDelay_;
    }

    function setRevealPeriod(uint256 revealPeriod_) external onlyArbitrable {
        if (revealPeriod_ < MIN_REVEAL_PERIOD || revealPeriod_ > MAX_REVEAL_PERIOD) revert INVALID_REVEAL_PERIOD();

        emit RevealPeriodSet(_revealPeriod, revealPeriod_);
        _revealPeriod = revealPeriod_;
    }

    function setArbitrationCost(uint256 arbitrationCost_) external onlyArbitrable {
        if (arbitrationCost_ < MIN_ARBITRATION_COST || arbitrationCost_ > MAX_ARBITRATION_COST) {
            revert INVALID_ARBITRATION_COST();
        }

        emit ArbitrationCostSet(_arbitrationCost, arbitrationCost_);
        _arbitrationCost = arbitrationCost_;
    }

    /// @notice Explicitly reject upgrades to keep this contract non-upgradeable.
    function upgradeToAndCall(address, bytes memory) external pure {
        revert NON_UPGRADEABLE();
    }

    /**
     * @notice Function used to create a new dispute. Only callable by the arbitrable contract.
     * @param _choices The number of choices for the dispute
     * @param _extraData Additional data for the dispute
     * @return disputeID The ID of the new dispute
     */
    function createDispute(
        uint256 _choices,
        bytes calldata _extraData
    ) external onlyArbitrable nonReentrant returns (uint256 disputeID) {
        // only support 2 choices for now
        if (_choices != 2) revert INVALID_DISPUTE_CHOICES();

        uint256 arbitrationCost_ = _arbitrationCostFromExtraData(_extraData);

        // get tokens from arbitrable
        // arbitrable must have approved the arbitrator to transfer the tokens
        // fails otherwise
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(address(_votingToken)).safeTransferFrom(address(arbitrable), address(this), arbitrationCost_);

        disputeCount++;
        Dispute storage newDispute = disputes[disputeCount];

        newDispute.id = disputeCount;
        newDispute.arbitrable = address(arbitrable);
        newDispute.currentRound = 0;
        newDispute.choices = _choices;
        newDispute.executed = false;

        newDispute.rounds[0].votingStartTime = block.timestamp + _votingDelay;
        newDispute.rounds[0].votingEndTime = newDispute.rounds[0].votingStartTime + _votingPeriod;
        newDispute.rounds[0].revealPeriodStartTime = newDispute.rounds[0].votingEndTime;
        newDispute.rounds[0].revealPeriodEndTime = newDispute.rounds[0].votingEndTime + _revealPeriod;
        newDispute.rounds[0].votes = 0; // total votes cast
        newDispute.rounds[0].ruling = IArbitrable.Party.None; // winning choice
        newDispute.rounds[0].extraData = _extraData;
        uint256 creationBlock = block.number - 1;
        newDispute.rounds[0].creationBlock = creationBlock;
        newDispute.rounds[0].totalSupply = _totalVotingPowerAt(creationBlock);
        newDispute.rounds[0].cost = arbitrationCost_;

        emit DisputeCreated(
            newDispute.id,
            address(arbitrable),
            newDispute.rounds[0].votingStartTime,
            newDispute.rounds[0].votingEndTime,
            newDispute.rounds[0].revealPeriodEndTime,
            newDispute.rounds[0].totalSupply,
            newDispute.rounds[0].creationBlock,
            newDispute.rounds[0].cost,
            _extraData,
            _choices
        );
        emit DisputeCreation(newDispute.id, arbitrable);

        return newDispute.id;
    }

    /**
     * @notice Gets the receipt for a voter on a given dispute
     * @param disputeId the id of dispute
     * @param voter The address of the voter
     * @return The voting receipt
     */
    function getReceipt(
        uint256 disputeId,
        address voter
    ) external view validDisputeID(disputeId) returns (Receipt memory) {
        uint256 round = disputes[disputeId].currentRound;
        return disputes[disputeId].rounds[round].receipts[voter];
    }

    /**
     * @notice Gets the receipt for a voter on a given dispute and round
     * @param disputeId The id of dispute
     * @param round The round number
     * @param voter The address of the voter
     * @return The voting receipt for the specified round
     */
    function getReceiptByRound(
        uint256 disputeId,
        uint256 round,
        address voter
    ) external view validDisputeID(disputeId) returns (Receipt memory) {
        if (round > disputes[disputeId].currentRound) revert INVALID_ROUND();
        return disputes[disputeId].rounds[round].receipts[voter];
    }

    function getVotingRoundInfo(
        uint256 disputeId,
        uint256 round
    ) external view override validDisputeID(disputeId) returns (VotingRoundInfo memory info) {
        VotingRound storage votingRound = _roundStorage(disputeId, round);
        info.state = uint8(_getVotingRoundState(disputeId, round));
        info.votingStartTime = votingRound.votingStartTime;
        info.votingEndTime = votingRound.votingEndTime;
        info.revealPeriodStartTime = votingRound.revealPeriodStartTime;
        info.revealPeriodEndTime = votingRound.revealPeriodEndTime;
        info.creationBlock = votingRound.creationBlock;
        info.totalSupply = votingRound.totalSupply;
        info.cost = votingRound.cost;
        info.totalVotes = votingRound.votes;
        info.requesterVotes = votingRound.choiceVotes[uint256(IArbitrable.Party.Requester)];
        info.challengerVotes = votingRound.choiceVotes[uint256(IArbitrable.Party.Challenger)];
        info.ruling = votingRound.ruling;
    }

    function getVoterRoundStatus(
        uint256 disputeId,
        uint256 round,
        address voter
    ) external view override validDisputeID(disputeId) returns (VoterRoundStatus memory status) {
        VotingRound storage votingRound = _roundStorage(disputeId, round);
        Receipt storage receipt = votingRound.receipts[voter];

        status.hasCommitted = receipt.hasCommitted;
        status.hasRevealed = receipt.hasRevealed;
        status.commitHash = receipt.commitHash;
        status.choice = receipt.choice;
        status.votes = receipt.votes;
        status.rewardsClaimed = votingRound.rewardsClaimed[voter];
        status.slashedOrProcessed = _voterSlashedOrProcessed[disputeId][round][voter];
        status.claimableReward = _computeRewardsForRound(disputeId, round, voter);
    }

    function isVoterSlashedOrProcessed(
        uint256 disputeId,
        uint256 round,
        address voter
    ) external view override validDisputeID(disputeId) returns (bool) {
        _roundStorage(disputeId, round);
        return _voterSlashedOrProcessed[disputeId][round][voter];
    }

    function computeCommitHash(
        uint256 disputeId,
        uint256 round,
        address voter,
        uint256 choice,
        string calldata reason,
        bytes32 salt
    ) external view override returns (bytes32 commitHash) {
        return _computeCommitHash(disputeId, round, voter, choice, reason, salt);
    }

    /**
     * @notice Gets the state of a dispute
     * @param disputeId The id of the dispute
     * @return Dispute state
     */
    function currentRoundState(uint256 disputeId) external view returns (DisputeState) {
        return _getVotingRoundState(disputeId, disputes[disputeId].currentRound);
    }

    /**
     * @notice Gets the votes for a specific choice and the total votes in a given round of a dispute
     * @param disputeId The ID of the dispute
     * @param round The round number
     * @param choice The choice number to get votes for
     * @return choiceVotes The number of votes for the specified choice
     */
    function getVotesByRound(
        uint256 disputeId,
        uint256 round,
        uint256 choice
    ) external view validDisputeID(disputeId) returns (uint256 choiceVotes) {
        Dispute storage dispute = disputes[disputeId];
        if (choice == 0 || choice > dispute.choices) revert INVALID_VOTE_CHOICE();
        choiceVotes = _roundStorage(dispute, round).choiceVotes[choice];
    }

    /**
     * @notice Gets the total votes in a given round of a dispute
     * @param disputeId The ID of the dispute
     * @param round The round number
     * @return totalVotes The total number of votes cast in the specified round
     */
    function getTotalVotesByRound(
        uint256 disputeId,
        uint256 round
    ) external view validDisputeID(disputeId) returns (uint256 totalVotes) {
        totalVotes = _roundStorage(disputeId, round).votes;
    }

    /**
     * @notice Get the state of a specific voting round for a dispute
     * @param disputeId The ID of the dispute
     * @param round The round number
     * @return The state of the voting round
     */
    function _getVotingRoundState(
        uint256 disputeId,
        uint256 round
    ) internal view validDisputeID(disputeId) returns (DisputeState) {
        VotingRound storage votingRound = _roundStorage(disputeId, round);

        if (block.timestamp < votingRound.votingStartTime) {
            return DisputeState.Pending;
        } else if (block.timestamp < votingRound.votingEndTime) {
            return DisputeState.Active;
        } else if (block.timestamp < votingRound.revealPeriodEndTime) {
            return DisputeState.Reveal;
        } else {
            return DisputeState.Solved;
        }
    }

    /**
     * @notice Get the status of a dispute
     * @dev This function maps the DisputeState to the IArbitrator.DisputeStatus
     * @param disputeId The ID of the dispute to check
     * @return The status of the dispute as defined in IArbitrator.DisputeStatus
     * @dev checks for valid dispute ID first in the state function
     */
    function disputeStatus(uint256 disputeId) public view returns (DisputeStatus) {
        DisputeState disputeState = _getVotingRoundState(disputeId, disputes[disputeId].currentRound);

        if (disputeState == DisputeState.Solved) {
            // executed or solved
            return DisputeStatus.Solved;
        } else {
            // pending, active, reveal voting states
            return DisputeStatus.Waiting;
        }
    }

    /**
     * @notice Returns the current ruling for a dispute.
     * @param disputeId The ID of the dispute.
     * @return ruling The current ruling of the dispute.
     */
    function currentRuling(
        uint256 disputeId
    ) external view override validDisputeID(disputeId) returns (IArbitrable.Party) {
        Dispute storage dispute = disputes[disputeId];
        uint256 round = dispute.currentRound;

        if (dispute.executed) {
            return dispute.rounds[round].ruling;
        }

        if (_getVotingRoundState(disputeId, round) == DisputeState.Solved) {
            uint256 winningChoice = _determineWinningChoice(disputeId, round);
            return _convertChoiceToParty(winningChoice);
        }

        return dispute.rounds[round].ruling;
    }

    /**
     * @notice Cast a vote for a dispute
     * @param disputeId The id of the dispute to vote on
     * @param commitHash Commit keccak256 hash of:
     * `abi.encode(block.chainid, address(this), disputeId, round, voter, choice, reason, salt)`
     */
    function commitVote(uint256 disputeId, bytes32 commitHash) external nonReentrant {
        _commitVoteInternal(msg.sender, disputeId, commitHash);

        emit VoteCommitted(msg.sender, disputeId, commitHash);
    }

    /**
     * @notice Commit a vote on behalf of a juror if caller is authorized by the stake vault.
     * @param disputeId The id of the dispute to vote on.
     * @param voter The juror whose vote is being committed.
     * @param commitHash Commit keccak256 hash of:
     * `abi.encode(block.chainid, address(this), disputeId, round, voter, choice, reason, salt)`
     */
    function commitVoteFor(uint256 disputeId, address voter, bytes32 commitHash) external nonReentrant {
        if (address(_stakeVault) == address(0)) revert STAKE_VAULT_NOT_SET();
        if (!_stakeVault.isAuthorizedJurorOperator(voter, msg.sender)) revert UNAUTHORIZED_DELEGATE();

        _commitVoteInternal(voter, disputeId, commitHash);
        emit VoteCommitted(voter, disputeId, commitHash);
    }

    /**
     * @notice Reveal a previously committed vote for a dispute
     * @param disputeId The id of the dispute to reveal the vote for
     * @param voter The address of the voter. Added for custodial voting.
     * @param choice The choice that was voted for
     * @param reason The reason for the vote
     * @param salt The salt used in the commit phase
     */
    function revealVote(
        uint256 disputeId,
        address voter,
        uint256 choice,
        string calldata reason,
        bytes32 salt
    ) external nonReentrant {
        Dispute storage dispute = disputes[disputeId];
        uint256 round = dispute.currentRound;

        if (_getVotingRoundState(disputeId, round) != DisputeState.Reveal) revert VOTING_CLOSED();
        if (choice == 0 || choice > dispute.choices) revert INVALID_VOTE_CHOICE();

        Receipt storage receipt = dispute.rounds[round].receipts[voter];
        if (!receipt.hasCommitted) revert NO_COMMITTED_VOTE();
        if (receipt.hasRevealed) revert ALREADY_REVEALED_VOTE();

        // Reconstruct the hash to verify the revealed vote
        bytes32 reconstructedHash = _computeCommitHash(disputeId, round, voter, choice, reason, salt);
        if (reconstructedHash != receipt.commitHash) revert HASHES_DO_NOT_MATCH();

        uint256 votes = _votingPowerAt(voter, dispute.rounds[round].creationBlock);

        if (votes == 0) revert VOTER_HAS_NO_VOTES();

        receipt.hasRevealed = true;
        receipt.choice = choice;
        receipt.votes = votes;

        dispute.rounds[round].votes += votes;
        dispute.rounds[round].choiceVotes[choice] += votes;

        emit VoteRevealed(voter, disputeId, receipt.commitHash, choice, reason, votes);
    }

    /**
     * @notice Internal function that caries out voting commitment logic
     * @param voter The voter that is casting their vote
     * @param disputeId The id of the dispute to vote on
     * @param commitHash The keccak256 hash of:
     * `abi.encode(block.chainid, address(this), disputeId, round, voter, choice, reason, salt)`
     */
    function _commitVoteInternal(address voter, uint256 disputeId, bytes32 commitHash) internal {
        Dispute storage dispute = disputes[disputeId];
        uint256 round = dispute.currentRound;

        if (_getVotingRoundState(disputeId, round) != DisputeState.Active) revert VOTING_CLOSED();

        Receipt storage receipt = dispute.rounds[round].receipts[voter];
        if (receipt.hasCommitted) revert VOTER_ALREADY_VOTED();
        uint256 votes = _votingPowerAt(voter, dispute.rounds[round].creationBlock);

        if (votes == 0) revert VOTER_HAS_NO_VOTES();

        receipt.hasCommitted = true;
        receipt.commitHash = commitHash;
    }

    function _computeCommitHash(
        uint256 disputeId,
        uint256 round,
        address voter,
        uint256 choice,
        string calldata reason,
        bytes32 salt
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), disputeId, round, voter, choice, reason, salt));
    }

    /**
     * @notice Checks if a voter can vote in a specific round
     * @param disputeId The ID of the dispute
     * @param round The round number
     * @param voter The address of the voter
     * @return votingPower The voting power of the voter in the round
     * @return canVote True if the voter can vote in the round, false otherwise
     */
    function votingPowerInRound(
        uint256 disputeId,
        uint256 round,
        address voter
    ) public view validDisputeID(disputeId) returns (uint256, bool) {
        Dispute storage dispute = disputes[disputeId];
        VotingRound storage votingRound = _roundStorage(dispute, round);
        uint256 votes = _votingPowerAt(voter, votingRound.creationBlock);

        return (votes, votes > 0);
    }

    /**
     * @notice Checks if a voter can vote in the current round
     * @param disputeId The ID of the dispute
     * @param voter The address of the voter
     * @return votingPower The voting power of the voter in the current round
     * @return canVote True if the voter can vote in the current round, false otherwise
     */
    function votingPowerInCurrentRound(uint256 disputeId, address voter) public view returns (uint256, bool) {
        return votingPowerInRound(disputeId, disputes[disputeId].currentRound, voter);
    }

    /**
     * @notice Permissionless slashing hook for missed reveal or incorrect vote in solved rounds.
     * @dev Slashing only works when a stake vault is configured.
     * @param disputeId The dispute ID.
     * @param round The voting round.
     * @param voter The juror to process.
     */
    function slashVoter(
        uint256 disputeId,
        uint256 round,
        address voter
    ) external nonReentrant validDisputeID(disputeId) {
        if (address(_stakeVault) == address(0)) revert STAKE_VAULT_NOT_SET();
        VotingRound storage votingRound = _roundStorage(disputeId, round);
        if (_getVotingRoundState(disputeId, round) != DisputeState.Solved) revert DISPUTE_NOT_SOLVED();

        if (_voterSlashedOrProcessed[disputeId][round][voter]) return;

        uint256 snapshotVotes = _votingPowerAt(voter, votingRound.creationBlock);
        if (snapshotVotes == 0) {
            _voterSlashedOrProcessed[disputeId][round][voter] = true;
            return;
        }

        Receipt storage receipt = votingRound.receipts[voter];
        uint256 winningChoice = _determineWinningChoice(disputeId, round);

        bool missedReveal = !receipt.hasRevealed;
        bool wrongVote = receipt.hasRevealed && winningChoice != 0 && receipt.choice != winningChoice;

        if (!missedReveal && !wrongVote) {
            _voterSlashedOrProcessed[disputeId][round][voter] = true;
            return;
        }

        address rewardEscrow = IGoalTreasury(_stakeVault.goalTreasury()).rewardEscrow();
        if (rewardEscrow == address(0) || rewardEscrow.code.length == 0) revert INVALID_SLASH_RECIPIENT();

        uint256 slashWeight = bps2Uint(wrongOrMissedSlashBps, snapshotVotes);
        if (slashWeight != 0) {
            uint256 callerBountyWeight = bps2Uint(slashCallerBountyBps, slashWeight);
            uint256 rewardEscrowWeight = slashWeight - callerBountyWeight;

            if (callerBountyWeight != 0) {
                _slashJurorStake(voter, callerBountyWeight, msg.sender);
            }
            if (rewardEscrowWeight != 0) {
                _slashJurorStake(voter, rewardEscrowWeight, rewardEscrow);
            }
        }

        _voterSlashedOrProcessed[disputeId][round][voter] = true;
        emit VoterSlashed(disputeId, round, voter, snapshotVotes, slashWeight, missedReveal, rewardEscrow);
    }

    /**
     * @notice Execute a dispute and set the ruling
     * @param disputeId The ID of the dispute to execute
     */
    function executeRuling(uint256 disputeId) external nonReentrant {
        Dispute storage dispute = disputes[disputeId];
        uint256 round = dispute.currentRound;
        if (dispute.executed) revert DISPUTE_ALREADY_EXECUTED();
        if (_getVotingRoundState(disputeId, round) != DisputeState.Solved) revert DISPUTE_NOT_SOLVED();

        uint256 winningChoice = _determineWinningChoice(disputeId, round);

        // Convert winning choice to Party enum
        IArbitrable.Party ruling = _convertChoiceToParty(winningChoice);

        dispute.rounds[round].ruling = ruling;
        dispute.executed = true;
        dispute.winningChoice = winningChoice;

        // Call the rule function on the arbitrable contract
        arbitrable.rule(disputeId, uint256(ruling));

        emit DisputeExecuted(disputeId, ruling);
    }

    /**
     * @notice Allows voters to view their proportional share of the cost for a voting round if they voted on the correct side.
     * @param disputeId The ID of the dispute.
     * @param round The round number.
     * @param voter The address of the voter.
     * @return The amount of rewards the voter is entitled to.
     */
    function getRewardsForRound(uint256 disputeId, uint256 round, address voter) external view returns (uint256) {
        return _computeRewardsForRound(disputeId, round, voter);
    }

    function _computeRewardsForRound(uint256 disputeId, uint256 round, address voter) internal view returns (uint256) {
        VotingRound storage votingRound = _roundStorage(disputeId, round);
        Receipt storage receipt = votingRound.receipts[voter];

        // Ensure the dispute round is finalized
        if (_getVotingRoundState(disputeId, round) != DisputeState.Solved) return 0;

        // If no votes were cast, return 0
        if (votingRound.votes == 0) return 0;

        // Check that the voter has voted
        if (!receipt.hasRevealed) return 0;

        // Check that the voter hasn't already claimed
        if (votingRound.rewardsClaimed[voter]) return 0;

        uint256 winningChoice = _determineWinningChoice(disputeId, round);

        uint256 amount = 0;
        uint256 totalRewards = votingRound.cost; // Total amount to distribute among voters

        if (winningChoice == 0) {
            // Ruling is 0 or Party.None, both sides can withdraw proportional share
            amount = (receipt.votes * totalRewards) / votingRound.votes;
        } else {
            // Ruling is not 0, only winning voters can withdraw
            if (receipt.choice != winningChoice) {
                return 0;
            }
            uint256 totalWinningVotes = votingRound.choiceVotes[winningChoice];

            if (totalWinningVotes == 0) return 0;

            // Calculate voter's share
            amount = (receipt.votes * totalRewards) / totalWinningVotes;
        }

        return amount;
    }

    function _roundStorage(uint256 disputeId, uint256 round) internal view returns (VotingRound storage votingRound) {
        votingRound = _roundStorage(disputes[disputeId], round);
    }

    function _roundStorage(
        Dispute storage dispute,
        uint256 round
    ) internal view returns (VotingRound storage votingRound) {
        if (round > dispute.currentRound) revert INVALID_ROUND();
        votingRound = dispute.rounds[round];
    }

    /// @notice Routes invalid/no-vote round rewards to the configured sink.
    function withdrawInvalidRoundRewards(uint256 disputeId, uint256 round) external {
        Dispute storage dispute = disputes[disputeId];
        VotingRound storage votingRound = _roundStorage(dispute, round);
        uint256 totalRewards = votingRound.cost; // Total amount to distribute among voters

        // Ensure the dispute round is finalized
        if (_getVotingRoundState(disputeId, round) != DisputeState.Solved) {
            revert DISPUTE_NOT_SOLVED();
        }

        if (votingRound.votes > 0) revert VOTES_WERE_CAST();

        votingRound.cost = 0;
        IERC20(address(_votingToken)).safeTransfer(invalidRoundRewardsSink, totalRewards);
    }

    /**
     * @notice Allows voters to withdraw their proportional share of the cost for a voting round if they voted on the correct side of the ruling.
     * @param disputeId The ID of the dispute.
     * @param round The round number.
     * @param voter The address of the voter.
     */
    function withdrawVoterRewards(uint256 disputeId, uint256 round, address voter) external nonReentrant {
        Dispute storage dispute = disputes[disputeId];

        // Get the voting round
        VotingRound storage votingRound = _roundStorage(dispute, round);

        // Ensure the dispute round is finalized
        if (_getVotingRoundState(disputeId, round) != DisputeState.Solved) {
            revert DISPUTE_NOT_SOLVED();
        }

        // Check that the voter hasn't already claimed
        if (votingRound.rewardsClaimed[voter]) {
            revert REWARD_ALREADY_CLAIMED();
        }

        // Get the receipt for the voter
        Receipt storage receipt = votingRound.receipts[voter];

        // Check that the voter has voted
        if (!receipt.hasRevealed) {
            revert VOTER_HAS_NOT_VOTED();
        }

        uint256 winningChoice = _determineWinningChoice(disputeId, round);

        uint256 amount = 0;
        uint256 totalRewards = votingRound.cost; // Total amount to distribute among voters

        if (votingRound.votes == 0) revert NO_VOTES();

        if (winningChoice == 0) {
            // Ruling is 0 or Party.None, both sides can withdraw proportional share
            amount = (receipt.votes * totalRewards) / votingRound.votes;
        } else {
            // Ruling is not 0, only winning voters can withdraw
            if (receipt.choice != winningChoice) {
                revert VOTER_ON_LOSING_SIDE();
            }
            uint256 totalWinningVotes = votingRound.choiceVotes[winningChoice];

            if (totalWinningVotes == 0) revert NO_WINNING_VOTES();

            // Calculate voter's share
            amount = (receipt.votes * totalRewards) / totalWinningVotes;
        }

        // Mark as claimed
        votingRound.rewardsClaimed[voter] = true;

        // Transfer tokens to voter
        IERC20(address(_votingToken)).safeTransfer(voter, amount);

        emit RewardWithdrawn(disputeId, round, voter, amount);
    }

    /**
     * @notice Determines the winning choice based on the votes.
     * @param _disputeID The ID of the dispute.
     * @param _round The round number.
     * @return The choice with the highest votes.
     */
    function _determineWinningChoice(uint256 _disputeID, uint256 _round) internal view returns (uint256) {
        Dispute storage dispute = disputes[_disputeID];
        VotingRound storage votingRound = dispute.rounds[_round];

        uint256 winningChoice = 0;
        uint256 highestVotes = 0;
        bool tie = false;

        for (uint256 i = 1; i <= dispute.choices; i++) {
            uint256 votesForChoice = votingRound.choiceVotes[i];
            if (votesForChoice > highestVotes) {
                highestVotes = votesForChoice;
                winningChoice = i;
                tie = false; // reset tie since we have a new outright leader
            } else if (votesForChoice == highestVotes && votesForChoice != 0) {
                tie = true;
            }
        }

        if (tie) {
            return 0;
        }

        return winningChoice;
    }

    /**
     * @notice Converts a choice number to the corresponding Party enum.
     * @param _choice The choice number.
     * @return The corresponding Party.
     */
    function _convertChoiceToParty(uint256 _choice) internal pure returns (IArbitrable.Party) {
        if (_choice == 0) {
            return IArbitrable.Party.None;
        } else if (_choice == 1) {
            return IArbitrable.Party.Requester;
        } else if (_choice == 2) {
            return IArbitrable.Party.Challenger;
        } else {
            return IArbitrable.Party.None;
        }
    }

    /**
     * @dev Returns the arbitrator parameters for use in the TCR factory.
     * @return ArbitratorParams struct containing the necessary parameters for the factory.
     */
    function getArbitratorParamsForFactory() external view override returns (IArbitrator.ArbitratorParams memory) {
        return
            IArbitrator.ArbitratorParams({
                votingPeriod: _votingPeriod,
                votingDelay: _votingDelay,
                revealPeriod: _revealPeriod,
                arbitrationCost: _arbitrationCost,
                wrongOrMissedSlashBps: wrongOrMissedSlashBps,
                slashCallerBountyBps: slashCallerBountyBps
            });
    }

    function bps2Uint(uint256 bps, uint256 number) internal pure returns (uint256) {
        return (number * bps) / BPS_DENOMINATOR;
    }

    function _setStakeVault(address stakeVault_) internal {
        if (stakeVault_ == address(0)) revert INVALID_STAKE_VAULT_ADDRESS();
        if (address(_stakeVault) != address(0)) revert STAKE_VAULT_ALREADY_SET();

        address goalTreasury = IStakeVault(stakeVault_).goalTreasury();
        if (goalTreasury == address(0)) revert INVALID_STAKE_VAULT_GOAL_TREASURY();
        address rewardEscrow;
        try IGoalTreasury(goalTreasury).rewardEscrow() returns (address rewardEscrow_) {
            rewardEscrow = rewardEscrow_;
        } catch {
            revert INVALID_STAKE_VAULT_GOAL_TREASURY();
        }
        if (rewardEscrow == address(0) || rewardEscrow.code.length == 0) revert INVALID_STAKE_VAULT_REWARD_ESCROW();

        _stakeVault = IStakeVault(stakeVault_);
        emit StakeVaultConfigured(stakeVault_);
    }

    function _setFixedBudgetTreasury(address fixedBudgetTreasury_) internal {
        if (fixedBudgetTreasury_ == address(0)) return;
        if (address(_stakeVault) == address(0)) revert STAKE_VAULT_NOT_SET();
        if (fixedBudgetTreasury_.code.length == 0) revert INVALID_FIXED_BUDGET_CONTEXT();

        address goalFlow;
        try IGoalTreasury(_stakeVault.goalTreasury()).flow() returns (address goalFlow_) {
            goalFlow = goalFlow_;
        } catch {
            revert INVALID_FIXED_BUDGET_CONTEXT();
        }
        if (goalFlow == address(0) || goalFlow.code.length == 0) revert INVALID_FIXED_BUDGET_CONTEXT();

        address budgetFlow;
        try IBudgetTreasury(fixedBudgetTreasury_).flow() returns (address budgetFlow_) {
            budgetFlow = budgetFlow_;
        } catch {
            revert INVALID_FIXED_BUDGET_CONTEXT();
        }
        if (budgetFlow == address(0) || budgetFlow.code.length == 0) revert INVALID_FIXED_BUDGET_CONTEXT();

        address parentFlow;
        try IFlow(budgetFlow).parent() returns (address parentFlow_) {
            parentFlow = parentFlow_;
        } catch {
            revert INVALID_FIXED_BUDGET_CONTEXT();
        }
        if (parentFlow != goalFlow) revert INVALID_FIXED_BUDGET_CONTEXT();

        _fixedBudgetTreasury = fixedBudgetTreasury_;
    }

    function _budgetStakeLedger() internal view returns (IBudgetStakeLedger ledger) {
        address rewardEscrow = IGoalTreasury(_stakeVault.goalTreasury()).rewardEscrow();
        if (rewardEscrow == address(0) || rewardEscrow.code.length == 0) revert INVALID_STAKE_VAULT_REWARD_ESCROW();

        address ledgerAddr = IRewardEscrow(rewardEscrow).budgetStakeLedger();
        if (ledgerAddr == address(0) || ledgerAddr.code.length == 0) revert INVALID_STAKE_VAULT_REWARD_ESCROW();

        return IBudgetStakeLedger(ledgerAddr);
    }

    function _votingPowerAt(address voter, uint256 blockNumber) internal view returns (uint256 votes) {
        if (address(_stakeVault) != address(0)) {
            uint256 jurorVotes = _stakeVault.getPastJurorWeight(voter, blockNumber);
            if (jurorVotes == 0) return 0;

            address budgetTreasury = _fixedBudgetTreasury;
            if (budgetTreasury == address(0)) return jurorVotes;

            IBudgetStakeLedger ledger = _budgetStakeLedger();
            uint256 budgetVotes = ledger.getPastUserAllocatedStakeOnBudget(voter, budgetTreasury, blockNumber);
            if (budgetVotes == 0) return 0;

            uint256 allocationWeight = ledger.getPastUserAllocationWeight(voter, blockNumber);
            if (allocationWeight == 0) return 0;

            uint256 cappedJurorVotes = Math.min(jurorVotes, allocationWeight);
            uint256 proportionalVotes = Math.mulDiv(cappedJurorVotes, budgetVotes, allocationWeight);
            return Math.min(Math.min(proportionalVotes, jurorVotes), budgetVotes);
        }
        return _votingToken.getPastVotes(voter, blockNumber);
    }

    function _totalVotingPowerAt(uint256 blockNumber) internal view returns (uint256 totalVotes) {
        if (address(_stakeVault) != address(0)) {
            return _stakeVault.getPastTotalJurorWeight(blockNumber);
        }
        return _votingToken.getPastTotalSupply(blockNumber);
    }

    function _slashJurorStake(address juror, uint256 weightAmount, address recipient) internal {
        IJurorSlasher(_stakeVault.jurorSlasher()).slashJurorStake(juror, weightAmount, recipient);
    }

    /**
     * @notice Modifier to restrict function access to only the arbitrable contract
     */
    modifier onlyArbitrable() {
        if (msg.sender != address(arbitrable)) revert ONLY_ARBITRABLE();
        _;
    }

    /**
     * @notice Modifier to check if a dispute ID is valid
     * @param _disputeID The ID of the dispute to check
     */
    modifier validDisputeID(uint256 _disputeID) {
        if (_disputeID == 0 || _disputeID > disputeCount) revert INVALID_DISPUTE_ID();
        _;
    }

    /**
     * @notice Returns the cost of arbitration
     * @return cost The cost of arbitration
     */
    function arbitrationCost(bytes calldata _extraData) external view override returns (uint256 cost) {
        return _arbitrationCostFromExtraData(_extraData);
    }

    function _arbitrationCostFromExtraData(bytes calldata _extraData) internal view returns (uint256 cost) {
        (bool hasSnapshot, uint256 snapshotCost) = ArbitrationCostExtraData.decodeCost(_extraData);
        if (hasSnapshot) {
            if (snapshotCost < MIN_ARBITRATION_COST || snapshotCost > MAX_ARBITRATION_COST) {
                revert INVALID_ARBITRATION_COST();
            }
            return snapshotCost;
        }

        return _arbitrationCost;
    }

    /**
     * @notice Returns the voting token used for arbitration costs and reward distribution.
     * @return token The ERC20 token address.
     */
    function votingToken() external view override returns (IVotes token) {
        return _votingToken;
    }

    /**
     * @notice Returns the optional stake vault used for juror voting power snapshots.
     * @return vault The stake vault address, or zero if token-votes mode is active.
     */
    function stakeVault() external view returns (address vault) {
        return address(_stakeVault);
    }

    function fixedBudgetTreasury() external view returns (address budgetTreasury) {
        return _fixedBudgetTreasury;
    }

    function _ensureVotingTokenCompatibility(address votingToken_) internal view {
        (bool isCompatible, uint8 tokenDecimals) = VotingTokenCompatibility.readErc20AndDecimals(
            votingToken_,
            address(this)
        );
        if (!isCompatible) revert INVALID_VOTING_TOKEN_COMPATIBILITY();
        if (tokenDecimals != VOTING_TOKEN_DECIMALS) revert INVALID_VOTING_TOKEN_DECIMALS(tokenDecimals);
    }
}
