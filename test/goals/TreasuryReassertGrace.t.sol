// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { TreasuryReassertGrace } from "src/goals/library/TreasuryReassertGrace.sol";

contract TreasuryReassertGraceHarness {
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    TreasuryReassertGrace.State private _state;

    function activateOnce(uint64 graceDuration) external returns (bool activated, uint64 graceDeadline) {
        return _state.activateOnce(graceDuration);
    }

    function isActive() external view returns (bool) {
        return _state.isActive();
    }

    function consumeIfActive() external returns (bool consumed) {
        return _state.consumeIfActive();
    }

    function used() external view returns (bool) {
        return _state.used;
    }

    function deadline() external view returns (uint64) {
        return _state.deadline;
    }
}

contract TreasuryReassertGraceTest is Test {
    TreasuryReassertGraceHarness internal harness;

    function setUp() public {
        harness = new TreasuryReassertGraceHarness();
    }

    function test_activateOnce_zeroDuration_revertsAndDoesNotConsumeGraceUse() public {
        vm.expectRevert(TreasuryReassertGrace.INVALID_REASSERT_GRACE_DURATION.selector);
        harness.activateOnce(0);

        assertFalse(harness.used());
        assertEq(harness.deadline(), 0);
        assertFalse(harness.isActive());
    }

    function test_activateOnce_positiveDuration_setsGraceWindow() public {
        (bool activated, uint64 graceDeadline) = harness.activateOnce(1 days);

        assertTrue(activated);
        assertTrue(harness.used());
        assertEq(graceDeadline, uint64(block.timestamp + 1 days));
        assertEq(harness.deadline(), graceDeadline);
        assertTrue(harness.isActive());
    }
}
