// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalDeploymentRegistry } from "src/goals/GoalDeploymentRegistry.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";

contract GoalDeploymentRegistryTest is Test {
    uint256 internal constant GOAL_ID = 101;

    address internal registrarAdmin = makeAddr("registrar-admin");
    address internal registrar = makeAddr("registrar");
    address internal nonRegistrar = makeAddr("non-registrar");

    GoalDeploymentRegistry internal registry;
    GoalDeploymentRegistryMockGoalTreasury internal goalTreasury;
    GoalDeploymentRegistryMockGoalTreasury internal wrongGoalTreasury;

    function setUp() public {
        registry = new GoalDeploymentRegistry(registrarAdmin, registrar);
        goalTreasury = new GoalDeploymentRegistryMockGoalTreasury(GOAL_ID);
        wrongGoalTreasury = new GoalDeploymentRegistryMockGoalTreasury(GOAL_ID + 1);
    }

    function test_registerGoal_recordsCanonicalTreasury() public {
        vm.prank(registrar);
        registry.registerGoal(GOAL_ID, address(goalTreasury));

        assertTrue(registry.isRegisteredGoal(GOAL_ID));
        assertEq(registry.goalTreasuryOf(GOAL_ID), address(goalTreasury));
    }

    function test_registerGoal_revertsWhenCallerIsNotRegistrar() public {
        vm.prank(nonRegistrar);
        vm.expectRevert(IGoalDeploymentRegistry.UNAUTHORIZED.selector);
        registry.registerGoal(GOAL_ID, address(goalTreasury));
    }

    function test_registerGoal_revertsWhenGoalAlreadyRegistered() public {
        vm.startPrank(registrar);
        registry.registerGoal(GOAL_ID, address(goalTreasury));
        vm.expectRevert(abi.encodeWithSelector(IGoalDeploymentRegistry.GOAL_ALREADY_REGISTERED.selector, GOAL_ID));
        registry.registerGoal(GOAL_ID, address(goalTreasury));
        vm.stopPrank();
    }

    function test_registerGoal_revertsWhenTreasuryClaimsDifferentGoalId() public {
        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGoalDeploymentRegistry.INVALID_GOAL_TREASURY.selector,
                address(wrongGoalTreasury),
                GOAL_ID,
                GOAL_ID + 1
            )
        );
        registry.registerGoal(GOAL_ID, address(wrongGoalTreasury));
    }

    function test_setRegistrar_allowsRegistrarAdminToAuthorizeNewFactoryVersion() public {
        address newRegistrar = makeAddr("new-registrar");

        vm.prank(registrarAdmin);
        registry.setRegistrar(newRegistrar, true);

        assertTrue(registry.isRegistrar(newRegistrar));
    }

    function test_transferRegistrarAdmin_updatesAdminRole() public {
        address newRegistrarAdmin = makeAddr("new-registrar-admin");

        vm.prank(registrarAdmin);
        registry.transferRegistrarAdmin(newRegistrarAdmin);

        assertEq(registry.registrarAdmin(), newRegistrarAdmin);
    }
}

contract GoalDeploymentRegistryMockGoalTreasury {
    uint256 public immutable goalRevnetId;

    constructor(uint256 goalRevnetId_) {
        goalRevnetId = goalRevnetId_;
    }
}
