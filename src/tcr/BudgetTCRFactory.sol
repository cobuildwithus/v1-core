// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IArbitrator } from "./interfaces/IArbitrator.sol";
import { IGeneralizedTCRConfig } from "./interfaces/IGeneralizedTCRConfig.sol";
import { IERC20VotesArbitrator } from "./interfaces/IERC20VotesArbitrator.sol";
import { IBudgetTCRDeployer } from "./interfaces/IBudgetTCRDeployer.sol";
import { ISubmissionDepositStrategy } from "./interfaces/ISubmissionDepositStrategy.sol";
import { ISubmissionDepositStrategyCapabilities } from "./interfaces/ISubmissionDepositStrategyCapabilities.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";
import { JurorSlasherRouter } from "src/goals/JurorSlasherRouter.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

contract BudgetTCRFactory {
    uint256 internal constant HEALTHY_ARBITRATION_COST_MULTIPLIER = 6; // Healthy lower bound: 6x arb cost.
    bytes32 internal constant BUDGET_TCR_SALT_DOMAIN = keccak256("BudgetTCRFactory.BudgetTCR");

    error ADDRESS_ZERO();
    error UNAUTHORIZED_CALLER(address caller);
    error INVALID_ESCROW_BOND_BPS(uint256 escrowBondBps);
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error JUROR_SLASHER_NOT_CONFIGURED();
    error UNSUPPORTED_JUROR_SLASHER(address configuredSlasher);
    error INVALID_SLASHER_AUTHORITY(address expected, address actual);
    error INVALID_SLASHER_STAKE_VAULT(address expected, address actual);
    error UNDERWRITER_SLASHER_NOT_CONFIGURED();
    error UNDERWRITER_SLASHER_MISMATCH(address expected, address actual);
    error UNSUPPORTED_UNDERWRITER_SLASHER(address configuredSlasher);
    error INVALID_UNDERWRITER_SLASHER_AUTHORITY(address expected, address actual);
    error INVALID_UNDERWRITER_SLASHER_STAKE_VAULT(address expected, address actual);
    error UNAUTHORIZED_STACK_DEPLOYER(address caller);
    error SUBMISSION_DEPOSIT_STRATEGY_CAPABILITY_PROBE_FAILED(address strategy);

    struct RegistryConfigInput {
        address allocationMechanismAdmin;
        address invalidRoundRewardsSink;
        IVotes votingToken;
        ISubmissionDepositStrategy submissionDepositStrategy;
        IGeneralizedTCRConfig.RegistryPolicy registryPolicy;
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
    event BudgetStackDeployed(
        address indexed budgetTCR,
        bytes32 indexed itemID,
        address indexed childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    );
    event BudgetAllocationMechanismDeployed(
        address indexed budgetTCR,
        bytes32 indexed itemID,
        address indexed allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory
    );

    address public immutable budgetTCRImplementation;
    address public immutable arbitratorImplementation;
    address public immutable stackDeployerImplementation;
    address public immutable authorizedCaller;
    uint256 public immutable escrowBondBps;
    mapping(address stackDeployer => address budgetTCR) public budgetTCRByStackDeployer;
    mapping(address budgetTCR => address stackDeployer) public stackDeployerByBudgetTCR;
    mapping(address budgetTCR => address jurorSlasherRouter) public jurorSlasherRouterByBudgetTCR;

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
        if (escrowBondBps_ == 0 || escrowBondBps_ > FlowProtocolConstants.BPS_SCALE_UINT256) {
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
        address stakeVault = deploymentConfig.goalTreasury.stakeVault();
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
        bool requiresPremiumModule = _requiresPremiumModule(deploymentConfig);
        bool requiresUnderwriterSlasherRouter = _requiresUnderwriterSlasherRouter(deploymentConfig);
        _initializeStackDeployer(
            stackDeployer,
            budgetTCR,
            requiresPremiumModule ? deploymentConfig.riskModuleRouting.premiumEscrowImplementation : address(0)
        );
        budgetTCRByStackDeployer[stackDeployer] = budgetTCR;
        stackDeployerByBudgetTCR[budgetTCR] = stackDeployer;

        IERC20VotesArbitrator(arbitrator).initializeWithConfig(
            IERC20VotesArbitrator.InitConfig({
                invalidRoundRewardsSink: registryConfig.invalidRoundRewardsSink,
                votingToken: token,
                arbitrable: budgetTCR,
                votingPeriod: arbitratorParams.votingPeriod,
                votingDelay: arbitratorParams.votingDelay,
                revealPeriod: arbitratorParams.revealPeriod,
                arbitrationCost: arbitratorParams.arbitrationCost,
                stakeVault: stakeVault,
                fixedBudgetTreasury: address(0),
                wrongOrMissedSlashBps: arbitratorParams.wrongOrMissedSlashBps,
                slashCallerBountyBps: arbitratorParams.slashCallerBountyBps
            })
        );
        address jurorSlasherRouter = _resolveConfiguredJurorSlasherRouter(stakeVault);
        jurorSlasherRouterByBudgetTCR[budgetTCR] = jurorSlasherRouter;
        JurorSlasherRouter(jurorSlasherRouter).setAuthorizedSlasher(arbitrator, true);
        address underwriterSlasherRouter = requiresUnderwriterSlasherRouter
            ? _resolveUnderwriterSlasherRouter(
                deploymentConfig.riskModuleRouting.underwriterSlasherRouter,
                stakeVault,
                budgetTCR
            )
            : address(0);

        IGeneralizedTCRConfig.RegistryPolicy memory resolvedPolicy = _resolveRegistryPolicy(
            registryConfig,
            deploymentConfig,
            arbitratorParams.arbitrationCost
        );

        IBudgetTCR.InitConfig memory initConfig = _buildInitConfig(registryConfig, arbitrator, resolvedPolicy);

        IBudgetTCR.DeploymentConfig memory deploymentConfigFull = _buildDeploymentConfig(
            deploymentConfig,
            stackDeployer,
            underwriterSlasherRouter,
            requiresPremiumModule
        );

        IBudgetTCR(budgetTCR).initialize(initConfig, deploymentConfigFull);

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

    function onBudgetStackDeployed(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    ) external {
        address budgetTCR = budgetTCRByStackDeployer[msg.sender];
        if (budgetTCR == address(0)) revert UNAUTHORIZED_STACK_DEPLOYER(msg.sender);
        emit BudgetStackDeployed(budgetTCR, itemID, childFlow, budgetTreasury, premiumEscrow, strategy);
    }

    function onBudgetAllocationMechanismDeployed(
        bytes32 itemID,
        address allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory
    ) external {
        address budgetTCR = budgetTCRByStackDeployer[msg.sender];
        if (budgetTCR == address(0)) revert UNAUTHORIZED_STACK_DEPLOYER(msg.sender);
        _authorizeMechanismArbitrator(budgetTCR, allocationMechanismArbitrator);
        emit BudgetAllocationMechanismDeployed(
            budgetTCR,
            itemID,
            allocationMechanism,
            allocationMechanismArbitrator,
            roundFactory
        );
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

    function _authorizeMechanismArbitrator(address budgetTCR, address allocationMechanismArbitrator) internal {
        address jurorSlasherRouter = jurorSlasherRouterByBudgetTCR[budgetTCR];
        if (jurorSlasherRouter == address(0)) revert JUROR_SLASHER_NOT_CONFIGURED();
        JurorSlasherRouter(jurorSlasherRouter).setAuthorizedSlasher(allocationMechanismArbitrator, true);
    }

    function _initializeStackDeployer(
        address stackDeployer,
        address budgetTCR,
        address premiumEscrowImplementation
    ) internal {
        IBudgetTCRDeployer(stackDeployer).initializeWithConfig(
            budgetTCR,
            _stackModuleConfig(premiumEscrowImplementation),
            address(this)
        );
    }

    function _requiresPremiumModule(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) internal pure returns (bool) {
        return deploymentConfig.budgetPremiumPpm != 0 || deploymentConfig.budgetSlashPpm != 0;
    }

    function _requiresUnderwriterSlasherRouter(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) internal pure returns (bool) {
        return deploymentConfig.budgetSlashPpm != 0;
    }

    function _assertImplementationHasCode(address implementation) internal view {
        if (implementation.code.length == 0) {
            revert IMPLEMENTATION_HAS_NO_CODE(implementation);
        }
    }

    function _resolveConfiguredJurorSlasherRouter(address stakeVault) internal view returns (address router) {
        router = IStakeVault(stakeVault).jurorSlasher();
        if (router == address(0)) revert JUROR_SLASHER_NOT_CONFIGURED();
        _validateConfiguredJurorSlasher(router, stakeVault);
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

    function _buildInitConfig(
        RegistryConfigInput calldata registryConfig,
        address arbitrator,
        IGeneralizedTCRConfig.RegistryPolicy memory registryPolicy
    ) internal pure returns (IBudgetTCR.InitConfig memory config) {
        config = IBudgetTCR.InitConfig({
            allocationMechanismAdmin: registryConfig.allocationMechanismAdmin,
            tcrConfig: IGeneralizedTCRConfig.RegistryConfig({
                arbitrator: IArbitrator(arbitrator),
                votingToken: registryConfig.votingToken,
                submissionDepositStrategy: registryConfig.submissionDepositStrategy,
                registryPolicy: registryPolicy
            })
        });
    }

    function _buildDeploymentConfig(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        address stackDeployer,
        address underwriterSlasherRouter,
        bool requiresPremiumModule
    ) internal pure returns (IBudgetTCR.DeploymentConfig memory config) {
        config = IBudgetTCR.DeploymentConfig({
            stackDeployer: stackDeployer,
            budgetSuccessResolver: deploymentConfig.budgetSuccessResolver,
            budgetSpendPolicy: deploymentConfig.budgetSpendPolicy,
            riskModuleRouting: IBudgetTCR.RiskModuleRouting({
                budgetGatePolicy: deploymentConfig.riskModuleRouting.budgetGatePolicy,
                premiumEscrowImplementation: requiresPremiumModule
                    ? deploymentConfig.riskModuleRouting.premiumEscrowImplementation
                    : address(0),
                underwriterSlasherRouter: deploymentConfig.budgetSlashPpm != 0 ? underwriterSlasherRouter : address(0)
            }),
            goalFlow: deploymentConfig.goalFlow,
            goalTreasury: deploymentConfig.goalTreasury,
            goalToken: deploymentConfig.goalToken,
            cobuildToken: deploymentConfig.cobuildToken,
            goalRulesets: deploymentConfig.goalRulesets,
            goalRevnetId: deploymentConfig.goalRevnetId,
            paymentTokenDecimals: deploymentConfig.paymentTokenDecimals,
            budgetPremiumPpm: deploymentConfig.budgetPremiumPpm,
            budgetSlashPpm: deploymentConfig.budgetSlashPpm,
            budgetValidationBounds: deploymentConfig.budgetValidationBounds,
            oracleValidationBounds: deploymentConfig.oracleValidationBounds
        });
    }

    function _stackModuleConfig(
        address premiumEscrowImplementation
    ) internal pure returns (IBudgetStackDeployer.StackModuleConfig memory config) {
        config = IBudgetStackDeployer.StackModuleConfig({
            childFlowStrategyMode: IBudgetStackDeployer.ChildFlowStrategyMode.SharedBudgetFlowRouter,
            childFlowStrategyTarget: address(0),
            mechanismLayerMode: IBudgetStackDeployer.MechanismLayerMode.AllocationMechanismTCR,
            childFlowRecipientAdmin: address(0),
            premiumEscrowImplementation: premiumEscrowImplementation
        });
    }

    function _resolveUnderwriterSlasherRouter(
        address configuredRouter,
        address stakeVault,
        address budgetTCR
    ) internal view returns (address router) {
        if (configuredRouter == address(0) || configuredRouter.code.length == 0) {
            revert UNDERWRITER_SLASHER_NOT_CONFIGURED();
        }
        router = configuredRouter;
        _validateConfiguredUnderwriterSlasher(router, stakeVault, budgetTCR);

        address configuredOnStakeVault = IStakeVault(stakeVault).underwriterSlasher();
        if (configuredOnStakeVault == address(0)) revert UNDERWRITER_SLASHER_NOT_CONFIGURED();
        if (configuredOnStakeVault != router) {
            revert UNDERWRITER_SLASHER_MISMATCH(router, configuredOnStakeVault);
        }
    }

    function _validateConfiguredUnderwriterSlasher(
        address configuredSlasher,
        address stakeVault,
        address budgetTCR
    ) internal view {
        IUnderwriterSlasherRouter router = IUnderwriterSlasherRouter(configuredSlasher);

        try router.authority() returns (address authority_) {
            if (authority_ != budgetTCR) {
                revert INVALID_UNDERWRITER_SLASHER_AUTHORITY(budgetTCR, authority_);
            }
        } catch {
            revert UNSUPPORTED_UNDERWRITER_SLASHER(configuredSlasher);
        }

        try router.stakeVault() returns (IStakeVault stakeVault_) {
            address configuredStakeVault = address(stakeVault_);
            if (configuredStakeVault != stakeVault) {
                revert INVALID_UNDERWRITER_SLASHER_STAKE_VAULT(stakeVault, configuredStakeVault);
            }
        } catch {
            revert UNSUPPORTED_UNDERWRITER_SLASHER(configuredSlasher);
        }
    }

    function _resolveRegistryPolicy(
        RegistryConfigInput calldata registryConfig,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        uint256 arbitrationCost
    ) internal view returns (IGeneralizedTCRConfig.RegistryPolicy memory policy) {
        policy = registryConfig.registryPolicy;
        if (!_isEscrowBondStrategy(registryConfig.submissionDepositStrategy)) {
            return policy;
        }

        uint256 deposit = _deriveEscrowBondDeposit(deploymentConfig.budgetValidationBounds, arbitrationCost);
        policy.submissionBaseDeposit = deposit;
        policy.removalBaseDeposit = deposit;
        policy.submissionChallengeBaseDeposit = deposit;
        policy.removalChallengeBaseDeposit = 0;
    }

    function _deriveEscrowBondDeposit(
        IBudgetTCR.BudgetValidationBounds calldata budgetBounds,
        uint256 arbitrationCost
    ) internal view returns (uint256 deposit) {
        uint256 sizingBase = budgetBounds.maxRunwayCap != 0
            ? budgetBounds.maxRunwayCap
            : budgetBounds.maxActivationThreshold;
        uint256 sizingComponent = (sizingBase * escrowBondBps) / FlowProtocolConstants.BPS_SCALE_UINT256;
        uint256 floorComponent = arbitrationCost * HEALTHY_ARBITRATION_COST_MULTIPLIER;
        deposit = sizingComponent > floorComponent ? sizingComponent : floorComponent;
    }

    function _isEscrowBondStrategy(ISubmissionDepositStrategy strategy) internal view returns (bool) {
        try ISubmissionDepositStrategyCapabilities(address(strategy)).supportsEscrowBonding() returns (bool supported) {
            return supported;
        } catch {
            revert SUBMISSION_DEPOSIT_STRATEGY_CAPABILITY_PROBE_FAILED(address(strategy));
        }
    }
}
