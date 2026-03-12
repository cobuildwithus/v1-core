// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IPremiumEscrow } from "src/interfaces/IPremiumEscrow.sol";

/// @notice Managed preset escrow implementation that intentionally carries no premium logic.
contract NullPremiumEscrow is IPremiumEscrow {
    /// @dev Unused managed-premium inputs stay in the signature for `IPremiumEscrow` symmetry.
    function initialize(address, address, address, address, uint32) external pure override {}

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
