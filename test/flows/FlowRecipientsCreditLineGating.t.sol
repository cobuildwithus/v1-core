// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {IFlow} from "src/interfaces/IFlow.sol";

contract FlowRecipientsCreditLineGatingTest is FlowTestBase {
    function test_setRecipientEnabled_disablePreservesVirtualUnits_andReenableRestoresLatestAllocation() public {
        bytes32 recipientA = bytes32(uint256(501));
        bytes32 recipientB = bytes32(uint256(502));
        address recipientAddrA = address(0x501);
        address recipientAddrB = address(0x502);

        _addRecipient(recipientA, recipientAddrA);
        _addRecipient(recipientB, recipientAddrB);

        bytes32[] memory recipientIds = new bytes32[](2);
        recipientIds[0] = recipientA;
        recipientIds[1] = recipientB;

        uint32[] memory initialAllocations = new uint32[](2);
        initialAllocations[0] = 500_000;
        initialAllocations[1] = 500_000;

        vm.prank(allocator);
        flow.allocate(recipientIds, initialAllocations);

        uint128 unitsAHalf = flow.distributionPool().getUnits(recipientAddrA);
        uint128 unitsBHalf = flow.distributionPool().getUnits(recipientAddrB);
        assertGt(unitsAHalf, 0);
        assertGt(unitsBHalf, 0);

        vm.prank(manager);
        flow.setRecipientEnabled(recipientA, false);

        assertFalse(flow.isRecipientEnabled(recipientA));
        assertEq(flow.distributionPool().getUnits(recipientAddrA), 0);
        assertEq(flow.distributionPool().getUnits(recipientAddrB), unitsBHalf);

        bytes32[] memory disabledRecipientIds = new bytes32[](1);
        disabledRecipientIds[0] = recipientA;

        uint32[] memory disabledAllocations = new uint32[](1);
        disabledAllocations[0] = 1_000_000;

        vm.prank(allocator);
        flow.allocate(disabledRecipientIds, disabledAllocations);

        assertEq(flow.distributionPool().getUnits(recipientAddrA), 0);
        assertEq(flow.distributionPool().getUnits(recipientAddrB), 0);

        vm.prank(manager);
        flow.setRecipientEnabled(recipientA, true);

        assertTrue(flow.isRecipientEnabled(recipientA));
        assertGt(flow.distributionPool().getUnits(recipientAddrA), unitsAHalf);
        assertEq(flow.distributionPool().getUnits(recipientAddrB), 0);
    }

    function test_setRecipientEnabled_accessAndRecipientStateGuards() public {
        bytes32 recipientId = bytes32(uint256(601));
        address recipientAddr = address(0x601);
        _addRecipient(recipientId, recipientAddr);

        vm.prank(other);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        flow.setRecipientEnabled(recipientId, false);

        bytes32 missingRecipientId = bytes32(uint256(999_001));
        vm.prank(manager);
        vm.expectRevert(IFlow.INVALID_RECIPIENT_ID.selector);
        flow.setRecipientEnabled(missingRecipientId, false);

        vm.expectRevert(IFlow.INVALID_RECIPIENT_ID.selector);
        flow.isRecipientEnabled(missingRecipientId);

        vm.prank(manager);
        flow.removeRecipient(recipientId);

        assertFalse(flow.isRecipientEnabled(recipientId));

        vm.prank(manager);
        vm.expectRevert(IFlow.NOT_APPROVED_RECIPIENT.selector);
        flow.setRecipientEnabled(recipientId, true);
    }
}
