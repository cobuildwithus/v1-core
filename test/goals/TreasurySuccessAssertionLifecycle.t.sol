// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {TreasurySuccessAssertionLifecycle} from "src/goals/library/TreasurySuccessAssertionLifecycle.sol";
import {TreasuryReassertGrace} from "src/goals/library/TreasuryReassertGrace.sol";
import {TreasurySuccessAssertions} from "src/goals/library/TreasurySuccessAssertions.sol";

contract TreasurySuccessAssertionLifecycleHarness {
    using TreasurySuccessAssertions for TreasurySuccessAssertions.State;
    using TreasuryReassertGrace for TreasuryReassertGrace.State;

    TreasurySuccessAssertions.State private _successAssertions;
    TreasuryReassertGrace.State private _reassertGrace;

    function registerPending(bytes32 assertionId) external returns (uint64 assertedAt) {
        return _successAssertions.registerPending(assertionId);
    }

    function pendingId() external view returns (bytes32) {
        return TreasurySuccessAssertions.pendingId(_successAssertions);
    }

    function pendingAt() external view returns (uint64) {
        return TreasurySuccessAssertions.pendingAt(_successAssertions);
    }

    function clearPending() external returns (bytes32 clearedAssertionId) {
        return TreasurySuccessAssertionLifecycle.clearPending(_successAssertions);
    }

    function clearPendingAndResetGrace() external returns (bytes32 clearedAssertionId) {
        return TreasurySuccessAssertionLifecycle.clearPendingAndResetGrace(_successAssertions, _reassertGrace);
    }

    function clearMatching(bytes32 assertionId) external returns (bytes32 clearedAssertionId) {
        return TreasurySuccessAssertionLifecycle.clearMatching(_successAssertions, assertionId);
    }

    function clearMatchingAndTryActivateGrace(bytes32 assertionId, bool canActivateGrace, uint64 reassertGraceDuration)
        external
        returns (bytes32 clearedAssertionId, bool graceActivated, uint64 graceDeadline)
    {
        TreasurySuccessAssertionLifecycle.ClearResult memory result =
            TreasurySuccessAssertionLifecycle.clearMatchingAndTryActivateGrace(
                _successAssertions, _reassertGrace, assertionId, canActivateGrace, reassertGraceDuration
            );
        return (result.clearedAssertionId, result.graceActivated, result.graceDeadline);
    }

    function clearPendingAndTryFinalize(address successResolver)
        external
        returns (bytes32 clearedAssertionId, bytes memory finalizeFailureData)
    {
        return TreasurySuccessAssertionLifecycle.clearPendingAndTryFinalize(_successAssertions, successResolver);
    }

    function activateGrace(uint64 reassertGraceDuration) external returns (bool activated, uint64 graceDeadline) {
        return _reassertGrace.activateOnce(reassertGraceDuration);
    }

    function reassertGraceDeadline() external view returns (uint64) {
        return _reassertGrace.deadline;
    }

    function reassertGraceUsed() external view returns (bool) {
        return _reassertGrace.used;
    }
}

contract TreasurySuccessAssertionLifecycleFinalizeMock {
    error FINALIZE_REVERT();

    bytes32 public lastFinalizedAssertionId;
    uint256 public finalizeCallCount;
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function finalize(bytes32 assertionId) external returns (bool applied) {
        finalizeCallCount += 1;
        lastFinalizedAssertionId = assertionId;
        if (shouldRevert) revert FINALIZE_REVERT();
        return false;
    }
}

