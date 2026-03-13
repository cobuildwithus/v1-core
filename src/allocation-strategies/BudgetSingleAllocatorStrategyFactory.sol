// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { BudgetSingleAllocatorStrategy } from "./BudgetSingleAllocatorStrategy.sol";
import { IBudgetStackChildFlowStrategyFactory } from "src/interfaces/IBudgetStackChildFlowStrategyFactory.sol";
import { IBudgetStackControllerReader } from "src/interfaces/IBudgetStackControllerReader.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @notice Child-strategy factory that scopes each managed budget flow to its controller.
contract BudgetSingleAllocatorStrategyFactory is IBudgetStackChildFlowStrategyFactory {
    error INVALID_IMPLEMENTATION(address implementation);
    error INVALID_REGISTRAR(address registrar);

    address public immutable implementation;

    constructor(address implementation_) {
        if (implementation_ == address(0) || implementation_.code.length == 0) {
            revert INVALID_IMPLEMENTATION(implementation_);
        }
        implementation = implementation_;
    }

    function prepareChildFlowStrategy(
        address budgetTreasury,
        address,
        address,
        address registrar
    ) external returns (address strategy) {
        if (registrar == address(0) || registrar.code.length == 0) revert INVALID_REGISTRAR(registrar);

        address controller = IBudgetStackControllerReader(registrar).controller();
        if (controller == address(0) || controller.code.length == 0) revert INVALID_REGISTRAR(registrar);

        strategy = Clones.clone(implementation);
        BudgetSingleAllocatorStrategy(strategy).initialize(budgetTreasury, controller);
    }
}
