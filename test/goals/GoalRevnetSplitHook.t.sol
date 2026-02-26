// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract GoalRevnetSplitHookTest is Test {
    uint256 internal constant PROJECT_ID = 77;
    uint256 internal constant RESERVED_GROUP_ID = 1;
    uint32 internal constant SCALE_1E6 = 1_000_000;
    uint32 internal constant TREASURY_SETTLEMENT_SCALED = 250_000;

    address internal controller;
    address internal outsider = address(0xBEEF);
    address internal rewardEscrowSink = address(0xEE5C0);

    HookMockDirectory internal directory;
    HookMockTreasury internal treasury;
    HookMockFlow internal flow;
    HookMockUnderlying internal underlying;
    HookMockSuperToken internal superToken;
    GoalRevnetSplitHook internal hook;
    HookMockReservedTokenController internal controllerShim;

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
        uint256 rewardEscrowAmount,
        uint256 burnAmount
    );

    function setUp() public {
        directory = new HookMockDirectory();
        underlying = new HookMockUnderlying();
        superToken = new HookMockSuperToken(address(underlying));
        flow = new HookMockFlow(ISuperToken(address(superToken)));
        controllerShim = new HookMockReservedTokenController();
        controller = address(controllerShim);
        treasury = new HookMockTreasury(controller, PROJECT_ID);
        treasury.setTreasurySettlementRewardEscrowScaled(TREASURY_SETTLEMENT_SCALED);
        treasury.setRewardEscrow(rewardEscrowSink);
        directory.setController(PROJECT_ID, controller);

        hook = new GoalRevnetSplitHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            PROJECT_ID
        );

        treasury.setState(IGoalTreasury.GoalState.Active);
    }

    function test_constructor_setsGoalRevnetId() public view {
        assertEq(hook.goalRevnetId(), PROJECT_ID);
    }

    function test_initialize_clone_success_andBlocksReinitialize() public {
        GoalRevnetSplitHook clone = _newUninitializedClone();

        clone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            PROJECT_ID
        );

        assertEq(address(clone.directory()), address(directory));
        assertEq(address(clone.goalTreasury()), address(treasury));
        assertEq(address(clone.flow()), address(flow));
        assertEq(clone.goalRevnetId(), PROJECT_ID);
        assertEq(clone.underlyingToken(), address(underlying));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            PROJECT_ID
        );
    }

    function test_processSplitWith_defersWhenCanAcceptFalseAndNotSuccessSettlementWindow() public {
        treasury.setCanAccept(false);
        treasury.setState(IGoalTreasury.GoalState.Active);
        treasury.setResolved(false);
        treasury.setMintingOpen(false);

        uint256 amount = 1e18;
        underlying.mint(address(hook), amount);
        vm.prank(controller);
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(treasury.deferredHookSuperTokenAmount(), amount);
        assertEq(underlying.balanceOf(address(hook)), 0);
        assertEq(underlying.balanceOf(address(treasury)), amount);
        assertEq(treasury.callCount(), 0);
    }

    function test_processSplitWith_successSettlement_sendsRewardAndBurnsComplement_noRemainder() public {
        uint256 amount = 10_000;
        uint32 rewardScaled = TREASURY_SETTLEMENT_SCALED;
        uint256 expectedReward = (amount * rewardScaled) / SCALE_1E6;
        uint256 expectedBurn = amount - expectedReward;

        _setSuccessSettlementWindowOpen();
        underlying.mint(address(controllerShim), amount);

        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalSuccessSettlementProcessed(PROJECT_ID, address(underlying), amount, expectedReward, expectedBurn);
        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalFundingProcessed(
            PROJECT_ID,
            address(underlying),
            amount,
            0,
            false,
            IGoalTreasury.HookSplitAction.SuccessSettled
        );

        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        assertEq(underlying.balanceOf(rewardEscrowSink), expectedReward);
        assertEq(controllerShim.burnCallCount(), 1);
        assertEq(controllerShim.lastBurnProjectId(), PROJECT_ID);
        assertEq(controllerShim.lastBurnAmount(), expectedBurn);
        assertEq(expectedReward + expectedBurn, amount);
    }

    function test_processSplitWith_successSettlement_withZeroRewardBps_burnsAll() public {
        uint256 amount = 1234;
        treasury.setTreasurySettlementRewardEscrowScaled(0);
        _setSuccessSettlementWindowOpen();
        underlying.mint(address(controllerShim), amount);

        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        assertEq(underlying.balanceOf(rewardEscrowSink), 0);
        assertEq(controllerShim.lastBurnAmount(), amount);
    }

    function test_processSplitWith_successSettlement_withFullRewardBps_sendsAllToEscrow() public {
        uint256 amount = 7777;
        treasury.setTreasurySettlementRewardEscrowScaled(SCALE_1E6);
        _setSuccessSettlementWindowOpen();
        underlying.mint(address(controllerShim), amount);

        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        assertEq(underlying.balanceOf(rewardEscrowSink), amount);
        assertEq(controllerShim.burnCallCount(), 0);
    }

    function test_processSplitWith_successSettlement_revertsAndRollsBackIfBurnReverts() public {
        uint256 amount = 10_000;
        _setSuccessSettlementWindowOpen();
        controllerShim.setShouldRevertBurn(true);
        underlying.mint(address(controllerShim), amount);
        uint256 escrowBefore = underlying.balanceOf(rewardEscrowSink);

        vm.expectRevert("BURN_REVERT");
        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        // Whole controller->hook->escrow call chain is one tx; burn revert must roll back reward transfer.
        assertEq(underlying.balanceOf(rewardEscrowSink), escrowBefore);
        assertEq(underlying.balanceOf(address(controllerShim)), amount);
        assertEq(underlying.balanceOf(address(hook)), 0);
        assertEq(controllerShim.burnCallCount(), 0);
    }

    function test_processSplitWith_successSettlement_revertsIfRewardEscrowTransferCannotBeCovered() public {
        uint256 amount = 10_000;
        _setSuccessSettlementWindowOpen();

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                GoalRevnetSplitHook.INSUFFICIENT_HOOK_BALANCE.selector, address(underlying), amount, 0
            )
        );
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(controllerShim.burnCallCount(), 0);
        assertEq(underlying.balanceOf(rewardEscrowSink), 0);
    }

    function testFuzz_processSplitWith_successSettlement_splitConservesAmount_noRemainder(uint96 rawAmount, uint32 rawScaled)
        public
    {
        uint256 amount = bound(uint256(rawAmount), 1, 1e30);
        uint32 rewardScaled = uint32(bound(uint256(rawScaled), 0, SCALE_1E6));
        treasury.setTreasurySettlementRewardEscrowScaled(rewardScaled);
        uint256 expectedReward = (amount * rewardScaled) / SCALE_1E6;
        uint256 expectedBurn = amount - expectedReward;
        uint256 escrowBefore = underlying.balanceOf(rewardEscrowSink);

        _setSuccessSettlementWindowOpen();
        underlying.mint(address(controllerShim), amount);

        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        assertEq(underlying.balanceOf(rewardEscrowSink) - escrowBefore, expectedReward);
        assertEq(controllerShim.lastBurnAmount(), expectedBurn);
        assertEq(expectedReward + expectedBurn, amount);
    }

    function test_processSplitWith_terminalSettlesWhenMintingClosedAfterSuccess() public {
        treasury.setState(IGoalTreasury.GoalState.Succeeded);
        treasury.setResolved(true);
        treasury.setMintingOpen(false);

        uint256 amount = 1e18;
        underlying.mint(address(hook), amount);
        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalFundingProcessed(
            PROJECT_ID,
            address(underlying),
            amount,
            0,
            false,
            IGoalTreasury.HookSplitAction.TerminalSettled
        );
        vm.prank(controller);
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(controllerShim.burnCallCount(), 1);
        assertEq(controllerShim.lastBurnAmount(), amount);
        assertEq(underlying.balanceOf(address(hook)), 0);
        assertEq(underlying.balanceOf(address(treasury)), amount);
    }

    function test_constructor_revertsOnZeroDirectory() public {
        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        new GoalRevnetSplitHook(
            IJBDirectory(address(0)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            PROJECT_ID
        );
    }

    function test_constructor_revertsOnZeroGoalTreasury() public {
        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        new GoalRevnetSplitHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(0)),
            IFlow(address(flow)),
            PROJECT_ID
        );
    }

    function test_constructor_revertsOnZeroFlow() public {
        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        new GoalRevnetSplitHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(0)),
            PROJECT_ID
        );
    }

    function test_constructor_revertsWhenDirectoryIsNotContract() public {
        address notContract = address(0xD1E);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, notContract));
        new GoalRevnetSplitHook(IJBDirectory(notContract), IGoalTreasury(address(treasury)), IFlow(address(flow)), PROJECT_ID);
    }

    function test_constructor_revertsWhenGoalTreasuryIsNotContract() public {
        address notContract = address(0x717);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, notContract));
        new GoalRevnetSplitHook(IJBDirectory(address(directory)), IGoalTreasury(notContract), IFlow(address(flow)), PROJECT_ID);
    }

    function test_constructor_revertsWhenFlowIsNotContract() public {
        address notContract = address(0xF10);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, notContract));
        new GoalRevnetSplitHook(
            IJBDirectory(address(directory)), IGoalTreasury(address(treasury)), IFlow(notContract), PROJECT_ID
        );
    }

    function test_constructor_revertsOnZeroGoalRevnetId() public {
        vm.expectRevert(GoalRevnetSplitHook.INVALID_GOAL_REVNET_ID.selector);
        new GoalRevnetSplitHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            0
        );
    }

    function test_constructor_revertsWhenFlowSuperTokenUnderlyingIsZero() public {
        HookMockSuperToken superTokenWithoutUnderlying = new HookMockSuperToken(address(0));
        HookMockFlow flowWithMissingUnderlying = new HookMockFlow(ISuperToken(address(superTokenWithoutUnderlying)));

        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        new GoalRevnetSplitHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flowWithMissingUnderlying)),
            PROJECT_ID
        );
    }

    function test_initialize_clone_revertsWhenFlowSuperTokenUnderlyingIsZero() public {
        GoalRevnetSplitHook clone = _newUninitializedClone();
        HookMockSuperToken superTokenWithoutUnderlying = new HookMockSuperToken(address(0));
        HookMockFlow flowWithMissingUnderlying = new HookMockFlow(ISuperToken(address(superTokenWithoutUnderlying)));

        vm.expectRevert(GoalRevnetSplitHook.ADDRESS_ZERO.selector);
        clone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flowWithMissingUnderlying)),
            PROJECT_ID
        );
    }

    function test_initialize_clone_revertsWhenDirectoryIsNotContract() public {
        GoalRevnetSplitHook clone = _newUninitializedClone();
        address notContract = address(0xD1E);

        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, notContract));
        clone.initialize(IJBDirectory(notContract), IGoalTreasury(address(treasury)), IFlow(address(flow)), PROJECT_ID);
    }

    function test_initialize_clone_revertsWhenGoalTreasuryIsNotContract() public {
        GoalRevnetSplitHook clone = _newUninitializedClone();
        address notContract = address(0x717);

        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, notContract));
        clone.initialize(IJBDirectory(address(directory)), IGoalTreasury(notContract), IFlow(address(flow)), PROJECT_ID);
    }

    function test_initialize_clone_revertsWhenFlowIsNotContract() public {
        GoalRevnetSplitHook clone = _newUninitializedClone();
        address notContract = address(0xF10);

        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.NOT_A_CONTRACT.selector, notContract));
        clone.initialize(IJBDirectory(address(directory)), IGoalTreasury(address(treasury)), IFlow(notContract), PROJECT_ID);
    }

    function test_initialize_clone_revertsOnZeroGoalRevnetId() public {
        GoalRevnetSplitHook clone = _newUninitializedClone();

        vm.expectRevert(GoalRevnetSplitHook.INVALID_GOAL_REVNET_ID.selector);
        clone.initialize(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            0
        );
    }

    function test_constructor_setsUnderlyingTokenFromFlow() public view {
        assertEq(hook.underlyingToken(), address(underlying));
    }

    function test_supportsInterface_reportsExpectedIds() public view {
        assertTrue(hook.supportsInterface(type(IJBSplitHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0x12345678));
    }

    function test_processSplitWith_revertsOnInvalidProject() public {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.INVALID_PROJECT.selector, PROJECT_ID, PROJECT_ID + 1));
        hook.processSplitWith(_context(address(underlying), 1e18, PROJECT_ID + 1, RESERVED_GROUP_ID));
    }

    function test_processSplitWith_revertsOnInvalidSplitGroup() public {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.INVALID_SPLIT_GROUP.selector, RESERVED_GROUP_ID, 0));
        hook.processSplitWith(_context(address(underlying), 1e18, PROJECT_ID, 0));
    }

    function test_processSplitWith_revertsOnNativeValueMismatch() public {
        vm.deal(controller, 1);
        vm.prank(controller);
        (bool ok, bytes memory revertData) = address(hook).call{ value: 1 }(
            abi.encodeCall(
                GoalRevnetSplitHook.processSplitWith, (_context(address(underlying), 1e18, PROJECT_ID, RESERVED_GROUP_ID))
            )
        );

        assertFalse(ok);
        assertGe(revertData.length, 4);
        assertEq(bytes4(revertData), GoalRevnetSplitHook.NATIVE_VALUE_MISMATCH.selector);
    }

    function test_processSplitWith_revertsOnUnauthorizedCaller() public {
        vm.prank(outsider);
        vm.expectRevert(GoalRevnetSplitHook.UNAUTHORIZED_CALLER.selector);
        hook.processSplitWith(_context(address(underlying), 1e18, PROJECT_ID, RESERVED_GROUP_ID));
    }

    function test_processSplitWith_zeroAmount_emitsAndReturnsEarly() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalFundingProcessed(
            PROJECT_ID,
            address(underlying),
            0,
            0,
            false,
            IGoalTreasury.HookSplitAction.Deferred
        );

        vm.prank(controller);
        hook.processSplitWith(_context(address(underlying), 0, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(treasury.callCount(), 0);
        assertEq(treasury.lastAmount(), 0);
    }

    function test_processSplitWith_revertsWhenContextTokenDiffersFromUnderlying() public {
        address invalidToken = address(superToken);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                GoalRevnetSplitHook.INVALID_SOURCE_TOKEN.selector, address(underlying), invalidToken
            )
        );
        hook.processSplitWith(_context(invalidToken, 1e18, PROJECT_ID, RESERVED_GROUP_ID));
    }

    function test_processSplitWith_revertsWhenHookBalanceInsufficient() public {
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(GoalRevnetSplitHook.INSUFFICIENT_HOOK_BALANCE.selector, address(underlying), 1e18, 0)
        );
        hook.processSplitWith(_context(address(underlying), 1e18, PROJECT_ID, RESERVED_GROUP_ID));
    }

    function test_processSplitWith_wrapsUnderlyingFromHookBalance() public {
        uint256 amount = 13e18;
        underlying.mint(address(hook), amount);

        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalFundingProcessed(
            PROJECT_ID,
            address(underlying),
            amount,
            amount,
            true,
            IGoalTreasury.HookSplitAction.Funded
        );
        vm.prank(controller);
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(treasury.callCount(), 1);
        assertEq(treasury.lastAmount(), amount);
    }

    function test_processSplitWith_revertsWhenTreasuryReceivesLessThanRequested() public {
        uint256 amount = 10_000;
        underlying.setTransferFeeBps(100); // 1%
        underlying.mint(address(hook), amount);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(GoalRevnetSplitHook.SOURCE_TOKEN_AMOUNT_MISMATCH.selector, amount, 9_900));
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(treasury.callCount(), 0);
    }

    function test_processSplitWith_defersWhenGoalTreasuryCannotAcceptFunding() public {
        uint256 amount = 5e18;
        treasury.setCanAccept(false);
        underlying.mint(address(hook), amount);

        vm.expectEmit(true, true, true, true, address(hook));
        emit GoalFundingProcessed(
            PROJECT_ID,
            address(underlying),
            amount,
            0,
            false,
            IGoalTreasury.HookSplitAction.Deferred
        );
        vm.prank(controller);
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(treasury.deferredHookSuperTokenAmount(), amount);
        assertEq(treasury.callCount(), 0);
    }

    function test_processSplitWith_revertsWhenGoalTreasuryReturnsAcceptedFalse_andRollsBackTransfers() public {
        uint256 amount = 5e18;
        treasury.setAccepted(false);
        underlying.mint(address(hook), amount);
        uint256 flowBalanceBefore = superToken.balanceOf(address(flow));
        uint256 hookUnderlyingBefore = underlying.balanceOf(address(hook));

        vm.prank(controller);
        vm.expectRevert(HookMockTreasury.GOAL_TREASURY_REJECTED.selector);
        hook.processSplitWith(_context(address(underlying), amount, PROJECT_ID, RESERVED_GROUP_ID));

        assertEq(superToken.balanceOf(address(flow)), flowBalanceBefore);
        assertEq(underlying.balanceOf(address(hook)), hookUnderlyingBefore);
        assertEq(treasury.callCount(), 0);
        assertEq(treasury.lastAmount(), 0);
    }

    function test_processSplitWith_controllerStyleTransferThenCall_succeeds() public {
        uint256 amount = 5e18;
        underlying.mint(address(controllerShim), amount);

        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        assertEq(underlying.balanceOf(address(controllerShim)), 0);
        assertEq(treasury.callCount(), 1);
        assertEq(treasury.lastAmount(), amount);
    }

    function test_processSplitWith_controllerStyleTransferThenCall_revertRollsBackControllerTransfer() public {
        uint256 amount = 5e18;
        treasury.setAccepted(false);
        underlying.mint(address(controllerShim), amount);

        vm.expectRevert(HookMockTreasury.GOAL_TREASURY_REJECTED.selector);
        controllerShim.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        );

        assertEq(underlying.balanceOf(address(controllerShim)), amount);
        assertEq(underlying.balanceOf(address(hook)), 0);
        assertEq(superToken.balanceOf(address(flow)), 0);
        assertEq(treasury.callCount(), 0);
        assertEq(treasury.lastAmount(), 0);
    }

    function _newUninitializedClone() internal returns (GoalRevnetSplitHook clone) {
        GoalRevnetSplitHook implementation = new GoalRevnetSplitHook(
            IJBDirectory(address(0)),
            IGoalTreasury(address(0)),
            IFlow(address(0)),
            0
        );
        clone = GoalRevnetSplitHook(payable(Clones.clone(address(implementation))));
    }

    function _setSuccessSettlementWindowOpen() internal {
        treasury.setState(IGoalTreasury.GoalState.Succeeded);
        treasury.setResolved(true);
        treasury.setMintingOpen(true);
    }

    function _context(address token, uint256 amount, uint256 projectId, uint256 groupId)
        internal
        pure
        returns (JBSplitHookContext memory)
    {
        return JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: groupId,
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

contract HookMockDirectory {
    mapping(uint256 => address) private _controllerOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }
}

