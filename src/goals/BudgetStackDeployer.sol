// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { BudgetStackTypes } from "src/interfaces/BudgetStackTypes.sol";
import { IBudgetStackDeployer } from "src/interfaces/IBudgetStackDeployer.sol";
import { IBudgetStackChildFlowStrategyFactory } from "src/interfaces/IBudgetStackChildFlowStrategyFactory.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetFlowRouterStrategy } from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import { BudgetFlowRouterStrategy } from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { BudgetStackDeploymentLib } from "src/goals/library/BudgetStackDeploymentLib.sol";

contract BudgetStackDeployer is IBudgetStackDeployer, Initializable {
    address public override controller;
    address private _premiumEscrowImplementation;
    BudgetStackTypes.ChildFlowStrategyMode public childFlowStrategyMode;
    address public childFlowStrategyTarget;
    BudgetStackTypes.MechanismLayerMode public mechanismLayerMode;
    address public childFlowRecipientAdmin;
    address public immutable budgetTreasuryImplementation;
    address public immutable override roundFactory;
    address public immutable teamFlowFactory;
    address public immutable override allocationMechanismTcrImplementation;
    address public immutable override allocationMechanismArbitratorImplementation;
    address public immutable budgetFlowRouterStrategyImplementation;
    address public sharedBudgetFlowStrategy;

    error BUDGET_STAKE_LEDGER_MISMATCH(address expectedLedger, address providedLedger);
    error SHARED_BUDGET_STRATEGY_NOT_DEPLOYED();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error INVALID_STACK_MODULE_CONFIG();
    error INVALID_CHILD_FLOW_STRATEGY(address strategy);

    modifier onlyController() {
        if (msg.sender != controller) revert ONLY_CONTROLLER();
        _;
    }

    constructor(
        address budgetTreasuryImplementation_,
        address roundFactory_,
        address teamFlowFactory_,
        address allocationMechanismTcrImplementation_,
        address allocationMechanismArbitratorImplementation_,
        address budgetFlowRouterStrategyImplementation_
    ) {
        _assertImplementationAddress(budgetTreasuryImplementation_);
        _assertImplementationAddress(roundFactory_);
        _assertImplementationAddress(teamFlowFactory_);
        _assertImplementationAddress(allocationMechanismTcrImplementation_);
        _assertImplementationAddress(allocationMechanismArbitratorImplementation_);
        _assertImplementationAddress(budgetFlowRouterStrategyImplementation_);

        budgetTreasuryImplementation = budgetTreasuryImplementation_;
        roundFactory = roundFactory_;
        teamFlowFactory = teamFlowFactory_;
        allocationMechanismTcrImplementation = allocationMechanismTcrImplementation_;
        allocationMechanismArbitratorImplementation = allocationMechanismArbitratorImplementation_;
        budgetFlowRouterStrategyImplementation = budgetFlowRouterStrategyImplementation_;
        _disableInitializers();
    }

    function initializeWithConfig(
        address controller_,
        BudgetStackTypes.StackModuleConfig calldata stackModuleConfig_
    ) external initializer {
        _initializeWithConfig(controller_, stackModuleConfig_);
    }

    function _initializeWithConfig(
        address controller_,
        BudgetStackTypes.StackModuleConfig memory stackModuleConfig_
    ) internal {
        if (controller_ == address(0)) revert ADDRESS_ZERO();
        _validateStackModuleConfig(stackModuleConfig_);

        controller = controller_;
        _premiumEscrowImplementation = stackModuleConfig_.premiumEscrowImplementation;
        childFlowStrategyMode = stackModuleConfig_.childFlowStrategyMode;
        childFlowStrategyTarget = stackModuleConfig_.childFlowStrategyTarget;
        mechanismLayerMode = stackModuleConfig_.mechanismLayerMode;
        childFlowRecipientAdmin = stackModuleConfig_.childFlowRecipientAdmin;
    }

    function prepareBudgetStack(
        address budgetStakeLedger,
        address goalFlow
    ) external onlyController returns (BudgetStackTypes.PreparationResult memory result) {
        if (budgetStakeLedger == address(0)) revert ADDRESS_ZERO();
        if (goalFlow == address(0)) revert ADDRESS_ZERO();
        address treasuryAnchor = Clones.clone(budgetTreasuryImplementation);
        address strategy = _prepareChildFlowStrategy(treasuryAnchor, budgetStakeLedger, goalFlow);
        address premiumEscrow = _preparePremiumEscrow();
        (address allocationMechanism, address recipientAdmin) = _prepareMechanismLayer();
        result = BudgetStackTypes.PreparationResult({
            strategy: strategy,
            budgetTreasury: treasuryAnchor,
            premiumEscrow: premiumEscrow,
            childFlowRecipientAdmin: recipientAdmin,
            allocationMechanism: allocationMechanism
        });
    }

    function deployBudgetTreasury(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig
    ) external onlyController returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury = BudgetStackDeploymentLib.deployBudgetTreasury(
            controller,
            budgetTreasury,
            budgetConfig
        );
    }

    function deployBudgetTreasuryWithRiskModule(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig,
        BudgetStackTypes.RiskModuleInitConfig calldata riskModuleInitConfig
    ) external onlyController returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury = BudgetStackDeploymentLib.deployBudgetTreasuryWithRiskModule(
            controller,
            budgetTreasury,
            budgetConfig,
            riskModuleInitConfig
        );
    }

    function registerChildFlowRecipient(bytes32 recipientId, address childFlow) external onlyController {
        if (childFlowStrategyMode != BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter) return;
        address strategy = sharedBudgetFlowStrategy;
        if (strategy == address(0)) revert SHARED_BUDGET_STRATEGY_NOT_DEPLOYED();
        IBudgetFlowRouterStrategy(strategy).registerFlowRecipient(childFlow, recipientId);
    }

    function stackModuleConfig() external view returns (BudgetStackTypes.StackModuleConfig memory config) {
        config = BudgetStackTypes.StackModuleConfig({
            childFlowStrategyMode: childFlowStrategyMode,
            childFlowStrategyTarget: childFlowStrategyTarget,
            mechanismLayerMode: mechanismLayerMode,
            childFlowRecipientAdmin: childFlowRecipientAdmin,
            premiumEscrowImplementation: _premiumEscrowImplementation
        });
    }

    function initialMechanismFactories() external view override returns (address[] memory factories) {
        if (mechanismLayerMode == BudgetStackTypes.MechanismLayerMode.None) {
            return new address[](0);
        }

        address roundFactory_ = roundFactory;
        address teamFlowFactory_ = teamFlowFactory;

        if (teamFlowFactory_ == roundFactory_) {
            factories = new address[](1);
            factories[0] = roundFactory_;
            return factories;
        }

        factories = new address[](2);
        factories[0] = roundFactory_;
        factories[1] = teamFlowFactory_;
    }

    function _validateStackModuleConfig(BudgetStackTypes.StackModuleConfig memory stackModuleConfig_) internal view {
        if (stackModuleConfig_.premiumEscrowImplementation != address(0)) {
            _assertImplementationAddress(stackModuleConfig_.premiumEscrowImplementation);
        }

        if (stackModuleConfig_.childFlowStrategyMode == BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter) {
            if (stackModuleConfig_.childFlowStrategyTarget != address(0)) revert INVALID_STACK_MODULE_CONFIG();
        } else {
            _assertImplementationAddress(stackModuleConfig_.childFlowStrategyTarget);
        }

        if (stackModuleConfig_.mechanismLayerMode == BudgetStackTypes.MechanismLayerMode.AllocationMechanismTCR) {
            if (stackModuleConfig_.childFlowRecipientAdmin != address(0)) revert INVALID_STACK_MODULE_CONFIG();
            return;
        }

        if (stackModuleConfig_.childFlowRecipientAdmin == address(0)) revert INVALID_STACK_MODULE_CONFIG();
    }

    function _assertImplementationAddress(address implementation) internal view {
        if (implementation == address(0)) revert ADDRESS_ZERO();
        if (implementation.code.length == 0) revert IMPLEMENTATION_HAS_NO_CODE(implementation);
    }

    function _prepareChildFlowStrategy(
        address budgetTreasury,
        address budgetStakeLedger,
        address goalFlow
    ) internal returns (address strategy) {
        BudgetStackTypes.ChildFlowStrategyMode strategyMode = childFlowStrategyMode;
        address strategyTarget = childFlowStrategyTarget;

        if (strategyMode == BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter) {
            strategy = sharedBudgetFlowStrategy;
            if (strategy == address(0)) {
                strategy = Clones.clone(budgetFlowRouterStrategyImplementation);
                BudgetFlowRouterStrategy(strategy).initialize(budgetStakeLedger, address(this));
                sharedBudgetFlowStrategy = strategy;
            } else {
                address strategyLedger = _sharedBudgetFlowStrategyLedger(strategy);
                if (strategyLedger != budgetStakeLedger) {
                    revert BUDGET_STAKE_LEDGER_MISMATCH(strategyLedger, budgetStakeLedger);
                }
            }
            return strategy;
        }

        strategy = IBudgetStackChildFlowStrategyFactory(strategyTarget).prepareChildFlowStrategy(
            budgetTreasury,
            budgetStakeLedger,
            goalFlow,
            address(this)
        );
        if (strategy == address(0) || strategy.code.length == 0) revert INVALID_CHILD_FLOW_STRATEGY(strategy);
    }

    function _preparePremiumEscrow() internal returns (address premiumEscrow) {
        address implementation = _premiumEscrowImplementation;
        if (implementation == address(0)) {
            return address(0);
        }

        premiumEscrow = Clones.clone(implementation);
    }

    function _prepareMechanismLayer() internal returns (address allocationMechanism, address recipientAdmin) {
        recipientAdmin = childFlowRecipientAdmin;
        if (mechanismLayerMode != BudgetStackTypes.MechanismLayerMode.AllocationMechanismTCR) {
            return (address(0), recipientAdmin);
        }

        allocationMechanism = Clones.clone(allocationMechanismTcrImplementation);
        recipientAdmin = allocationMechanism;
    }

    function _sharedBudgetFlowStrategyLedger(address strategy) internal view returns (address ledger) {
        if (strategy == address(0)) return address(0);

        ledger = address(IBudgetFlowRouterStrategy(strategy).budgetStakeLedger());
    }
}
