// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISpendPolicy } from "src/interfaces/ISpendPolicy.sol";

library SpendPolicyValidationLib {
    uint256 private constant _MAX_SYNC_MODE = uint8(ISpendPolicy.SyncMode.LinearSpendDownFallback);

    function passesValidationProbe(address candidate) internal view returns (bool) {
        bytes memory syncModeData = _staticcall(candidate, abi.encodeCall(ISpendPolicy.syncMode, ()));
        if (syncModeData.length != 32) {
            return false;
        }
        uint256 rawSyncMode = abi.decode(syncModeData, (uint256));
        if (rawSyncMode > _MAX_SYNC_MODE) return false;

        bytes memory flowRateData = _staticcall(
            candidate,
            abi.encodeCall(ISpendPolicy.targetFlowRate, (_validationContext()))
        );
        if (flowRateData.length != 32) {
            return false;
        }
        int256 rawTargetFlowRate = abi.decode(flowRateData, (int256));
        return rawTargetFlowRate >= type(int96).min && rawTargetFlowRate <= type(int96).max;
    }

    function _validationContext() private view returns (ISpendPolicy.SpendContext memory ctx) {
        uint64 nowTs = uint64(block.timestamp);
        ctx = ISpendPolicy.SpendContext({
            nowTs: nowTs,
            activatedAt: nowTs,
            deadline: nowTs + 1,
            treasuryBalance: 1,
            timeRemaining: 1,
            incomingRate: 0,
            currentOutflowRate: 0
        });
    }

    function _staticcall(address candidate, bytes memory callData) private view returns (bytes memory returnData) {
        (bool success, bytes memory response) = candidate.staticcall(callData);
        if (!success) return bytes("");
        return response;
    }
}
