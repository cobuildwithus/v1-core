// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { BudgetStackTypes } from "./BudgetStackTypes.sol";
import { IBudgetTreasury } from "./IBudgetTreasury.sol";

interface IBudgetStackRuntimeDeployer {
    error ADDRESS_ZERO();
    error ONLY_CONTROLLER();

    function initializeWithConfig(
        address controller_,
        BudgetStackTypes.StackModuleConfig calldata stackModuleConfig_
    ) external;

    function prepareBudgetStack(
        address budgetStakeLedger,
        address goalFlow
    ) external returns (BudgetStackTypes.PreparationResult memory result);

    function deployBudgetTreasury(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig
    ) external returns (address deployedBudgetTreasury);

    function deployBudgetTreasuryWithRiskModule(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig,
        BudgetStackTypes.RiskModuleInitConfig calldata riskModuleInitConfig
    ) external returns (address deployedBudgetTreasury);

    function registerChildFlowRecipient(bytes32 recipientId, address childFlow) external;
    function stackModuleConfig() external view returns (BudgetStackTypes.StackModuleConfig memory config);
}
