// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { GoalFlowLedgerMode } from "src/library/GoalFlowLedgerMode.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { ICustomFlow } from "src/interfaces/IFlow.sol";

contract GoalFlowLedgerModeHarness {
    struct DetectParams {
        address ledger;
        uint256 prevWeight;
        uint256 newWeight;
        bytes32[] prevRecipientIds;
        uint32[] prevAllocationPpm;
        bytes32[] newRecipientIds;
        uint32[] newAllocationPpm;
    }

    IAllocationStrategy internal _strategy;
    GoalFlowLedgerMode.ValidationCache internal _cache;

    function setStrategy(address strategy_) external {
        _strategy = IAllocationStrategy(strategy_);
        delete _cache;
    }

    function validate(
        address ledger,
        address expectedFlow
    ) external returns (address goalTreasury) {
        return GoalFlowLedgerMode.validateOrRevert(_strategy, _cache, ledger, expectedFlow);
    }

    function validateView(
        address ledger,
        address expectedFlow
    ) external view returns (address goalTreasury) {
        return GoalFlowLedgerMode.validateOrRevertView(_strategy, _cache, ledger, expectedFlow);
    }

    function validateForInitializeView(
        address ledger,
        address expectedFlow
    ) external view returns (address goalTreasury) {
        return GoalFlowLedgerMode.validateForInitializeOrRevertView(_strategy, _cache, ledger, expectedFlow);
    }

    function detectCalldata(DetectParams calldata params) external view returns (address[] memory budgetTreasuries) {
        if (params.ledger == address(0)) return new address[](0);
        return
            IBudgetStakeLedger(params.ledger).previewChangedBudgetTreasuries(
                params.prevWeight,
                params.prevRecipientIds,
                params.prevAllocationPpm,
                params.newWeight,
                params.newRecipientIds,
                params.newAllocationPpm
            );
    }

    function prepareCheckpointContextView(
        address ledger,
        address account,
        address expectedFlow
    ) external view returns (uint256 newWeight, bool shouldCheckpoint) {
        uint256 allocationKey = _strategy.allocationKey(account, bytes(""));
        return GoalFlowLedgerMode.prepareCheckpointContextView(
            _strategy,
            _cache,
            ledger,
            account,
            allocationKey,
            expectedFlow
        );
    }

    function prepareCheckpointContextFromCommittedWeight(
        address ledger,
        address account,
        uint256 committedWeight,
        address expectedFlow
    ) external returns (uint256 resolvedWeight, bool shouldCheckpoint) {
        uint256 allocationKey = _strategy.allocationKey(account, bytes(""));
        return
            GoalFlowLedgerMode.prepareCheckpointContextFromCommittedWeight(
                _strategy,
                _cache,
                ledger,
                account,
                allocationKey,
                committedWeight,
                expectedFlow
            );
    }

    function buildChildSyncActions(
        address account,
        address[] calldata budgetTreasuries
    ) external view returns (GoalFlowLedgerMode.ChildSyncAction[] memory actions) {
        return GoalFlowLedgerMode.buildChildSyncActions(account, budgetTreasuries);
    }

    function requiredChildSyncRequirements(
        address account,
        address[] calldata budgetTreasuries
    ) external view returns (ICustomFlow.ChildSyncRequirement[] memory reqs) {
        return GoalFlowLedgerMode.requiredChildSyncRequirements(account, budgetTreasuries);
    }

    function executeChildSyncBestEffort(
        GoalFlowLedgerMode.ChildSyncAction[] memory actions
    ) external returns (GoalFlowLedgerMode.ChildSyncExecution[] memory executions) {
        return GoalFlowLedgerMode.executeChildSyncBestEffort(actions);
    }
}
