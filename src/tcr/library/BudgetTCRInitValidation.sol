// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { ISpendPolicy } from "src/interfaces/ISpendPolicy.sol";
import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { BudgetGatePolicyHook } from "src/goals/policies/library/BudgetGatePolicyHook.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";

library BudgetTCRInitValidation {
    function validateInitialization(
        IBudgetTCR.InitConfig calldata initConfig,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig
    ) external view returns (address budgetGatePolicy_) {
        if (deploymentConfig.stackDeployer == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.budgetSuccessResolver == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.budgetSpendPolicy == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.budgetGatePolicy == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalFlow) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalTreasury) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalToken) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.cobuildToken) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (address(deploymentConfig.goalRulesets) == address(0)) revert IGeneralizedTCR.ADDRESS_ZERO();
        if (deploymentConfig.budgetSpendPolicy.code.length == 0) {
            revert IBudgetTCR.NOT_A_CONTRACT(deploymentConfig.budgetSpendPolicy);
        }

        budgetGatePolicy_ = deploymentConfig.budgetGatePolicy;
        if (budgetGatePolicy_.code.length == 0) {
            revert IBudgetTCR.INVALID_BUDGET_GATE_POLICY(budgetGatePolicy_);
        }
        if (!BudgetGatePolicyHook.supportsBudgetGatePolicy(IBudgetGatePolicy(budgetGatePolicy_))) {
            revert IBudgetTCR.INVALID_BUDGET_GATE_POLICY(budgetGatePolicy_);
        }

        if (deploymentConfig.premiumEscrowImplementation == address(0)) {
            revert IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION(address(0));
        }
        if (deploymentConfig.premiumEscrowImplementation.code.length == 0) {
            revert IBudgetTCR.INVALID_PREMIUM_ESCROW_IMPLEMENTATION(deploymentConfig.premiumEscrowImplementation);
        }
        address underwriterSlasherRouter_ = deploymentConfig.underwriterSlasherRouter;
        if (underwriterSlasherRouter_ == address(0) || underwriterSlasherRouter_.code.length == 0) {
            revert IBudgetTCR.UNDERWRITER_SLASHER_NOT_CONFIGURED();
        }
        if (deploymentConfig.budgetPremiumPpm > FlowProtocolConstants.PPM_SCALE) {
            revert IBudgetTCR.INVALID_PPM(deploymentConfig.budgetPremiumPpm);
        }
        if (deploymentConfig.budgetSlashPpm > FlowProtocolConstants.PPM_SCALE) {
            revert IBudgetTCR.INVALID_PPM(deploymentConfig.budgetSlashPpm);
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

    function _requireValidBudgetSpendPolicy(address candidate) private view {
        try ISpendPolicy(candidate).syncMode() returns (ISpendPolicy.SyncMode mode) {
            if (uint8(mode) > uint8(ISpendPolicy.SyncMode.LinearSpendDownFallback)) {
                revert IBudgetTCR.INVALID_BUDGET_SPEND_POLICY(candidate);
            }
        } catch {
            revert IBudgetTCR.INVALID_BUDGET_SPEND_POLICY(candidate);
        }

        try ISpendPolicy(candidate).targetFlowRate(_spendPolicyValidationContext()) returns (int96) {} catch {
            revert IBudgetTCR.INVALID_BUDGET_SPEND_POLICY(candidate);
        }
    }

    function _spendPolicyValidationContext() private view returns (ISpendPolicy.SpendContext memory ctx) {
        uint64 nowTs = uint64(block.timestamp);
        ctx = ISpendPolicy.SpendContext({
            nowTs: nowTs,
            activatedAt: nowTs,
            deadline: nowTs + 1,
            treasuryBalance: 1,
            timeRemaining: 1,
            incomingRate: 0,
            currentOutflowRate: 0
        });
    }
}
