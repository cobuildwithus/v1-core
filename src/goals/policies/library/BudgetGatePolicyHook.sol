// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetGatePolicy, IZeroCoverageBudgetGatePolicy } from "src/interfaces/IBudgetGatePolicy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";

library BudgetGatePolicyHook {
    function supportsBudgetGatePolicy(IBudgetGatePolicy policy) internal view returns (bool supported) {
        try policy.evaluateBudgetGate(_zeroCoverageProbeContext()) returns (IBudgetGatePolicy.SyncResult memory) {
            return true;
        } catch {
            return false;
        }
    }

    function supportsZeroCoverageBudgetGatePolicy(IBudgetGatePolicy policy) internal view returns (bool compatible) {
        try IZeroCoverageBudgetGatePolicy(address(policy)).supportsZeroCoverageBudgetGate() returns (bool supported) {
            if (!supported) return false;
        } catch {
            return false;
        }

        IBudgetGatePolicy.SyncResult memory result = evaluateBudgetGate(policy, _zeroCoverageProbeContext());
        if (result.failures.length != 0) return false;
        return !result.shouldSetRecipientEnabled || result.recipientEnabled;
    }

    function evaluateBudgetGate(
        IBudgetGatePolicy policy,
        IBudgetGatePolicy.SyncContext memory context
    ) internal view returns (IBudgetGatePolicy.SyncResult memory result) {
        try policy.evaluateBudgetGate(context) returns (IBudgetGatePolicy.SyncResult memory policyResult) {
            return policyResult;
        } catch (bytes memory reason) {
            result.failures = new IBudgetGatePolicy.CallFailure[](1);
            result.failures[0] = IBudgetGatePolicy.CallFailure({
                callTarget: address(policy),
                selector: IBudgetGatePolicy.evaluateBudgetGate.selector,
                reason: reason
            });
        }
    }

    function _zeroCoverageProbeContext() private pure returns (IBudgetGatePolicy.SyncContext memory context) {
        context = IBudgetGatePolicy.SyncContext({
            itemID: bytes32(0),
            goalFlow: IFlow(address(0)),
            childFlow: address(0),
            budgetTreasury: address(0),
            coverageSource: address(0),
            coverageToCreditPpm: 0
        });
    }
}
