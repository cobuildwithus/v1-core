// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library StakeCoverageGateActions {
    struct FailureAccumulator {
        IBudgetGatePolicy.CallFailure[2] failures;
        uint256 count;
    }

    function evaluateStakeCoverageGate(
        IBudgetGatePolicy.SyncContext calldata context
    ) internal view returns (IBudgetGatePolicy.SyncResult memory result) {
        if (context.coverageToCreditPpm == 0) {
            result.shouldSetRecipientEnabled = true;
            result.recipientEnabled = false;
            result.failures = new IBudgetGatePolicy.CallFailure[](0);
            return result;
        }

        FailureAccumulator memory failureAccumulator;
        uint256 runwayCap;
        bool hasRunwayCap;
        try IBudgetTreasury(context.budgetTreasury).runwayCap() returns (uint256 cap) {
            runwayCap = cap;
            hasRunwayCap = cap != 0;
        } catch (bytes memory reason) {
            _pushFailure(failureAccumulator, context.budgetTreasury, IBudgetTreasury.runwayCap.selector, reason);
        }

        uint256 coverage;
        try IBudgetStakeLedger(context.coverageSource).budgetTotalAllocatedStake(context.budgetTreasury) returns (
            uint256 cov
        ) {
            coverage = cov;
        } catch (bytes memory reason) {
            return _handleCoverageReadFailure(context, failureAccumulator, hasRunwayCap, runwayCap, reason);
        }

        uint256 insuredLine = Math.mulDiv(
            coverage,
            uint256(context.coverageToCreditPpm),
            FlowProtocolConstants.PPM_SCALE_UINT256
        );

        uint256 effectiveCap = insuredLine;
        if (effectiveCap != 0 && hasRunwayCap && runwayCap < effectiveCap) {
            effectiveCap = runwayCap;
        }

        if (effectiveCap == 0) {
            result.shouldSetRecipientEnabled = true;
            result.recipientEnabled = false;
            result.failures = _toFailures(failureAccumulator);
            return result;
        }

        (bool loadedReceived, uint256 received) = _tryLoadReceivedOrPushFailure(
            failureAccumulator,
            context.goalFlow,
            context.childFlow
        );
        if (!loadedReceived) {
            result.failures = _toFailures(failureAccumulator);
            return result;
        }

        result.shouldSetRecipientEnabled = true;
        result.recipientEnabled = received < effectiveCap;
        result.failures = _toFailures(failureAccumulator);
    }

    function _handleCoverageReadFailure(
        IBudgetGatePolicy.SyncContext calldata context,
        FailureAccumulator memory failureAccumulator,
        bool hasRunwayCap,
        uint256 runwayCap,
        bytes memory coverageReadReason
    ) private view returns (IBudgetGatePolicy.SyncResult memory result) {
        if (hasRunwayCap) {
            (bool loadedReceived, uint256 received) = _tryLoadReceivedOrPushFailure(
                failureAccumulator,
                context.goalFlow,
                context.childFlow
            );
            if (loadedReceived && received >= runwayCap) {
                result.shouldSetRecipientEnabled = true;
                result.recipientEnabled = false;
            }
        }

        _pushFailure(
            failureAccumulator,
            context.coverageSource,
            IBudgetStakeLedger.budgetTotalAllocatedStake.selector,
            coverageReadReason
        );
        result.failures = _toFailures(failureAccumulator);
    }

    function _pushFailure(
        FailureAccumulator memory failureAccumulator,
        address callTarget,
        bytes4 selector,
        bytes memory reason
    ) private pure {
        uint256 count = failureAccumulator.count;
        if (count >= failureAccumulator.failures.length) return;

        failureAccumulator.failures[count] = IBudgetGatePolicy.CallFailure({
            callTarget: callTarget,
            selector: selector,
            reason: reason
        });
        failureAccumulator.count = count + 1;
    }

    function _toFailures(
        FailureAccumulator memory failureAccumulator
    ) private pure returns (IBudgetGatePolicy.CallFailure[] memory failures) {
        uint256 count = failureAccumulator.count;
        failures = new IBudgetGatePolicy.CallFailure[](count);
        for (uint256 i = 0; i < count; i++) {
            failures[i] = failureAccumulator.failures[i];
        }
    }

    function _tryLoadReceivedOrPushFailure(
        FailureAccumulator memory failureAccumulator,
        IFlow goalFlow,
        address childFlow
    ) private view returns (bool loadedReceived, uint256 received) {
        try goalFlow.getTotalReceivedByMember(childFlow) returns (uint256 totalReceived) {
            return (true, totalReceived);
        } catch (bytes memory readFailureReason) {
            _pushFailure(
                failureAccumulator,
                address(goalFlow),
                IFlow.getTotalReceivedByMember.selector,
                readFailureReason
            );
            return (false, 0);
        }
    }
}
