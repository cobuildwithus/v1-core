// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCRDeployer } from "./interfaces/IBudgetTCRDeployer.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";

import { BudgetTCRStackDeploymentLib } from "./library/BudgetTCRStackDeploymentLib.sol";

contract BudgetTCRDeployer is IBudgetTCRDeployer {
    address public override budgetTCR;
    address public immutable stackComponentDeployer;
    address public immutable budgetTreasuryImplementation;

    modifier onlyBudgetTCR() {
        if (msg.sender != budgetTCR) revert ONLY_BUDGET_TCR();
        _;
    }

    constructor(address stackComponentDeployer_) {
        if (stackComponentDeployer_ == address(0)) revert ADDRESS_ZERO();

        stackComponentDeployer = stackComponentDeployer_;
        budgetTreasuryImplementation = address(new BudgetTreasury());
    }

    function initialize(address budgetTCR_) external {
        if (budgetTCR_ == address(0)) revert ADDRESS_ZERO();
        if (budgetTCR != address(0)) revert ALREADY_INITIALIZED();

        budgetTCR = budgetTCR_;
    }

    function prepareBudgetStack(
        IERC20 goalToken,
        IERC20 cobuildToken,
        IJBRulesets goalRulesets,
        uint256 goalRevnetId,
        uint8 paymentTokenDecimals,
        address budgetStakeLedger,
        bytes32 recipientId
    ) external onlyBudgetTCR returns (PreparationResult memory result) {
        address treasuryAnchor = Clones.clone(budgetTreasuryImplementation);
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = BudgetTCRStackDeploymentLib.prepareBudgetStack(
            treasuryAnchor,
            goalToken,
            cobuildToken,
            goalRulesets,
            goalRevnetId,
            paymentTokenDecimals,
            stackComponentDeployer,
            budgetStakeLedger,
            recipientId
        );

        result = PreparationResult({
            stakeVault: prepared.stakeVault,
            strategy: prepared.strategy,
            budgetTreasury: treasuryAnchor
        });
    }

    function deployBudgetTreasury(
        address stakeVault,
        address childFlow,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external onlyBudgetTCR returns (address budgetTreasury) {
        budgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            budgetTCR,
            stakeVault,
            childFlow,
            listing,
            successResolver,
            successAssertionLiveness,
            successAssertionBond
        );
    }
}
