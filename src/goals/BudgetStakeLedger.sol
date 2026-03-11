// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IBudgetStackTopologyReader } from "../interfaces/IBudgetStackTopologyReader.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { FlowUnitMath } from "../library/FlowUnitMath.sol";
import { FlowProtocolConstants } from "../library/FlowProtocolConstants.sol";
import { SortedRecipientMerge } from "../library/SortedRecipientMerge.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract BudgetStakeLedger is IBudgetStakeLedger, Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Checkpoints for Checkpoints.Trace224;

    struct UserBudgetCheckpoint {
        uint64 lastCheckpoint;
    }

    struct BudgetCheckpoint {
        uint256 totalAllocatedStake;
        uint64 lastCheckpoint;
    }

    struct BudgetInfo {
        bool isTracked;
        uint64 removedAt;
        uint64 activatedAt;
    }

    struct BudgetDeltaBuckets {
        address[] decreases;
        address[] increases;
        uint256 decreaseCount;
        uint256 increaseCount;
    }

    struct MergeOrderState {
        bytes32 lastRecipientId;
        bool hasLastRecipientId;
    }

    address public override goalTreasury;

    mapping(address => mapping(address => UserBudgetCheckpoint)) private _userBudgetCheckpoints;
    mapping(address => BudgetCheckpoint) private _budgetCheckpoints;
    mapping(address => BudgetInfo) private _budgetInfo;
    mapping(bytes32 => address) private _budgetByRecipientId;
    mapping(address => uint256) private _registeredBudgetIndexPlusOne;

    EnumerableSet.AddressSet private _trackedBudgets;
    address[] private _registeredBudgets;
    mapping(address => mapping(address => Checkpoints.Trace224)) private _userAllocatedStakeCheckpoints;
    mapping(address => Checkpoints.Trace224) private _userAllocationWeightCheckpoints;

    constructor(address goalTreasury_) {
        _initialize(goalTreasury_);
        _disableInitializers();
    }

    function initialize(address goalTreasury_) external initializer {
        _initialize(goalTreasury_);
    }

    function _initialize(address goalTreasury_) private {
        if (goalTreasury_ == address(0)) revert ADDRESS_ZERO();
        goalTreasury = goalTreasury_;
    }

    function getPastUserAllocatedStakeOnBudget(
        address account,
        address budget,
        uint256 blockNumber
    ) external view override returns (uint256) {
        if (blockNumber >= block.number) revert BLOCK_NOT_YET_MINED();
        return _userAllocatedStakeCheckpoints[account][budget].upperLookupRecent(SafeCast.toUint32(blockNumber));
    }

    function getPastUserAllocationWeight(
        address account,
        uint256 blockNumber
    ) external view override returns (uint256) {
        if (blockNumber >= block.number) revert BLOCK_NOT_YET_MINED();
        return _userAllocationWeightCheckpoints[account].upperLookupRecent(SafeCast.toUint32(blockNumber));
    }

    /// @notice Restricts calls to the goal flow or that flow's configured allocation pipeline.
    modifier onlyGoalFlowOrPipeline() {
        address goalFlow = _requireGoalFlow();
        if (msg.sender != goalFlow && msg.sender != IFlow(goalFlow).allocationPipeline()) {
            revert ONLY_GOAL_FLOW_OR_PIPELINE();
        }
        _;
    }

    modifier onlyBudgetRegistryManager() {
        if (msg.sender != IFlow(_requireGoalFlow()).recipientAdmin()) revert ONLY_BUDGET_REGISTRY_MANAGER();
        _;
    }

    function checkpointAllocation(
        address account,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external override onlyGoalFlowOrPipeline returns (address[] memory changedBudgetTreasuries) {
        if (IGoalTreasury(goalTreasury).resolved()) return new address[](0);
        if (account == address(0)) revert ADDRESS_ZERO();
        if (prevRecipientIds.length != prevAllocationPpm.length) revert INVALID_CHECKPOINT_DATA();
        if (newRecipientIds.length != newAllocationPpm.length) revert INVALID_CHECKPOINT_DATA();

        if (prevWeight != newWeight) {
            _userAllocationWeightCheckpoints[account].push(
                SafeCast.toUint32(block.number),
                SafeCast.toUint224(newWeight)
            );
        }
        changedBudgetTreasuries = _checkpointAllocationCalldata(
            account,
            prevWeight,
            prevRecipientIds,
            prevAllocationPpm,
            newWeight,
            newRecipientIds,
            newAllocationPpm,
            uint64(block.timestamp)
        );
    }

    function previewChangedBudgetTreasuries(
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) external view override returns (address[] memory changedBudgetTreasuries) {
        if (IGoalTreasury(goalTreasury).resolved()) return new address[](0);
        if (prevRecipientIds.length != prevAllocationPpm.length) {
            revert INVALID_CHECKPOINT_DATA();
        }
        if (newRecipientIds.length != newAllocationPpm.length) revert INVALID_CHECKPOINT_DATA();
        return
            _previewChangedBudgetTreasuriesCalldata(
                prevWeight,
                prevRecipientIds,
                prevAllocationPpm,
                newWeight,
                newRecipientIds,
                newAllocationPpm
            );
    }

    function registerBudget(bytes32 recipientId, address budget) external override onlyBudgetRegistryManager {
        if (budget == address(0)) revert ADDRESS_ZERO();
        if (IGoalTreasury(goalTreasury).resolved()) revert GOAL_TERMINAL();
        uint64 activatedAt = _validateBudgetForRegistration(recipientId, budget);

        address existing = _budgetByRecipientId[recipientId];
        if (existing != address(0)) {
            if (existing != budget) revert BUDGET_ALREADY_REGISTERED();
            return;
        }
        BudgetInfo storage info = _budgetInfo[budget];
        if (info.isTracked) revert BUDGET_ALREADY_REGISTERED();

        if (_registeredBudgetIndexPlusOne[budget] == 0) {
            _registeredBudgets.push(budget);
            _registeredBudgetIndexPlusOne[budget] = _registeredBudgets.length;
        }

        _budgetByRecipientId[recipientId] = budget;
        info.isTracked = true;
        if (info.removedAt != 0) info.removedAt = 0;
        if (activatedAt != 0) info.activatedAt = activatedAt;
        _trackedBudgets.add(budget);

        emit BudgetRegistered(recipientId, budget);
    }

    function removeBudget(bytes32 recipientId) external override onlyBudgetRegistryManager {
        address budget = _budgetByRecipientId[recipientId];
        if (budget == address(0)) return;

        delete _budgetByRecipientId[recipientId];
        BudgetInfo storage info = _budgetInfo[budget];
        if (info.removedAt == 0) {
            info.removedAt = uint64(block.timestamp);
        }
        info.isTracked = false;
        _trackedBudgets.remove(budget);
        emit BudgetRemoved(recipientId, budget);
    }

    function budgetForRecipient(bytes32 recipientId) external view override returns (address) {
        return _budgetByRecipientId[recipientId];
    }

    function trackedBudgetCount() external view override returns (uint256) {
        return _trackedBudgets.length();
    }

    function allTrackedBudgetsResolved() external view override returns (bool) {
        uint256 trackedCount = _trackedBudgets.length();
        for (uint256 i = 0; i < trackedCount; ) {
            if (_effectiveBudgetResolvedOrRemovedAt(_trackedBudgets.at(i)) == 0) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function trackedBudgetAt(uint256 index) external view override returns (address) {
        return _trackedBudgets.at(index);
    }

    function registeredBudgetCount() external view override returns (uint256) {
        return _registeredBudgets.length;
    }

    function registeredBudgetAt(uint256 index) external view override returns (address) {
        return _registeredBudgets[index];
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view override returns (uint256) {
        return _currentUserAllocatedStake(account, budget);
    }

    function budgetTotalAllocatedStake(address budget) external view override returns (uint256) {
        return _budgetCheckpoints[budget].totalAllocatedStake;
    }

    function budgetInfo(address budget) external view override returns (BudgetInfoView memory info) {
        BudgetInfo storage budgetInfo_ = _budgetInfo[budget];
        info.isTracked = budgetInfo_.isTracked;
        info.removedAt = budgetInfo_.removedAt;
        info.activatedAt = _activatedAtForBudgetInfo(budget, budgetInfo_);
        info.resolvedOrRemovedAt = _effectiveBudgetResolvedOrRemovedAt(budget);
    }

    function userBudgetCheckpoint(
        address account,
        address budget
    ) external view override returns (UserBudgetCheckpointView memory checkpoint) {
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];
        checkpoint.allocatedStake = _currentUserAllocatedStake(account, budget);
        checkpoint.lastCheckpoint = userCheckpoint.lastCheckpoint;
    }

    function budgetCheckpoint(address budget) external view override returns (BudgetCheckpointView memory checkpoint) {
        BudgetCheckpoint storage budgetCheckpoint_ = _budgetCheckpoints[budget];
        checkpoint.totalAllocatedStake = budgetCheckpoint_.totalAllocatedStake;
        checkpoint.lastCheckpoint = budgetCheckpoint_.lastCheckpoint;
    }

    function trackedBudgetSlice(
        uint256 start,
        uint256 count
    ) external view override returns (TrackedBudgetSummary[] memory summaries) {
        uint256 total = _trackedBudgets.length();
        if (start >= total || count == 0) return new TrackedBudgetSummary[](0);

        uint256 endExclusive = _boundedEndExclusive(start, count, total);
        uint256 length = endExclusive - start;
        summaries = new TrackedBudgetSummary[](length);

        for (uint256 i = 0; i < length; ) {
            address budget = _trackedBudgets.at(start + i);
            summaries[i] = TrackedBudgetSummary({
                budget: budget,
                resolvedOrRemovedAt: _effectiveBudgetResolvedOrRemovedAt(budget),
                totalAllocatedStake: _budgetCheckpoints[budget].totalAllocatedStake
            });
            unchecked {
                ++i;
            }
        }
    }

    function _checkpointBudgetAllocation(
        address account,
        address budget,
        uint256 oldAllocated,
        uint256 newAllocated,
        uint64 nowTs
    ) internal {
        BudgetCheckpoint storage budgetCheckpointData = _budgetCheckpoints[budget];
        UserBudgetCheckpoint storage userCheckpoint = _userBudgetCheckpoints[account][budget];

        uint256 userStoredAllocated = _currentUserAllocatedStake(account, budget);
        if (userStoredAllocated != oldAllocated) {
            revert ALLOCATION_DRIFT(account, budget, userStoredAllocated, oldAllocated);
        }

        if (newAllocated > oldAllocated) {
            budgetCheckpointData.totalAllocatedStake += newAllocated - oldAllocated;
        } else {
            uint256 allocatedDecrease = oldAllocated - newAllocated;
            uint256 totalAllocated = budgetCheckpointData.totalAllocatedStake;
            if (allocatedDecrease > totalAllocated) {
                revert TOTAL_ALLOCATED_UNDERFLOW(budget, totalAllocated, allocatedDecrease);
            }
            budgetCheckpointData.totalAllocatedStake = totalAllocated - allocatedDecrease;
        }

        userCheckpoint.lastCheckpoint = nowTs;
        budgetCheckpointData.lastCheckpoint = nowTs;

        _userAllocatedStakeCheckpoints[account][budget].push(
            SafeCast.toUint32(block.number),
            SafeCast.toUint224(newAllocated)
        );

        emit AllocationCheckpointed(account, budget, newAllocated, nowTs);
    }

    function _checkpointAllocationCalldata(
        address account,
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm,
        uint64 nowTs
    ) internal returns (address[] memory changedBudgetTreasuries) {
        if (prevRecipientIds.length == 0 && newRecipientIds.length == 0) return new address[](0);

        BudgetDeltaBuckets memory buckets = _initBudgetDeltaBuckets(prevRecipientIds.length + newRecipientIds.length);
        MergeOrderState memory orderState;

        (SortedRecipientMerge.Cursor memory mergeCursor, ) = SortedRecipientMerge.init(
            prevRecipientIds,
            newRecipientIds,
            SortedRecipientMerge.Precondition.AssumeSorted
        );

        while (SortedRecipientMerge.hasNext(mergeCursor, prevRecipientIds.length, newRecipientIds.length)) {
            (
                SortedRecipientMerge.Step memory step,
                SortedRecipientMerge.Cursor memory nextCursor
            ) = SortedRecipientMerge.next(prevRecipientIds, newRecipientIds, mergeCursor);
            mergeCursor = nextCursor;
            _assertStrictMergedOrder(step.recipientId, orderState);
            orderState.lastRecipientId = step.recipientId;
            orderState.hasLastRecipientId = true;

            address budget = _budgetByRecipientId[step.recipientId];
            if (budget == address(0)) continue;

            uint256 oldAllocated = step.hasOld
                ? _effectiveAllocatedStake(prevWeight, prevAllocationPpm[step.oldIndex])
                : 0;
            uint256 newAllocated = step.hasNew
                ? _effectiveAllocatedStake(newWeight, newAllocationPpm[step.newIndex])
                : 0;
            if (oldAllocated == newAllocated) continue;

            _checkpointBudgetAllocation(account, budget, oldAllocated, newAllocated, nowTs);
            _recordBudgetDelta(buckets, budget, oldAllocated, newAllocated);
        }

        return _mergeBudgetDeltaBuckets(buckets);
    }

    function _previewChangedBudgetTreasuriesCalldata(
        uint256 prevWeight,
        bytes32[] calldata prevRecipientIds,
        uint32[] calldata prevAllocationPpm,
        uint256 newWeight,
        bytes32[] calldata newRecipientIds,
        uint32[] calldata newAllocationPpm
    ) internal view returns (address[] memory changedBudgetTreasuries) {
        if (prevRecipientIds.length == 0 && newRecipientIds.length == 0) {
            return new address[](0);
        }

        BudgetDeltaBuckets memory buckets = _initBudgetDeltaBuckets(prevRecipientIds.length + newRecipientIds.length);
        MergeOrderState memory orderState;

        (SortedRecipientMerge.Cursor memory mergeCursor, ) = SortedRecipientMerge.init(
            prevRecipientIds,
            newRecipientIds,
            SortedRecipientMerge.Precondition.AssumeSorted
        );

        while (SortedRecipientMerge.hasNext(mergeCursor, prevRecipientIds.length, newRecipientIds.length)) {
            (
                SortedRecipientMerge.Step memory step,
                SortedRecipientMerge.Cursor memory nextCursor
            ) = SortedRecipientMerge.next(prevRecipientIds, newRecipientIds, mergeCursor);
            mergeCursor = nextCursor;
            _assertStrictMergedOrder(step.recipientId, orderState);
            orderState.lastRecipientId = step.recipientId;
            orderState.hasLastRecipientId = true;

            uint256 oldAllocated = step.hasOld
                ? _effectiveAllocatedStake(prevWeight, prevAllocationPpm[step.oldIndex])
                : 0;
            uint256 newAllocated = step.hasNew
                ? _effectiveAllocatedStake(newWeight, newAllocationPpm[step.newIndex])
                : 0;
            if (oldAllocated == newAllocated) continue;

            address budget = _budgetByRecipientId[step.recipientId];
            if (budget == address(0)) continue;
            _recordBudgetDelta(buckets, budget, oldAllocated, newAllocated);
        }

        return _mergeBudgetDeltaBuckets(buckets);
    }

    function _initBudgetDeltaBuckets(uint256 maxCount) internal pure returns (BudgetDeltaBuckets memory buckets) {
        buckets.decreases = new address[](maxCount);
        buckets.increases = new address[](maxCount);
    }

    function _assertStrictMergedOrder(bytes32 recipientId, MergeOrderState memory orderState) internal pure {
        if (orderState.hasLastRecipientId && recipientId <= orderState.lastRecipientId) {
            revert NOT_SORTED_OR_DUPLICATE();
        }
    }

    function _recordBudgetDelta(
        BudgetDeltaBuckets memory buckets,
        address budget,
        uint256 oldAllocated,
        uint256 newAllocated
    ) internal pure {
        if (newAllocated < oldAllocated) {
            buckets.decreases[buckets.decreaseCount] = budget;
            unchecked {
                ++buckets.decreaseCount;
            }
        } else {
            buckets.increases[buckets.increaseCount] = budget;
            unchecked {
                ++buckets.increaseCount;
            }
        }
    }

    function _mergeBudgetDeltaBuckets(
        BudgetDeltaBuckets memory buckets
    ) internal pure returns (address[] memory changedBudgetTreasuries) {
        uint256 totalCount = buckets.decreaseCount + buckets.increaseCount;
        changedBudgetTreasuries = new address[](totalCount);
        for (uint256 i = 0; i < buckets.decreaseCount; ) {
            changedBudgetTreasuries[i] = buckets.decreases[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < buckets.increaseCount; ) {
            changedBudgetTreasuries[buckets.decreaseCount + i] = buckets.increases[i];
            unchecked {
                ++i;
            }
        }
    }

    function _boundedEndExclusive(
        uint256 start,
        uint256 count,
        uint256 total
    ) internal pure returns (uint256 endExclusive) {
        endExclusive = start + count;
        if (endExclusive > total || endExclusive < start) {
            endExclusive = total;
        }
    }

    function _effectiveAllocatedStake(uint256 weight, uint32 allocationPpm) internal pure returns (uint256) {
        return FlowUnitMath.effectiveAllocatedStake(weight, allocationPpm, FlowProtocolConstants.PPM_SCALE_UINT256);
    }

    function _currentUserAllocatedStake(address account, address budget) internal view returns (uint256) {
        return _userAllocatedStakeCheckpoints[account][budget].latest();
    }

    function _validateBudgetForRegistration(
        bytes32 recipientId,
        address budget
    ) internal view returns (uint64 activatedAt) {
        if (budget.code.length == 0) revert INVALID_BUDGET_NOT_CONTRACT(budget);

        address goalFlow = _requireGoalFlow();
        address topologyRegistry;
        try IFlow(goalFlow).recipientAdmin() returns (address topologyRegistry_) {
            topologyRegistry = topologyRegistry_;
        } catch {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyRegistryRead);
        }
        if (topologyRegistry.code.length == 0) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyRegistry);
        }

        IBudgetTreasury budgetTreasury = IBudgetTreasury(budget);
        address treasuryAuthority;
        try budgetTreasury.authority() returns (address authority_) {
            treasuryAuthority = authority_;
        } catch {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TreasuryAuthorityRead);
        }
        if (treasuryAuthority != topologyRegistry) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TreasuryAuthorityMismatch);
        }

        IBudgetStackTopologyReader.BudgetStackTopology memory topology;
        bool active;
        try IBudgetStackTopologyReader(topologyRegistry).budgetStackTopologyForBudgetTreasury(budget) returns (
            IBudgetStackTopologyReader.BudgetStackTopology memory topology_,
            bool active_
        ) {
            topology = topology_;
            active = active_;
        } catch {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyLookup);
        }

        bytes32 topologyRecipientId;
        try IBudgetStackTopologyReader(topologyRegistry).itemIdForBudgetTreasury(budget) returns (bytes32 itemId_) {
            topologyRecipientId = itemId_;
        } catch {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyRecipientIdLookup);
        }

        if (!active) revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyInactive);
        if (topologyRecipientId != recipientId) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyRecipientIdMismatch);
        }
        if (topology.budgetTreasury != budget) {
            revert INVALID_BUDGET_TOPOLOGY(
                budget,
                IBudgetStakeLedger.BudgetTopologyProbe.TopologyBudgetTreasuryMismatch
            );
        }
        if (topology.childFlow == address(0) || topology.childFlow.code.length == 0) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyChildFlow);
        }
        if (topology.strategy == address(0) || topology.strategy.code.length == 0) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyStrategy);
        }
        address budgetFlow = _readBudgetFlow(budgetTreasury, budget);
        if (budgetFlow != topology.childFlow) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.TopologyChildFlowMismatch);
        }
        _requireBudgetFlowParent(goalFlow, budgetFlow);
        _requireChildFlowUsesExpectedStrategy(budgetFlow, topology.strategy, budget);

        if (_readExecutionDuration(budgetTreasury, budget) == 0) revert INVALID_BUDGET_EXECUTION_DURATION(budget);
        if (_readFundingDeadline(budgetTreasury, budget) == 0) revert INVALID_BUDGET_FUNDING_DEADLINE(budget);

        activatedAt = _readActivatedAt(budgetTreasury, budget);
        _requireResolvedAtReadable(budgetTreasury, budget);
        _requireStateReadable(budgetTreasury, budget);
    }

    function _readBudgetFlow(
        IBudgetTreasury budgetTreasury,
        address budget
    ) internal view returns (address budgetFlow) {
        try budgetTreasury.flow() returns (address budgetFlow_) {
            budgetFlow = budgetFlow_;
        } catch {
            revert INVALID_BUDGET_FLOW_READ(budget);
        }
        if (budgetFlow == address(0) || budgetFlow.code.length == 0) {
            revert INVALID_BUDGET_FLOW(budget, budgetFlow);
        }
    }

    function _requireBudgetFlowParent(address goalFlow, address budgetFlow) internal view {
        address parentFlow;
        try IFlow(budgetFlow).parent() returns (address parentFlow_) {
            parentFlow = parentFlow_;
        } catch {
            revert INVALID_BUDGET_PARENT_READ(budgetFlow);
        }
        if (parentFlow != goalFlow) {
            revert INVALID_BUDGET_PARENT_MISMATCH(budgetFlow, goalFlow, parentFlow);
        }
    }

    function _requireChildFlowUsesExpectedStrategy(
        address childFlow,
        address expectedStrategy,
        address budget
    ) internal view {
        address configuredStrategy;
        try IFlow(childFlow).strategy() returns (IAllocationStrategy strategy_) {
            configuredStrategy = address(strategy_);
        } catch {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.ChildFlowStrategyRead);
        }
        if (configuredStrategy != expectedStrategy) {
            revert INVALID_BUDGET_TOPOLOGY(budget, IBudgetStakeLedger.BudgetTopologyProbe.ChildFlowStrategyMismatch);
        }
    }

    function _readExecutionDuration(
        IBudgetTreasury budgetTreasury,
        address budget
    ) internal view returns (uint64 executionDuration) {
        try budgetTreasury.executionDuration() returns (uint64 executionDuration_) {
            executionDuration = executionDuration_;
        } catch {
            revert INVALID_BUDGET_EXECUTION_DURATION(budget);
        }
    }

    function _readFundingDeadline(
        IBudgetTreasury budgetTreasury,
        address budget
    ) internal view returns (uint64 fundingDeadline) {
        try budgetTreasury.fundingDeadline() returns (uint64 fundingDeadline_) {
            fundingDeadline = fundingDeadline_;
        } catch {
            revert INVALID_BUDGET_FUNDING_DEADLINE(budget);
        }
    }

    function _readActivatedAt(
        IBudgetTreasury budgetTreasury,
        address budget
    ) internal view returns (uint64 activatedAt) {
        try budgetTreasury.activatedAt() returns (uint64 activatedAt_) {
            activatedAt = activatedAt_;
        } catch {
            revert INVALID_BUDGET_ACTIVATED_AT(budget);
        }
    }

    function _requireResolvedAtReadable(IBudgetTreasury budgetTreasury, address budget) internal view {
        try budgetTreasury.resolvedAt() returns (uint64) {
            // No-op: registration only validates read-success for this field.
        } catch {
            revert INVALID_BUDGET_RESOLVED_AT(budget);
        }
    }

    function _requireStateReadable(IBudgetTreasury budgetTreasury, address budget) internal view {
        try budgetTreasury.state() returns (IBudgetTreasury.BudgetState) {
            // No-op: registration only validates read-success for this field.
        } catch {
            revert INVALID_BUDGET_STATE(budget);
        }
    }

    function _activatedAtForBudgetInfo(
        address budget,
        BudgetInfo storage info
    ) internal view returns (uint64 activatedAt) {
        activatedAt = info.activatedAt;
        if (activatedAt != 0) return activatedAt;
        return IBudgetTreasury(budget).activatedAt();
    }

    function _goalFlow() internal view returns (address goalFlow) {
        goalFlow = IGoalTreasury(goalTreasury).flow();
    }

    function _requireGoalFlow() internal view returns (address goalFlow) {
        goalFlow = _goalFlow();
        if (goalFlow == address(0) || goalFlow.code.length == 0) revert INVALID_GOAL_FLOW(goalFlow);
    }

    function _effectiveBudgetResolvedOrRemovedAt(address budget) internal view returns (uint64 resolvedOrRemovedAt) {
        BudgetInfo storage info = _budgetInfo[budget];
        uint64 removedAt = info.removedAt;
        uint64 resolvedAt = IBudgetTreasury(budget).resolvedAt();
        if (removedAt == 0) return resolvedAt;
        if (resolvedAt == 0) return removedAt;
        return removedAt < resolvedAt ? removedAt : resolvedAt;
    }
}
