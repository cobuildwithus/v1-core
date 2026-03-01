// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { IERC20VotesArbitrator } from "./interfaces/IERC20VotesArbitrator.sol";
import { IBudgetTCRDeployer } from "./interfaces/IBudgetTCRDeployer.sol";
import { ISubmissionDepositStrategy } from "./interfaces/ISubmissionDepositStrategy.sol";
import { ISubmissionDepositStrategyCapabilities } from "./interfaces/ISubmissionDepositStrategyCapabilities.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { JurorSlasherRouter } from "src/goals/JurorSlasherRouter.sol";

contract BudgetTCRFactory {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant HEALTHY_ARBITRATION_COST_MULTIPLIER = 6; // Healthy lower bound: 6x arb cost.
    bytes32 internal constant BUDGET_TCR_SALT_DOMAIN = keccak256("BudgetTCRFactory.BudgetTCR");

    error ADDRESS_ZERO();
    error UNAUTHORIZED_CALLER(address caller);
    error INVALID_ESCROW_BOND_BPS(uint256 escrowBondBps);
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error UNSUPPORTED_JUROR_SLASHER(address configuredSlasher);
    error INVALID_SLASHER_AUTHORITY(address expected, address actual);
    error INVALID_SLASHER_STAKE_VAULT(address expected, address actual);
    error UNDERWRITER_SLASHER_NOT_CONFIGURED();
    error UNSUPPORTED_UNDERWRITER_SLASHER(address configuredSlasher);
    error INVALID_UNDERWRITER_SLASHER_AUTHORITY(address expected, address actual);
    error INVALID_UNDERWRITER_SLASHER_STAKE_VAULT(address expected, address actual);

    struct RegistryConfigInput {
        address governor;
        address invalidRoundRewardsSink;
        bytes arbitratorExtraData;
        string registrationMetaEvidence;
        string clearingMetaEvidence;
        IVotes votingToken;
        uint256 submissionBaseDeposit;
        uint256 removalBaseDeposit;
        uint256 submissionChallengeBaseDeposit;
        uint256 removalChallengeBaseDeposit;
        uint256 challengePeriodDuration;
        ISubmissionDepositStrategy submissionDepositStrategy;
    }

    struct DeployedBudgetTCRStack {
        address budgetTCR;
        address arbitrator;
        address token;
    }

    event BudgetTCRStackDeployedForGoal(
        address indexed sender,
        address indexed budgetTCR,
        address indexed arbitrator,
        address token,
        address goalFlow,
        address goalTreasury
    );

    address public immutable budgetTCRImplementation;
    address public immutable arbitratorImplementation;
    address public immutable stackDeployerImplementation;
    address public immutable authorizedCaller;
    uint256 public immutable escrowBondBps;

    constructor(
        address budgetTCRImplementation_,
        address arbitratorImplementation_,
        address stackDeployerImplementation_,
        address authorizedCaller_,
        uint256 escrowBondBps_
    ) {
        if (budgetTCRImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (arbitratorImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (stackDeployerImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (authorizedCaller_ == address(0)) revert ADDRESS_ZERO();
        if (escrowBondBps_ == 0 || escrowBondBps_ > BPS_DENOMINATOR) {
            revert INVALID_ESCROW_BOND_BPS(escrowBondBps_);
        }
        _assertImplementationHasCode(budgetTCRImplementation_);
        _assertImplementationHasCode(arbitratorImplementation_);
        _assertImplementationHasCode(stackDeployerImplementation_);

        budgetTCRImplementation = budgetTCRImplementation_;
        arbitratorImplementation = arbitratorImplementation_;
        stackDeployerImplementation = stackDeployerImplementation_;
        authorizedCaller = authorizedCaller_;
        escrowBondBps = escrowBondBps_;
    }

    function deployBudgetTCRStackForGoal(
        RegistryConfigInput calldata registryConfig,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        IArbitrator.ArbitratorParams calldata arbitratorParams
    ) external returns (DeployedBudgetTCRStack memory deployed) {
        if (msg.sender != authorizedCaller) revert UNAUTHORIZED_CALLER(msg.sender);
        address token = address(registryConfig.votingToken);
        if (token == address(0)) revert ADDRESS_ZERO();
        if (registryConfig.invalidRoundRewardsSink == address(0)) revert ADDRESS_ZERO();
        if (address(registryConfig.submissionDepositStrategy) == address(0)) revert ADDRESS_ZERO();
        address stakeVault = IGoalTreasury(address(deploymentConfig.goalTreasury)).stakeVault();
        if (stakeVault == address(0)) revert ADDRESS_ZERO();

        bytes32 budgetTCRSalt = deriveBudgetTCRSalt(
            msg.sender,
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            token
        );
        address budgetTCR = Clones.cloneDeterministic(budgetTCRImplementation, budgetTCRSalt);
        address arbitrator = Clones.clone(arbitratorImplementation);
        address stackDeployer = Clones.clone(stackDeployerImplementation);
        IBudgetTCRDeployer(stackDeployer).initialize(budgetTCR, deploymentConfig.premiumEscrowImplementation);

        IERC20VotesArbitrator(arbitrator).initializeWithStakeVaultAndSlashConfig(
            registryConfig.invalidRoundRewardsSink,
            token,
            budgetTCR,
            arbitratorParams.votingPeriod,
            arbitratorParams.votingDelay,
            arbitratorParams.revealPeriod,
            arbitratorParams.arbitrationCost,
            stakeVault,
            arbitratorParams.wrongOrMissedSlashBps,
            arbitratorParams.slashCallerBountyBps
        );
        _configureJurorSlasherIfFactoryAuthority(deploymentConfig.goalTreasury, stakeVault, arbitrator);
        address underwriterSlasherRouter =
            _resolveUnderwriterSlasherRouter(deploymentConfig.goalTreasury, deploymentConfig.underwriterSlasherRouter);

        (
            uint256 submissionBaseDeposit,
            uint256 removalBaseDeposit,
            uint256 submissionChallengeBaseDeposit,
            uint256 removalChallengeBaseDeposit
        ) = _resolveDeposits(registryConfig, deploymentConfig, arbitratorParams.arbitrationCost);

        IBudgetTCR.RegistryConfig memory registryConfigFull = _buildRegistryConfig(
            registryConfig,
            arbitrator,
            submissionBaseDeposit,
            removalBaseDeposit,
            submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit
        );

        IBudgetTCR.DeploymentConfig memory deploymentConfigFull = _buildDeploymentConfig(
            deploymentConfig,
            stackDeployer,
            underwriterSlasherRouter
        );

        IBudgetTCR(budgetTCR).initialize(registryConfigFull, deploymentConfigFull);

        emit BudgetTCRStackDeployedForGoal(
            msg.sender,
            budgetTCR,
            arbitrator,
            token,
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury)
        );

        deployed = DeployedBudgetTCRStack({ budgetTCR: budgetTCR, arbitrator: arbitrator, token: token });
    }

    function deriveBudgetTCRSalt(
        address sender,
        address goalFlow,
        address goalTreasury,
        uint256 goalRevnetId,
        address votingToken
    ) public pure returns (bytes32 salt) {
        salt = keccak256(abi.encode(BUDGET_TCR_SALT_DOMAIN, sender, goalFlow, goalTreasury, goalRevnetId, votingToken));
    }

    function predictBudgetTCRAddress(
        address sender,
        address goalFlow,
        address goalTreasury,
        uint256 goalRevnetId,
        address votingToken
    ) external view returns (address predicted) {
        bytes32 budgetTCRSalt = deriveBudgetTCRSalt(sender, goalFlow, goalTreasury, goalRevnetId, votingToken);
        predicted = Clones.predictDeterministicAddress(budgetTCRImplementation, budgetTCRSalt, address(this));
    }

    function _assertImplementationHasCode(address implementation) internal view {
        if (implementation.code.length == 0) {
            revert IMPLEMENTATION_HAS_NO_CODE(implementation);
        }
    }

    function _configureJurorSlasherIfFactoryAuthority(
        IGoalTreasury goalTreasury,
        address stakeVault,
        address arbitrator
    ) internal {
        if (goalTreasury.authority() != address(this)) return;

        address router = IStakeVault(stakeVault).jurorSlasher();
        if (router == address(0)) {
            router = address(new JurorSlasherRouter(IStakeVault(stakeVault), address(this)));
            goalTreasury.configureJurorSlasher(router);
        } else {
            _validateConfiguredJurorSlasher(router, stakeVault);
        }

        JurorSlasherRouter(router).setAuthorizedSlasher(arbitrator, true);
    }

    function _validateConfiguredJurorSlasher(address configuredSlasher, address stakeVault) internal view {
        address slasherAuthority;
        try JurorSlasherRouter(configuredSlasher).authority() returns (address authority_) {
            slasherAuthority = authority_;
        } catch {
            revert UNSUPPORTED_JUROR_SLASHER(configuredSlasher);
        }
        if (slasherAuthority != address(this)) {
            revert INVALID_SLASHER_AUTHORITY(address(this), slasherAuthority);
        }

        address slasherStakeVault;
        try JurorSlasherRouter(configuredSlasher).stakeVault() returns (IStakeVault stakeVault_) {
            slasherStakeVault = address(stakeVault_);
        } catch {
            revert UNSUPPORTED_JUROR_SLASHER(configuredSlasher);
        }
        if (slasherStakeVault != stakeVault) {
            revert INVALID_SLASHER_STAKE_VAULT(stakeVault, slasherStakeVault);
        }
    }

    function _buildRegistryConfig(
        RegistryConfigInput calldata registryConfig,
        address arbitrator,
        uint256 submissionBaseDeposit,
        uint256 removalBaseDeposit,
        uint256 submissionChallengeBaseDeposit,
        uint256 removalChallengeBaseDeposit
    ) internal pure returns (IBudgetTCR.RegistryConfig memory config) {
        config = IBudgetTCR.RegistryConfig({
            governor: registryConfig.governor,
            arbitrator: IArbitrator(arbitrator),
            arbitratorExtraData: registryConfig.arbitratorExtraData,
            registrationMetaEvidence: registryConfig.registrationMetaEvidence,
            clearingMetaEvidence: registryConfig.clearingMetaEvidence,
            votingToken: registryConfig.votingToken,
            submissionBaseDeposit: submissionBaseDeposit,
            removalBaseDeposit: removalBaseDeposit,
            submissionChallengeBaseDeposit: submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: removalChallengeBaseDeposit,
            challengePeriodDuration: registryConfig.challengePeriodDuration,
            submissionDepositStrategy: registryConfig.submissionDepositStrategy
        });
    }

    function _buildDeploymentConfig(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        address stackDeployer,
        address underwriterSlasherRouter
    ) internal pure returns (IBudgetTCR.DeploymentConfig memory config) {
        config = IBudgetTCR.DeploymentConfig({
            stackDeployer: stackDeployer,
            budgetSuccessResolver: deploymentConfig.budgetSuccessResolver,
            goalFlow: deploymentConfig.goalFlow,
            goalTreasury: deploymentConfig.goalTreasury,
            goalToken: deploymentConfig.goalToken,
            cobuildToken: deploymentConfig.cobuildToken,
            goalRulesets: deploymentConfig.goalRulesets,
            goalRevnetId: deploymentConfig.goalRevnetId,
            paymentTokenDecimals: deploymentConfig.paymentTokenDecimals,
            premiumEscrowImplementation: deploymentConfig.premiumEscrowImplementation,
            underwriterSlasherRouter: underwriterSlasherRouter,
            budgetPremiumPpm: deploymentConfig.budgetPremiumPpm,
            budgetSlashPpm: deploymentConfig.budgetSlashPpm,
            managerRewardPool: deploymentConfig.managerRewardPool,
            budgetValidationBounds: deploymentConfig.budgetValidationBounds,
            oracleValidationBounds: deploymentConfig.oracleValidationBounds
        });
    }

    function _resolveUnderwriterSlasherRouter(IGoalTreasury goalTreasury, address configuredRouter)
        internal
        returns (address router)
    {
        if (configuredRouter == address(0) || configuredRouter.code.length == 0) {
            revert UNDERWRITER_SLASHER_NOT_CONFIGURED();
        }
        router = configuredRouter;

        if (goalTreasury.authority() == address(this)) {
            goalTreasury.configureUnderwriterSlasher(router);
        }
    }

    function _resolveDeposits(
        RegistryConfigInput calldata registryConfig,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        uint256 arbitrationCost
    )
        internal
        view
        returns (
            uint256 submissionBaseDeposit,
            uint256 removalBaseDeposit,
            uint256 submissionChallengeBaseDeposit,
            uint256 removalChallengeBaseDeposit
        )
    {
        if (!_isEscrowBondStrategy(registryConfig.submissionDepositStrategy)) {
            return (
                registryConfig.submissionBaseDeposit,
                registryConfig.removalBaseDeposit,
                registryConfig.submissionChallengeBaseDeposit,
                registryConfig.removalChallengeBaseDeposit
            );
        }

        uint256 deposit = _deriveEscrowBondDeposit(deploymentConfig.budgetValidationBounds, arbitrationCost);
        return (deposit, deposit, deposit, 0);
    }

    function _deriveEscrowBondDeposit(
        IBudgetTCR.BudgetValidationBounds calldata budgetBounds,
        uint256 arbitrationCost
    ) internal view returns (uint256 deposit) {
        uint256 sizingBase = budgetBounds.maxRunwayCap != 0
            ? budgetBounds.maxRunwayCap
            : budgetBounds.maxActivationThreshold;
        uint256 sizingComponent = (sizingBase * escrowBondBps) / BPS_DENOMINATOR;
        uint256 floorComponent = arbitrationCost * HEALTHY_ARBITRATION_COST_MULTIPLIER;
        deposit = sizingComponent > floorComponent ? sizingComponent : floorComponent;
    }

    function _isEscrowBondStrategy(ISubmissionDepositStrategy strategy) internal view returns (bool) {
        try ISubmissionDepositStrategyCapabilities(address(strategy)).supportsEscrowBonding() returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }
}
