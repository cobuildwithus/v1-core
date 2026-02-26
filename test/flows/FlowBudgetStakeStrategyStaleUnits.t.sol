// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowAllocationsBase } from "test/flows/FlowAllocations.t.sol";
import { BudgetStakeStrategy } from "test/harness/BudgetStakeStrategy.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";

contract FlowBudgetStakeStrategyStaleUnitsTest is FlowAllocationsBase {
    bytes32 internal constant RECIPIENT_ID = bytes32(uint256(1));
    address internal constant RECIPIENT = address(0x1111);

    FlowBudgetStakeMockLedger internal ledger;
    FlowBudgetStakeMockTreasury internal budgetTreasury;
    BudgetStakeStrategy internal budgetStrategy;

    function setUp() public override {
        super.setUp();

        ledger = new FlowBudgetStakeMockLedger();
        budgetTreasury = new FlowBudgetStakeMockTreasury();
        budgetStrategy = new BudgetStakeStrategy(IBudgetStakeLedger(address(ledger)), RECIPIENT_ID);
        ledger.setBudget(RECIPIENT_ID, address(budgetTreasury));

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(budgetStrategy));
        flow = _deployFlowWithStrategies(strategies);

        _addRecipient(RECIPIENT_ID, RECIPIENT);
    }

    function test_weightDropToZero_permissionlessClearRemovesStaleUnits() public {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = RECIPIENT_ID;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        bytes[][] memory allocationData = _allocationData();
        uint256 key = uint256(uint160(allocator));

        uint256 initialWeight = 12e24;
        ledger.setAllocatedStake(allocator, address(budgetTreasury), initialWeight);

        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            address(budgetStrategy),
            address(flow),
            recipientIds,
            scaled
        );

        uint128 unitsAfterInitialAllocation = flow.distributionPool().getUnits(RECIPIENT);
        assertEq(unitsAfterInitialAllocation, _units(initialWeight, 1_000_000));

        bytes32 initialCommit = flow.getAllocationCommitment(address(budgetStrategy), key);
        assertTrue(initialCommit != bytes32(0));

        ledger.setAllocatedStake(allocator, address(budgetTreasury), 0);

        vm.prank(other);
        flow.clearStaleAllocation(address(budgetStrategy), key);

        assertEq(flow.distributionPool().getUnits(RECIPIENT), uint128(0));

        bytes32 clearedCommit = flow.getAllocationCommitment(address(budgetStrategy), key);
        assertTrue(clearedCommit != bytes32(0));
        assertEq(clearedCommit, initialCommit);
        assertEq(clearedCommit, keccak256(abi.encode(recipientIds, scaled)));
    }

    function test_weightDecreaseNonZero_unitsRemainStaleUntilAllocatorUpdates() public {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = RECIPIENT_ID;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        bytes[][] memory allocationData = _allocationData();
        uint256 key = uint256(uint160(allocator));

        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;
        ledger.setAllocatedStake(allocator, address(budgetTreasury), initialWeight);

        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            address(budgetStrategy),
            address(flow),
            recipientIds,
            scaled
        );

        uint128 expectedInitialUnits = _units(initialWeight, 1_000_000);
        assertEq(flow.distributionPool().getUnits(RECIPIENT), expectedInitialUnits);

        // Dropping stake without calling allocate leaves previously committed units in place.
        ledger.setAllocatedStake(allocator, address(budgetTreasury), reducedWeight);
        assertEq(flow.distributionPool().getUnits(RECIPIENT), expectedInitialUnits);

        vm.expectRevert(abi.encodeWithSelector(CustomFlow.STALE_CLEAR_WEIGHT_NOT_ZERO.selector, reducedWeight));
        vm.prank(other);
        flow.clearStaleAllocation(address(budgetStrategy), key);

        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            address(budgetStrategy),
            address(flow),
            recipientIds,
            scaled
        );

        assertEq(flow.distributionPool().getUnits(RECIPIENT), _units(reducedWeight, 1_000_000));
    }

    function test_weightDecreaseNonZero_permissionlessSyncUpdatesUnits() public {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = RECIPIENT_ID;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        bytes[][] memory allocationData = _allocationData();
        uint256 key = uint256(uint160(allocator));

        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;
        ledger.setAllocatedStake(allocator, address(budgetTreasury), initialWeight);

        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            address(budgetStrategy),
            address(flow),
            recipientIds,
            scaled
        );

        uint128 expectedInitialUnits = _units(initialWeight, 1_000_000);
        assertEq(flow.distributionPool().getUnits(RECIPIENT), expectedInitialUnits);

        ledger.setAllocatedStake(allocator, address(budgetTreasury), reducedWeight);
        bytes32 commitBeforeSync = flow.getAllocationCommitment(address(budgetStrategy), key);

        vm.prank(other);
        flow.syncAllocation(address(budgetStrategy), key);

        assertEq(flow.distributionPool().getUnits(RECIPIENT), _units(reducedWeight, 1_000_000));
        bytes32 commitAfterSync = flow.getAllocationCommitment(address(budgetStrategy), key);
        assertEq(commitAfterSync, commitBeforeSync);
        assertEq(commitAfterSync, keccak256(abi.encode(recipientIds, scaled)));
    }

    function test_syncAllocation_revertsWhenNoExistingCommitment() public {
        vm.expectRevert(CustomFlow.STALE_CLEAR_NO_COMMITMENT.selector);
        vm.prank(other);
        flow.syncAllocation(address(budgetStrategy), uint256(uint160(allocator)));
    }

    function test_syncAllocation_usesCachedWeightForUnitRecompute() public {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = RECIPIENT_ID;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        bytes[][] memory allocationData = _allocationData();
        uint256 key = uint256(uint160(allocator));

        uint256 initialWeight = 12e24;
        uint256 reducedWeight = 3e24;
        ledger.setAllocatedStake(allocator, address(budgetTreasury), initialWeight);

        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            address(budgetStrategy),
            address(flow),
            recipientIds,
            scaled
        );

        ledger.setAllocatedStake(allocator, address(budgetTreasury), reducedWeight);

        vm.prank(other);
        flow.syncAllocation(address(budgetStrategy), key);

        assertEq(flow.distributionPool().getUnits(RECIPIENT), _units(reducedWeight, 1_000_000));
        assertEq(flow.getAllocationCommitment(address(budgetStrategy), key), keccak256(abi.encode(recipientIds, scaled)));
    }

    function test_clearStaleAllocation_revertsWhenWeightNotZero() public {
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = RECIPIENT_ID;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        bytes[][] memory allocationData = _allocationData();
        uint256 key = uint256(uint160(allocator));

        uint256 initialWeight = 12e24;
        ledger.setAllocatedStake(allocator, address(budgetTreasury), initialWeight);

        _allocateWithPrevStateForStrategy(
            allocator,
            allocationData,
            address(budgetStrategy),
            address(flow),
            recipientIds,
            scaled
        );

        vm.expectRevert(abi.encodeWithSelector(CustomFlow.STALE_CLEAR_WEIGHT_NOT_ZERO.selector, initialWeight));
        vm.prank(other);
        flow.clearStaleAllocation(address(budgetStrategy), key);
    }

    function test_clearStaleAllocation_revertsWhenNoExistingCommitment() public {
        vm.expectRevert(CustomFlow.STALE_CLEAR_NO_COMMITMENT.selector);
        vm.prank(other);
        flow.clearStaleAllocation(address(budgetStrategy), uint256(uint160(allocator)));
    }

    function _allocationData() internal pure returns (bytes[][] memory data) {
        data = new bytes[][](1);
        data[0] = new bytes[](1);
        data[0][0] = "";
    }
}

contract FlowBudgetStakeMockLedger {
    mapping(bytes32 => address) internal _budgetByRecipient;
    mapping(address => mapping(address => uint256)) internal _allocatedStake;

    function setBudget(bytes32 recipientId, address budget) external {
        _budgetByRecipient[recipientId] = budget;
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetByRecipient[recipientId];
    }

    function setAllocatedStake(address account, address budget, uint256 amount) external {
        _allocatedStake[account][budget] = amount;
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256) {
        return _allocatedStake[account][budget];
    }
}

contract FlowBudgetStakeMockTreasury {
    bool public resolved;

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}
