// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCRDeployer } from "./interfaces/IBudgetTCRDeployer.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IBudgetFlowRouterStrategy } from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import { BudgetFlowRouterStrategy } from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import { IBudgetTCRFactoryDiscoveryEmitter } from "./interfaces/IBudgetTCRFactoryDiscoveryEmitter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";

import { BudgetTCRStackDeploymentLib } from "./library/BudgetTCRStackDeploymentLib.sol";

contract BudgetTCRDeployer is IBudgetTCRDeployer, Initializable {
    address public override budgetTCR;
    address public premiumEscrowImplementation;
    address public discoveryEmitter;
    address public immutable budgetTreasuryImplementation;
    address public immutable override roundFactory;
    address public immutable override allocationMechanismTcrImplementation;
    address public immutable override allocationMechanismArbitratorImplementation;
    address public immutable budgetFlowRouterStrategyImplementation;
    address public sharedBudgetFlowStrategy;
    address public sharedBudgetFlowStrategyLedger;

    error BUDGET_STAKE_LEDGER_MISMATCH(address expectedLedger, address providedLedger);
    error SHARED_BUDGET_STRATEGY_NOT_DEPLOYED();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);

    modifier onlyBudgetTCR() {
        if (msg.sender != budgetTCR) revert ONLY_BUDGET_TCR();
        _;
    }

    constructor(
        address budgetTreasuryImplementation_,
        address roundFactory_,
        address allocationMechanismTcrImplementation_,
        address allocationMechanismArbitratorImplementation_,
        address budgetFlowRouterStrategyImplementation_
    ) {
        _assertImplementationAddress(budgetTreasuryImplementation_);
        _assertImplementationAddress(roundFactory_);
        _assertImplementationAddress(allocationMechanismTcrImplementation_);
        _assertImplementationAddress(allocationMechanismArbitratorImplementation_);
        _assertImplementationAddress(budgetFlowRouterStrategyImplementation_);

        budgetTreasuryImplementation = budgetTreasuryImplementation_;
        roundFactory = roundFactory_;
        allocationMechanismTcrImplementation = allocationMechanismTcrImplementation_;
        allocationMechanismArbitratorImplementation = allocationMechanismArbitratorImplementation_;
        budgetFlowRouterStrategyImplementation = budgetFlowRouterStrategyImplementation_;
        _disableInitializers();
    }

    function initialize(
        address budgetTCR_,
        address premiumEscrowImplementation_,
        address discoveryEmitter_
    ) external initializer {
        _initialize(budgetTCR_, premiumEscrowImplementation_, discoveryEmitter_);
    }

    function _initialize(address budgetTCR_, address premiumEscrowImplementation_, address discoveryEmitter_) internal {
        if (budgetTCR_ == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrowImplementation_ == address(0) || premiumEscrowImplementation_.code.length == 0) {
            revert ADDRESS_ZERO();
        }
        if (discoveryEmitter_ != address(0) && discoveryEmitter_.code.length == 0) revert ADDRESS_ZERO();

        budgetTCR = budgetTCR_;
        premiumEscrowImplementation = premiumEscrowImplementation_;
        discoveryEmitter = discoveryEmitter_;
    }

    function prepareBudgetStack(
        IERC20 goalToken,
        IERC20 cobuildToken,
        IJBRulesets goalRulesets,
        uint256 goalRevnetId,
        uint8 paymentTokenDecimals,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        bytes32
    ) external onlyBudgetTCR returns (PreparationResult memory result) {
        address strategy = sharedBudgetFlowStrategy;
        if (strategy == address(0)) {
            strategy = Clones.clone(budgetFlowRouterStrategyImplementation);
            BudgetFlowRouterStrategy(strategy).initialize(budgetStakeLedger, address(this));
            sharedBudgetFlowStrategy = strategy;
            sharedBudgetFlowStrategyLedger = budgetStakeLedger;
        } else if (sharedBudgetFlowStrategyLedger != budgetStakeLedger) {
            revert BUDGET_STAKE_LEDGER_MISMATCH(sharedBudgetFlowStrategyLedger, budgetStakeLedger);
        }

        address treasuryAnchor = Clones.clone(budgetTreasuryImplementation);
        address premiumEscrow = Clones.clone(premiumEscrowImplementation);
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = BudgetTCRStackDeploymentLib.prepareBudgetStack(
            treasuryAnchor,
            premiumEscrow,
            goalToken,
            cobuildToken,
            goalRulesets,
            goalRevnetId,
            paymentTokenDecimals,
            strategy,
            budgetStakeLedger,
            goalFlow,
            underwriterSlasherRouter,
            budgetSlashPpm
        );

        result = PreparationResult({
            strategy: prepared.strategy,
            budgetTreasury: treasuryAnchor,
            premiumEscrow: prepared.premiumEscrow
        });
    }

    function deployBudgetTreasury(
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external onlyBudgetTCR returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            budgetTCR,
            budgetTreasury,
            premiumEscrow,
            childFlow,
            budgetStakeLedger,
            goalFlow,
            underwriterSlasherRouter,
            budgetSlashPpm,
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

    function emitBudgetStackDeployed(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    ) external onlyBudgetTCR {
        address emitter = discoveryEmitter;
        if (emitter == address(0)) return;
        IBudgetTCRFactoryDiscoveryEmitter(emitter).onBudgetStackDeployed(
            itemID,
            childFlow,
            budgetTreasury,
            premiumEscrow,
            strategy
        );
    }

    function emitBudgetAllocationMechanismDeployed(
        bytes32 itemID,
        address allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory_
    ) external onlyBudgetTCR {
        address emitter = discoveryEmitter;
        if (emitter == address(0)) return;
        IBudgetTCRFactoryDiscoveryEmitter(emitter).onBudgetAllocationMechanismDeployed(
            itemID,
            allocationMechanism,
            allocationMechanismArbitrator,
            roundFactory_
        );
    }

    function _assertImplementationAddress(address implementation) internal view {
        if (implementation == address(0)) revert ADDRESS_ZERO();
        if (implementation.code.length == 0) revert IMPLEMENTATION_HAS_NO_CODE(implementation);
    }
}
