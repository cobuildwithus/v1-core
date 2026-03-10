// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LinearSpendPolicy} from "src/goals/policies/LinearSpendPolicy.sol";
import {UnitsCapSpendPolicy} from "src/goals/policies/UnitsCapSpendPolicy.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract SpendPolicyTest is Test {
    LinearSpendPolicy internal linearImplementation;
    UnitsCapSpendPolicy internal unitsCapImplementation;

    function setUp() public {
        linearImplementation = new LinearSpendPolicy();
        unitsCapImplementation = new UnitsCapSpendPolicy();
    }

    function test_linearSpendPolicy_returnsZeroWhenNoRecipientUnits() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(false, ISpendPolicy.SyncMode.LinearSpendDownFallback);

        assertEq(policy.targetFlowRate(_context(100, 10, 0, 50)), 0);
    }

    function test_linearSpendPolicy_returnsZeroWhenNoTimeRemaining() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(false, ISpendPolicy.SyncMode.LinearSpendDownFallback);

        assertEq(policy.targetFlowRate(_context(100, 0, 2, 50)), 0);
    }

    function test_linearSpendPolicy_includesIncomingRateWhenConfigured() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, ISpendPolicy.SyncMode.Capped);

        assertEq(policy.targetFlowRate(_context(100, 10, 2, 7)), 17);
    }

    function test_linearSpendPolicy_capsToInt96Max() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, ISpendPolicy.SyncMode.Capped);
        ISpendPolicy.SpendContext memory ctx = _context(type(uint256).max, 1, 1, type(int96).max);

        assertEq(policy.targetFlowRate(ctx), type(int96).max);
    }

    function test_linearSpendPolicy_returnsConfiguredSyncMode() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(false, ISpendPolicy.SyncMode.LinearSpendDownFallback);

        assertEq(uint256(policy.syncMode()), uint256(ISpendPolicy.SyncMode.LinearSpendDownFallback));
    }

    function test_linearSpendPolicy_initialize_rejectsMalformedSyncModeCallData() public {
        LinearSpendPolicy policy = LinearSpendPolicy(Clones.clone(address(linearImplementation)));

        (bool ok, bytes memory revertData) =
            address(policy).call(abi.encodeWithSelector(LinearSpendPolicy.initialize.selector, false, uint8(2)));

        assertFalse(ok);
        assertEq(revertData.length, 0);
    }

    function test_unitsCapSpendPolicy_returnsZeroWhenNoRecipientUnits() public {
        UnitsCapSpendPolicy policy = _deployUnitsCapSpendPolicy(10, 100, 0, 10, false);

        assertEq(policy.targetFlowRate(_context(100, 10, 0, 25)), 0);
    }

    function test_unitsCapSpendPolicy_appliesDesiredCapAndRunwayFloor() public {
        UnitsCapSpendPolicy policy = _deployUnitsCapSpendPolicy(5, 25, 100, 10, false);

        assertEq(policy.targetFlowRate(_context(200, 10, 10, 0)), 10);
    }

    function test_unitsCapSpendPolicy_includesPositiveIncomingRateWhenConfigured() public {
        UnitsCapSpendPolicy policy = _deployUnitsCapSpendPolicy(50, 500, 1_000, 10, true);

        assertEq(policy.targetFlowRate(_context(1_000, 10, 10, 20)), 20);
    }

    function test_unitsCapSpendPolicy_ignoresNegativeIncomingRate() public {
        UnitsCapSpendPolicy policy = _deployUnitsCapSpendPolicy(50, 500, 0, 10, true);

        assertEq(policy.targetFlowRate(_context(100, 10, 10, -20)), 10);
    }

    function test_unitsCapSpendPolicy_capsToInt96Max() public {
        uint128 uncappedRate = uint128(uint96(type(int96).max));
        UnitsCapSpendPolicy policy = _deployUnitsCapSpendPolicy(uncappedRate, type(uint128).max, 0, 1, false);
        ISpendPolicy.SpendContext memory ctx = _context(uint256(uint96(type(int96).max)) * 2, 10, 2, 0);

        assertEq(policy.targetFlowRate(ctx), type(int96).max);
    }

    function test_unitsCapSpendPolicy_returnsCappedSyncMode() public {
        UnitsCapSpendPolicy policy = _deployUnitsCapSpendPolicy(10, 100, 0, 10, false);

        assertEq(uint256(policy.syncMode()), uint256(ISpendPolicy.SyncMode.Capped));
    }

    function test_unitsCapSpendPolicy_initialize_revertsOnZeroMinRunwaySeconds() public {
        UnitsCapSpendPolicy policy = UnitsCapSpendPolicy(Clones.clone(address(unitsCapImplementation)));

        vm.expectRevert(UnitsCapSpendPolicy.INVALID_MIN_RUNWAY_SECONDS.selector);
        policy.initialize(10, 100, 0, 0, false);
    }

    function _deployLinearSpendPolicy(bool includeIncomingRate, ISpendPolicy.SyncMode syncMode)
        internal
        returns (LinearSpendPolicy policy)
    {
        policy = LinearSpendPolicy(Clones.clone(address(linearImplementation)));
        policy.initialize(includeIncomingRate, syncMode);
    }

    function _deployUnitsCapSpendPolicy(
        uint128 ratePerUnitPerSecond,
        uint128 maxTotalRate,
        uint256 reserveFloor,
        uint64 minRunwaySeconds,
        bool includeIncomingRate
    ) internal returns (UnitsCapSpendPolicy policy) {
        policy = UnitsCapSpendPolicy(Clones.clone(address(unitsCapImplementation)));
        policy.initialize(ratePerUnitPerSecond, maxTotalRate, reserveFloor, minRunwaySeconds, includeIncomingRate);
    }

    function _context(uint256 balance, uint256 remaining, uint128 units, int96 incomingRate)
        internal
        pure
        returns (ISpendPolicy.SpendContext memory ctx)
    {
        ctx = ISpendPolicy.SpendContext({
            nowTs: 0,
            activatedAt: 0,
            deadline: 0,
            treasuryBalance: balance,
            timeRemaining: remaining,
            incomingRate: incomingRate,
            currentOutflowRate: 0,
            totalRecipientUnits: units
        });
    }
}
