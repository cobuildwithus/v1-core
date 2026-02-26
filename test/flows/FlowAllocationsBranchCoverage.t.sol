// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { FlowTypes } from "src/storage/FlowStorage.sol";
import { FlowAllocations } from "src/library/FlowAllocations.sol";
import { AllocationCommitment } from "src/library/AllocationCommitment.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { MockAllocationStrategy } from "test/mocks/MockAllocationStrategy.sol";

import { ISuperfluidPool } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";

contract FlowAllocationsCoverageHarness {
    FlowTypes.Config internal _cfg;
    FlowTypes.RecipientsState internal _recipients;
    FlowTypes.AllocationState internal _alloc;

    function configure(address pool, uint32 ppmScale) external {
        _cfg.distributionPool = ISuperfluidPool(pool);
        _cfg.ppmScale = ppmScale;
    }

    function setRecipient(bytes32 id, address recipient, bool isRemoved, uint32 recipientIndexPlusOne) external {
        _recipients.recipients[id] = FlowTypes.FlowRecipient({
            recipient: recipient,
            recipientIndexPlusOne: recipientIndexPlusOne,
            isRemoved: isRemoved,
            recipientType: FlowTypes.RecipientType.ExternalAccount,
            metadata: FlowTypes.RecipientMetadata({
                title: "",
                description: "",
                image: "",
                tagline: "",
                url: ""
            })
        });

        if (recipientIndexPlusOne != 0) {
            while (_recipients.recipientIdByIndex.length < recipientIndexPlusOne) {
                _recipients.recipientIdByIndex.push(bytes32(0));
            }
            _recipients.recipientIdByIndex[recipientIndexPlusOne - 1] = id;
        }
    }

    function setCommit(address strategy, uint256 key, bytes32 commit) external {
        _alloc.allocCommit[strategy][key] = commit;
    }

    function setWeightPlusOne(address strategy, uint256 key, uint256 weightPlusOne) external {
        _alloc.allocWeightPlusOne[strategy][key] = weightPlusOne;
    }

    function commitOf(address strategy, uint256 key) external view returns (bytes32) {
        return _alloc.allocCommit[strategy][key];
    }

    function applyMemoryUnchecked(
        address strategy,
        uint256 key,
        bytes32[] memory prevRecipientIds,
        uint32[] memory prevAllocationScaled,
        uint256 prevWeight,
        bytes32[] memory newRecipientIds,
        uint32[] memory newAllocationScaled
    ) external {
        FlowAllocations.applyAllocationWithPreviousStateMemoryUnchecked(
            _cfg,
            _recipients,
            _alloc,
            strategy,
            key,
            prevRecipientIds,
            prevAllocationScaled,
            prevWeight,
            newRecipientIds,
            newAllocationScaled
        );
    }
}

contract FlowAllocationsCoveragePool {
    mapping(address => uint128) internal _units;
    bool internal _updateOk = true;

    function setUnits(address member, uint128 units) external {
        _units[member] = units;
    }

    function setUpdateOk(bool ok) external {
        _updateOk = ok;
    }

    function getUnits(address member) external view returns (uint128) {
        return _units[member];
    }

    function updateMemberUnits(address member, uint128 units) external returns (bool) {
        if (!_updateOk) return false;
        _units[member] = units;
        return true;
    }
}

