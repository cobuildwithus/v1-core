// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library BudgetTCRCreditCapActions {
    event BudgetCreditCapEnforcementFailed(
        bytes32 indexed itemID,
        address indexed budgetTreasury,
        address callTarget,
        bytes4 indexed selector,
        bytes reason
    );

    function bestEffortEnforceBudgetCreditCap(
        IFlow goalFlow,
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address budgetStakeLedger,
        uint256 lambda
    ) external {
        uint256 runwayCap;
        bool hasRunwayCap;
        try IBudgetTreasury(budgetTreasury).runwayCap() returns (uint256 cap) {
            runwayCap = cap;
            hasRunwayCap = cap != 0;
        } catch (bytes memory reason) {
            _emitBudgetCreditCapEnforcementFailed(
                itemID, budgetTreasury, budgetTreasury, IBudgetTreasury.runwayCap.selector, reason
            );
        }

        if (lambda == 0) {
            if (!hasRunwayCap) {
                try goalFlow.setRecipientEnabled(itemID, true) {} catch (bytes memory reason) {
                    _emitBudgetCreditCapEnforcementFailed(
                        itemID,
                        budgetTreasury,
                        address(goalFlow),
                        IFlow.setRecipientEnabled.selector,
                        reason
                    );
                }
                return;
            }

            uint256 received;
            try goalFlow.getTotalReceivedByMember(childFlow) returns (uint256 totalReceived) {
                received = totalReceived;
            } catch (bytes memory reason) {
                _emitBudgetCreditCapEnforcementFailed(
                    itemID,
                    budgetTreasury,
                    address(goalFlow),
                    IFlow.getTotalReceivedByMember.selector,
                    reason
                );
                return;
            }

            bool enabled = received < runwayCap;
            try goalFlow.setRecipientEnabled(itemID, enabled) {} catch (bytes memory reason) {
                _emitBudgetCreditCapEnforcementFailed(
                    itemID, budgetTreasury, address(goalFlow), IFlow.setRecipientEnabled.selector, reason
                );
            }
            return;
        }

        uint256 coverage;
        try IBudgetStakeLedger(budgetStakeLedger).budgetTotalAllocatedStake(budgetTreasury) returns (uint256 cov) {
            coverage = cov;
        } catch (bytes memory reason) {
            if (hasRunwayCap) {
                if (!_bestEffortDisableRecipientWhenRunwayExceeded(goalFlow, itemID, budgetTreasury, childFlow, runwayCap)) {
                    _emitBudgetCreditCapEnforcementFailed(
                        itemID,
                        budgetTreasury,
                        budgetStakeLedger,
                        IBudgetStakeLedger.budgetTotalAllocatedStake.selector,
                        reason
                    );
                    return;
                }
            }

            _emitBudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                budgetStakeLedger,
                IBudgetStakeLedger.budgetTotalAllocatedStake.selector,
                reason
            );
            return;
        }

        uint64 duration;
        try IBudgetTreasury(budgetTreasury).executionDuration() returns (uint64 dur) {
            duration = dur;
        } catch (bytes memory reason) {
            if (hasRunwayCap) {
                if (!_bestEffortDisableRecipientWhenRunwayExceeded(goalFlow, itemID, budgetTreasury, childFlow, runwayCap)) {
                    _emitBudgetCreditCapEnforcementFailed(
                        itemID,
                        budgetTreasury,
                        budgetTreasury,
                        IBudgetTreasury.executionDuration.selector,
                        reason
                    );
                    return;
                }
            }

            _emitBudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                budgetTreasury,
                IBudgetTreasury.executionDuration.selector,
                reason
            );
            return;
        }

        uint256 creditLine = Math.mulDiv(coverage, uint256(duration), lambda);

        uint256 effectiveCap = creditLine;
        if (effectiveCap != 0 && hasRunwayCap && runwayCap < effectiveCap) {
            effectiveCap = runwayCap;
        }

        if (effectiveCap == 0) {
            try goalFlow.setRecipientEnabled(itemID, false) {} catch (bytes memory reason) {
                _emitBudgetCreditCapEnforcementFailed(
                    itemID, budgetTreasury, address(goalFlow), IFlow.setRecipientEnabled.selector, reason
                );
            }
            return;
        }

        uint256 receivedForEffectiveCap;
        try goalFlow.getTotalReceivedByMember(childFlow) returns (uint256 totalReceived) {
            receivedForEffectiveCap = totalReceived;
        } catch (bytes memory reason) {
            _emitBudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                address(goalFlow),
                IFlow.getTotalReceivedByMember.selector,
                reason
            );
            return;
        }

        bool enabledForEffectiveCap = receivedForEffectiveCap < effectiveCap;
        try goalFlow.setRecipientEnabled(itemID, enabledForEffectiveCap) {} catch (bytes memory reason) {
            _emitBudgetCreditCapEnforcementFailed(
                itemID, budgetTreasury, address(goalFlow), IFlow.setRecipientEnabled.selector, reason
            );
        }
    }

    function _bestEffortDisableRecipientWhenRunwayExceeded(
        IFlow goalFlow,
        bytes32 itemID,
        address budgetTreasury,
        address childFlow,
        uint256 runwayCap
    ) private returns (bool checked) {
        uint256 received;
        try goalFlow.getTotalReceivedByMember(childFlow) returns (uint256 totalReceived) {
            received = totalReceived;
        } catch (bytes memory reason) {
            _emitBudgetCreditCapEnforcementFailed(
                itemID,
                budgetTreasury,
                address(goalFlow),
                IFlow.getTotalReceivedByMember.selector,
                reason
            );
            return false;
        }

        if (received >= runwayCap) {
            try goalFlow.setRecipientEnabled(itemID, false) {} catch (bytes memory reason) {
                _emitBudgetCreditCapEnforcementFailed(
                    itemID, budgetTreasury, address(goalFlow), IFlow.setRecipientEnabled.selector, reason
                );
            }
        }

        return true;
    }

    function _emitBudgetCreditCapEnforcementFailed(
        bytes32 itemID,
        address budgetTreasury,
        address callTarget,
        bytes4 selector,
        bytes memory reason
    ) private {
        emit BudgetCreditCapEnforcementFailed(itemID, budgetTreasury, callTarget, selector, reason);
    }
}
