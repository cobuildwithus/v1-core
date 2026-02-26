// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IFlow } from "../interfaces/IFlow.sol";
import { ITreasuryDonations } from "../interfaces/ITreasuryDonations.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TreasuryDonations } from "./library/TreasuryDonations.sol";

abstract contract TreasuryBase is ReentrancyGuard, ITreasuryDonations {
    event FlowRateZeroingFailed(address indexed flow, bytes reason);

    function donateUnderlyingAndUpgrade(
        uint256 amount
    ) external virtual override nonReentrant returns (uint256 received) {
        return _donateUnderlyingAndUpgrade(amount);
    }

    function _donateUnderlyingAndUpgrade(uint256 amount) internal returns (uint256 received) {
        if (!_canAcceptDonation()) _revertInvalidState();
        if (amount == 0) return 0;

        address underlyingToken;
        (received, underlyingToken) = TreasuryDonations.donateUnderlyingAndUpgradeToFlow(
            _superToken(),
            msg.sender,
            _flowAddress(),
            amount
        );
        if (received == 0) return 0;

        _afterDonation(msg.sender, underlyingToken, amount, received);
    }

    function _treasuryBalance() internal view returns (uint256) {
        return _superToken().balanceOf(_flowAddress());
    }

    function _forceFlowRateToZero() internal {
        IFlow flowContract = _flowContract();
        if (flowContract.targetOutflowRate() != 0) {
            flowContract.setTargetOutflowRate(0);
        }
    }

    function _tryForceFlowRateToZero() internal returns (bool stopped, bytes memory revertData) {
        IFlow flowContract = _flowContract();

        int96 currentRate;
        try flowContract.targetOutflowRate() returns (int96 targetOutflowRate_) {
            currentRate = targetOutflowRate_;
        } catch (bytes memory reason_) {
            emit FlowRateZeroingFailed(address(flowContract), reason_);
            return (false, reason_);
        }
        if (currentRate == 0) return (true, bytes(""));

        try flowContract.setTargetOutflowRate(0) {
            return (true, bytes(""));
        } catch (bytes memory reason_) {
            emit FlowRateZeroingFailed(address(flowContract), reason_);
            return (false, reason_);
        }
    }

    function _flowAddress() internal view returns (address) {
        return address(_flowContract());
    }

    function _flowContract() internal view virtual returns (IFlow);
    function _superToken() internal view virtual returns (ISuperToken);
    function _canAcceptDonation() internal view virtual returns (bool);
    function _afterDonation(
        address donor,
        address sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount
    ) internal virtual;
    function _revertInvalidState() internal pure virtual;
}
