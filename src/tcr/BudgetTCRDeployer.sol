// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCRDeployer } from "./interfaces/IBudgetTCRDeployer.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IBudgetFlowRouterStrategy } from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { BudgetFlowRouterStrategy } from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";

import { BudgetTCRStackDeploymentLib } from "./library/BudgetTCRStackDeploymentLib.sol";

contract BudgetTCRDeployer is IBudgetTCRDeployer {
    address public override budgetTCR;
    address public immutable budgetTreasuryImplementation;
    address public immutable override roundFactory;
    address public immutable override allocationMechanismTcrImplementation;
    address public immutable override allocationMechanismArbitratorImplementation;
    address public sharedBudgetFlowStrategy;
    address public sharedBudgetFlowStrategyLedger;

    error BUDGET_STAKE_LEDGER_MISMATCH(address expectedLedger, address providedLedger);
    error SHARED_BUDGET_STRATEGY_NOT_DEPLOYED();

    modifier onlyBudgetTCR() {
        if (msg.sender != budgetTCR) revert ONLY_BUDGET_TCR();
        _;
    }

    constructor() {
        budgetTreasuryImplementation = address(new BudgetTreasury());
        roundFactory = address(new RoundFactory());
        allocationMechanismTcrImplementation = address(new AllocationMechanismTCR());
        allocationMechanismArbitratorImplementation = address(new ERC20VotesArbitrator());
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
        bytes32
    ) external onlyBudgetTCR returns (PreparationResult memory result) {
        address strategy = sharedBudgetFlowStrategy;
        if (strategy == address(0)) {
            strategy = address(new BudgetFlowRouterStrategy(IBudgetStakeLedger(budgetStakeLedger), address(this)));
            sharedBudgetFlowStrategy = strategy;
            sharedBudgetFlowStrategyLedger = budgetStakeLedger;
        } else if (sharedBudgetFlowStrategyLedger != budgetStakeLedger) {
            revert BUDGET_STAKE_LEDGER_MISMATCH(sharedBudgetFlowStrategyLedger, budgetStakeLedger);
        }

        address treasuryAnchor = Clones.clone(budgetTreasuryImplementation);
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = BudgetTCRStackDeploymentLib.prepareBudgetStack(
            treasuryAnchor,
            goalToken,
            cobuildToken,
            goalRulesets,
            goalRevnetId,
            paymentTokenDecimals,
            strategy
        );

        result = PreparationResult({ strategy: prepared.strategy, budgetTreasury: treasuryAnchor });
    }

    function deployBudgetTreasury(
        address budgetTreasury,
        address childFlow,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external onlyBudgetTCR returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            budgetTCR,
            budgetTreasury,
            childFlow,
            listing,
            successResolver,
            successAssertionLiveness,
            successAssertionBond
        );
    }

    function registerChildFlowRecipient(bytes32 recipientId, address childFlow) external onlyBudgetTCR {
        address strategy = sharedBudgetFlowStrategy;
        if (strategy == address(0)) revert SHARED_BUDGET_STRATEGY_NOT_DEPLOYED();
        IBudgetFlowRouterStrategy(strategy).registerFlowRecipient(childFlow, recipientId);
    }
}
