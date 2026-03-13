// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IUMATreasurySuccessResolverConfig } from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";

library SuccessResolverValidationLib {
    function passesValidationProbe(address candidate) internal view returns (bool) {
        address optimisticOracle = _readAddress(
            candidate,
            abi.encodeCall(IUMATreasurySuccessResolverConfig.optimisticOracle, ())
        );
        if (optimisticOracle == address(0) || optimisticOracle.code.length == 0) return false;

        address assertionCurrency = _readAddress(
            candidate,
            abi.encodeCall(IUMATreasurySuccessResolverConfig.assertionCurrency, ())
        );
        return assertionCurrency != address(0) && assertionCurrency.code.length != 0;
    }

    function _readAddress(address candidate, bytes memory callData) private view returns (address account) {
        bytes memory returnData = _staticcall(candidate, callData);
        if (returnData.length != 32) return address(0);
        account = abi.decode(returnData, (address));
    }

    function _staticcall(address candidate, bytes memory callData) private view returns (bytes memory returnData) {
        (bool success, bytes memory response) = candidate.staticcall(callData);
        if (!success) return bytes("");
        return response;
    }
}
