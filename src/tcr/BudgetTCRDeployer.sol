// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCRDeployer } from "./interfaces/IBudgetTCRDeployer.sol";
import { IBudgetTCR } from "./interfaces/IBudgetTCR.sol";
import { IBudgetTCRChildFlowStrategyFactory } from "./interfaces/IBudgetTCRChildFlowStrategyFactory.sol";
import { IBudgetFlowRouterStrategy } from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import { BudgetFlowRouterStrategy } from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import { IBudgetTCRFactoryDiscoveryEmitter } from "./interfaces/IBudgetTCRFactoryDiscoveryEmitter.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";

import { BudgetTCRStackDeploymentLib } from "./library/BudgetTCRStackDeploymentLib.sol";

contract BudgetTCRDeployer is IBudgetTCRDeployer, Initializable {
    address public override budgetTCR;
    address public premiumEscrowImplementation;
    address public discoveryEmitter;
    ChildFlowStrategyMode public childFlowStrategyMode;
    address public childFlowStrategyTarget;
    MechanismLayerMode public mechanismLayerMode;
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

    modifier onlyBudgetTCR() {
        if (msg.sender != budgetTCR) revert ONLY_BUDGET_TCR();
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

    function initialize(
        address budgetTCR_,
        address premiumEscrowImplementation_,
        address discoveryEmitter_
    ) external initializer {
        _initializeOpenPreset(budgetTCR_, premiumEscrowImplementation_, discoveryEmitter_);
    }

    function initializeWithConfig(
        address budgetTCR_,
        StackModuleConfig calldata stackModuleConfig_,
        address discoveryEmitter_
    ) external initializer {
        _initializeWithConfig(budgetTCR_, stackModuleConfig_, discoveryEmitter_);
    }

    function _initializeOpenPreset(
        address budgetTCR_,
        address premiumEscrowImplementation_,
        address discoveryEmitter_
    ) internal {
        _initializeWithConfig(
            budgetTCR_,
            StackModuleConfig({
                childFlowStrategyMode: ChildFlowStrategyMode.SharedBudgetFlowRouter,
                childFlowStrategyTarget: address(0),
                mechanismLayerMode: MechanismLayerMode.AllocationMechanismTCR,
                childFlowRecipientAdmin: address(0),
                premiumEscrowImplementation: premiumEscrowImplementation_
            }),
            discoveryEmitter_
        );
    }

    function _initializeWithConfig(
        address budgetTCR_,
        StackModuleConfig memory stackModuleConfig_,
        address discoveryEmitter_
    ) internal {
        if (budgetTCR_ == address(0)) revert ADDRESS_ZERO();
        if (discoveryEmitter_ != address(0) && discoveryEmitter_.code.length == 0) revert ADDRESS_ZERO();
        _validateStackModuleConfig(stackModuleConfig_);

        budgetTCR = budgetTCR_;
        premiumEscrowImplementation = stackModuleConfig_.premiumEscrowImplementation;
        discoveryEmitter = discoveryEmitter_;
        childFlowStrategyMode = stackModuleConfig_.childFlowStrategyMode;
        childFlowStrategyTarget = stackModuleConfig_.childFlowStrategyTarget;
        mechanismLayerMode = stackModuleConfig_.mechanismLayerMode;
        childFlowRecipientAdmin = stackModuleConfig_.childFlowRecipientAdmin;
    }

    function prepareBudgetStack(
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter
    ) external onlyBudgetTCR returns (PreparationResult memory result) {
        if (budgetStakeLedger == address(0)) revert ADDRESS_ZERO();
        if (goalFlow == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouter == address(0)) revert ADDRESS_ZERO();

        address strategy = _prepareChildFlowStrategy(budgetStakeLedger, goalFlow);
        address treasuryAnchor = Clones.clone(budgetTreasuryImplementation);
        address premiumEscrow = Clones.clone(premiumEscrowImplementation);
        (address allocationMechanism, address recipientAdmin) = _prepareMechanismLayer();
        result = PreparationResult({
            strategy: strategy,
            budgetTreasury: treasuryAnchor,
            premiumEscrow: premiumEscrow,
            childFlowRecipientAdmin: recipientAdmin,
            allocationMechanism: allocationMechanism
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
        address spendPolicy,
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
            spendPolicy,
            successAssertionLiveness,
            successAssertionBond
        );
    }

    function registerChildFlowRecipient(bytes32 recipientId, address childFlow) external onlyBudgetTCR {
        if (childFlowStrategyMode != ChildFlowStrategyMode.SharedBudgetFlowRouter) return;
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

    function stackModuleConfig() external view returns (StackModuleConfig memory config) {
        config = StackModuleConfig({
            childFlowStrategyMode: childFlowStrategyMode,
            childFlowStrategyTarget: childFlowStrategyTarget,
            mechanismLayerMode: mechanismLayerMode,
            childFlowRecipientAdmin: childFlowRecipientAdmin,
            premiumEscrowImplementation: premiumEscrowImplementation
        });
    }

    function initialMechanismFactories() external view override returns (address[] memory factories) {
        if (mechanismLayerMode == MechanismLayerMode.None) {
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

    function sharedBudgetFlowStrategyLedger() external view returns (address ledger) {
        ledger = _sharedBudgetFlowStrategyLedger(sharedBudgetFlowStrategy);
    }

    function _validateStackModuleConfig(StackModuleConfig memory stackModuleConfig_) internal view {
        if (
            stackModuleConfig_.premiumEscrowImplementation == address(0) ||
            stackModuleConfig_.premiumEscrowImplementation.code.length == 0
        ) {
            revert ADDRESS_ZERO();
        }

        if (stackModuleConfig_.childFlowStrategyMode == ChildFlowStrategyMode.SharedBudgetFlowRouter) {
            if (stackModuleConfig_.childFlowStrategyTarget != address(0)) revert INVALID_STACK_MODULE_CONFIG();
        } else {
            _assertImplementationAddress(stackModuleConfig_.childFlowStrategyTarget);
        }

        if (stackModuleConfig_.mechanismLayerMode == MechanismLayerMode.AllocationMechanismTCR) {
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
        address budgetStakeLedger,
        address goalFlow
    ) internal returns (address strategy) {
        ChildFlowStrategyMode strategyMode = childFlowStrategyMode;
        address strategyTarget = childFlowStrategyTarget;

        if (strategyMode == ChildFlowStrategyMode.SharedBudgetFlowRouter) {
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

        if (strategyMode == ChildFlowStrategyMode.Fixed) {
            return strategyTarget;
        }

        strategy = IBudgetTCRChildFlowStrategyFactory(strategyTarget).prepareChildFlowStrategy(
            budgetStakeLedger,
            goalFlow,
            address(this)
        );
        if (strategy == address(0) || strategy.code.length == 0) revert INVALID_CHILD_FLOW_STRATEGY(strategy);
    }

    function _prepareMechanismLayer() internal returns (address allocationMechanism, address recipientAdmin) {
        recipientAdmin = childFlowRecipientAdmin;
        if (mechanismLayerMode != MechanismLayerMode.AllocationMechanismTCR) {
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
