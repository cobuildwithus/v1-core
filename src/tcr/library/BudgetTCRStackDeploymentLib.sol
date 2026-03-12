// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";

library BudgetTCRStackDeploymentLib {
    error ADDRESS_ZERO();
    error INVALID_TREASURY(address treasury);
    error INVALID_TREASURY_CONFIGURATION(address treasury);

    function deployBudgetTreasury(
        address controller,
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig memory budgetConfig,
        IBudgetStackDeployer.RiskModuleInitConfig memory riskModuleInitConfig
    ) internal returns (address) {
        if (controller == address(0)) revert ADDRESS_ZERO();
        if (budgetTreasury == address(0)) revert ADDRESS_ZERO();
        if (budgetConfig.flow == address(0)) revert ADDRESS_ZERO();
        if (budgetConfig.successResolver == address(0)) revert ADDRESS_ZERO();
        if (budgetConfig.spendPolicy == address(0)) revert ADDRESS_ZERO();
        if (riskModuleInitConfig.goalFlow == address(0)) revert ADDRESS_ZERO();

        if (budgetTreasury.code.length == 0) revert INVALID_TREASURY(budgetTreasury);

        address premiumEscrow = budgetConfig.premiumEscrow;
        BudgetTreasury(budgetTreasury).initialize(controller, budgetConfig);

        _assertTreasuryConfiguration(
            budgetTreasury,
            controller,
            budgetConfig.flow,
            premiumEscrow,
            budgetConfig.spendPolicy
        );
        if (premiumEscrow == address(0)) return budgetTreasury;

        // Concrete escrow implementations decide whether stake-ledger/slasher inputs are mandatory.
        IPremiumEscrow(premiumEscrow).initialize(
            budgetTreasury,
            riskModuleInitConfig.budgetStakeLedger,
            riskModuleInitConfig.goalFlow,
            riskModuleInitConfig.underwriterSlasherRouter,
            riskModuleInitConfig.budgetSlashPpm
        );
        return budgetTreasury;
    }

    function _assertTreasuryConfiguration(
        address budgetTreasury,
        address controller,
        address childFlow,
        address premiumEscrow,
        address spendPolicy
    ) private view {
        address configuredController;
        address configuredFlow;
        address configuredPremiumEscrow;
        address configuredSpendPolicy;

        try IBudgetTreasury(budgetTreasury).controller() returns (address controller_) {
            configuredController = controller_;
        } catch {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }

        try IBudgetTreasury(budgetTreasury).flow() returns (address flow_) {
            configuredFlow = flow_;
        } catch {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }
        try IBudgetTreasury(budgetTreasury).premiumEscrow() returns (address premiumEscrow_) {
            configuredPremiumEscrow = premiumEscrow_;
        } catch {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }
        try IBudgetTreasury(budgetTreasury).spendPolicy() returns (address spendPolicy_) {
            configuredSpendPolicy = spendPolicy_;
        } catch {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }

        if (
            configuredController != controller ||
            configuredFlow != childFlow ||
            configuredPremiumEscrow != premiumEscrow ||
            configuredSpendPolicy != spendPolicy
        ) {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }
    }
}
