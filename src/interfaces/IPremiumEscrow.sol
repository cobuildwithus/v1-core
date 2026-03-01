// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IBudgetTreasury} from "./IBudgetTreasury.sol";
import {IUnderwriterSlasherRouter} from "./IUnderwriterSlasherRouter.sol";

interface IPremiumEscrow {
    function initialize(
        address budgetTreasury,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm
    ) external;

    function checkpoint(address account) external;
    function claim(address to) external returns (uint256 amount);
    function close(IBudgetTreasury.BudgetState state, uint64 activatedAt, uint64 closedAt) external;
    function slash(address underwriter) external returns (uint256 slashWeight);
}
