// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { GoalFlowLedgerMode } from "src/library/GoalFlowLedgerMode.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { ICustomFlow } from "src/interfaces/IFlow.sol";

contract GoalFlowLedgerModeHarness {
    struct DetectParams {
        uint256 percentageScale;
        address ledger;
        uint256 prevWeight;
        uint256 newWeight;
        bytes32[] prevRecipientIds;
        uint32[] prevAllocationsScaled;
        bytes32[] newRecipientIds;
        uint32[] newAllocationsScaled;
    }

    IAllocationStrategy[] internal _strategies;
    GoalFlowLedgerMode.ValidationCache internal _cache;

    function setStrategies(address[] calldata strategies) external {
        delete _strategies;
        uint256 count = strategies.length;
        for (uint256 i = 0; i < count; ) {
            _strategies.push(IAllocationStrategy(strategies[i]));
            unchecked {
                ++i;
            }
        }
        delete _cache;
    }

    function validate(
        address ledger,
        address expectedFlow
    ) external returns (address goalTreasury, address stakeVault) {
        return GoalFlowLedgerMode.validateOrRevert(_strategiesMemory(), _cache, ledger, expectedFlow);
    }

    function validateView(
        address ledger,
        address expectedFlow
    ) external view returns (address goalTreasury, address stakeVault) {
        return GoalFlowLedgerMode.validateOrRevertView(_strategiesMemory(), _cache, ledger, expectedFlow);
    }

    function validateForInitializeView(
        address ledger,
        address expectedFlow
    ) external view returns (address goalTreasury, address stakeVault) {
        return GoalFlowLedgerMode.validateForInitializeOrRevertView(_strategiesMemory(), _cache, ledger, expectedFlow);
    }

    function detectCalldata(DetectParams calldata params) external view returns (address[] memory budgetTreasuries) {
        return
            GoalFlowLedgerMode.detectBudgetDeltasCalldata(
                params.percentageScale,
                params.ledger,
                params.prevWeight,
                params.prevRecipientIds,
                params.prevAllocationsScaled,
                params.newWeight,
                params.newRecipientIds,
                params.newAllocationsScaled
            );
    }

    function prepareCheckpointContextView(
        address ledger,
        address account,
        address expectedFlow
    ) external view returns (uint256 newWeight, bool shouldCheckpoint) {
        return GoalFlowLedgerMode.prepareCheckpointContextView(_strategiesMemory(), _cache, ledger, account, expectedFlow);
    }

    function prepareCheckpointContextFromCommittedWeight(
        address ledger,
        uint256 committedWeight,
        address expectedFlow
    ) external returns (uint256 resolvedWeight, bool shouldCheckpoint) {
        return
            GoalFlowLedgerMode.prepareCheckpointContextFromCommittedWeight(
                _strategiesMemory(),
                _cache,
                ledger,
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

    function _strategiesMemory() private view returns (IAllocationStrategy[] memory strategies) {
        uint256 count = _strategies.length;
        strategies = new IAllocationStrategy[](count);
        for (uint256 i = 0; i < count; ) {
            strategies[i] = _strategies[i];
            unchecked {
                ++i;
            }
        }
    }
}
