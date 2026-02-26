// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { IFlow } from "src/interfaces/IFlow.sol";
import { AllocationCommitment } from "src/library/AllocationCommitment.sol";

contract AllocationCommitmentTest is Test {
    AllocationCommitmentHarness internal harness;

    function setUp() public {
        harness = new AllocationCommitmentHarness();
    }

    function test_hashMemory_matchesAbiEncode() public view {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(11));
        ids[1] = bytes32(uint256(22));

        uint32[] memory scaled = new uint32[](2);
        scaled[0] = 400_000;
        scaled[1] = 600_000;

        bytes32 memoryHash = harness.hashMemory(ids, scaled);
        assertEq(memoryHash, keccak256(abi.encode(ids, scaled)));
    }

    function test_hashMemory_revertsOnLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));

        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.expectRevert(IFlow.ARRAY_LENGTH_MISMATCH.selector);
        harness.hashMemory(ids, scaled);
    }
}

contract AllocationCommitmentHarness {
    function hashMemory(bytes32[] memory recipientIds, uint32[] memory scaled) external pure returns (bytes32) {
        return AllocationCommitment.hashMemory(recipientIds, scaled);
    }
}
