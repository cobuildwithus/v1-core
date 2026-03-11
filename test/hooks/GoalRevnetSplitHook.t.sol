// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {MockFeeOnTransferVotesToken} from "test/mocks/MockFeeOnTransferVotesToken.sol";
import {SharedMockUnderlying, SharedMockSuperToken} from "test/goals/helpers/TreasurySharedMocks.sol";

contract GoalRevnetSplitHookTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 77;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;
    address internal constant FLOW_SINK = address(0xF10);
    address internal constant BURN_SINK = address(0xB001);

    event GoalSuccessSettlementProcessed(
        uint256 indexed projectId, address indexed sourceToken, uint256 sourceAmount, uint256 burnAmount
    );

    address internal controller = makeAddr("controller");

    SharedMockUnderlying internal underlyingToken;
    SharedMockSuperToken internal superToken;
    GoalRevnetSplitHookMockDirectory internal directory;
    GoalRevnetSplitHookMockFlow internal flow;
    GoalRevnetSplitHookTreasuryHarness internal goalTreasury;
    GoalRevnetSplitHook internal hook;

    function setUp() public {
        underlyingToken = new SharedMockUnderlying();
        superToken = new SharedMockSuperToken(address(underlyingToken));
        directory = new GoalRevnetSplitHookMockDirectory();
        flow = new GoalRevnetSplitHookMockFlow(ISuperToken(address(superToken)));
        goalTreasury =
            new GoalRevnetSplitHookTreasuryHarness(underlyingToken, superToken, address(flow), FLOW_SINK, BURN_SINK);

        hook = _deployHook(IJBDirectory(address(directory)), IGoalTreasury(address(goalTreasury)), GOAL_REVNET_ID);
        goalTreasury.setHook(address(hook));

        directory.setController(GOAL_REVNET_ID, controller);
    }

    function test_processSplitWith_fundingIngress_transfersExactAmount_andForwardsSuperTokensToFlow() public {
        uint256 amount = 100e18;
        underlyingToken.mint(address(hook), amount);

        vm.prank(controller);
        hook.processSplitWith(_context(address(underlyingToken), amount));

        assertEq(underlyingToken.balanceOf(address(hook)), 0);
        assertEq(underlyingToken.balanceOf(address(goalTreasury)), 0);
        assertEq(superToken.balanceOf(FLOW_SINK), amount);
        assertEq(goalTreasury.processHookSplitCallCount(), 1);
        assertEq(goalTreasury.lastSourceToken(), address(underlyingToken));
        assertEq(goalTreasury.lastSourceAmount(), amount);
        assertEq(uint256(goalTreasury.lastAction()), uint256(IGoalTreasury.HookSplitAction.Funded));
        assertEq(goalTreasury.totalRaised(), amount);
    }

    function test_processSplitWith_deferredIngress_tracksDeferredSuperTokens() public {
        uint256 amount = 75e18;
        underlyingToken.mint(address(hook), amount);
        goalTreasury.setLifecycleState(IGoalTreasury.GoalState.Active);
        goalTreasury.setDeadlinePassed(true);

        vm.prank(controller);
        hook.processSplitWith(_context(address(underlyingToken), amount));

        assertEq(underlyingToken.balanceOf(address(goalTreasury)), 0);
        assertEq(superToken.balanceOf(address(goalTreasury)), amount);
        assertEq(goalTreasury.deferredHookSuperTokenAmount(), amount);
        assertEq(uint256(goalTreasury.lastAction()), uint256(IGoalTreasury.HookSplitAction.Deferred));
    }

    function test_processSplitWith_successSettlement_burnsUnderlyingAmount() public {
        uint256 amount = 40e18;
        underlyingToken.mint(address(hook), amount);
        goalTreasury.setLifecycleState(IGoalTreasury.GoalState.Succeeded);
        goalTreasury.setMintingOpen(true);

        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalSuccessSettlementProcessed(GOAL_REVNET_ID, address(underlyingToken), amount, amount);

        vm.prank(controller);
        hook.processSplitWith(_context(address(underlyingToken), amount));

        assertEq(underlyingToken.balanceOf(BURN_SINK), amount);
        assertEq(goalTreasury.totalBurned(), amount);
        assertEq(uint256(goalTreasury.lastAction()), uint256(IGoalTreasury.HookSplitAction.SuccessSettled));
    }

    function test_processSplitWith_terminalSettlement_convertsAndSettlesResidualAmount() public {
        uint256 amount = 55e18;
        underlyingToken.mint(address(hook), amount);
        goalTreasury.setLifecycleState(IGoalTreasury.GoalState.Expired);

        vm.prank(controller);
        hook.processSplitWith(_context(address(underlyingToken), amount));

        assertEq(underlyingToken.balanceOf(address(goalTreasury)), 0);
        assertEq(superToken.balanceOf(address(goalTreasury)), 0);
        assertEq(underlyingToken.balanceOf(BURN_SINK), amount);
        assertEq(goalTreasury.totalBurned(), amount);
        assertEq(goalTreasury.terminalSettledAmount(), amount);
        assertEq(uint256(goalTreasury.lastAction()), uint256(IGoalTreasury.HookSplitAction.TerminalSettled));
    }

    function test_initialize_revertsWhenGoalTreasurySuperTokenIsZero() public {
        GoalRevnetSplitHookMockTreasury zeroSuperTokenTreasury =
            new GoalRevnetSplitHookMockTreasury(address(flow), ISuperToken(address(0)));
        GoalRevnetSplitHook implementation = new GoalRevnetSplitHook();
        GoalRevnetSplitHook deployedHook = GoalRevnetSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        deployedHook.initialize(
            IJBDirectory(address(directory)), IGoalTreasury(address(zeroSuperTokenTreasury)), GOAL_REVNET_ID
        );
    }

    function test_initialize_revertsWhenGoalTreasurySuperTokenIsNotContract() public {
        address nonContractSuperToken = makeAddr("nonContractSuperToken");
        GoalRevnetSplitHookMockTreasury nonContractSuperTokenTreasury =
            new GoalRevnetSplitHookMockTreasury(address(flow), ISuperToken(nonContractSuperToken));
        GoalRevnetSplitHook implementation = new GoalRevnetSplitHook();
        GoalRevnetSplitHook deployedHook = GoalRevnetSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(
            abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, nonContractSuperToken)
        );
        deployedHook.initialize(
            IJBDirectory(address(directory)), IGoalTreasury(address(nonContractSuperTokenTreasury)), GOAL_REVNET_ID
        );
    }

    function test_initialize_revertsWhenGoalTreasurySuperTokenUnderlyingTokenIsZero() public {
        SharedMockSuperToken zeroUnderlyingSuperToken = new SharedMockSuperToken(address(0));
        GoalRevnetSplitHookMockTreasury zeroUnderlyingTreasury =
            new GoalRevnetSplitHookMockTreasury(address(flow), ISuperToken(address(zeroUnderlyingSuperToken)));
        GoalRevnetSplitHook implementation = new GoalRevnetSplitHook();
        GoalRevnetSplitHook deployedHook = GoalRevnetSplitHook(payable(Clones.clone(address(implementation))));

        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        deployedHook.initialize(
            IJBDirectory(address(directory)), IGoalTreasury(address(zeroUnderlyingTreasury)), GOAL_REVNET_ID
        );
    }

    function test_processSplitWith_revertsWhenFeeTokenDeliversLessToTreasury() public {
        MockFeeOnTransferVotesToken feeToken =
            new MockFeeOnTransferVotesToken("Fee", "FEE", 100, makeAddr("feeRecipient"));
        SharedMockSuperToken feeSuperToken = new SharedMockSuperToken(address(feeToken));
        GoalRevnetSplitHookMockFlow feeFlow = new GoalRevnetSplitHookMockFlow(ISuperToken(address(feeSuperToken)));
        GoalRevnetSplitHookMockTreasury feeTreasury =
            new GoalRevnetSplitHookMockTreasury(address(feeFlow), ISuperToken(address(feeSuperToken)));

        GoalRevnetSplitHook feeHook =
            _deployHook(IJBDirectory(address(directory)), IGoalTreasury(address(feeTreasury)), GOAL_REVNET_ID);

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

    function _deployHook(IJBDirectory directory_, IGoalTreasury goalTreasury_, uint256 goalRevnetId_)
        internal
        returns (GoalRevnetSplitHook deployedHook)
    {
        GoalRevnetSplitHook implementation = new GoalRevnetSplitHook();
        deployedHook = GoalRevnetSplitHook(payable(Clones.clone(address(implementation))));
        deployedHook.initialize(directory_, goalTreasury_, goalRevnetId_);
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
        return ISuperToken(address(_superToken));
    }
}

