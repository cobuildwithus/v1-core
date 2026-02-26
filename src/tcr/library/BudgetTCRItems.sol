// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

library BudgetTCRItems {
    function decodeItemData(bytes memory item) internal pure returns (IBudgetTCR.BudgetListing memory listing) {
        return abi.decode(item, (IBudgetTCR.BudgetListing));
    }
}