contract HookMockTreasury {
    error GOAL_TREASURY_REJECTED();

    address private _burnController;
    uint256 private _burnProjectId;
    bool public accepted = true;
    bool public canAccept = true;
    bool public mintingOpen;
    bool public resolved;
    IGoalTreasury.GoalState public state = IGoalTreasury.GoalState.Active;
    address public rewardEscrow;
    uint256 public callCount;
    uint256 public lastAmount;
    uint32 public treasurySettlementRewardEscrowScaled;
    uint256 public deferredHookSuperTokenAmount;

    constructor(address burnController_, uint256 burnProjectId_) {
        _burnController = burnController_;
        _burnProjectId = burnProjectId_;
    }

    function setAccepted(bool accepted_) external {
        accepted = accepted_;
    }

    function setCanAccept(bool canAccept_) external {
        canAccept = canAccept_;
    }

    function setMintingOpen(bool mintingOpen_) external {
        mintingOpen = mintingOpen_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }

    function setState(IGoalTreasury.GoalState state_) external {
        state = state_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }

    function setTreasurySettlementRewardEscrowScaled(uint32 settlementRewardEscrowScaled_) external {
        treasurySettlementRewardEscrowScaled = settlementRewardEscrowScaled_;
    }

    function canAcceptHookFunding() public view returns (bool) {
        if (!canAccept || resolved) return false;
        return state == IGoalTreasury.GoalState.Funding || state == IGoalTreasury.GoalState.Active;
    }

    function processHookSplit(
        address sourceToken,
        uint256 sourceAmount
    )
        external
        returns (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount)
    {
        if (canAcceptHookFunding()) {
            if (!accepted) revert GOAL_TREASURY_REJECTED();
            callCount += 1;
            lastAmount = sourceAmount;
            return (IGoalTreasury.HookSplitAction.Funded, sourceAmount, 0, 0);
        }

        if (state == IGoalTreasury.GoalState.Succeeded && mintingOpen) {
            rewardAmount = (sourceAmount * treasurySettlementRewardEscrowScaled) / 1_000_000;
            burnAmount = sourceAmount - rewardAmount;

            if (rewardAmount != 0) {
                require(IERC20(sourceToken).transfer(rewardEscrow, rewardAmount), "REWARD_TRANSFER_FAILED");
            }
            if (burnAmount != 0) {
                HookMockReservedTokenController(_burnController).burnTokensOf(
                    address(this), _burnProjectId, burnAmount, "GOAL_SUCCESS_SETTLEMENT_BURN"
                );
            }
            return (IGoalTreasury.HookSplitAction.SuccessSettled, 0, rewardAmount, burnAmount);
        }

        if (resolved) {
            burnAmount = sourceAmount;
            if (burnAmount != 0) {
                HookMockReservedTokenController(_burnController).burnTokensOf(
                    address(this), _burnProjectId, burnAmount, "GOAL_TERMINAL_RESIDUAL_BURN"
                );
            }
            return (IGoalTreasury.HookSplitAction.TerminalSettled, sourceAmount, 0, burnAmount);
        }

        deferredHookSuperTokenAmount += sourceAmount;
        return (IGoalTreasury.HookSplitAction.Deferred, sourceAmount, 0, 0);
    }
}