contract TreasurySuccessAssertionLifecycleTest is Test {
    TreasurySuccessAssertionLifecycleHarness internal harness;
    TreasurySuccessAssertionLifecycleFinalizeMock internal finalizeMock;

    function setUp() public {
        harness = new TreasurySuccessAssertionLifecycleHarness();
        finalizeMock = new TreasurySuccessAssertionLifecycleFinalizeMock();
    }

    function test_clearMatching_clearsExpectedPendingAssertion() public {
        bytes32 assertionId = keccak256("matching");
        harness.registerPending(assertionId);

        bytes32 clearedAssertionId = harness.clearMatching(assertionId);

        assertEq(clearedAssertionId, assertionId);
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
    }

    function test_clearPending_clearsPendingAssertion() public {
        bytes32 assertionId = keccak256("clear-pending");
        harness.registerPending(assertionId);

        bytes32 clearedAssertionId = harness.clearPending();

        assertEq(clearedAssertionId, assertionId);
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
    }

    function test_clearPendingAndResetGrace_clearsPendingAssertionAndGraceDeadline() public {
        bytes32 assertionId = keccak256("clear-pending-reset-grace");
        harness.registerPending(assertionId);
        harness.activateGrace(1 days);

        bytes32 clearedAssertionId = harness.clearPendingAndResetGrace();

        assertEq(clearedAssertionId, assertionId);
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
        assertEq(harness.reassertGraceDeadline(), 0);
        assertTrue(harness.reassertGraceUsed());
    }

    function test_clearMatchingAndTryActivateGrace_whenAllowed_opensGraceWindow() public {
        bytes32 assertionId = keccak256("clear-matching-activate-grace");
        harness.registerPending(assertionId);

        (bytes32 clearedAssertionId, bool graceActivated, uint64 graceDeadline) =
            harness.clearMatchingAndTryActivateGrace(assertionId, true, 1 days);

        assertEq(clearedAssertionId, assertionId);
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
        assertTrue(graceActivated);
        assertEq(graceDeadline, uint64(block.timestamp + 1 days));
        assertEq(harness.reassertGraceDeadline(), graceDeadline);
        assertTrue(harness.reassertGraceUsed());
    }

    function test_clearMatchingAndTryActivateGrace_whenNotAllowed_keepsGraceClosed() public {
        bytes32 assertionId = keccak256("clear-matching-no-grace");
        harness.registerPending(assertionId);

        (bytes32 clearedAssertionId, bool graceActivated, uint64 graceDeadline) =
            harness.clearMatchingAndTryActivateGrace(assertionId, false, 1 days);

        assertEq(clearedAssertionId, assertionId);
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
        assertFalse(graceActivated);
        assertEq(graceDeadline, 0);
        assertEq(harness.reassertGraceDeadline(), 0);
        assertFalse(harness.reassertGraceUsed());
    }

    function test_clearPendingAndTryFinalize_success_clearsAssertionAndCallsFinalize() public {
        bytes32 assertionId = keccak256("finalize-success");
        harness.registerPending(assertionId);

        (bytes32 clearedAssertionId, bytes memory finalizeFailureData) =
            harness.clearPendingAndTryFinalize(address(finalizeMock));

        assertEq(clearedAssertionId, assertionId);
        assertEq(finalizeFailureData.length, 0);
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
        assertEq(finalizeMock.finalizeCallCount(), 1);
        assertEq(finalizeMock.lastFinalizedAssertionId(), assertionId);
    }

    function test_clearPendingAndTryFinalize_revert_returnsRevertDataAndKeepsAssertionCleared() public {
        bytes32 assertionId = keccak256("finalize-revert");
        harness.registerPending(assertionId);
        finalizeMock.setShouldRevert(true);

        (bytes32 clearedAssertionId, bytes memory finalizeFailureData) =
            harness.clearPendingAndTryFinalize(address(finalizeMock));

        assertEq(clearedAssertionId, assertionId);
        assertEq(
            finalizeFailureData,
            abi.encodeWithSelector(TreasurySuccessAssertionLifecycleFinalizeMock.FINALIZE_REVERT.selector)
        );
        assertEq(harness.pendingId(), bytes32(0));
        assertEq(harness.pendingAt(), 0);
        assertEq(finalizeMock.finalizeCallCount(), 0);
        assertEq(finalizeMock.lastFinalizedAssertionId(), bytes32(0));
    }

    function test_clearPendingAndTryFinalize_withoutPendingAssertion_isNoOp() public {
        (bytes32 clearedAssertionId, bytes memory finalizeFailureData) =
            harness.clearPendingAndTryFinalize(address(finalizeMock));

        assertEq(clearedAssertionId, bytes32(0));
        assertEq(finalizeFailureData.length, 0);
        assertEq(finalizeMock.finalizeCallCount(), 0);
    }
}
