// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { MockFeeOnTransferVotesToken } from "test/mocks/MockFeeOnTransferVotesToken.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { SharedMockSuperToken } from "test/goals/helpers/TreasurySharedMocks.sol";

contract GoalRevnetSplitHookTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 77;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;

    address internal controller = makeAddr("controller");

    MockVotesToken internal underlyingToken;
    SharedMockSuperToken internal superToken;
    GoalRevnetSplitHookMockDirectory internal directory;
    GoalRevnetSplitHookMockFlow internal flow;
    GoalRevnetSplitHookMockTreasury internal goalTreasury;
    GoalRevnetSplitHook internal hook;

    function setUp() public {
        underlyingToken = new MockVotesToken("Underlying", "UND");
        superToken = new SharedMockSuperToken(address(underlyingToken));
        directory = new GoalRevnetSplitHookMockDirectory();
        flow = new GoalRevnetSplitHookMockFlow(ISuperToken(address(superToken)));
        goalTreasury = new GoalRevnetSplitHookMockTreasury();

        hook = _deployHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(goalTreasury)),
            IFlow(address(flow)),
            GOAL_REVNET_ID
        );

        directory.setController(GOAL_REVNET_ID, controller);
    }

    function test_processSplitWith_transfersExactAmountAndForwardsToTreasury() public {
        uint256 amount = 100e18;
        underlyingToken.mint(address(hook), amount);
        goalTreasury.setResponse(IGoalTreasury.HookSplitAction.Funded, amount, 0);

        vm.prank(controller);
        hook.processSplitWith(_context(address(underlyingToken), amount));

        assertEq(underlyingToken.balanceOf(address(hook)), 0);
        assertEq(underlyingToken.balanceOf(address(goalTreasury)), amount);
        assertEq(goalTreasury.processHookSplitCallCount(), 1);
        assertEq(goalTreasury.lastSourceToken(), address(underlyingToken));
        assertEq(goalTreasury.lastSourceAmount(), amount);
    }

    function test_processSplitWith_revertsWhenFeeTokenDeliversLessToTreasury() public {
        MockFeeOnTransferVotesToken feeToken =
            new MockFeeOnTransferVotesToken("Fee", "FEE", 100, makeAddr("feeRecipient"));
        SharedMockSuperToken feeSuperToken = new SharedMockSuperToken(address(feeToken));
        GoalRevnetSplitHookMockFlow feeFlow = new GoalRevnetSplitHookMockFlow(ISuperToken(address(feeSuperToken)));
        GoalRevnetSplitHookMockTreasury feeTreasury = new GoalRevnetSplitHookMockTreasury();

        GoalRevnetSplitHook feeHook = _deployHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(feeTreasury)),
            IFlow(address(feeFlow)),
            GOAL_REVNET_ID
        );

        uint256 amount = 100e18;
        uint256 expectedReceived = amount - ((amount * 100) / 10_000);

        feeToken.mint(address(feeHook), amount);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(GoalRevnetSplitHook.SOURCE_TOKEN_AMOUNT_MISMATCH.selector, amount, expectedReceived)
        );
        feeHook.processSplitWith(_context(address(feeToken), amount));

        assertEq(feeTreasury.processHookSplitCallCount(), 0);
    }

    function _deployHook(
        IJBDirectory directory_,
        IGoalTreasury goalTreasury_,
        IFlow flow_,
        uint256 goalRevnetId_
    ) internal returns (GoalRevnetSplitHook deployedHook) {
        GoalRevnetSplitHook implementation = new GoalRevnetSplitHook();
        deployedHook = GoalRevnetSplitHook(payable(Clones.clone(address(implementation))));
        deployedHook.initialize(directory_, goalTreasury_, flow_, goalRevnetId_);
    }

    function _context(address token, uint256 amount) internal pure returns (JBSplitHookContext memory context) {
        context = JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: GOAL_REVNET_ID,
            groupId: RESERVED_TOKENS_GROUP_ID,
            split: JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            })
        });
    }
}

contract GoalRevnetSplitHookMockDirectory {
    mapping(uint256 projectId => address controller) internal _controllerOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }
}

contract GoalRevnetSplitHookMockFlow {
    ISuperToken internal immutable _superToken;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }
}

contract GoalRevnetSplitHookMockTreasury {
    IGoalTreasury.HookSplitAction internal _action;
    uint256 internal _superTokenAmount;
    uint256 internal _burnAmount;

    uint256 public processHookSplitCallCount;
    address public lastSourceToken;
    uint256 public lastSourceAmount;

    function setResponse(IGoalTreasury.HookSplitAction action_, uint256 superTokenAmount_, uint256 burnAmount_) external {
        _action = action_;
        _superTokenAmount = superTokenAmount_;
        _burnAmount = burnAmount_;
    }

    function processHookSplit(
        address sourceToken,
        uint256 sourceAmount
    ) external returns (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount) {
        processHookSplitCallCount += 1;
        lastSourceToken = sourceToken;
        lastSourceAmount = sourceAmount;
        return (_action, _superTokenAmount, _burnAmount);
    }
}
