// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "./IBudgetTCR.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

interface IBudgetTCRStackDeployer {
    struct PreparationResult {
        address stakeVault;
        address strategy;
        address budgetTreasury;
    }

    error ADDRESS_ZERO();
    error ONLY_BUDGET_TCR();

    function prepareBudgetStack(
        IERC20 goalToken,
        IERC20 cobuildToken,
        IJBRulesets goalRulesets,
        uint256 goalRevnetId,
        uint8 paymentTokenDecimals,
        address budgetStakeLedger,
        bytes32 recipientId
    ) external returns (PreparationResult memory result);

    function deployBudgetTreasury(
        address stakeVault,
        address childFlow,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external returns (address budgetTreasury);

    function registerChildFlowRecipient(bytes32 recipientId, address childFlow) external;
}
