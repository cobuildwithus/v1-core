// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { RoundPrizeVault } from "src/rounds/RoundPrizeVault.sol";
import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title RoundFactory
 * @notice A permissionless deployer for the round onchain stack.
 *
 *         Each deployed round consists of:
 *         - A RoundSubmissionTCR: per-round registry of submissions.
 *         - An ERC20VotesArbitrator: adjudicates disputes for the registry (stake-vault voting).
 *         - A RoundPrizeVault: holds prize funds and pays out in the underlying goal token.
 *         - A PrizePoolSubmissionDepositStrategy: routes accepted submission deposits into the prize vault.
 */
contract RoundFactory {
    using Clones for address;

    error ADDRESS_ZERO();
    error INVALID_BUDGET_CONTEXT();
    error SUPER_TOKEN_UNDERLYING_MISMATCH(address expectedUnderlying, address actualUnderlying);

    event RoundDeployed(
        bytes32 indexed roundId,
        address indexed budgetTreasury,
        address indexed prizeVault,
        address submissionTCR,
        address arbitrator,
        address depositStrategy,
        address underlyingToken,
        address superToken
    );

    /// @notice Deployment timing for a round submission window.
    struct RoundTiming {
        uint64 startAt;
        uint64 endAt;
    }

    /// @notice Configuration for a RoundSubmissionTCR instance.
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

    /// @notice Configuration for an ERC20VotesArbitrator instance.
    struct ArbitratorConfig {
        uint256 votingPeriod;
        uint256 votingDelay;
        uint256 revealPeriod;
        uint256 arbitrationCost;
        uint256 wrongOrMissedSlashBps;
        uint256 slashCallerBountyBps;
    }

    /// @notice Returned addresses for a deployed round stack.
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

    /// @dev Clone targets.
    address public immutable roundSubmissionTcrImplementation;
    address public immutable arbitratorImplementation;

    constructor() {
        roundSubmissionTcrImplementation = address(new RoundSubmissionTCR());
        arbitratorImplementation = address(new ERC20VotesArbitrator());
    }

    /// @notice Deploy a full round stack for a given budget.
    /// @param roundId A caller-supplied identifier (recommended: parent mechanism TCR itemID).
    /// @param budgetTreasury Budget treasury whose flow will stream into the prize vault.
    /// @param timing Submission window for the round.
    /// @param roundOperator Trusted operator allowed to set payout entitlements in the prize vault.
    /// @param tcrConfig Configuration for the per-round submission registry.
    /// @param arbConfig Configuration for the arbitrator (set slash bps to 0 to disable slashing).
    function createRoundForBudget(
        bytes32 roundId,
        address budgetTreasury,
        RoundTiming calldata timing,
        address roundOperator,
        SubmissionTcrConfig calldata tcrConfig,
        ArbitratorConfig calldata arbConfig
    ) external returns (DeployedRound memory out) {
        if (budgetTreasury == address(0)) revert ADDRESS_ZERO();
        if (roundOperator == address(0)) revert ADDRESS_ZERO();

        // Resolve budget flow -> goal flow -> goal treasury -> stake vault.
        address budgetFlow = _requireDeployedContract(IBudgetTreasury(budgetTreasury).flow());

        address goalFlow = _requireDeployedContract(IFlow(budgetFlow).parent());

        address goalTreasury = _requireDeployedContract(IFlow(goalFlow).flowOperator());

        // Optional sanity check: the goal treasury should report the same flow.
        if (IGoalTreasury(goalTreasury).flow() != goalFlow) revert INVALID_BUDGET_CONTEXT();

        address stakeVault = _requireDeployedContract(IGoalTreasury(goalTreasury).stakeVault());

        // Tokens.
        IERC20 underlying = IStakeVault(stakeVault).goalToken();
        ISuperToken superTok = IFlow(budgetFlow).superToken();
        address expectedUnderlying = address(underlying);
        address superUnderlying = _resolveSuperUnderlying(superTok);
        if (superUnderlying != expectedUnderlying) {
            revert SUPER_TOKEN_UNDERLYING_MISMATCH(expectedUnderlying, superUnderlying);
        }

        // 1) Clone the per-round submission TCR.
        address submissionTcr = roundSubmissionTcrImplementation.clone();

        // 2) Deploy prize vault (receives deposits + super token streams; pays underlying).
        RoundPrizeVault prizeVault = new RoundPrizeVault(underlying, superTok, RoundSubmissionTCR(submissionTcr), roundOperator);

        // 3) Deploy deposit strategy that routes accepted submission deposits into the prize vault.
        PrizePoolSubmissionDepositStrategy depositStrategy =
            new PrizePoolSubmissionDepositStrategy(underlying, address(prizeVault));

        // 4) Clone + initialize arbitrator (stake-vault voting scoped to this budget).
        address arbitrator = arbitratorImplementation.clone();
        IERC20VotesArbitrator(arbitrator).initializeWithStakeVaultAndBudgetScopeAndSlashConfig(
            address(prizeVault), // invalidRoundRewardsSink: keep funds in the round pool.
            address(underlying),
            submissionTcr,
            arbConfig.votingPeriod,
            arbConfig.votingDelay,
            arbConfig.revealPeriod,
            arbConfig.arbitrationCost,
            stakeVault,
            budgetTreasury,
            arbConfig.wrongOrMissedSlashBps,
            arbConfig.slashCallerBountyBps
        );

        // 5) Initialize the submission registry.
        RoundSubmissionTCR(submissionTcr).initialize(
            RoundSubmissionTCR.RoundConfig({
                roundId: roundId,
                startAt: timing.startAt,
                endAt: timing.endAt,
                prizeVault: address(prizeVault)
            }),
            RoundSubmissionTCR.RegistryConfig({
                arbitrator: IArbitrator(arbitrator),
                arbitratorExtraData: tcrConfig.arbitratorExtraData,
                registrationMetaEvidence: tcrConfig.registrationMetaEvidence,
                clearingMetaEvidence: tcrConfig.clearingMetaEvidence,
                governor: tcrConfig.governor,
                votingToken: IVotes(address(underlying)),
                submissionBaseDeposit: tcrConfig.submissionBaseDeposit,
                submissionDepositStrategy: depositStrategy,
                removalBaseDeposit: tcrConfig.removalBaseDeposit,
                submissionChallengeBaseDeposit: tcrConfig.submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit: tcrConfig.removalChallengeBaseDeposit,
                challengePeriodDuration: tcrConfig.challengePeriodDuration
            })
        );

        out = DeployedRound({
            prizeVault: address(prizeVault),
            submissionTCR: submissionTcr,
            arbitrator: arbitrator,
            depositStrategy: address(depositStrategy),
            underlyingToken: address(underlying),
            superToken: address(superTok),
            stakeVault: stakeVault,
            goalTreasury: goalTreasury,
            goalFlow: goalFlow,
            budgetFlow: budgetFlow
        });

        emit RoundDeployed(
            roundId,
            budgetTreasury,
            address(prizeVault),
            submissionTcr,
            arbitrator,
            address(depositStrategy),
            address(underlying),
            address(superTok)
        );
    }

    function _requireDeployedContract(address candidate) internal view returns (address deployed) {
        if (candidate == address(0) || candidate.code.length == 0) revert INVALID_BUDGET_CONTEXT();
        return candidate;
    }

    function _resolveSuperUnderlying(ISuperToken superTok) internal view returns (address underlyingToken) {
        try superTok.getUnderlyingToken() returns (address resolvedUnderlying) {
            return resolvedUnderlying;
        } catch {
            revert INVALID_BUDGET_CONTEXT();
        }
    }
}
