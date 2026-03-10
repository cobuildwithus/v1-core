// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISpendPolicy } from "src/interfaces/ISpendPolicy.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract LinearSpendPolicy is ISpendPolicy, Initializable {
    uint256 private constant INT96_MAX_UINT = uint256(uint96(type(int96).max));

    bool public includeIncomingRate;
    SyncMode private _syncMode;
    bool private _policyInitialized;

    error POLICY_NOT_INITIALIZED();

    constructor() {
        _disableInitializers();
    }

    function initialize(bool includeIncomingRate_, SyncMode syncMode_) external initializer {
        includeIncomingRate = includeIncomingRate_;
        _syncMode = syncMode_;
        _policyInitialized = true;
    }

    function targetFlowRate(SpendContext calldata ctx) external view override returns (int96) {
        _requireInitialized();
        if (ctx.totalRecipientUnits == 0 || ctx.timeRemaining == 0) return 0;

        uint256 spendDown = ctx.treasuryBalance / ctx.timeRemaining;
        uint256 aggregate = spendDown;

        if (includeIncomingRate && ctx.incomingRate > 0) {
            aggregate = _capAddUint96(aggregate, uint256(uint96(ctx.incomingRate)));
        }

        return _toInt96Capped(aggregate);
    }

    function syncMode() external view override returns (SyncMode) {
        _requireInitialized();
        return _syncMode;
    }

    function _requireInitialized() private view {
        if (!_policyInitialized) revert POLICY_NOT_INITIALIZED();
    }

    function _capAddUint96(uint256 a, uint256 b) private pure returns (uint256) {
        if (a >= INT96_MAX_UINT || b >= INT96_MAX_UINT) return INT96_MAX_UINT;
        if (b > INT96_MAX_UINT - a) return INT96_MAX_UINT;
        return a + b;
    }

    function _toInt96Capped(uint256 value) private pure returns (int96) {
        if (value == 0) return 0;
        if (value >= INT96_MAX_UINT) return type(int96).max;
        return SafeCast.toInt96(SafeCast.toInt256(value));
    }
}
