// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ISpendPolicy } from "src/interfaces/ISpendPolicy.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract UnitsCapSpendPolicy is ISpendPolicy, Initializable {
    uint256 private constant INT96_MAX_UINT = uint256(uint96(type(int96).max));

    uint128 public ratePerUnitPerSecond;
    uint128 public maxTotalRate;
    uint256 public reserveFloor;
    uint64 public minRunwaySeconds;
    bool public includeIncomingRate;
    bool private _policyInitialized;

    error INVALID_MIN_RUNWAY_SECONDS();
    error POLICY_NOT_INITIALIZED();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint128 ratePerUnitPerSecond_,
        uint128 maxTotalRate_,
        uint256 reserveFloor_,
        uint64 minRunwaySeconds_,
        bool includeIncomingRate_
    ) external initializer {
        if (minRunwaySeconds_ == 0) revert INVALID_MIN_RUNWAY_SECONDS();

        ratePerUnitPerSecond = ratePerUnitPerSecond_;
        maxTotalRate = maxTotalRate_;
        reserveFloor = reserveFloor_;
        minRunwaySeconds = minRunwaySeconds_;
        includeIncomingRate = includeIncomingRate_;
        _policyInitialized = true;
    }

    function targetFlowRate(SpendContext calldata ctx) external view override returns (int96) {
        _requireInitialized();
        if (ctx.totalRecipientUnits == 0) return 0;

        uint256 desired = uint256(ratePerUnitPerSecond) * uint256(ctx.totalRecipientUnits);
        uint256 cap = uint256(maxTotalRate);
        if (desired > cap) desired = cap;

        uint256 sustainable = _sustainableRate(ctx);
        if (desired > sustainable) desired = sustainable;

        return _toInt96Capped(desired);
    }

    function syncMode() external view override returns (SyncMode) {
        _requireInitialized();
        return SyncMode.Capped;
    }

    function _requireInitialized() private view {
        if (!_policyInitialized) revert POLICY_NOT_INITIALIZED();
    }

    function _sustainableRate(SpendContext calldata ctx) private view returns (uint256 sustainable) {
        if (includeIncomingRate && ctx.incomingRate > 0) {
            sustainable = uint256(uint96(ctx.incomingRate));
        }

        if (ctx.treasuryBalance > reserveFloor) {
            uint256 runwayDrain = (ctx.treasuryBalance - reserveFloor) / minRunwaySeconds;
            sustainable = _capAddUint96(sustainable, runwayDrain);
        }
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
