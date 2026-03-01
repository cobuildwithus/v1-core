// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";

contract MockUnderwriterSlasherRouter is IUnderwriterSlasherRouter {
    address public override authority;
    address private _stakeVault;
    mapping(address => bool) public override isAuthorizedPremiumEscrow;

    constructor(address authority_, address stakeVault_) {
        authority = authority_;
        _stakeVault = stakeVault_;
    }

    function stakeVault() external view override returns (IStakeVault) {
        return IStakeVault(_stakeVault);
    }

    function setAuthorizedPremiumEscrow(address premiumEscrow, bool authorized) external override {
        isAuthorizedPremiumEscrow[premiumEscrow] = authorized;
    }

    function slashUnderwriter(address, uint256) external override { }
}