contract GoalRevnetSplitHookTreasuryHarness {
    error ONLY_HOOK();
    error INVALID_HOOK_SOURCE_TOKEN(address token);

    IERC20 private immutable _underlyingToken;
    SharedMockSuperToken private immutable _superToken;
    address private immutable _flow;
    address private immutable _flowSink;
    address private immutable _burnSink;
    address private _hook;
    IGoalTreasury.GoalState private _state;
    bool private _deadlinePassed;
    bool private _minRaiseWindowElapsedWithoutGoal;
    bool private _mintingOpen;

    uint256 public totalRaised;
    uint256 public deferredHookSuperTokenAmount;
    uint256 public totalBurned;
    uint256 public terminalSettledAmount;
    uint256 public processHookSplitCallCount;
    address public lastSourceToken;
    uint256 public lastSourceAmount;
    IGoalTreasury.HookSplitAction public lastAction;

    constructor(
        IERC20 underlyingToken_,
        SharedMockSuperToken superToken_,
        address flow_,
        address flowSink_,
        address burnSink_
    ) {
        _underlyingToken = underlyingToken_;
        _superToken = superToken_;
        _flow = flow_;
        _flowSink = flowSink_;
        _burnSink = burnSink_;
        _mintingOpen = true;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function superToken() external view returns (ISuperToken) {
        return ISuperToken(address(_superToken));
    }

    function setHook(address hook_) external {
        _hook = hook_;
    }

    function setLifecycleState(IGoalTreasury.GoalState state_) external {
        _state = state_;
    }

    function setDeadlinePassed(bool deadlinePassed_) external {
        _deadlinePassed = deadlinePassed_;
    }

    function setMinRaiseWindowElapsedWithoutGoal(bool elapsed_) external {
        _minRaiseWindowElapsedWithoutGoal = elapsed_;
    }

    function setMintingOpen(bool mintingOpen_) external {
        _mintingOpen = mintingOpen_;
    }

    function processHookSplit(address sourceToken, uint256 sourceAmount)
        external
        returns (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount)
    {
        if (msg.sender != _hook) revert ONLY_HOOK();
        if (sourceToken != address(_underlyingToken)) revert INVALID_HOOK_SOURCE_TOKEN(sourceToken);

        processHookSplitCallCount += 1;
        lastSourceToken = sourceToken;
        lastSourceAmount = sourceAmount;

        if (sourceAmount == 0) {
            lastAction = IGoalTreasury.HookSplitAction.Deferred;
            return (lastAction, 0, 0);
        }

        if (!_isTerminalState(_state) && !_minRaiseWindowElapsedWithoutGoal && !_deadlinePassed) {
            superTokenAmount = _upgradeHeldSource(sourceAmount);
            _superToken.transfer(_flowSink, superTokenAmount);
            totalRaised += superTokenAmount;
            lastAction = IGoalTreasury.HookSplitAction.Funded;
            return (lastAction, superTokenAmount, 0);
        }

        if (_state == IGoalTreasury.GoalState.Succeeded && _mintingOpen) {
            _underlyingToken.transfer(_burnSink, sourceAmount);
            totalBurned += sourceAmount;
            lastAction = IGoalTreasury.HookSplitAction.SuccessSettled;
            return (lastAction, 0, sourceAmount);
        }

        if (_isTerminalState(_state)) {
            superTokenAmount = _upgradeHeldSource(sourceAmount);
            burnAmount = _settleHeldSuperTokens(superTokenAmount);
            terminalSettledAmount += superTokenAmount;
            lastAction = IGoalTreasury.HookSplitAction.TerminalSettled;
            return (lastAction, superTokenAmount, burnAmount);
        }

        superTokenAmount = _upgradeHeldSource(sourceAmount);
        deferredHookSuperTokenAmount += superTokenAmount;
        lastAction = IGoalTreasury.HookSplitAction.Deferred;
        return (lastAction, superTokenAmount, 0);
    }

    function _upgradeHeldSource(uint256 sourceAmount) private returns (uint256 superTokenAmount) {
        _underlyingToken.approve(address(_superToken), 0);
        _underlyingToken.approve(address(_superToken), sourceAmount);
        uint256 superBalanceBefore = _superToken.balanceOf(address(this));
        _superToken.upgrade(sourceAmount);
        _underlyingToken.approve(address(_superToken), 0);
        return _superToken.balanceOf(address(this)) - superBalanceBefore;
    }

    function _settleHeldSuperTokens(uint256 amount) private returns (uint256 burnAmount) {
        uint256 underlyingBefore = _underlyingToken.balanceOf(address(this));
        _superToken.downgrade(amount);
        burnAmount = _underlyingToken.balanceOf(address(this)) - underlyingBefore;
        if (burnAmount != 0) {
            _underlyingToken.transfer(_burnSink, burnAmount);
            totalBurned += burnAmount;
        }
    }

    function _isTerminalState(IGoalTreasury.GoalState state_) private pure returns (bool) {
        return state_ == IGoalTreasury.GoalState.Succeeded || state_ == IGoalTreasury.GoalState.Expired;
    }
}

contract GoalRevnetSplitHookMockTreasury {
    address private immutable _flow;
    ISuperToken private immutable _superToken;
    uint256 public processHookSplitCallCount;

    constructor(address flow_, ISuperToken superToken_) {
        _flow = flow_;
        _superToken = superToken_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function processHookSplit(address, uint256)
        external
        returns (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 burnAmount)
    {
        processHookSplitCallCount += 1;
        return (IGoalTreasury.HookSplitAction.Funded, 0, 0);
    }
}
