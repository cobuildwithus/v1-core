// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

library BudgetTCRStackDeploymentLib {
    error ADDRESS_ZERO();
    error INVALID_TREASURY(address treasury);
    error INVALID_TREASURY_CONFIGURATION(address treasury);
    error INVALID_STRATEGY(address strategy);
    error INVALID_PREMIUM_ESCROW(address premiumEscrow);

    struct PreparationResult {
        address strategy;
        address premiumEscrow;
    }

    function prepareBudgetStack(
        address treasuryAnchor,
        address premiumEscrow,
        IERC20,
        IERC20,
        IJBRulesets,
        uint256,
        uint8,
        address strategy,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32
    ) internal view returns (PreparationResult memory result) {
        if (treasuryAnchor == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrow == address(0)) revert ADDRESS_ZERO();
        if (strategy == address(0) || strategy.code.length == 0) revert INVALID_STRATEGY(strategy);
        if (premiumEscrow.code.length == 0) revert INVALID_PREMIUM_ESCROW(premiumEscrow);
        if (budgetStakeLedger == address(0)) revert ADDRESS_ZERO();
        if (goalFlow == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouter == address(0)) revert ADDRESS_ZERO();

        result = PreparationResult({ strategy: strategy, premiumEscrow: premiumEscrow });
    }

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
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) internal returns (address) {
        if (budgetTCR == address(0)) revert ADDRESS_ZERO();
        if (budgetTreasury == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrow == address(0)) revert ADDRESS_ZERO();
        if (childFlow == address(0)) revert ADDRESS_ZERO();
        if (budgetStakeLedger == address(0)) revert ADDRESS_ZERO();
        if (goalFlow == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouter == address(0)) revert ADDRESS_ZERO();
        if (successResolver == address(0)) revert ADDRESS_ZERO();

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
                successAssertionPolicyHash: listing.oracleConfig.assertionPolicyHash
            })
        );

        _assertTreasuryConfiguration(budgetTreasury, budgetTCR, childFlow, premiumEscrow);
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
        address premiumEscrow
    ) private view {
        address configuredController;
        address configuredFlow;
        address configuredPremiumEscrow;

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

        if (
            configuredController != budgetTCR || configuredFlow != childFlow || configuredPremiumEscrow != premiumEscrow
        ) {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }
    }
}
