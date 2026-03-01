// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalTreasury } from "../interfaces/IGoalTreasury.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// slither-disable-next-line locked-ether
contract GoalRevnetSplitHook is IJBSplitHook, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error INVALID_GOAL_REVNET_ID();
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_SOURCE_TOKEN(address expectedToken, address actualToken);
    error UNAUTHORIZED_CALLER();
    error INVALID_SPLIT_GROUP(uint256 expectedGroupId, uint256 actualGroupId);
    error NATIVE_VALUE_MISMATCH(uint256 expected, uint256 actual);
    error INSUFFICIENT_HOOK_BALANCE(address token, uint256 expected, uint256 available);
    error SOURCE_TOKEN_AMOUNT_MISMATCH(uint256 expected, uint256 actual);

    event GoalFundingProcessed(
        uint256 indexed projectId,
        address indexed sourceToken,
        uint256 sourceAmount,
        uint256 superTokenAmount,
        bool accepted,
        IGoalTreasury.HookSplitAction action
    );
    event GoalSuccessSettlementProcessed(
        uint256 indexed projectId,
        address indexed sourceToken,
        uint256 sourceAmount,
        uint256 burnAmount
    );

    IJBDirectory public directory;
    IGoalTreasury public goalTreasury;
    IFlow public flow;
    ISuperToken public superToken;
    address public underlyingToken;
    uint256 public goalRevnetId;

    uint256 private constant RESERVED_TOKENS_GROUP_ID = 1;

    constructor(IJBDirectory directory_, IGoalTreasury goalTreasury_, IFlow flow_, uint256 goalRevnetId_) {
        if (
            address(directory_) == address(0) &&
            address(goalTreasury_) == address(0) &&
            address(flow_) == address(0) &&
            goalRevnetId_ == 0
        ) {
            _disableInitializers();
            return;
        }

        _initialize(directory_, goalTreasury_, flow_, goalRevnetId_);
        _disableInitializers();
    }

    function initialize(
        IJBDirectory directory_,
        IGoalTreasury goalTreasury_,
        IFlow flow_,
        uint256 goalRevnetId_
    ) external initializer {
        __ReentrancyGuard_init();
        _initialize(directory_, goalTreasury_, flow_, goalRevnetId_);
    }

    function _initialize(
        IJBDirectory directory_,
        IGoalTreasury goalTreasury_,
        IFlow flow_,
        uint256 goalRevnetId_
    ) internal {
        address directoryAddress = address(directory_);
        address goalTreasuryAddress = address(goalTreasury_);
        address flowAddress = address(flow_);

        if (directoryAddress == address(0) || goalTreasuryAddress == address(0) || flowAddress == address(0)) {
            revert ADDRESS_ZERO();
        }
        if (directoryAddress.code.length == 0) revert NOT_A_CONTRACT(directoryAddress);
        if (goalTreasuryAddress.code.length == 0) revert NOT_A_CONTRACT(goalTreasuryAddress);
        if (flowAddress.code.length == 0) revert NOT_A_CONTRACT(flowAddress);
        if (goalRevnetId_ == 0) revert INVALID_GOAL_REVNET_ID();

        directory = directory_;
        goalTreasury = goalTreasury_;
        flow = flow_;
        goalRevnetId = goalRevnetId_;
        superToken = flow_.superToken();
        underlyingToken = superToken.getUnderlyingToken();
        if (underlyingToken == address(0)) revert ADDRESS_ZERO();
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function processSplitWith(JBSplitHookContext calldata context) external payable override nonReentrant {
        if (context.projectId != goalRevnetId) revert INVALID_PROJECT(goalRevnetId, context.projectId);
        if (context.token != underlyingToken) revert INVALID_SOURCE_TOKEN(underlyingToken, context.token);
        if (context.groupId != RESERVED_TOKENS_GROUP_ID) {
            revert INVALID_SPLIT_GROUP(RESERVED_TOKENS_GROUP_ID, context.groupId);
        }
        if (msg.value != 0) revert NATIVE_VALUE_MISMATCH(0, msg.value);

        if (msg.sender != address(directory.controllerOf(context.projectId))) revert UNAUTHORIZED_CALLER();

        if (context.amount == 0) {
            emit GoalFundingProcessed(
                context.projectId,
                context.token,
                0,
                0,
                false,
                IGoalTreasury.HookSplitAction.Deferred
            );
            return;
        }

        IERC20 sourceToken = IERC20(context.token);
        uint256 treasuryBalanceBefore = sourceToken.balanceOf(address(goalTreasury));
        _requireHookBalance(sourceToken, context.amount);
        sourceToken.safeTransfer(address(goalTreasury), context.amount);
        uint256 receivedAmount = sourceToken.balanceOf(address(goalTreasury)) - treasuryBalanceBefore;
        if (receivedAmount != context.amount) revert SOURCE_TOKEN_AMOUNT_MISMATCH(context.amount, receivedAmount);
        (
            IGoalTreasury.HookSplitAction action,
            uint256 superTokenAmount,
            uint256 burnAmount
        ) = goalTreasury.processHookSplit(context.token, receivedAmount);

        bool funded = action == IGoalTreasury.HookSplitAction.Funded;

        if (action == IGoalTreasury.HookSplitAction.SuccessSettled) {
            emit GoalSuccessSettlementProcessed(
                context.projectId,
                context.token,
                context.amount,
                burnAmount
            );
        }

        emit GoalFundingProcessed(
            context.projectId,
            context.token,
            context.amount,
            funded ? superTokenAmount : 0,
            funded,
            action
        );
    }

    function _requireHookBalance(IERC20 token, uint256 amount) internal view {
        uint256 hookBalance = token.balanceOf(address(this));
        if (hookBalance < amount) revert INSUFFICIENT_HOOK_BALANCE(address(token), amount, hookBalance);
    }
}