contract FlowAllocationsBranchCoverageTest is Test {
    uint32 internal constant PPM_SCALE = 1_000_000;
    uint256 internal constant ALLOCATION_KEY = 7;
    uint256 internal constant TEST_WEIGHT = 1e21;

    bytes32 internal constant ID_A = bytes32(uint256(1));
    bytes32 internal constant ID_B = bytes32(uint256(2));

    FlowAllocationsCoverageHarness internal harness;
    FlowAllocationsCoveragePool internal pool;
    MockAllocationStrategy internal strategy;

    function setUp() public {
        harness = new FlowAllocationsCoverageHarness();
        pool = new FlowAllocationsCoveragePool();
        strategy = new MockAllocationStrategy();

        harness.configure(address(pool), PPM_SCALE);
        harness.setRecipient(ID_A, makeAddr("recipient-a"), false, 1);
        harness.setRecipient(ID_B, makeAddr("recipient-b"), false, 2);

        strategy.setWeight(ALLOCATION_KEY, TEST_WEIGHT);
    }

    function test_applyMemory_brandNew_revertsWhenPrevStateProvided() public {
        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        harness.applyMemoryUnchecked(
            address(strategy),
            ALLOCATION_KEY,
            _ids(ID_A),
            _scaled(PPM_SCALE),
            TEST_WEIGHT,
            _ids(ID_A),
            _scaled(PPM_SCALE)
        );
    }

    function test_applyMemory_existing_revertsOnPrevCommitMismatch() public {
        harness.setCommit(address(strategy), ALLOCATION_KEY, AllocationCommitment.hashMemory(_ids(ID_A), _scaled(PPM_SCALE)));
        harness.setWeightPlusOne(address(strategy), ALLOCATION_KEY, 1);

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        harness.applyMemoryUnchecked(
            address(strategy),
            ALLOCATION_KEY,
            _ids(ID_B),
            _scaled(PPM_SCALE),
            TEST_WEIGHT,
            _ids(ID_A),
            _scaled(PPM_SCALE)
        );
    }

    function test_applyMemory_existing_revertsWhenCachedWeightMissing() public {
        harness.setCommit(address(strategy), ALLOCATION_KEY, AllocationCommitment.hashMemory(_ids(ID_A), _scaled(PPM_SCALE)));
        harness.setWeightPlusOne(address(strategy), ALLOCATION_KEY, 0);

        vm.expectRevert(IFlow.INVALID_PREV_ALLOCATION.selector);
        harness.applyMemoryUnchecked(
            address(strategy),
            ALLOCATION_KEY,
            _ids(ID_A),
            _scaled(PPM_SCALE),
            TEST_WEIGHT,
            _ids(ID_A),
            _scaled(PPM_SCALE)
        );
    }

    function test_applyMemory_revertsWhenNewRecipientListIsEmpty() public {
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        vm.expectRevert(IFlow.TOO_FEW_RECIPIENTS.selector);
        harness.applyMemoryUnchecked(
            address(strategy), ALLOCATION_KEY, emptyIds, emptyScaled, 0, emptyIds, emptyScaled
        );
    }

    function test_applyMemory_revertsOnUnsortedNewRecipientIds() public {
        bytes32[] memory unsorted = _ids(ID_B, ID_A);

        vm.expectRevert(IFlow.NOT_SORTED_OR_DUPLICATE.selector);
        harness.applyMemoryUnchecked(
            address(strategy), ALLOCATION_KEY, new bytes32[](0), new uint32[](0), 0, unsorted, _scaled(500_000, 500_000)
        );
    }

    function test_applyMemory_revertsOnLengthMismatchForNewArrays() public {
        vm.expectRevert(IFlow.ARRAY_LENGTH_MISMATCH.selector);
        harness.applyMemoryUnchecked(
            address(strategy),
            ALLOCATION_KEY,
            new bytes32[](0),
            new uint32[](0),
            0,
            _ids(ID_A),
            new uint32[](0)
        );
    }

    function test_applyMemory_coversBrandNewAndExistingUnchangedCommitPath() public {
        bytes32[] memory ids = _ids(ID_A, ID_B);
        uint32[] memory scaled = _scaled(500_000, 500_000);
        bytes32[] memory emptyIds = new bytes32[](0);
        uint32[] memory emptyScaled = new uint32[](0);

        harness.applyMemoryUnchecked(address(strategy), ALLOCATION_KEY, emptyIds, emptyScaled, 0, ids, scaled);

        bytes32 beforeCommit = harness.commitOf(address(strategy), ALLOCATION_KEY);
        harness.applyMemoryUnchecked(address(strategy), ALLOCATION_KEY, ids, scaled, TEST_WEIGHT, ids, scaled);
        bytes32 afterCommit = harness.commitOf(address(strategy), ALLOCATION_KEY);

        assertEq(afterCommit, beforeCommit);
    }

    function test_applyMemory_coversNegativeAndPositiveDeltaPaths_thenOverflowsOnPositiveSum() public {
        bytes32[] memory oldIds = _ids(ID_A);
        uint32[] memory oldScaled = _scaled(PPM_SCALE);

        harness.setCommit(address(strategy), ALLOCATION_KEY, AllocationCommitment.hashMemory(oldIds, oldScaled));
        harness.setWeightPlusOne(address(strategy), ALLOCATION_KEY, 1);

        pool.setUnits(makeAddr("recipient-b"), type(uint128).max);

        vm.expectRevert(IFlow.OVERFLOW.selector);
        harness.applyMemoryUnchecked(
            address(strategy),
            ALLOCATION_KEY,
            oldIds,
            oldScaled,
            TEST_WEIGHT,
            _ids(ID_A, ID_B),
            _scaled(500_000, 500_000)
        );
    }

    function test_applyMemory_revertsWhenPoolUnitUpdateFails() public {
        bytes32[] memory oldIds = _ids(ID_A);
        uint32[] memory oldScaled = _scaled(PPM_SCALE);

        harness.setCommit(address(strategy), ALLOCATION_KEY, AllocationCommitment.hashMemory(oldIds, oldScaled));
        harness.setWeightPlusOne(address(strategy), ALLOCATION_KEY, 1);
        pool.setUpdateOk(false);

        vm.expectRevert(IFlow.UNITS_UPDATE_FAILED.selector);
        harness.applyMemoryUnchecked(
            address(strategy),
            ALLOCATION_KEY,
            oldIds,
            oldScaled,
            TEST_WEIGHT,
            _ids(ID_B),
            _scaled(PPM_SCALE)
        );
    }

    function _ids(bytes32 a) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = a;
    }

    function _ids(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _scaled(uint32 a) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](1);
        arr[0] = a;
    }

    function _scaled(uint32 a, uint32 b) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
