// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface IBudgetStackChildFlowStrategyFactory {
    function prepareChildFlowStrategy(
        address budgetTreasury,
        address budgetStakeLedger,
        address goalFlow,
        address registrar
    ) external returns (address strategy);
}
