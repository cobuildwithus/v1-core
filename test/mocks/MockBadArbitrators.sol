// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @dev Implements IArbitrator, but NOT votingToken(). Triggers try/catch mismatch path.
contract MockArbitratorNoVotingToken is IArbitrator {
    function createDispute(uint256, bytes calldata) external pure returns (uint256) {
        return 1;
    }

    function arbitrationCost(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function disputeStatus(uint256) external pure returns (DisputeStatus) {
        return DisputeStatus.Waiting;
    }

    function currentRuling(uint256) external pure returns (IArbitrable.Party) {
        return IArbitrable.Party.None;
    }

    function getArbitratorParamsForFactory() external pure returns (ArbitratorParams memory) {
        return ArbitratorParams({
            votingPeriod: 0,
            votingDelay: 0,
            revealPeriod: 0,
            arbitrationCost: 0,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });
    }
}

/// @dev Implements IERC20VotesArbitrator but returns a mismatched voting token.
contract MockMismatchedVotesArbitrator is IERC20VotesArbitrator {
    IVotes internal immutable _token;

    constructor(IVotes token_) {
        _token = token_;
    }

    function votingToken() external view returns (IVotes token) {
        return _token;
    }

    function fixedBudgetTreasury() external pure returns (address budgetTreasury) {
        budgetTreasury = address(0);
    }

    function initialize(address, address, address, uint256, uint256, uint256, uint256) external pure {}

    function initializeWithSlashConfig(address, address, address, uint256, uint256, uint256, uint256, uint256, uint256)
        external
        pure
    { }

    function initializeWithStakeVaultAndSlashConfig(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256,
        uint256
    ) external pure {}

    function initializeWithStakeVault(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address
    ) external pure {}

    function initializeWithStakeVaultAndBudgetScope(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        address
    ) external pure {}

    function initializeWithStakeVaultAndBudgetScopeAndSlashConfig(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256,
        uint256
    ) external pure {}

    function createDispute(uint256, bytes calldata) external pure returns (uint256) {
        return 1;
    }

    function arbitrationCost(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function disputeStatus(uint256) external pure returns (DisputeStatus) {
        return DisputeStatus.Waiting;
    }

    function currentRuling(uint256) external pure returns (IArbitrable.Party) {
        return IArbitrable.Party.None;
    }

    function getVotingRoundInfo(uint256, uint256) external pure returns (VotingRoundInfo memory info) {
        info.state = 0;
    }

    function getVoterRoundStatus(uint256, uint256, address) external pure returns (VoterRoundStatus memory status) {
        status.hasCommitted = false;
    }

    function isVoterSlashedOrProcessed(uint256, uint256, address) external pure returns (bool) {
        return false;
    }

    function computeCommitHash(
        uint256,
        uint256,
        address,
        uint256,
        string calldata,
        bytes32
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function getArbitratorParamsForFactory() external pure returns (ArbitratorParams memory) {
        return ArbitratorParams({
            votingPeriod: 0,
            votingDelay: 0,
            revealPeriod: 0,
            arbitrationCost: 0,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });
    }
}

/// @dev Implements IERC20VotesArbitrator but returns an invalid ruling (out of range).
contract MockInvalidRulingVotesArbitrator is IERC20VotesArbitrator {
    IVotes internal immutable _token;
    address public arbitrable;

    constructor(IVotes token_, address arbitrable_) {
        _token = token_;
        arbitrable = arbitrable_;
    }

    function votingToken() external view returns (IVotes token) {
        return _token;
    }

    function fixedBudgetTreasury() external pure returns (address budgetTreasury) {
        budgetTreasury = address(0);
    }

    function initialize(address, address, address, uint256, uint256, uint256, uint256) external pure {}

    function initializeWithSlashConfig(address, address, address, uint256, uint256, uint256, uint256, uint256, uint256)
        external
        pure
    { }

    function initializeWithStakeVaultAndSlashConfig(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256,
        uint256
    ) external pure {}

    function initializeWithStakeVault(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address
    ) external pure {}

    function initializeWithStakeVaultAndBudgetScope(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        address
    ) external pure {}

    function initializeWithStakeVaultAndBudgetScopeAndSlashConfig(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256,
        uint256
    ) external pure {}

    function createDispute(uint256, bytes calldata) external view returns (uint256) {
        if (msg.sender != arbitrable) revert ONLY_ARBITRABLE();
        return 1;
    }

    function arbitrationCost(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function disputeStatus(uint256) external pure returns (DisputeStatus) {
        return DisputeStatus.Solved;
    }

    function currentRuling(uint256) external pure returns (IArbitrable.Party) {
        return IArbitrable.Party(uint256(3));
    }

    function getVotingRoundInfo(uint256, uint256) external pure returns (VotingRoundInfo memory info) {
        info.state = 0;
    }

    function getVoterRoundStatus(uint256, uint256, address) external pure returns (VoterRoundStatus memory status) {
        status.hasCommitted = false;
    }

    function isVoterSlashedOrProcessed(uint256, uint256, address) external pure returns (bool) {
        return false;
    }

    function computeCommitHash(
        uint256,
        uint256,
        address,
        uint256,
        string calldata,
        bytes32
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function getArbitratorParamsForFactory() external pure returns (ArbitratorParams memory) {
        return ArbitratorParams({
            votingPeriod: 0,
            votingDelay: 0,
            revealPeriod: 0,
            arbitrationCost: 0,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });
    }
}
