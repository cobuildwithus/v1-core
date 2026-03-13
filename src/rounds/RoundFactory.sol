// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { RoundPrizeVault } from "src/rounds/RoundPrizeVault.sol";
import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import { IERC20VotesArbitrator } from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IAllocationMechanismFactory } from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { BudgetContextReaderBase } from "src/library/BudgetContextReaderBase.sol";

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
 *         - An ERC20VotesArbitrator: adjudicates disputes for the registry (stake-vault voting, no juror slashing).
 *         - A RoundPrizeVault: holds prize funds and pays out in the underlying goal token.
 *         - A PrizePoolSubmissionDepositStrategy: routes accepted submission deposits into the prize vault.
 */
contract RoundFactory is IAllocationMechanismFactory, BudgetContextReaderBase {
    using Clones for address;

    enum BudgetContextProbe {
        BudgetTreasury,
        BudgetFlowRead,
        BudgetFlow,
        GoalFlowRead,
        GoalFlow,
        GoalTreasuryRead,
        GoalTreasury,
        GoalTreasuryFlowRead,
        StakeVaultRead,
        StakeVault,
        SuperTokenRead,
        SuperToken,
        SuperTokenUnderlyingRead
    }

    error ADDRESS_ZERO();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error INVALID_BUDGET_CONTEXT(BudgetContextProbe probe, address candidate);
    error GOAL_TREASURY_FLOW_MISMATCH(address goalTreasury, address expectedGoalFlow, address actualGoalFlow);
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

    /// @notice Configuration for a non-slashing ERC20VotesArbitrator instance.
    struct ArbitratorConfig {
        uint256 votingPeriod;
        uint256 votingDelay;
        uint256 revealPeriod;
        uint256 arbitrationCost;
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

    /// @notice Opaque config payload shape for generic `deployForBudget`.
    struct AllocationMechanismConfig {
        RoundTiming timing;
        address roundOperator;
        IGeneralizedTCRConfig.RegistryPolicy tcrPolicy;
        ArbitratorConfig arbConfig;
    }

    /// @notice Resolved runtime context for a budget-scoped round deployment.
    struct BudgetRoundContext {
        address budgetTreasury;
        address budgetFlow;
        address goalFlow;
        address goalTreasury;
        address stakeVault;
        IERC20 underlying;
        ISuperToken superToken;
    }

    /// @dev Clone targets.
    address public immutable roundSubmissionTcrImplementation;
    address public immutable roundPrizeVaultImplementation;
    address public immutable prizePoolSubmissionDepositStrategyImplementation;
    address public immutable arbitratorImplementation;

    constructor(
        address roundSubmissionTcrImplementation_,
        address roundPrizeVaultImplementation_,
        address prizePoolSubmissionDepositStrategyImplementation_,
        address arbitratorImplementation_
    ) {
        roundSubmissionTcrImplementation = _assertImplementationAddress(roundSubmissionTcrImplementation_);
        roundPrizeVaultImplementation = _assertImplementationAddress(roundPrizeVaultImplementation_);
        prizePoolSubmissionDepositStrategyImplementation = _assertImplementationAddress(
            prizePoolSubmissionDepositStrategyImplementation_
        );
        arbitratorImplementation = _assertImplementationAddress(arbitratorImplementation_);
    }

    /// @notice Deploy a full round stack for a given budget.
    /// @param roundId A caller-supplied identifier (recommended: parent mechanism TCR itemID).
    /// @param budgetTreasury Budget treasury whose flow will stream into the prize vault.
    /// @param timing Submission window for the round.
    /// @param roundOperator Trusted operator allowed to set payout entitlements in the prize vault.
    /// @param tcrPolicy Shared registry policy for the per-round submission registry.
    /// @param arbConfig Configuration for the round arbitrator voting windows and arbitration cost.
    function createRoundForBudget(
        bytes32 roundId,
        address budgetTreasury,
        RoundTiming memory timing,
        address roundOperator,
        IGeneralizedTCRConfig.RegistryPolicy memory tcrPolicy,
        ArbitratorConfig memory arbConfig
    ) public returns (DeployedRound memory out) {
        _validateCreateRoundInputs(budgetTreasury, roundOperator);
        BudgetRoundContext memory context = _resolveBudgetRoundContext(budgetTreasury);

        address submissionTcr = roundSubmissionTcrImplementation.clone();
        address prizeVault = _deployRoundPrizeVault(context, submissionTcr, roundOperator);
        PrizePoolSubmissionDepositStrategy depositStrategy = _deployRoundDepositStrategy(
            context.underlying,
            prizeVault
        );
        address arbitrator = _deployRoundArbitrator(context, submissionTcr, prizeVault, arbConfig);
        _initializeRoundSubmissionRegistry(
            roundId,
            timing,
            tcrPolicy,
            context.underlying,
            submissionTcr,
            prizeVault,
            arbitrator,
            depositStrategy
        );

        out = DeployedRound({
            prizeVault: prizeVault,
            submissionTCR: submissionTcr,
            arbitrator: arbitrator,
            depositStrategy: address(depositStrategy),
            underlyingToken: address(context.underlying),
            superToken: address(context.superToken),
            stakeVault: context.stakeVault,
            goalTreasury: context.goalTreasury,
            goalFlow: context.goalFlow,
            budgetFlow: context.budgetFlow
        });

        emit RoundDeployed(
            roundId,
            context.budgetTreasury,
            prizeVault,
            submissionTcr,
            arbitrator,
            address(depositStrategy),
            address(context.underlying),
            address(context.superToken)
        );
    }

    /// @notice Generic mechanism-factory adapter used by allocation mechanism registry.
    function deployForBudget(
        bytes32 mechanismId,
        address budgetTreasury,
        bytes calldata mechanismConfig
    ) external override returns (IAllocationMechanismFactory.DeployedMechanism memory out) {
        AllocationMechanismConfig memory cfg = abi.decode(mechanismConfig, (AllocationMechanismConfig));
        DeployedRound memory deployed = createRoundForBudget(
            mechanismId,
            budgetTreasury,
            cfg.timing,
            cfg.roundOperator,
            cfg.tcrPolicy,
            cfg.arbConfig
        );

        out = IAllocationMechanismFactory.DeployedMechanism({
            mechanism: deployed.submissionTCR,
            payoutRecipient: deployed.prizeVault,
            arbitrator: deployed.arbitrator,
            auxiliary: deployed.depositStrategy
        });
    }

    function _validateCreateRoundInputs(address budgetTreasury, address roundOperator) internal view {
        if (budgetTreasury == address(0)) revert ADDRESS_ZERO();
        if (roundOperator == address(0)) revert ADDRESS_ZERO();
        _requireBudgetContextContract(budgetTreasury, uint8(BudgetContextProbe.BudgetTreasury));
    }

    function _resolveBudgetRoundContext(
        address budgetTreasury
    ) internal view returns (BudgetRoundContext memory context) {
        context.budgetTreasury = budgetTreasury;
        context.budgetFlow = _readBudgetFlow(budgetTreasury);
        context.goalFlow = _readGoalFlow(context.budgetFlow);
        context.goalTreasury = _readGoalTreasury(context.goalFlow);
        address reportedGoalFlow = _readGoalTreasuryFlow(context.goalTreasury);
        if (reportedGoalFlow != context.goalFlow) {
            revert GOAL_TREASURY_FLOW_MISMATCH(context.goalTreasury, context.goalFlow, reportedGoalFlow);
        }

        context.stakeVault = _readStakeVault(context.goalTreasury);
        context.underlying = IStakeVault(context.stakeVault).goalToken();
        context.superToken = _readSuperToken(context.budgetFlow);

        address expectedUnderlying = address(context.underlying);
        address superUnderlying = _resolveSuperUnderlying(context.superToken);
        if (superUnderlying != expectedUnderlying) {
            revert SUPER_TOKEN_UNDERLYING_MISMATCH(expectedUnderlying, superUnderlying);
        }
    }

    function _assertImplementationAddress(address implementation) internal view returns (address deployed) {
        if (implementation == address(0)) revert ADDRESS_ZERO();
        if (implementation.code.length == 0) revert IMPLEMENTATION_HAS_NO_CODE(implementation);
        return implementation;
    }

    function _revertInvalidBudgetContext(uint8 probe, address candidate) internal pure override {
        revert INVALID_BUDGET_CONTEXT(BudgetContextProbe(probe), candidate);
    }

    function _readBudgetFlow(address budgetTreasury) internal view returns (address budgetFlow) {
        return
            _readBudgetContextContract(
                IBudgetTreasury(budgetTreasury).flow,
                budgetTreasury,
                uint8(BudgetContextProbe.BudgetFlowRead),
                uint8(BudgetContextProbe.BudgetFlow)
            );
    }

    function _readGoalFlow(address budgetFlow) internal view returns (address goalFlow) {
        return
            _readBudgetContextContract(
                IFlow(budgetFlow).parent,
                budgetFlow,
                uint8(BudgetContextProbe.GoalFlowRead),
                uint8(BudgetContextProbe.GoalFlow)
            );
    }

    function _readGoalTreasury(address goalFlow) internal view returns (address goalTreasury) {
        return
            _readBudgetContextContract(
                IFlow(goalFlow).flowOperator,
                goalFlow,
                uint8(BudgetContextProbe.GoalTreasuryRead),
                uint8(BudgetContextProbe.GoalTreasury)
            );
    }

    function _readGoalTreasuryFlow(address goalTreasury) internal view returns (address goalFlow) {
        return
            _readBudgetContextValue(
                IGoalTreasury(goalTreasury).flow,
                goalTreasury,
                uint8(BudgetContextProbe.GoalTreasuryFlowRead)
            );
    }

    function _readStakeVault(address goalTreasury) internal view returns (address stakeVault) {
        return
            _readBudgetContextContract(
                IGoalTreasury(goalTreasury).stakeVault,
                goalTreasury,
                uint8(BudgetContextProbe.StakeVaultRead),
                uint8(BudgetContextProbe.StakeVault)
            );
    }

    function _readSuperToken(address budgetFlow) internal view returns (ISuperToken superTok) {
        return
            _readBudgetContextContract(
                IFlow(budgetFlow).superToken,
                budgetFlow,
                uint8(BudgetContextProbe.SuperTokenRead),
                uint8(BudgetContextProbe.SuperToken)
            );
    }

    function _deployRoundPrizeVault(
        BudgetRoundContext memory context,
        address submissionTcr,
        address roundOperator
    ) internal returns (address prizeVault) {
        prizeVault = roundPrizeVaultImplementation.clone();
        RoundPrizeVault(prizeVault).initialize(
            context.underlying,
            context.superToken,
            RoundSubmissionTCR(submissionTcr),
            roundOperator
        );
    }

    function _deployRoundDepositStrategy(
        IERC20 underlying,
        address prizeVault
    ) internal returns (PrizePoolSubmissionDepositStrategy depositStrategy) {
        depositStrategy = PrizePoolSubmissionDepositStrategy(prizePoolSubmissionDepositStrategyImplementation.clone());
        depositStrategy.initialize(underlying, prizeVault);
    }

    function _deployRoundArbitrator(
        BudgetRoundContext memory context,
        address submissionTcr,
        address prizeVault,
        ArbitratorConfig memory arbConfig
    ) internal returns (address arbitrator) {
        arbitrator = arbitratorImplementation.clone();
        IERC20VotesArbitrator(arbitrator).initializeWithConfig(
            IERC20VotesArbitrator.InitConfig({
                invalidRoundRewardsSink: prizeVault, // keep unresolved/no-vote rewards in the round pool.
                votingToken: address(context.underlying),
                arbitrable: submissionTcr,
                votingPeriod: arbConfig.votingPeriod,
                votingDelay: arbConfig.votingDelay,
                revealPeriod: arbConfig.revealPeriod,
                arbitrationCost: arbConfig.arbitrationCost,
                stakeVault: context.stakeVault,
                fixedBudgetTreasury: context.budgetTreasury,
                wrongOrMissedSlashBps: 0,
                slashCallerBountyBps: 0
            })
        );
    }

    function _initializeRoundSubmissionRegistry(
        bytes32 roundId,
        RoundTiming memory timing,
        IGeneralizedTCRConfig.RegistryPolicy memory tcrPolicy,
        IERC20 underlying,
        address submissionTcr,
        address prizeVault,
        address arbitrator,
        PrizePoolSubmissionDepositStrategy depositStrategy
    ) internal {
        RoundSubmissionTCR(submissionTcr).initialize(
            RoundSubmissionTCR.RoundConfig({
                roundId: roundId,
                startAt: timing.startAt,
                endAt: timing.endAt,
                prizeVault: prizeVault
            }),
            IGeneralizedTCRConfig.RegistryConfig({
                arbitrator: IArbitrator(arbitrator),
                votingToken: IVotes(address(underlying)),
                submissionDepositStrategy: depositStrategy,
                registryPolicy: tcrPolicy
            })
        );
    }

    function _resolveSuperUnderlying(ISuperToken superTok) internal view returns (address underlyingToken) {
        try superTok.getUnderlyingToken() returns (address resolvedUnderlying) {
            return resolvedUnderlying;
        } catch {
            revert INVALID_BUDGET_CONTEXT(BudgetContextProbe.SuperTokenUnderlyingRead, address(superTok));
        }
    }
}
