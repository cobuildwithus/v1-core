// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { BudgetTopologyRegistryLib } from "src/goals/library/BudgetTopologyRegistryLib.sol";

contract BudgetTCRStorageV1 {
    IFlow public goalFlow;
    IGoalTreasury public goalTreasury;

    IERC20 public goalToken;
    IERC20 public cobuildToken;

    IJBRulesets public goalRulesets;
    uint256 public goalRevnetId;
    uint8 public paymentTokenDecimals;

    address public stackDeployer;
    address public premiumEscrowImplementation;
    address internal _budgetGatePolicy;
    address public underwriterSlasherRouter;
    uint32 public budgetPremiumPpm;
    uint32 public budgetSlashPpm;
    address public budgetSuccessResolver;
    address internal _budgetSpendPolicy;
    address public allocationMechanismAdmin;

    IBudgetTCR.BudgetValidationBounds public budgetValidationBounds;
    IBudgetTCR.OracleValidationBounds public oracleValidationBounds;

    mapping(bytes32 => BudgetTopologyRegistryLib.BudgetDeployment) internal _budgetDeployments;
    mapping(address => bytes32) internal _itemIdByBudgetTreasury;
    mapping(address => bytes32) internal _itemIdByChildFlow;
    mapping(bytes32 => bool) internal _pendingRegistrationActivations;
    mapping(bytes32 => bool) internal _pendingRemovalFinalizations;

    function budgetSpendPolicy() public view virtual returns (address policy) {
        policy = _budgetSpendPolicy;
    }

    function budgetGatePolicy() public view virtual returns (address policy) {
        policy = _budgetGatePolicy;
    }
}
