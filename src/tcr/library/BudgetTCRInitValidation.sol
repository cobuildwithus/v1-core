// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { SpendPolicyValidationLib } from "src/library/SpendPolicyValidationLib.sol";

library BudgetTCRInitValidation {
    function validateInitialization(
        IBudgetTCR.InitConfig calldata initConfig,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) external view returns (address budgetGatePolicy_) {
        if (deploymentConfig.stackDeployer == address(0)) {
            revert IGeneralizedTCR.ADDRESS_ZERO();
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

        bool explicitNoPremiumMode = deploymentConfig.riskModuleRouting.requireZeroPremiumAndSlashRates;
        bool requiresPremiumModule = _requiresPremiumModule(deploymentConfig);
        budgetGatePolicy_ = _validateBudgetGatePolicy(deploymentConfig);
        if (explicitNoPremiumMode) {
            if (requiresPremiumModule) revert IBudgetTCR.PREMIUM_MODULE_ABSENCE_REQUIRES_ZERO_RATES();
            _requireAbsentPremiumModuleWiring(deploymentConfig);
        } else {
            if (!requiresPremiumModule) revert IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH();
            _requirePremiumModuleWiring(deploymentConfig);
        }
        if (deploymentConfig.goalTreasury.budgetStakeLedger() == address(0)) {
            revert IBudgetTCR.BUDGET_STAKE_LEDGER_NOT_CONFIGURED();
        }
        if (initConfig.allocationMechanismAdmin == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();

        _requireValidBudgetSpendPolicy(deploymentConfig.budgetSpendPolicy);

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

    function validateStackModuleCompatibility(IBudgetTCR.DeploymentConfig calldata deploymentConfig) external view {
        IBudgetStackDeployer.StackModuleConfig memory stackModuleConfig = IBudgetStackDeployer(
            deploymentConfig.stackDeployer
        ).stackModuleConfig();
        bool explicitNoPremiumMode = deploymentConfig.riskModuleRouting.requireZeroPremiumAndSlashRates;
        bool requiresPremiumModule = _requiresPremiumModule(deploymentConfig);
        bool stackRequiresZeroRates = stackModuleConfig.premiumEscrowMode ==
            IBudgetStackDeployer.PremiumEscrowMode.None;
        if (explicitNoPremiumMode) {
            if (requiresPremiumModule) revert IBudgetTCR.PREMIUM_MODULE_ABSENCE_REQUIRES_ZERO_RATES();
            if (!stackRequiresZeroRates) revert IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH();
            return;
        }

        if (stackRequiresZeroRates) revert IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH();
    }

    function _requiresPremiumModule(IBudgetTCR.DeploymentConfig calldata deploymentConfig) private pure returns (bool) {
        return deploymentConfig.budgetPremiumPpm != 0 || deploymentConfig.budgetSlashPpm != 0;
    }

    function _requireAbsentPremiumModuleWiring(IBudgetTCR.DeploymentConfig calldata deploymentConfig) private pure {
        if (deploymentConfig.riskModuleRouting.premiumEscrowImplementation != address(0)) {
            revert IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH();
        }
        if (deploymentConfig.riskModuleRouting.underwriterSlasherRouter != address(0)) {
            revert IBudgetTCR.PREMIUM_MODULE_CONFIG_MISMATCH();
        }
    }

    function _requirePremiumModuleWiring(IBudgetTCR.DeploymentConfig calldata deploymentConfig) private view {
        address premiumEscrowImplementation = deploymentConfig.riskModuleRouting.premiumEscrowImplementation;
        if (premiumEscrowImplementation == address(0)) {
            revert IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION(address(0));
        }
        if (premiumEscrowImplementation.code.length == 0) {
            revert IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION(premiumEscrowImplementation);
        }

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
