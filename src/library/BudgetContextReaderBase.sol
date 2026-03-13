// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

abstract contract BudgetContextReaderBase {
    function _revertInvalidBudgetContext(uint8 probe, address candidate) internal pure virtual;

    function _requireBudgetContextContract(address candidate, uint8 probe) internal view returns (address deployed) {
        if (candidate == address(0) || candidate.code.length == 0) _revertInvalidBudgetContext(probe, candidate);
        return candidate;
    }

    function _readBudgetContextValue(
        function() external view returns (address) reader,
        address candidate,
        uint8 readProbe
    ) internal view returns (address value) {
        try reader() returns (address value_) {
            return value_;
        } catch {
            _revertInvalidBudgetContext(readProbe, candidate);
        }
    }

    function _readBudgetContextContract(
        function() external view returns (address) reader,
        address candidate,
        uint8 readProbe,
        uint8 valueProbe
    ) internal view returns (address deployed) {
        return _requireBudgetContextContract(_readBudgetContextValue(reader, candidate, readProbe), valueProbe);
    }

    function _readBudgetContextContract(
        function() external view returns (ISuperToken) reader,
        address candidate,
        uint8 readProbe,
        uint8 valueProbe
    ) internal view returns (ISuperToken deployed) {
        address deployedAddress;
        try reader() returns (ISuperToken deployed_) {
            deployedAddress = address(deployed_);
        } catch {
            _revertInvalidBudgetContext(readProbe, candidate);
        }
        _requireBudgetContextContract(deployedAddress, valueProbe);
        return ISuperToken(deployedAddress);
    }
}