contract HookMockFlow {
    ISuperToken private immutable _superToken;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }
}

contract HookMockUnderlying is ERC20 {
    uint16 private _transferFeeBps;

    constructor() ERC20("Underlying", "UND") { }

    function setTransferFeeBps(uint16 feeBps) external {
        _transferFeeBps = feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = (amount * _transferFeeBps) / 10_000;
        uint256 received = amount - fee;

        super._update(from, to, received);
        if (fee != 0) {
            _burn(from, fee);
        }
    }
}

contract HookMockSuperToken is ERC20 {
    address private immutable _underlying;
    uint16 private _transferFeeBps;
    uint16 private _upgradeMintBps = 10_000;

    constructor(address underlying_) ERC20("Super", "SUP") {
        _underlying = underlying_;
    }

    function setTransferFeeBps(uint16 feeBps) external {
        _transferFeeBps = feeBps;
    }

    function setUpgradeMintBps(uint16 mintBps) external {
        _upgradeMintBps = mintBps;
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlying;
    }

    function upgrade(uint256 amount) external {
        require(IERC20(_underlying).transferFrom(msg.sender, address(this), amount), "UNDERLYING_TRANSFER_FROM_FAILED");
        uint256 minted = (amount * _upgradeMintBps) / 10_000;
        _mint(msg.sender, minted);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = (amount * _transferFeeBps) / 10_000;
        uint256 received = amount - fee;

        super._update(from, to, received);
        if (fee != 0) {
            _burn(from, fee);
        }
    }
}

