// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { CobuildSplitHook } from "src/hooks/CobuildSplitHook.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";

contract CobuildSplitHookTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 77;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;
    uint256 internal constant GOAL_ID_ONE = 101;
    uint256 internal constant GOAL_ID_TWO = 202;

    address internal controller = makeAddr("controller");
    address internal routeSetter = makeAddr("route-setter");
    address internal beneficiary = makeAddr("beneficiary");
    address internal historicalBeneficiary = makeAddr("historical-beneficiary");
    address internal newOwner = makeAddr("new-owner");

    CobuildSplitHookMockToken internal communityToken;
    CobuildSplitHookMockDirectory internal directory;
    CobuildSplitHookMockGoalTerminal internal goalTerminalOne;
    CobuildSplitHookMockGoalTerminal internal goalTerminalTwo;
    CobuildSplitHook internal hook;

    function setUp() public {
        communityToken = new CobuildSplitHookMockToken("Community", "COMM");
        directory = new CobuildSplitHookMockDirectory();
        goalTerminalOne = new CobuildSplitHookMockGoalTerminal(communityToken);
        goalTerminalTwo = new CobuildSplitHookMockGoalTerminal(communityToken);

        hook = _deployHook();

        directory.setController(COMMUNITY_REVNET_ID, controller);
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(communityToken), IJBTerminal(address(goalTerminalOne)));
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(communityToken), IJBTerminal(address(goalTerminalTwo)));

        hook.setApprovedGoal(GOAL_ID_ONE, true);
        hook.setApprovedGoal(GOAL_ID_TWO, true);
        hook.setRouteSetter(routeSetter);
    }

    function test_processSplitWith_consumesPendingRoute_andRecordsObservedVolume() public {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, _goalIds(), _weights(1, 3));

        communityToken.mint(address(hook), 100e18);

        vm.prank(controller);
        hook.processSplitWith(_context(100e18));

        assertFalse(hook.hasPendingRoute());
        assertEq(goalTerminalOne.totalReceived(), 25e18);
        assertEq(goalTerminalTwo.totalReceived(), 75e18);
        assertEq(goalTerminalOne.lastBeneficiary(), beneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), beneficiary);
        assertEq(communityToken.balanceOf(address(hook)), 0);
        assertEq(hook.observedVolumeOf(GOAL_ID_ONE), 25e18);
        assertEq(hook.observedVolumeOf(GOAL_ID_TWO), 75e18);
        assertEq(hook.observedTotalVolume(), 100e18);
    }

    function test_processSplitWith_usesHistoricalRouteForPendingHistoricalRoute() public {
        _seedObservedRoute(100e18, 2, 3, beneficiary);

        vm.prank(routeSetter);
        hook.beginPendingHistoricalRoute(historicalBeneficiary, historicalBeneficiary);

        communityToken.mint(address(hook), 50e18);

        vm.prank(controller);
        hook.processSplitWith(_context(50e18));

        assertEq(goalTerminalOne.totalReceived(), 60e18);
        assertEq(goalTerminalTwo.totalReceived(), 90e18);
        assertEq(goalTerminalOne.lastBeneficiary(), historicalBeneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), historicalBeneficiary);
        assertEq(hook.observedVolumeOf(GOAL_ID_ONE), 40e18);
        assertEq(hook.observedVolumeOf(GOAL_ID_TWO), 60e18);
        assertEq(hook.observedTotalVolume(), 100e18);
    }

    function test_processSplitWith_usesManualDefaultForPendingHistoricalRouteWithoutHistory() public {
        hook.setDefaultRoute(_goalIds(), _weights(2, 1));

        vm.prank(routeSetter);
        hook.beginPendingHistoricalRoute(historicalBeneficiary, historicalBeneficiary);

        communityToken.mint(address(hook), 90e18);

        vm.prank(controller);
        hook.processSplitWith(_context(90e18));

        assertEq(goalTerminalOne.totalReceived(), 60e18);
        assertEq(goalTerminalTwo.totalReceived(), 30e18);
        assertEq(goalTerminalOne.lastBeneficiary(), historicalBeneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), historicalBeneficiary);
        assertEq(hook.observedTotalVolume(), 0);
    }

    function test_processSplitWith_usesHistoricalRouteForDirectPayWhenDefaultBeneficiarySet() public {
        _seedObservedRoute(100e18, 2, 3, beneficiary);
        hook.setDefaultBeneficiary(historicalBeneficiary);

        communityToken.mint(address(hook), 50e18);

        vm.prank(controller);
        hook.processSplitWith(_context(50e18));

        assertEq(goalTerminalOne.totalReceived(), 60e18);
        assertEq(goalTerminalTwo.totalReceived(), 90e18);
        assertEq(goalTerminalOne.lastBeneficiary(), historicalBeneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), historicalBeneficiary);
        assertEq(hook.observedTotalVolume(), 100e18);
    }

    function test_processSplitWith_usesManualDefaultForDirectPayWhenNoHistoryExists() public {
        hook.setDefaultBeneficiary(beneficiary);
        hook.setDefaultRoute(_goalIds(), _weights(2, 1));

        communityToken.mint(address(hook), 90e18);

        vm.prank(controller);
        hook.processSplitWith(_context(90e18));

        assertEq(goalTerminalOne.totalReceived(), 60e18);
        assertEq(goalTerminalTwo.totalReceived(), 30e18);
        assertEq(goalTerminalOne.lastBeneficiary(), beneficiary);
        assertEq(goalTerminalTwo.lastBeneficiary(), beneficiary);
        assertEq(hook.observedTotalVolume(), 0);
    }

    function test_processSplitWith_escrowsDirectPayWithoutDefaultBeneficiaryEvenWhenHistoryExists() public {
        _seedObservedRoute(100e18, 2, 3, beneficiary);

        communityToken.mint(address(hook), 50e18);

        vm.prank(controller);
        hook.processSplitWith(_context(50e18));

        assertEq(goalTerminalOne.totalReceived(), 40e18);
        assertEq(goalTerminalTwo.totalReceived(), 60e18);
        assertEq(communityToken.balanceOf(address(hook)), 50e18);
        assertEq(hook.observedVolumeOf(GOAL_ID_ONE), 40e18);
        assertEq(hook.observedVolumeOf(GOAL_ID_TWO), 60e18);
        assertEq(hook.observedTotalVolume(), 100e18);
    }

    function test_processSplitWith_escrowsDirectPayWithoutDefaultBeneficiaryEvenWhenManualDefaultExists() public {
        hook.setDefaultRoute(_goalIds(), _weights(2, 1));

        communityToken.mint(address(hook), 90e18);

        vm.prank(controller);
        hook.processSplitWith(_context(90e18));

        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(goalTerminalTwo.totalReceived(), 0);
        assertEq(communityToken.balanceOf(address(hook)), 90e18);
        assertEq(hook.observedTotalVolume(), 0);
    }

    function test_processSplitWith_ignoresUnapprovedGoalsWhenDerivingHistoricalRoute() public {
        _seedObservedRoute(100e18, 1, 3, beneficiary);
        hook.setApprovedGoal(GOAL_ID_TWO, false);
        hook.setDefaultBeneficiary(historicalBeneficiary);

        communityToken.mint(address(hook), 40e18);

        vm.prank(controller);
        hook.processSplitWith(_context(40e18));

        assertEq(goalTerminalOne.totalReceived(), 65e18);
        assertEq(goalTerminalTwo.totalReceived(), 75e18);
        assertEq(goalTerminalOne.lastBeneficiary(), historicalBeneficiary);

        (uint256[] memory historicalGoalIds, uint256[] memory historicalVolumes) = hook.historicalRoute();
        assertEq(historicalGoalIds.length, 1);
        assertEq(historicalGoalIds[0], GOAL_ID_ONE);
        assertEq(historicalVolumes.length, 1);
        assertEq(historicalVolumes[0], 25e18);
    }

    function test_processSplitWith_escrowsWhenNoRouteIsAvailable() public {
        communityToken.mint(address(hook), 50e18);

        vm.prank(controller);
        hook.processSplitWith(_context(50e18));

        assertEq(goalTerminalOne.totalReceived(), 0);
        assertEq(goalTerminalTwo.totalReceived(), 0);
        assertEq(communityToken.balanceOf(address(hook)), 50e18);
    }

    function test_sweepEscrowed_routesHeldBalanceUsingExplicitRoute() public {
        communityToken.mint(address(hook), 80e18);

        uint256 sweptAmount = hook.sweepEscrowed(beneficiary, _goalIds(), _weights(1, 1));

        assertEq(sweptAmount, 80e18);
        assertEq(goalTerminalOne.totalReceived(), 40e18);
        assertEq(goalTerminalTwo.totalReceived(), 40e18);
        assertEq(communityToken.balanceOf(address(hook)), 0);
    }

    function test_processSplitWith_revertsWhenSelectedGoalHasNoPrimaryTerminal() public {
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(communityToken), IJBTerminal(address(0)));

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = GOAL_ID_ONE;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary, beneficiary, goalIds, weights);

        communityToken.mint(address(hook), 10e18);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.NO_GOAL_TERMINAL.selector, GOAL_ID_ONE));
        hook.processSplitWith(_context(10e18));
    }

    function test_beginPendingRoute_revertsForUnapprovedGoal() public {
        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 999;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.prank(routeSetter);
        vm.expectRevert(abi.encodeWithSelector(CobuildSplitHook.GOAL_NOT_APPROVED.selector, 999));
        hook.beginPendingRoute(beneficiary, beneficiary, goalIds, weights);
    }

    function test_beginPendingHistoricalRoute_revertsWhenCallerIsNotRouteSetter() public {
        vm.prank(makeAddr("not-route-setter"));
        vm.expectRevert(CobuildSplitHook.UNAUTHORIZED.selector);
        hook.beginPendingHistoricalRoute(beneficiary, beneficiary);
    }

    function test_processSplitWith_revertsWhenCallerIsNotController() public {
        communityToken.mint(address(hook), 10e18);

        vm.expectRevert(CobuildSplitHook.UNAUTHORIZED.selector);
        hook.processSplitWith(_context(10e18));
    }

    function test_transferOwnership_updatesRouteSetterWhenPreviousOwnerWasRouteSetter() public {
        hook.setRouteSetter(address(this));

        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner);
        assertEq(hook.routeSetter(), newOwner);
    }

    function _deployHook() internal returns (CobuildSplitHook deployedHook) {
        CobuildSplitHook implementation = new CobuildSplitHook();
        deployedHook = CobuildSplitHook(payable(Clones.clone(address(implementation))));
        deployedHook.initialize(IJBDirectory(address(directory)), COMMUNITY_REVNET_ID, address(communityToken), address(this));
    }

    function _seedObservedRoute(uint256 amount, uint32 firstWeight, uint32 secondWeight, address beneficiary_) internal {
        vm.prank(routeSetter);
        hook.beginPendingRoute(beneficiary_, beneficiary_, _goalIds(), _weights(firstWeight, secondWeight));

        communityToken.mint(address(hook), amount);

        vm.prank(controller);
        hook.processSplitWith(_context(amount));
    }

    function _goalIds() internal pure returns (uint256[] memory goalIds) {
        goalIds = new uint256[](2);
        goalIds[0] = GOAL_ID_ONE;
        goalIds[1] = GOAL_ID_TWO;
    }

    function _weights(uint32 firstWeight, uint32 secondWeight) internal pure returns (uint32[] memory weights) {
        weights = new uint32[](2);
        weights[0] = firstWeight;
        weights[1] = secondWeight;
    }

    function _context(uint256 amount) internal view returns (JBSplitHookContext memory context) {
        context = JBSplitHookContext({
            token: address(communityToken),
            amount: amount,
            decimals: 18,
            projectId: COMMUNITY_REVNET_ID,
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

contract CobuildSplitHookMockDirectory {
    mapping(uint256 projectId => address controller) internal _controllerOf;
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _primaryTerminalOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract CobuildSplitHookMockGoalTerminal {
    CobuildSplitHookMockToken internal immutable _token;

    uint256 public totalReceived;
    uint256 public lastProjectId;
    address public lastBeneficiary;
    uint256 public lastAmount;

    constructor(CobuildSplitHookMockToken token_) {
        _token = token_;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    ) external returns (uint256 beneficiaryTokenCount) {
        require(token == address(_token), "token");
        _token.transferFrom(msg.sender, address(this), amount);

        totalReceived += amount;
        lastProjectId = projectId;
        lastBeneficiary = beneficiary;
        lastAmount = amount;

        return amount;
    }
}

contract CobuildSplitHookMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
