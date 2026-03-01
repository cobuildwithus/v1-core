// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IBudgetTreasury} from "./IBudgetTreasury.sol";

/// @notice Temporary typed surface for premium-escrow lookup during vNext parallel integration.
interface IBudgetTreasuryPremiumEscrow is IBudgetTreasury {
    function premiumEscrow() external view returns (address);
}
