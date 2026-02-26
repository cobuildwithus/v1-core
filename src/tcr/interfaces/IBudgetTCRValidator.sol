// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "./IBudgetTCR.sol";

interface IBudgetTCRValidator {
    function verifyItemData(
        bytes calldata item,
        IBudgetTCR.BudgetValidationBounds calldata budgetBounds,
        IBudgetTCR.OracleValidationBounds calldata oracleBounds,
        uint64 goalDeadline
    ) external view returns (bool valid);
}
