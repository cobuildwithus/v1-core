// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";

/// @notice Managed preset escrow implementation that intentionally carries no premium logic.
contract NullPremiumEscrow is IPremiumEscrow, Initializable {
    error ADDRESS_ZERO();

    address public budgetTreasury;
    address public budgetStakeLedger;
    address public goalFlow;
    address public underwriterSlasherRouter;
    uint32 public budgetSlashPpm;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address budgetTreasury_,
        address budgetStakeLedger_,
        address goalFlow_,
        address underwriterSlasherRouter_,
        uint32 budgetSlashPpm_
    ) external initializer {
        if (budgetTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (budgetStakeLedger_ == address(0)) revert ADDRESS_ZERO();
        if (goalFlow_ == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouter_ == address(0)) revert ADDRESS_ZERO();

        budgetTreasury = budgetTreasury_;
        budgetStakeLedger = budgetStakeLedger_;
        goalFlow = goalFlow_;
        underwriterSlasherRouter = underwriterSlasherRouter_;
        budgetSlashPpm = budgetSlashPpm_;
    }

    function connectManagerRewardPool(address) external pure override {}

    function checkpoint(address) external pure override {}

    function claim(address) external pure override returns (uint256 amount) {
        return 0;
    }

    function burnOnGoalFailure() external pure override returns (uint256 amount) {
        return 0;
    }

    function close(IBudgetTreasury.BudgetState, uint64, uint64) external pure override {}

    function slash(address) external pure override returns (uint256 slashWeight) {
        return 0;
    }

    function userCov(address) external pure override returns (uint256) {
        return 0;
    }

    function exposureIntegral(address) external pure override returns (uint256) {
        return 0;
    }

    function creditDrawn(address) external pure override returns (uint256) {
        return 0;
    }
}
