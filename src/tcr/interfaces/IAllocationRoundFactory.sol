// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

/// @notice Canonical round-factory surface used by allocation mechanism registries.
/// @dev Any factory with this ABI may be allowlisted by an allocation mechanism registry.
interface IAllocationRoundFactory {
    struct RoundTiming {
        uint64 startAt;
        uint64 endAt;
    }

    struct SubmissionTcrConfig {
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        address governor;
        uint256 submissionBaseDeposit;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
    }

    struct ArbitratorConfig {
        uint256 votingPeriod;
        uint256 votingDelay;
        uint256 revealPeriod;
        uint256 arbitrationCost;
        uint256 wrongOrMissedSlashBps;
        uint256 slashCallerBountyBps;
    }

    struct DeployedRound {
        address prizeVault;
        address submissionTCR;
        address arbitrator;
        address depositStrategy;
        address underlyingToken;
        address superToken;
        address stakeVault;
        address goalTreasury;
        address goalFlow;
        address budgetFlow;
    }

    function createRoundForBudget(
        bytes32 roundId,
        address budgetTreasury,
        RoundTiming calldata timing,
        address roundOperator,
        SubmissionTcrConfig calldata tcrConfig,
        ArbitratorConfig calldata arbConfig
    ) external returns (DeployedRound memory out);
}