contract HookMockReservedTokenController {
    uint256 public burnCallCount;
    uint256 public lastBurnProjectId;
    uint256 public lastBurnAmount;
    bool public shouldRevertBurn;

    function setShouldRevertBurn(bool shouldRevertBurn_) external {
        shouldRevertBurn = shouldRevertBurn_;
    }

    function burnTokensOf(address, uint256 projectId, uint256 tokenCount, string calldata) external {
        if (shouldRevertBurn) revert("BURN_REVERT");
        burnCallCount += 1;
        lastBurnProjectId = projectId;
        lastBurnAmount = tokenCount;
    }

    function sendReservedSplit(
        GoalRevnetSplitHook hook,
        IERC20 transferToken,
        address contextToken,
        uint256 amount,
        uint256 projectId,
        uint256 groupId
    )
        external
    {
        if (amount != 0) {
            require(transferToken.transfer(address(hook), amount), "TRANSFER_FAILED");
        }

        hook.processSplitWith(
            JBSplitHookContext({
                token: contextToken,
                amount: amount,
                decimals: 18,
                projectId: projectId,
                groupId: groupId,
                split: JBSplit({
                    percent: 0,
                    projectId: 0,
                    beneficiary: payable(address(0)),
                    preferAddToBalance: false,
                    lockedUntil: 0,
                    hook: IJBSplitHook(address(0))
                })
            })
        );
    }
}
