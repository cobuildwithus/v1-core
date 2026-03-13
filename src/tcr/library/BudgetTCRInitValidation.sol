// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { BudgetStackTypes } from "src/interfaces/BudgetStackTypes.sol";
import { IBudgetStackControllerReader } from "src/interfaces/IBudgetStackControllerReader.sol";
import { IBudgetStackRuntimeDeployer } from "src/interfaces/IBudgetStackRuntimeDeployer.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { BudgetStackPresetConfigLib } from "src/goals/library/BudgetStackPresetConfigLib.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { SpendPolicyValidationLib } from "src/library/SpendPolicyValidationLib.sol";

library BudgetTCRInitValidation {
    function validateInitialization(
        IBudgetTCR.InitConfig calldata initConfig,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        address expectedController
    ) external view returns (address budgetGatePolicy_) {
        if (deploymentConfig.stackDeployer == address(0)) {
            revert IGeneralizedTCR.ADDRESS_ZERO();
        }
        if (deploymentConfig.stackDeployer.code.length == 0) {
            revert IBudgetTCR.NOT_A_CONTRACT(deploymentConfig.stackDeployer);
        }
        if (deploymentConfig.discoveryEmitter == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.discoveryEmitter.code.length == 0) {
            revert IBudgetTCR.NOT_A_CONTRACT(deploymentConfig.discoveryEmitter);
        }
        if (deploymentConfig.budgetSuccessResolver == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.budgetSpendPolicy == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalFlow) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalTreasury) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalToken) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.cobuildToken) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalRulesets) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.budgetSpendPolicy.code.length == 0) {
            revert IBudgetTCR.NOT_A_CONTRACT(deploymentConfig.budgetSpendPolicy);
        }

        if (deploymentConfig.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE) {
            revert IBudgetTCR.INVALID_PPM(deploymentConfig.budgetPremiumPpm);
        }
        if (deploymentConfig.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE) {
            revert IBudgetTCR.INVALID_PPM(deploymentConfig.budgetSlashPpm);
        }

        bool requiresPremiumModule = _requiresPremiumModule(deploymentConfig);
        bool hasPremiumModuleWiring = _hasPremiumModuleWiring(deploymentConfig);
        bool requiresUnderwriterSlasherRouter = _requiresUnderwriterSlasherRouter(deploymentConfig);
        bool hasUnderwriterSlasherRouterWiring = _hasUnderwriterSlasherRouterWiring(deploymentConfig);
        budgetGatePolicy_ = _validateBudgetGatePolicy(deploymentConfig);
        _requirePremiumModuleConsistency(requiresPremiumModule, hasPremiumModuleWiring);
        _requireUnderwriterSlasherRouterConsistency(
            requiresUnderwriterSlasherRouter,
            hasUnderwriterSlasherRouterWiring
        );
        if (requiresPremiumModule) _requirePremiumEscrowImplementation(deploymentConfig);
        if (requiresUnderwriterSlasherRouter) _requireUnderwriterSlasherRouterWiring(deploymentConfig);
        if (deploymentConfig.goalTreasury.budgetStakeLedger() == address(0)) {
            revert IBudgetTCR.BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
        }
        if (initConfig.allocationMechanismAdmin == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();

        _requireValidBudgetSpendPolicy(deploymentConfig.budgetSpendPolicy);
        _requireCompatibleStackDeployer(expectedController, deploymentConfig);

        IBudgetTCR.BudgetValidationBounds calldata budgetBounds = deploymentConfig.budgetValidationBounds;
        IBudgetTCR.OracleValidationBounds calldata oracleBounds = deploymentConfig.oracleValidationBounds;
        if (budgetBounds.maxExecutionDuration < budgetBounds.minExecutionDuration) {
            revert IBudgetTCR.INVALID_BOUNDS();
        }
        if (budgetBounds.maxActivationThreshold < budgetBounds.minActivationThreshold) {
            revert IBudgetTCR.INVALID_BOUNDS();
        }
        if (oracleBounds.liveness == 0 || oracleBounds.bondAmount == 0) {
            revert IBudgetTCR.INVALID_BOUNDS();
        }
    }

    function _requireCompatibleStackDeployer(
        address expectedController,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) private view {
        if (IBudgetStackControllerReader(deploymentConfig.stackDeployer).controller() != expectedController) {
            revert IBudgetTCR.INVALID_STACK_DEPLOYER(deploymentConfig.stackDeployer);
        }

        BudgetStackTypes.StackModuleConfig memory stackModuleConfig = IBudgetStackRuntimeDeployer(
            deploymentConfig.stackDeployer
        ).stackModuleConfig();
        bool requiresPremiumModule = _requiresPremiumModule(deploymentConfig);
        address expectedPremiumEscrowImplementation = requiresPremiumModule
            ? deploymentConfig.riskModuleRouting.premiumEscrowImplementation
            : address(0);
        BudgetStackTypes.StackModuleConfig memory expectedStackConfig = BudgetStackPresetConfigLib.openPreset(
            expectedPremiumEscrowImplementation
        );

        if (
            stackModuleConfig.childFlowStrategyMode != expectedStackConfig.childFlowStrategyMode ||
            stackModuleConfig.childFlowStrategyTarget != expectedStackConfig.childFlowStrategyTarget ||
            stackModuleConfig.mechanismLayerMode != expectedStackConfig.mechanismLayerMode ||
            stackModuleConfig.childFlowRecipientAdmin != expectedStackConfig.childFlowRecipientAdmin ||
            stackModuleConfig.premiumEscrowImplementation != expectedStackConfig.premiumEscrowImplementation
        ) {
            revert IBudgetTCR.STACK_MODULE_CONFIG_MISMATCH();
        }
    }

    function _requiresPremiumModule(IBudgetTCR.DeploymentConfig calldata deploymentConfig) private pure returns (bool) {
        return deploymentConfig.budgetPremiumPpm != 0 || deploymentConfig.budgetSlashPpm != 0;
    }

    function _requiresUnderwriterSlasherRouter(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) private pure returns (bool) {
        return deploymentConfig.budgetSlashPpm != 0;
    }

    function _hasPremiumModuleWiring(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) private pure returns (bool) {
        return deploymentConfig.riskModuleRouting.premiumEscrowImplementation != address(0);
    }

    function _hasUnderwriterSlasherRouterWiring(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) private pure returns (bool) {
        return deploymentConfig.riskModuleRouting.underwriterSlasherRouter != address(0);
    }

    function _requirePremiumModuleConsistency(bool requiresPremiumModule, bool hasPremiumModuleWiring) private pure {
        if (requiresPremiumModule) {
            if (!hasPremiumModuleWiring) revert IBudgetTCR.PREMIUM_MODULE_ABSENCE_REQUIRES_ZERO_RATES();
            return;
        }

        if (hasPremiumModuleWiring) revert IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH();
    }

    function _requireUnderwriterSlasherRouterConsistency(
        bool requiresUnderwriterSlasherRouter,
        bool hasUnderwriterSlasherRouterWiring
    ) private pure {
        if (requiresUnderwriterSlasherRouter) {
            if (!hasUnderwriterSlasherRouterWiring) revert IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED();
            return;
        }

        if (hasUnderwriterSlasherRouterWiring) revert IBudgetTCR.UNDERWRITER_SLASHER_CONFIG_MISMATCH();
    }

    function _requirePremiumEscrowImplementation(IBudgetTCR.DeploymentConfig calldata deploymentConfig) private view {
        address premiumEscrowImplementation = deploymentConfig.riskModuleRouting.premiumEscrowImplementation;
        if (premiumEscrowImplementation == address(0)) {
            revert IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION(address(0));
        }
        if (premiumEscrowImplementation.code.length == 0) {
            revert IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION(premiumEscrowImplementation);
        }
    }

    function _requireUnderwriterSlasherRouterWiring(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) private view {
        address underwriterSlasherRouter_ = deploymentConfig.riskModuleRouting.underwriterSlasherRouter;
        if (underwriterSlasherRouter_ == address(0) || underwriterSlasherRouter_.code.length == 0) {
            revert IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED();
        }
    }

    function _requireValidBudgetSpendPolicy(address candidate) private view {
        if (!SpendPolicyValidationLib.passesValidationProbe(candidate)) {
            revert IBudgetTCR.INVALID_BUDGET_SPEND_POLICY(candidate);
        }
    }

    function _validateBudgetGatePolicy(
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) private view returns (address budgetGatePolicy_) {
        budgetGatePolicy_ = deploymentConfig.riskModuleRouting.budgetGatePolicy;
        if (budgetGatePolicy_ == address(0)) {
            if (deploymentConfig.budgetSlashPpm == 0) return address(0);
            revert IGeneralizedTCR.ADDRESS_ZERO();
        }
        if (budgetGatePolicy_.code.length == 0) {
            revert IBudgetTCR.INVALID_BUDGET_GATE_POLICY(budgetGatePolicy_);
        }

        bool compatible = deploymentConfig.budgetSlashPpm == 0
            ? BudgetGatePolicyHook.supportsZeroCoverageBudgetGatePolicy(IBudgetGatePolicy(budgetGatePolicy_))
            : BudgetGatePolicyHook.supportsBudgetGatePolicy(IBudgetGatePolicy(budgetGatePolicy_));
        if (!compatible) {
            revert IBudgetTCR.INVALID_BUDGET_GATE_POLICY(budgetGatePolicy_);
        }
    }
}
