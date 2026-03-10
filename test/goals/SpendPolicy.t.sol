// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {LinearSpendPolicy} from "src/goals/policies/LinearSpendPolicy.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";

import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";

contract SpendPolicyTest is Test, SpendPolicyTestUtils {
    LinearSpendPolicy internal linearImplementation;

    function setUp() public {
        linearImplementation = new LinearSpendPolicy();
    }

    function test_linearSpendPolicy_returnsZeroWhenNoTimeRemaining() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(false, 0, ISpendPolicy.SyncMode.LinearSpendDownFallback);

        assertEq(policy.targetFlowRate(_context(100, 0, 50)), 0);
    }

    function test_linearSpendPolicy_returnsBalanceSpenddownWhenIncomingExcluded() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(false, 0, ISpendPolicy.SyncMode.LinearSpendDownFallback);

        assertEq(policy.targetFlowRate(_context(100, 10, 7)), 10);
    }

    function test_linearSpendPolicy_includesIncomingRateWhenConfigured() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped);

        assertEq(policy.targetFlowRate(_context(100, 10, 7)), 17);
    }

    function test_linearSpendPolicy_ignoresNegativeIncomingRate() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped);

        assertEq(policy.targetFlowRate(_context(100, 10, -7)), 10);
    }

    function test_linearSpendPolicy_appliesConfiguredMaxTargetFlowRate() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, 12, ISpendPolicy.SyncMode.Capped);

        assertEq(policy.targetFlowRate(_context(100, 10, 7)), 12);
    }

    function test_linearSpendPolicy_capsToInt96Max() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped);
        ISpendPolicy.SpendContext memory ctx = _context(type(uint256).max, 1, type(int96).max);

        assertEq(policy.targetFlowRate(ctx), type(int96).max);
    }

    function test_linearSpendPolicy_respectsMaxTargetFlowRateBelowInt96Max() public {
        uint256 cappedTarget = uint256(uint96(type(int96).max)) - 1;
        LinearSpendPolicy policy = _deployLinearSpendPolicy(true, cappedTarget, ISpendPolicy.SyncMode.Capped);

        assertEq(policy.targetFlowRate(_context(type(uint256).max, 1, type(int96).max)), int96(uint96(cappedTarget)));
    }

    function test_linearSpendPolicy_returnsConfiguredSyncMode() public {
        LinearSpendPolicy policy = _deployLinearSpendPolicy(false, 123, ISpendPolicy.SyncMode.LinearSpendDownFallback);

        assertEq(uint256(policy.syncMode()), uint256(ISpendPolicy.SyncMode.LinearSpendDownFallback));
    }

    function test_linearSpendPolicy_revertsBeforeInitialization_forImplementationAndClone() public {
        vm.expectRevert(LinearSpendPolicy.POLICY_NOT_INITIALIZED.selector);
        linearImplementation.syncMode();
        vm.expectRevert(LinearSpendPolicy.POLICY_NOT_INITIALIZED.selector);
        linearImplementation.targetFlowRate(_context(100, 10, 0));

        LinearSpendPolicy clone = LinearSpendPolicy(Clones.clone(address(linearImplementation)));

        vm.expectRevert(LinearSpendPolicy.POLICY_NOT_INITIALIZED.selector);
        clone.syncMode();
        vm.expectRevert(LinearSpendPolicy.POLICY_NOT_INITIALIZED.selector);
        clone.targetFlowRate(_context(100, 10, 0));
    }

    function test_linearSpendPolicy_initialize_rejectsMalformedSyncModeCallData() public {
        LinearSpendPolicy policy = LinearSpendPolicy(Clones.clone(address(linearImplementation)));

        (bool ok, bytes memory revertData) = address(policy).call(
            abi.encodeWithSelector(LinearSpendPolicy.initialize.selector, false, uint256(0), uint8(2))
        );

        assertFalse(ok);
        assertEq(revertData.length, 0);
    }

    function _context(uint256 balance, uint256 remaining, int96 incomingRate)
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
            currentOutflowRate: 0
        });
    }
}
