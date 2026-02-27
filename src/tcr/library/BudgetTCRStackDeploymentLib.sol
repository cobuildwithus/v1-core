// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

library BudgetTCRStackDeploymentLib {
    error ADDRESS_ZERO();
    error INVALID_TREASURY(address treasury);
    error INVALID_TREASURY_CONFIGURATION(address treasury);
    error INVALID_STRATEGY(address strategy);

    struct PreparationResult {
        address strategy;
    }

    function prepareBudgetStack(
        address treasuryAnchor,
        IERC20,
        IERC20,
        IJBRulesets,
        uint256,
        uint8,
        address strategy
    ) internal returns (PreparationResult memory result) {
        if (treasuryAnchor == address(0)) revert ADDRESS_ZERO();
        if (strategy == address(0) || strategy.code.length == 0) revert INVALID_STRATEGY(strategy);
        result = PreparationResult({ strategy: strategy });
    }

    function deployBudgetTreasury(
        address budgetTCR,
        address budgetTreasury,
        address childFlow,
        IBudgetTCR.BudgetListing memory listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) internal returns (address) {
        if (budgetTCR == address(0)) revert ADDRESS_ZERO();
        if (budgetTreasury == address(0)) revert ADDRESS_ZERO();
        if (childFlow == address(0)) revert ADDRESS_ZERO();
        if (successResolver == address(0)) revert ADDRESS_ZERO();

        if (budgetTreasury.code.length == 0) revert INVALID_TREASURY(budgetTreasury);

        BudgetTreasury(budgetTreasury).initialize(
            budgetTCR,
            IBudgetTreasury.BudgetConfig({
                flow: childFlow,
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

        _assertTreasuryConfiguration(budgetTreasury, budgetTCR, childFlow);
        return budgetTreasury;
    }

    function _assertTreasuryConfiguration(address budgetTreasury, address budgetTCR, address childFlow) private view {
        address configuredController;
        address configuredFlow;

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

        if (configuredController != budgetTCR || configuredFlow != childFlow) {
            revert INVALID_TREASURY_CONFIGURATION(budgetTreasury);
        }
    }
}
