// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IUnderwriterSlasherRouter } from "src/interfaces/IUnderwriterSlasherRouter.sol";

contract MockUnderwriterSlasherRouter is IUnderwriterSlasherRouter {
    address public immutable override authority;
    IStakeVault private immutable _stakeVault;
    mapping(address => bool) public override isAuthorizedPremiumEscrow;

    constructor(address authority_, address stakeVault_) {
        authority = authority_;
        _stakeVault = IStakeVault(stakeVault_);
    }

    function stakeVault() external view override returns (IStakeVault) {
        return _stakeVault;
    }

    function setAuthorizedPremiumEscrow(address premiumEscrow, bool authorized) external override {
        isAuthorizedPremiumEscrow[premiumEscrow] = authorized;
    }

    function slashUnderwriter(address, uint256) external override { }

    function retryForwarding() external pure override returns (uint256 forwardedSuperTokenAmount) {
        return 0;
    }

    function retryConversionAndForward()
        external
        pure
        override
        returns (uint256 convertedGoalAmount, uint256 forwardedSuperTokenAmount)
    {
        return (0, 0);
    }
}
