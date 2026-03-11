// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { BudgetSingleAllocatorStrategy } from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import { IManagedBudgetController } from "src/interfaces/IManagedBudgetController.sol";
import { IManagedBudgetControllerStackDeployer } from "src/interfaces/IManagedBudgetControllerStackDeployer.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { BudgetTCRStackDeploymentLib } from "src/tcr/library/BudgetTCRStackDeploymentLib.sol";

/// @notice Managed budget-stack deployer that keeps managed preset wiring off the open BudgetTCR path.
contract ManagedBudgetControllerStackDeployer is IManagedBudgetControllerStackDeployer {
    error NOT_A_CONTRACT(address account);
    error ONLY_CONTROLLER(address expected, address caller);

    address public immutable budgetTreasuryImplementation;
    address public immutable premiumEscrowImplementation;

    constructor(address budgetTreasuryImplementation_, address premiumEscrowImplementation_) {
        if (budgetTreasuryImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (premiumEscrowImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (budgetTreasuryImplementation_.code.length == 0) revert NOT_A_CONTRACT(budgetTreasuryImplementation_);
        if (premiumEscrowImplementation_.code.length == 0) revert NOT_A_CONTRACT(premiumEscrowImplementation_);

        budgetTreasuryImplementation = budgetTreasuryImplementation_;
        premiumEscrowImplementation = premiumEscrowImplementation_;
    }

    function prepareBudgetStack(
        address controller,
        address authority,
        address budgetAllocationLedger,
        address goalFlow,
        address goalTreasury
    ) external override returns (PreparationResult memory result) {
        _requireController(controller);
        _requireContract(authority);
        _requireContract(budgetAllocationLedger);
        _requireContract(goalFlow);
        _requireContract(goalTreasury);

        address budgetTreasury = Clones.clone(budgetTreasuryImplementation);
        result = PreparationResult({
            strategy: address(new BudgetSingleAllocatorStrategy(authority, budgetTreasury, authority)),
            budgetTreasury: budgetTreasury,
            premiumEscrow: Clones.clone(premiumEscrowImplementation)
        });
    }

    function deployBudgetTreasury(
        address controller,
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address budgetAllocationLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        IManagedBudgetController.BudgetConfig calldata config,
        address successResolver,
        address spendPolicy,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external override returns (address deployedBudgetTreasury) {
        _requireController(controller);

        IBudgetTCR.BudgetListing memory listing = IBudgetTCR.BudgetListing({
            metadata: config.metadata,
            fundingDeadline: config.fundingDeadline,
            executionDuration: config.executionDuration,
            activationThreshold: config.activationThreshold,
            runwayCap: config.runwayCap,
            oracleConfig: IBudgetTCR.OracleConfig({
                oracleSpecHash: config.successOracleSpecHash,
                assertionPolicyHash: config.successAssertionPolicyHash
            })
        });

        deployedBudgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            controller,
            budgetTreasury,
            premiumEscrow,
            childFlow,
            budgetAllocationLedger,
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

    function _requireController(address controller) private view {
        if (controller == address(0)) revert ADDRESS_ZERO();
        if (msg.sender != controller) revert ONLY_CONTROLLER(controller, msg.sender);
        if (controller.code.length == 0) revert NOT_A_CONTRACT(controller);
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert ADDRESS_ZERO();
        if (account.code.length == 0) revert NOT_A_CONTRACT(account);
    }
}
