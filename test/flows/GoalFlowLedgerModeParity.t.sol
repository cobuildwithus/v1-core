// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { GoalFlowLedgerModeHarness } from "test/harness/GoalFlowLedgerModeHarness.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { FlowUnitMath } from "src/library/FlowUnitMath.sol";

contract GoalFlowLedgerModeParityTest is Test {
    uint256 internal constant PPM_SCALE = FlowProtocolConstants.PPM_SCALE_UINT256;
    uint256 internal constant POOL_SIZE = 12;
    uint256 internal constant UNIT_WEIGHT_SCALE = 1e15;

    GoalFlowLedgerModeHarness internal harness;
    GoalFlowLedgerModeParityLedger internal ledger;

    function setUp() public {
        harness = new GoalFlowLedgerModeHarness();
        ledger = new GoalFlowLedgerModeParityLedger();
    }

    function testFuzz_detectBudgetDeltas_calldataExpectedReference(
        uint256 prevWeight,
        uint256 newWeight,
        uint16 prevMask,
        uint16 newMask,
        uint16 budgetMask,
        uint16 budgetClassMask,
        uint256 prevPpmSeed,
        uint256 newPpmSeed
    ) public {
        bytes32[] memory pool = _idPool();
        bytes32[] memory prevRecipientIds = _selectIds(pool, prevMask);
        bytes32[] memory newRecipientIds = _selectIds(pool, newMask);
        uint32[] memory prevAllocationPpm = _buildAllocationPpm(prevRecipientIds.length, prevPpmSeed);
        uint32[] memory newAllocationPpm = _buildAllocationPpm(newRecipientIds.length, newPpmSeed);

        _seedBudgets(pool, budgetMask, budgetClassMask);
        _detectAndAssertReference(prevWeight, prevRecipientIds, prevAllocationPpm, newWeight, newRecipientIds, newAllocationPpm);
    }

    function test_detectBudgetDeltas_addRecipientBranch_reportsOnlyAddedBudget() public {
        bytes32 idA = bytes32(uint256(1));
        bytes32 idB = bytes32(uint256(2));
        address budgetA = address(0xB001);
        address budgetB = address(0xB002);

        ledger.setBudget(idA, budgetA);
        ledger.setBudget(idB, budgetB);

        bytes32[] memory prevRecipientIds = new bytes32[](1);
        prevRecipientIds[0] = idA;

        uint32[] memory prevAllocationPpm = new uint32[](1);
        prevAllocationPpm[0] = 200_000;

        bytes32[] memory newRecipientIds = new bytes32[](2);
        newRecipientIds[0] = idA;
        newRecipientIds[1] = idB;

        uint32[] memory newAllocationPpm = new uint32[](2);
        newAllocationPpm[0] = 200_000;
        newAllocationPpm[1] = 300_000;

        uint256 weight = 10 * UNIT_WEIGHT_SCALE;
        address[] memory deltas = _detectAndAssertReference(weight, prevRecipientIds, prevAllocationPpm, weight, newRecipientIds, newAllocationPpm);
        _assertSingleDelta(deltas, budgetB);
    }

    function test_detectBudgetDeltas_addRecipientBranch_roundingToZeroEmitsNoDelta() public {
        bytes32 idA = bytes32(uint256(1));
        ledger.setBudget(idA, address(0xB001));

        bytes32[] memory prevRecipientIds = new bytes32[](0);
        uint32[] memory prevAllocationPpm = new uint32[](0);

        bytes32[] memory newRecipientIds = new bytes32[](1);
        newRecipientIds[0] = idA;

        uint32[] memory newAllocationPpm = new uint32[](1);
        newAllocationPpm[0] = 333_333;

        address[] memory deltas = _detectAndAssertReference(0, prevRecipientIds, prevAllocationPpm, 3, newRecipientIds, newAllocationPpm);
        _assertNoDelta(deltas);
    }

    function test_detectBudgetDeltas_removeRecipientBranch_reportsRemovedBudget() public {
        bytes32 idA = bytes32(uint256(1));
        bytes32 idB = bytes32(uint256(2));
        address budgetA = address(0xB001);
        address budgetB = address(0xB002);

        ledger.setBudget(idA, budgetA);
        ledger.setBudget(idB, budgetB);

        bytes32[] memory prevRecipientIds = new bytes32[](2);
        prevRecipientIds[0] = idA;
        prevRecipientIds[1] = idB;

        uint32[] memory prevAllocationPpm = new uint32[](2);
        prevAllocationPpm[0] = 250_000;
        prevAllocationPpm[1] = 750_000;

        bytes32[] memory newRecipientIds = new bytes32[](1);
        newRecipientIds[0] = idB;

        uint32[] memory newAllocationPpm = new uint32[](1);
        newAllocationPpm[0] = 750_000;

        uint256 weight = 10 * UNIT_WEIGHT_SCALE;
        address[] memory deltas = _detectAndAssertReference(weight, prevRecipientIds, prevAllocationPpm, weight, newRecipientIds, newAllocationPpm);
        _assertSingleDelta(deltas, budgetA);
    }

    function test_detectBudgetDeltas_removeRecipientBranch_roundingToZeroEmitsNoDelta() public {
        bytes32 idA = bytes32(uint256(1));
        ledger.setBudget(idA, address(0xB001));

        bytes32[] memory prevRecipientIds = new bytes32[](1);
        prevRecipientIds[0] = idA;

        uint32[] memory prevAllocationPpm = new uint32[](1);
        prevAllocationPpm[0] = 333_333;

        bytes32[] memory newRecipientIds = new bytes32[](0);
        uint32[] memory newAllocationPpm = new uint32[](0);

        address[] memory deltas = _detectAndAssertReference(3, prevRecipientIds, prevAllocationPpm, 0, newRecipientIds, newAllocationPpm);
        _assertNoDelta(deltas);
    }

    function test_detectBudgetDeltas_roundingKeepsMulDivUnchanged_emitsNoDelta() public {
        bytes32 idA = bytes32(uint256(1));
        ledger.setBudget(idA, address(0xB001));

        bytes32[] memory prevRecipientIds = new bytes32[](1);
        prevRecipientIds[0] = idA;

        uint32[] memory prevAllocationPpm = new uint32[](1);
        prevAllocationPpm[0] = 100_001;

        bytes32[] memory newRecipientIds = new bytes32[](1);
        newRecipientIds[0] = idA;

        uint32[] memory newAllocationPpm = new uint32[](1);
        newAllocationPpm[0] = 100_000;

        address[] memory deltas = _detectAndAssertReference(10, prevRecipientIds, prevAllocationPpm, 11, newRecipientIds, newAllocationPpm);
        _assertNoDelta(deltas);
    }

    function test_detectBudgetDeltas_roundsRawAllocatedToUnitScale_emitsNoDelta() public {
        bytes32 idA = bytes32(uint256(1));
        ledger.setBudget(idA, address(0xB001));

        bytes32[] memory prevRecipientIds = new bytes32[](1);
        prevRecipientIds[0] = idA;

        uint32[] memory prevAllocationPpm = new uint32[](1);
        prevAllocationPpm[0] = 1_000_000;

        bytes32[] memory newRecipientIds = new bytes32[](1);
        newRecipientIds[0] = idA;

        uint32[] memory newAllocationPpm = new uint32[](1);
        newAllocationPpm[0] = 1_000_000;

        // Raw allocated changes from 1 to 999_999_999_999_999, but both quantize to zero effective stake.
        address[] memory deltas =
            _detectAndAssertReference(1, prevRecipientIds, prevAllocationPpm, UNIT_WEIGHT_SCALE - 1, newRecipientIds, newAllocationPpm);
        _assertNoDelta(deltas);
    }

    function test_detectBudgetDeltas_prioritizesDecreasesBeforeIncreases() public {
        bytes32 idA = bytes32(uint256(1));
        bytes32 idB = bytes32(uint256(2));
        address budgetA = address(0xB001);
        address budgetB = address(0xB002);

        ledger.setBudget(idA, budgetA);
        ledger.setBudget(idB, budgetB);

        bytes32[] memory prevRecipientIds = new bytes32[](2);
        prevRecipientIds[0] = idA;
        prevRecipientIds[1] = idB;

        uint32[] memory prevAllocationPpm = new uint32[](2);
        prevAllocationPpm[0] = 300_000; // increases
        prevAllocationPpm[1] = 700_000; // decreases

        bytes32[] memory newRecipientIds = new bytes32[](2);
        newRecipientIds[0] = idA;
        newRecipientIds[1] = idB;

        uint32[] memory newAllocationPpm = new uint32[](2);
        newAllocationPpm[0] = 600_000;
        newAllocationPpm[1] = 400_000;

        uint256 weight = 100 * UNIT_WEIGHT_SCALE;
        address[] memory deltas = _detectAndAssertReference(
            weight,
            prevRecipientIds,
            prevAllocationPpm,
            weight,
            newRecipientIds,
            newAllocationPpm
        );

        assertEq(deltas.length, 2);
        // idA sorts before idB, but idB decreases while idA increases.
        assertEq(deltas[0], budgetB);
        assertEq(deltas[1], budgetA);
    }

    function test_detectBudgetDeltas_preservesStableOrderWithinDecreaseAndIncreaseBuckets() public {
        bytes32 idA = bytes32(uint256(1));
        bytes32 idB = bytes32(uint256(2));
        bytes32 idC = bytes32(uint256(3));
        bytes32 idD = bytes32(uint256(4));

        address budgetA = address(0xB001);
        address budgetB = address(0xB002);
        address budgetC = address(0xB003);
        address budgetD = address(0xB004);

        ledger.setBudget(idA, budgetA);
        ledger.setBudget(idB, budgetB);
        ledger.setBudget(idC, budgetC);
        ledger.setBudget(idD, budgetD);

        bytes32[] memory prevRecipientIds = new bytes32[](4);
        prevRecipientIds[0] = idA;
        prevRecipientIds[1] = idB;
        prevRecipientIds[2] = idC;
        prevRecipientIds[3] = idD;

        uint32[] memory prevAllocationPpm = new uint32[](4);
        prevAllocationPpm[0] = 250_000; // increase
        prevAllocationPpm[1] = 250_000; // decrease
        prevAllocationPpm[2] = 250_000; // increase
        prevAllocationPpm[3] = 250_000; // decrease

        bytes32[] memory newRecipientIds = new bytes32[](4);
        newRecipientIds[0] = idA;
        newRecipientIds[1] = idB;
        newRecipientIds[2] = idC;
        newRecipientIds[3] = idD;

        uint32[] memory newAllocationPpm = new uint32[](4);
        newAllocationPpm[0] = 300_000;
        newAllocationPpm[1] = 200_000;
        newAllocationPpm[2] = 350_000;
        newAllocationPpm[3] = 150_000;

        uint256 weight = 100 * UNIT_WEIGHT_SCALE;
        address[] memory deltas = _detectAndAssertReference(
            weight,
            prevRecipientIds,
            prevAllocationPpm,
            weight,
            newRecipientIds,
            newAllocationPpm
        );

        assertEq(deltas.length, 4);
        // Decreases first (idB then idD), then increases (idA then idC).
        assertEq(deltas[0], budgetB);
        assertEq(deltas[1], budgetD);
        assertEq(deltas[2], budgetA);
        assertEq(deltas[3], budgetC);
    }

    function testFuzz_unitQuantization_poolUnitsAndLedgerStakeStayAligned(
        uint256 weight,
        uint32 allocationPpm
    ) public pure {
        allocationPpm = uint32(bound(uint256(allocationPpm), 0, PPM_SCALE));

        uint256 weighted = FlowUnitMath.weightedAllocation(weight, allocationPpm, PPM_SCALE);
        uint256 units = FlowUnitMath.poolUnitsFromScaledAllocation(weight, allocationPpm, PPM_SCALE);
        uint256 allocated = FlowUnitMath.effectiveAllocatedStake(weight, allocationPpm, PPM_SCALE);

        assertEq(allocated, units * UNIT_WEIGHT_SCALE);
        assertEq(allocated, FlowUnitMath.floorToUnitWeightScale(weighted));
        assertEq(weighted - allocated, weighted % UNIT_WEIGHT_SCALE);
    }

    function testFuzz_flowUnitMath_matchesCanonicalMulDivFlooring(
        uint256 weight,
        uint32 allocationPpm
    ) public pure {
        allocationPpm = uint32(bound(uint256(allocationPpm), 0, PPM_SCALE));

        uint256 expectedWeighted = Math.mulDiv(weight, allocationPpm, PPM_SCALE);
        uint256 expectedUnits = expectedWeighted / UNIT_WEIGHT_SCALE;
        uint256 expectedAllocated = expectedUnits * UNIT_WEIGHT_SCALE;

        assertEq(FlowUnitMath.weightedAllocation(weight, allocationPpm, PPM_SCALE), expectedWeighted);
        assertEq(FlowUnitMath.poolUnitsFromScaledAllocation(weight, allocationPpm, PPM_SCALE), expectedUnits);
        assertEq(FlowUnitMath.effectiveAllocatedStake(weight, allocationPpm, PPM_SCALE), expectedAllocated);
        assertEq(FlowUnitMath.floorToUnitWeightScale(expectedWeighted), expectedAllocated);
    }

    function _detectAndAssertReference(
        uint256 prevWeight,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationPpm,
        uint256 newWeight,
        bytes32[] memory newRecipientIds,
        uint32[] memory newAllocationPpm
    ) internal view returns (address[] memory fromCalldata) {
        GoalFlowLedgerModeHarness.DetectParams memory params = GoalFlowLedgerModeHarness.DetectParams({
            allocationScalePpm: PPM_SCALE,
            ledger: address(ledger),
            prevWeight: prevWeight,
            newWeight: newWeight,
            prevRecipientIds: prevRecipientIds,
            prevAllocationPpm: prevAllocationPpm,
            newRecipientIds: newRecipientIds,
            newAllocationPpm: newAllocationPpm
        });
        fromCalldata = harness.detectCalldata(params);
        _assertExpectedDeltas(fromCalldata, prevWeight, prevRecipientIds, prevAllocationPpm, newWeight, newRecipientIds, newAllocationPpm);
    }

    function _assertSingleDelta(address[] memory deltas, address expectedBudget) internal pure {
        assertEq(deltas.length, 1);
        assertEq(deltas[0], expectedBudget);
    }

    function _assertNoDelta(address[] memory deltas) internal pure {
        assertEq(deltas.length, 0);
    }

    function _assertExpectedDeltas(
        address[] memory actual,
        uint256 prevWeight,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationPpm,
        uint256 newWeight,
        bytes32[] memory newRecipientIds,
        uint32[] memory newAllocationPpm
    ) internal view {
        address[] memory expected = _expectedBudgetDeltas(prevWeight, prevRecipientIds, prevAllocationPpm, newWeight, newRecipientIds, newAllocationPpm);
        assertEq(actual.length, expected.length);
        for (uint256 i = 0; i < actual.length; ) {
            assertEq(actual[i], expected[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _expectedBudgetDeltas(
        uint256 prevWeight,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationPpm,
        uint256 newWeight,
        bytes32[] memory newRecipientIds,
        uint32[] memory newAllocationPpm
    ) internal view returns (address[] memory deltas) {
        uint256 oldLen = prevRecipientIds.length;
        uint256 newLen = newRecipientIds.length;
        address[] memory tmpBudgets = new address[](oldLen + newLen);
        bool[] memory tmpIsDecrease = new bool[](oldLen + newLen);
        uint256 count;
        uint256 oldIndex;
        uint256 newIndex;
        while (oldIndex < oldLen || newIndex < newLen) {
            bytes32 recipientId;
            uint256 oldAllocated;
            uint256 newAllocated;

            if (newIndex >= newLen || (oldIndex < oldLen && uint256(prevRecipientIds[oldIndex]) < uint256(newRecipientIds[newIndex]))) {
                recipientId = prevRecipientIds[oldIndex];
                oldAllocated = _allocatedStakeFromPpm(prevWeight, prevAllocationPpm[oldIndex]);
                unchecked {
                    ++oldIndex;
                }
            } else if (oldIndex >= oldLen || uint256(newRecipientIds[newIndex]) < uint256(prevRecipientIds[oldIndex])) {
                recipientId = newRecipientIds[newIndex];
                newAllocated = _allocatedStakeFromPpm(newWeight, newAllocationPpm[newIndex]);
                unchecked {
                    ++newIndex;
                }
            } else {
                recipientId = prevRecipientIds[oldIndex];
                oldAllocated = _allocatedStakeFromPpm(prevWeight, prevAllocationPpm[oldIndex]);
                newAllocated = _allocatedStakeFromPpm(newWeight, newAllocationPpm[newIndex]);
                unchecked {
                    ++oldIndex;
                    ++newIndex;
                }
            }

            if (oldAllocated == newAllocated) continue;
            address budget = ledger.budgetForRecipient(recipientId);
            if (budget == address(0)) continue;

            bool isDecrease = newAllocated < oldAllocated;
            tmpBudgets[count] = budget;
            tmpIsDecrease[count] = isDecrease;
            unchecked {
                ++count;
            }
        }

        deltas = new address[](count);
        uint256 writeIndex;
        for (uint256 i = 0; i < count; ) {
            if (!tmpIsDecrease[i]) {
                unchecked {
                    ++i;
                }
                continue;
            }
            deltas[writeIndex] = tmpBudgets[i];
            unchecked {
                ++writeIndex;
                ++i;
            }
        }
        for (uint256 i = 0; i < count; ) {
            if (tmpIsDecrease[i]) {
                unchecked {
                    ++i;
                }
                continue;
            }
            deltas[writeIndex] = tmpBudgets[i];
            unchecked {
                ++writeIndex;
                ++i;
            }
        }
    }

    function _allocatedStakeFromPpm(uint256 weight, uint32 allocationPpm) internal pure returns (uint256) {
        return FlowUnitMath.effectiveAllocatedStake(weight, allocationPpm, PPM_SCALE);
    }

    function _idPool() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](POOL_SIZE);
        for (uint256 i = 0; i < POOL_SIZE; ) {
            ids[i] = bytes32(i + 1);
            unchecked {
                ++i;
            }
        }
    }

    function _selectIds(bytes32[] memory pool, uint16 mask) internal pure returns (bytes32[] memory selected) {
        uint256 count;
        for (uint256 i = 0; i < POOL_SIZE; ) {
            if ((mask & (uint16(1) << i)) != 0) {
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }

        selected = new bytes32[](count);
        uint256 index;
        for (uint256 i = 0; i < POOL_SIZE; ) {
            if ((mask & (uint16(1) << i)) != 0) {
                selected[index] = pool[i];
                unchecked {
                    ++index;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _buildAllocationPpm(uint256 length, uint256 seed) internal pure returns (uint32[] memory allocationPpm) {
        allocationPpm = new uint32[](length);
        for (uint256 i = 0; i < length; ) {
            allocationPpm[i] = uint32(uint256(keccak256(abi.encode(seed, i))) % PPM_SCALE);
            unchecked {
                ++i;
            }
        }
    }

    function _seedBudgets(bytes32[] memory pool, uint16 budgetMask, uint16 budgetClassMask) internal {
        for (uint256 i = 0; i < POOL_SIZE; ) {
            bytes32 recipientId = pool[i];
            address budget = address(0);
            if ((budgetMask & (uint16(1) << i)) != 0) {
                if ((budgetClassMask & (uint16(1) << i)) == 0) {
                    budget = address(uint160(0xB000 + i + 1));
                } else {
                    budget = address(uint160(0xC000 + (i % 3) + 1));
                }
            }
            ledger.setBudget(recipientId, budget);
            unchecked {
                ++i;
            }
        }
    }
}

contract GoalFlowLedgerModeParityLedger {
    mapping(bytes32 => address) internal _budgetByRecipient;

    function setBudget(bytes32 recipientId, address budgetTreasury) external {
        _budgetByRecipient[recipientId] = budgetTreasury;
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetByRecipient[recipientId];
    }
}
