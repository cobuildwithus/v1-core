// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

contract GoalDeploymentRegistry is IGoalDeploymentRegistry {
    address public override registrarAdmin;

    mapping(address account => bool allowed) private _isRegistrar;
    mapping(uint256 goalId => address goalTreasury) private _goalTreasuryOf;

    modifier onlyRegistrarAdmin() {
        if (msg.sender != registrarAdmin) revert UNAUTHORIZED();
        _;
    }

    modifier onlyRegistrar() {
        if (!_isRegistrar[msg.sender]) revert UNAUTHORIZED();
        _;
    }

    constructor(address registrarAdmin_, address initialRegistrar) {
        if (registrarAdmin_ == address(0)) revert ADDRESS_ZERO();

        registrarAdmin = registrarAdmin_;
        emit RegistrarAdminTransferred(address(0), registrarAdmin_);

        if (initialRegistrar != address(0)) {
            _isRegistrar[initialRegistrar] = true;
            emit RegistrarSet(initialRegistrar, true);
        }
    }

    function isRegistrar(address account) external view override returns (bool) {
        return _isRegistrar[account];
    }

    function isRegisteredGoal(uint256 goalId) external view override returns (bool) {
        return _goalTreasuryOf[goalId] != address(0);
    }

    function goalTreasuryOf(uint256 goalId) external view override returns (address goalTreasury) {
        goalTreasury = _goalTreasuryOf[goalId];
    }

    function transferRegistrarAdmin(address newRegistrarAdmin) external override onlyRegistrarAdmin {
        if (newRegistrarAdmin == address(0)) revert ADDRESS_ZERO();

        address previousRegistrarAdmin = registrarAdmin;
        registrarAdmin = newRegistrarAdmin;

        emit RegistrarAdminTransferred(previousRegistrarAdmin, newRegistrarAdmin);
    }

    function setRegistrar(address registrar, bool allowed) external override onlyRegistrarAdmin {
        if (registrar == address(0)) revert ADDRESS_ZERO();

        _isRegistrar[registrar] = allowed;
        emit RegistrarSet(registrar, allowed);
    }

    function registerGoal(uint256 goalId, address goalTreasury) external override onlyRegistrar {
        if (goalId == 0) revert INVALID_GOAL_ID();
        if (goalTreasury == address(0)) revert ADDRESS_ZERO();
        if (_goalTreasuryOf[goalId] != address(0)) revert GOAL_ALREADY_REGISTERED(goalId);
        if (goalTreasury.code.length == 0) revert NOT_A_CONTRACT(goalTreasury);

        uint256 actualGoalId;
        try IGoalTreasury(goalTreasury).goalRevnetId() returns (uint256 resolvedGoalId) {
            actualGoalId = resolvedGoalId;
        } catch {
            revert INVALID_GOAL_TREASURY(goalTreasury, goalId, 0);
        }
        if (actualGoalId != goalId) revert INVALID_GOAL_TREASURY(goalTreasury, goalId, actualGoalId);

        _goalTreasuryOf[goalId] = goalTreasury;
        emit GoalRegistered(goalId, goalTreasury, msg.sender);
    }
}
