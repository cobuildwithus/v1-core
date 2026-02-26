// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowAllocationsBase } from "test/flows/FlowAllocations.t.sol";

contract FlowAllocationPropertiesTest is FlowAllocationsBase {
    bytes32 internal constant RECIPIENT_ID_1 = bytes32(uint256(1));
    bytes32 internal constant RECIPIENT_ID_2 = bytes32(uint256(2));
    bytes32 internal constant RECIPIENT_ID_3 = bytes32(uint256(3));
    bytes32 internal constant RECIPIENT_ID_4 = bytes32(uint256(4));

    address internal constant RECIPIENT_1 = address(0x1111);
    address internal constant RECIPIENT_2 = address(0x2222);
    address internal constant RECIPIENT_3 = address(0x3333);
    address internal constant RECIPIENT_4 = address(0x4444);

    function setUp() public override {
        super.setUp();

        _addRecipient(RECIPIENT_ID_1, RECIPIENT_1);
        _addRecipient(RECIPIENT_ID_2, RECIPIENT_2);
        _addRecipient(RECIPIENT_ID_3, RECIPIENT_3);
        _addRecipient(RECIPIENT_ID_4, RECIPIENT_4);

        strategy.setCanAllocate(_allocatorKey(), allocator, true);
    }

    function testFuzz_allocate_commitMatchesCanonicalHash(
        uint96 weightASeed,
        uint96 weightBSeed,
        uint32 splitASeed,
        uint32 splitBSeed
    ) public {
        uint256 weightA = bound(uint256(weightASeed), 1e18, 1e30);
        uint256 weightB = bound(uint256(weightBSeed), 1e18, 1e30);
        uint256 key = _allocatorKey();

        bytes32[] memory ids = _ids123();
        uint32[] memory bpsA = _scaled3(splitASeed, splitBSeed);
        uint32[] memory bpsB = _scaled3(splitBSeed, splitASeed);
        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);

        strategy.setWeight(key, weightA);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(flow), ids, bpsA);

        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, bpsA)));

        strategy.setWeight(key, weightB);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(flow), ids, bpsB);

        assertEq(flow.getAllocationCommitment(address(strategy), key), keccak256(abi.encode(ids, bpsB)));
    }

    function testFuzz_allocate_touchedRecipientUnitsMatchReference(
        uint96 weightASeed,
        uint96 weightBSeed,
        uint32 splitASeed,
        uint32 splitBSeed
    ) public {
        uint256 weightA = bound(uint256(weightASeed), 1e18, 1e30);
        uint256 weightB = bound(uint256(weightBSeed), 1e18, 1e30);
        uint256 key = _allocatorKey();

        (uint32 bps12A, uint32 bps12B) = _bps2(splitASeed);
        (uint32 bps23A, uint32 bps23B) = _bps2(splitBSeed);

        bytes32[] memory ids12 = _ids12();
        uint32[] memory bps12 = _pairScaled(bps12A, bps12B);

        bytes32[] memory ids23 = _ids23();
        uint32[] memory bps23 = _pairScaled(bps23A, bps23B);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);

        strategy.setWeight(key, weightA);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(flow), ids12, bps12);

        assertEq(flow.distributionPool().getUnits(RECIPIENT_1), _units(weightA, bps12A));
        assertEq(flow.distributionPool().getUnits(RECIPIENT_2), _units(weightA, bps12B));
        assertEq(flow.distributionPool().getUnits(RECIPIENT_3), uint128(0));
        assertEq(flow.distributionPool().getUnits(RECIPIENT_4), uint128(0));

        strategy.setWeight(key, weightB);
        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(flow), ids23, bps23);

        assertEq(flow.distributionPool().getUnits(RECIPIENT_1), uint128(0));
        assertEq(flow.distributionPool().getUnits(RECIPIENT_2), _units(weightB, bps23A));
        assertEq(flow.distributionPool().getUnits(RECIPIENT_3), _units(weightB, bps23B));
        assertEq(flow.distributionPool().getUnits(RECIPIENT_4), uint128(0));
    }

    function _ids123() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](3);
        ids[0] = RECIPIENT_ID_1;
        ids[1] = RECIPIENT_ID_2;
        ids[2] = RECIPIENT_ID_3;
    }

    function _ids12() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        ids[0] = RECIPIENT_ID_1;
        ids[1] = RECIPIENT_ID_2;
    }

    function _ids23() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        ids[0] = RECIPIENT_ID_2;
        ids[1] = RECIPIENT_ID_3;
    }

    function _bps2(uint32 seed) internal pure returns (uint32 a, uint32 b) {
        a = uint32((uint256(seed) % 999_999) + 1);
        b = 1_000_000 - a;
    }

    function _scaled3(uint32 seedA, uint32 seedB) internal pure returns (uint32[] memory scaled) {
        uint32 a = uint32((uint256(seedA) % 999_998) + 1);
        uint32 remaining = 1_000_000 - a;
        uint32 b = uint32((uint256(seedB) % (remaining - 1)) + 1);
        uint32 c = 1_000_000 - a - b;

        scaled = _pairScaled3(a, b, c);
    }

    function _pairScaled(uint32 a, uint32 b) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](2);
        scaled[0] = a;
        scaled[1] = b;
    }

    function _pairScaled3(uint32 a, uint32 b, uint32 c) internal pure returns (uint32[] memory scaled) {
        scaled = new uint32[](3);
        scaled[0] = a;
        scaled[1] = b;
        scaled[2] = c;
    }
}
