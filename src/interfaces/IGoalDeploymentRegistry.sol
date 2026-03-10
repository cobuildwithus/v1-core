// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface IGoalDeploymentRegistry {
    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error UNAUTHORIZED();
    error INVALID_GOAL_ID();
    error GOAL_ALREADY_REGISTERED(uint256 goalId);
    error INVALID_GOAL_TREASURY(address goalTreasury, uint256 expectedGoalId, uint256 actualGoalId);

    event GoalRegistered(uint256 indexed goalId, address indexed goalTreasury, address indexed registrar);
    event RegistrarSet(address indexed registrar, bool allowed);
    event RegistrarAdminTransferred(address indexed previousRegistrarAdmin, address indexed newRegistrarAdmin);

    function registrarAdmin() external view returns (address);
    function isRegistrar(address account) external view returns (bool);
    function isRegisteredGoal(uint256 goalId) external view returns (bool);
    function goalTreasuryOf(uint256 goalId) external view returns (address goalTreasury);

    function transferRegistrarAdmin(address newRegistrarAdmin) external;
    function setRegistrar(address registrar, bool allowed) external;
    function registerGoal(uint256 goalId, address goalTreasury) external;
}
