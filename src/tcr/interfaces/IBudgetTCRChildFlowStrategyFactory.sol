// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface IBudgetTCRChildFlowStrategyFactory {
    function prepareChildFlowStrategy(
        address budgetStakeLedger,
        address goalFlow,
        address registrar
    ) external returns (address strategy);
}
