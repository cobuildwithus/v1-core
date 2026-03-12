// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";

library BudgetTCRStackDeploymentLib {
    error ADDRESS_ZERO();
    error INVALID_TREASURY(address treasury);
    error INVALID_TREASURY_CONFIGURATION(address treasury);

    function deployBudgetTreasury(
        address budgetTCR,
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        IBudgetTCR.BudgetListing memory listing,
        address successResolver,
        address spendPolicy,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) internal returns (address) {
        if (budgetTCR == address(0)) revert ADDRESS_ZERO();
        if (budgetTreasury == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrow == address(0)) revert ADDRESS_ZERO();
        if (childFlow == address(0)) revert ADDRESS_ZERO();
        if (goalFlow == address(0)) revert ADDRESS_ZERO();
        if (successResolver == address(0)) revert ADDRESS_ZERO();
        if (spendPolicy == address(0)) revert ADDRESS_ZERO();

        if (budgetTreasury.code.length == 0) revert INVALID_TREASURY(budgetTreasury);

        BudgetTreasury(budgetTreasury).initialize(
            budgetTCR,
            IBudgetTreasury.BudgetConfig({
                flow: childFlow,
                premiumEscrow: premiumEscrow,
                fundingDeadline: listing.fundingDeadline,
                executionDuration: listing.executionDuration,
                activationThreshold: listing.activationThreshold,
                runwayCap: listing.runwayCap,
                successResolver: successResolver,
                successAssertionLiveness: successAssertionLiveness,
                successAssertionBond: successAssertionBond,
                successOracleSpecHash: listing.oracleConfig.oracleSpecHash,
                successAssertionPolicyHash: listing.oracleConfig.assertionPolicyHash,
                spendPolicy: spendPolicy
            })
        );

        _assertTreasuryConfiguration(budgetTreasury, budgetTCR, childFlow, premiumEscrow, spendPolicy);
        // Concrete escrow implementations decide whether stake-ledger/slasher inputs are mandatory.
        IPremiumEscrow(premiumEscrow).initialize(
            budgetTreasury,
            budgetStakeLedger,
            goalFlow,
            underwriterSlasherRouter,
            budgetSlashPpm
        );
        return budgetTreasury;
    }

    function _assertTreasuryConfiguration(
        address budgetTreasury,
        address budgetTCR,
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
            configuredController != budgetTCR ||
            configuredFlow != childFlow ||
            configuredPremiumEscrow != premiumEscrow ||
            configuredSpendPolicy != spendPolicy
        ) {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }
    }
}
