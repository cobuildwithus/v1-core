// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CobuildExitRouter} from "src/juicebox/CobuildExitRouter.sol";
import {ICobuildCommunityTerminal} from "src/interfaces/ICobuildCommunityTerminal.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v5/interfaces/IJBCashOutTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildExitRouterTest is Test {
    uint256 internal constant GOAL_ID = 1;
    uint256 internal constant CHILD_COMMUNITY_ID = 2;
    uint256 internal constant COMMUNITY_ID = 3;
    uint256 internal constant COBUILD_ID = 4;

    CobuildExitRouterMockToken internal goalToken;
    CobuildExitRouterMockToken internal childCommunityToken;
    CobuildExitRouterMockToken internal communityToken;
    CobuildExitRouterMockToken internal cobuildToken;

    CobuildExitRouterMockDirectory internal directory;
    CobuildExitRouterMockTokens internal tokens;
    CobuildExitRouterMockController internal controller;
    CobuildExitRouterMockGoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildExitRouterMockGoalTreasury internal goalTreasury;
    CobuildExitRouterMockStakeVault internal stakeVault;
    CobuildExitRouterMockCommunityTerminal internal communityTerminal;

    CobuildExitRouterMockCashOutTerminal internal goalToChildTerminal;
    CobuildExitRouterMockCashOutTerminal internal goalToCommunityTerminal;
    CobuildExitRouterMockCashOutTerminal internal goalToCobuildTerminal;
    CobuildExitRouterMockCashOutTerminal internal childToCommunityTerminal;
    CobuildExitRouterMockCashOutTerminal internal communityToChildTerminal;
    CobuildExitRouterMockCashOutTerminal internal communityToCobuildTerminal;
    CobuildExitRouterMockCashOutTerminal internal communityToNativeTerminal;
    CobuildExitRouterMockCashOutTerminal internal cobuildToNativeTerminal;

    CobuildExitRouter internal router;

    function setUp() public {
        goalToken = new CobuildExitRouterMockToken("Goal", "GOAL");
        childCommunityToken = new CobuildExitRouterMockToken("Child Community", "CHILD");
        communityToken = new CobuildExitRouterMockToken("Community", "COMM");
        cobuildToken = new CobuildExitRouterMockToken("Cobuild", "COBUILD");

        directory = new CobuildExitRouterMockDirectory();
        tokens = new CobuildExitRouterMockTokens();
        controller = new CobuildExitRouterMockController(tokens);
        goalDeploymentRegistry = new CobuildExitRouterMockGoalDeploymentRegistry();
        stakeVault = new CobuildExitRouterMockStakeVault();
        goalTreasury = new CobuildExitRouterMockGoalTreasury();
        communityTerminal = new CobuildExitRouterMockCommunityTerminal(tokens);

        goalToChildTerminal = new CobuildExitRouterMockCashOutTerminal(goalToken);
        goalToCommunityTerminal = new CobuildExitRouterMockCashOutTerminal(goalToken);
        goalToCobuildTerminal = new CobuildExitRouterMockCashOutTerminal(goalToken);
        childToCommunityTerminal = new CobuildExitRouterMockCashOutTerminal(childCommunityToken);
        communityToChildTerminal = new CobuildExitRouterMockCashOutTerminal(communityToken);
        communityToCobuildTerminal = new CobuildExitRouterMockCashOutTerminal(communityToken);
        communityToNativeTerminal = new CobuildExitRouterMockCashOutTerminal(communityToken);
        cobuildToNativeTerminal = new CobuildExitRouterMockCashOutTerminal(cobuildToken);

        tokens.setTokenOf(GOAL_ID, address(goalToken));
        tokens.setTokenOf(CHILD_COMMUNITY_ID, address(childCommunityToken));
        tokens.setTokenOf(COMMUNITY_ID, address(communityToken));
        tokens.setTokenOf(COBUILD_ID, address(cobuildToken));

        directory.setController(GOAL_ID, IJBController(address(controller)));
        directory.setController(CHILD_COMMUNITY_ID, IJBController(address(controller)));
        directory.setController(COMMUNITY_ID, IJBController(address(controller)));
        directory.setController(COBUILD_ID, IJBController(address(controller)));

        goalDeploymentRegistry.setGoalTreasury(GOAL_ID, address(goalTreasury));

        router = new CobuildExitRouter(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            ICobuildCommunityTerminal(address(communityTerminal)),
            cobuildToken,
            COBUILD_ID
        );

        vm.deal(address(cobuildToNativeTerminal), 20 ether);
        vm.deal(address(communityTerminal), 20 ether);
        vm.deal(address(communityToNativeTerminal), 20 ether);
    }

    function test_exitToCommunityToken_transfersImmediateCommunityToken() public {
        _configureGoal(COMMUNITY_ID, address(communityToken));
        communityTerminal.setConfig(COMMUNITY_ID, address(cobuildToken), COBUILD_ID, false, true);
        directory.setPrimaryTerminal(GOAL_ID, address(communityToken), IJBTerminal(address(goalToCommunityTerminal)));

        goalToken.mint(address(this), 5 ether);
        goalToken.approve(address(router), 5 ether);

        address beneficiary = makeAddr("beneficiary");
        uint256 amountOut = router.exitToCommunityToken(
            GOAL_ID, 5 ether, 5 ether, beneficiary, block.timestamp + 1, bytes("goal-exit")
        );

        assertEq(amountOut, 5 ether);
        assertEq(communityToken.balanceOf(beneficiary), 5 ether);
        assertEq(goalToken.balanceOf(address(router)), 0);
    }

    function test_exitToCobuildToken_walksConfiguredCommunityLineage() public {
        _configureGoal(CHILD_COMMUNITY_ID, address(childCommunityToken));
        communityTerminal.setConfig(CHILD_COMMUNITY_ID, address(communityToken), COMMUNITY_ID, false, true);
        communityTerminal.setConfig(COMMUNITY_ID, address(cobuildToken), COBUILD_ID, false, true);

        directory.setPrimaryTerminal(GOAL_ID, address(childCommunityToken), IJBTerminal(address(goalToChildTerminal)));
        directory.setPrimaryTerminal(
            CHILD_COMMUNITY_ID, address(communityToken), IJBTerminal(address(communityTerminal))
        );
        directory.setPrimaryTerminal(COMMUNITY_ID, address(cobuildToken), IJBTerminal(address(communityTerminal)));

        goalToken.mint(address(this), 4 ether);
        goalToken.approve(address(router), 4 ether);

        address beneficiary = makeAddr("beneficiary");
        uint256 amountOut =
            router.exitToCobuildToken(GOAL_ID, 4 ether, 4 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 4 ether);
        assertEq(cobuildToken.balanceOf(beneficiary), 4 ether);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(childCommunityToken.balanceOf(address(router)), 0);
        assertEq(communityToken.balanceOf(address(router)), 0);
    }

    function test_exitToEth_cashesOutFinalRootToNative() public {
        _configureGoal(CHILD_COMMUNITY_ID, address(childCommunityToken));
        communityTerminal.setConfig(CHILD_COMMUNITY_ID, address(communityToken), COMMUNITY_ID, false, true);
        communityTerminal.setConfig(COMMUNITY_ID, address(cobuildToken), COBUILD_ID, false, true);

        directory.setPrimaryTerminal(GOAL_ID, address(childCommunityToken), IJBTerminal(address(goalToChildTerminal)));
        directory.setPrimaryTerminal(
            CHILD_COMMUNITY_ID, address(communityToken), IJBTerminal(address(communityTerminal))
        );
        directory.setPrimaryTerminal(COMMUNITY_ID, address(cobuildToken), IJBTerminal(address(communityTerminal)));
        directory.setPrimaryTerminal(
            COBUILD_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(cobuildToNativeTerminal))
        );

        goalToken.mint(address(this), 3 ether);
        goalToken.approve(address(router), 3 ether);

        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 amountOut =
            router.exitToEth(GOAL_ID, 3 ether, 3 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 3 ether);
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, 3 ether);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(childCommunityToken.balanceOf(address(router)), 0);
        assertEq(communityToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
    }

    function test_exitToCommunityToken_revertsWhenImmediateLayerIsCobuildRoot() public {
        _configureGoal(COBUILD_ID, address(cobuildToken));
        directory.setPrimaryTerminal(GOAL_ID, address(cobuildToken), IJBTerminal(address(goalToCobuildTerminal)));

        goalToken.mint(address(this), 1 ether);
        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.NO_COMMUNITY_LAYER.selector, GOAL_ID));
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenImmediateLayerIsNotRegisteredCommunity() public {
        _configureGoal(CHILD_COMMUNITY_ID, address(childCommunityToken));
        directory.setPrimaryTerminal(GOAL_ID, address(childCommunityToken), IJBTerminal(address(goalToChildTerminal)));

        goalToken.mint(address(this), 1 ether);
        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.INVALID_COMMUNITY_LAYER.selector, CHILD_COMMUNITY_ID, address(childCommunityToken)
            )
        );
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCommunityToken_revertsWhenBeneficiaryIsRouter() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.SELF_BENEFICIARY.selector));
        router.exitToCommunityToken(GOAL_ID, 1 ether, 0, address(router), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_supportsDirectNativeCommunityRoot() public {
        _configureGoal(COMMUNITY_ID, address(communityToken));
        communityTerminal.setConfig(COMMUNITY_ID, address(communityToken), COMMUNITY_ID, true, true);

        directory.setPrimaryTerminal(GOAL_ID, address(communityToken), IJBTerminal(address(goalToCommunityTerminal)));
        directory.setPrimaryTerminal(COMMUNITY_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(communityTerminal)));

        goalToken.mint(address(this), 2 ether);
        goalToken.approve(address(router), 2 ether);

        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 amountOut =
            router.exitToEth(GOAL_ID, 2 ether, 2 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 2 ether);
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, 2 ether);
    }

    function test_exitToEth_revertsWhenBeneficiaryIsRouter() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildExitRouter.SELF_BENEFICIARY.selector));
        router.exitToEth(GOAL_ID, 1 ether, 0, payable(address(router)), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToEth_supportsMaxCommunityHopsBeforeCobuild() public {
        uint256[] memory hopIds = new uint256[](8);
        CobuildExitRouterMockToken[] memory hopTokens = new CobuildExitRouterMockToken[](8);

        for (uint256 i; i < hopIds.length; i++) {
            uint256 hopId = 100 + i;
            hopIds[i] = hopId;
            hopTokens[i] = new CobuildExitRouterMockToken("Hop", "HOP");

            tokens.setTokenOf(hopId, address(hopTokens[i]));
            directory.setController(hopId, IJBController(address(controller)));
        }

        for (uint256 i; i < hopIds.length; i++) {
            address paymentToken = i + 1 == hopIds.length ? address(cobuildToken) : address(hopTokens[i + 1]);
            uint256 paymentSourceRevnetId = i + 1 == hopIds.length ? COBUILD_ID : hopIds[i + 1];

            communityTerminal.setConfig(hopIds[i], paymentToken, paymentSourceRevnetId, false, true);
            directory.setPrimaryTerminal(hopIds[i], paymentToken, IJBTerminal(address(communityTerminal)));
        }

        _configureGoal(hopIds[0], address(hopTokens[0]));
        directory.setPrimaryTerminal(GOAL_ID, address(hopTokens[0]), IJBTerminal(address(goalToChildTerminal)));
        directory.setPrimaryTerminal(
            COBUILD_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(cobuildToNativeTerminal))
        );

        goalToken.mint(address(this), 1 ether);
        goalToken.approve(address(router), 1 ether);

        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 amountOut =
            router.exitToEth(GOAL_ID, 1 ether, 1 ether, beneficiary, block.timestamp + 1, bytes("goal-exit"));

        assertEq(amountOut, 1 ether);
        assertEq(beneficiary.balance - beneficiaryBalanceBefore, 1 ether);
    }

    function test_exitToCobuildToken_revertsWhenCommunityRootOnlySupportsDirectNativeExit() public {
        _configureGoal(COMMUNITY_ID, address(communityToken));
        communityTerminal.setConfig(COMMUNITY_ID, address(communityToken), COMMUNITY_ID, true, true);

        directory.setPrimaryTerminal(GOAL_ID, address(communityToken), IJBTerminal(address(goalToCommunityTerminal)));

        goalToken.mint(address(this), 1 ether);
        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.COBUILD_ROUTE_UNAVAILABLE.selector, COMMUNITY_ID, address(communityToken)
            )
        );
        router.exitToCobuildToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCobuildToken_revertsWhenCommunityHopTerminalIsRetargeted() public {
        _configureGoal(CHILD_COMMUNITY_ID, address(childCommunityToken));
        communityTerminal.setConfig(CHILD_COMMUNITY_ID, address(communityToken), COMMUNITY_ID, false, true);

        directory.setPrimaryTerminal(GOAL_ID, address(childCommunityToken), IJBTerminal(address(goalToChildTerminal)));
        directory.setPrimaryTerminal(
            CHILD_COMMUNITY_ID, address(communityToken), IJBTerminal(address(childToCommunityTerminal))
        );

        goalToken.mint(address(this), 1 ether);
        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildExitRouter.INVALID_COMMUNITY_TERMINAL.selector,
                CHILD_COMMUNITY_ID,
                address(communityToken),
                address(childToCommunityTerminal)
            )
        );
        router.exitToCobuildToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function test_exitToCobuildToken_revertsWhenCommunityLineageLoopsPastMaxHops() public {
        _configureGoal(CHILD_COMMUNITY_ID, address(childCommunityToken));
        communityTerminal.setConfig(CHILD_COMMUNITY_ID, address(communityToken), COMMUNITY_ID, false, true);
        communityTerminal.setConfig(COMMUNITY_ID, address(childCommunityToken), CHILD_COMMUNITY_ID, false, true);

        directory.setPrimaryTerminal(GOAL_ID, address(childCommunityToken), IJBTerminal(address(goalToChildTerminal)));
        directory.setPrimaryTerminal(
            CHILD_COMMUNITY_ID, address(communityToken), IJBTerminal(address(communityTerminal))
        );
        directory.setPrimaryTerminal(
            COMMUNITY_ID, address(childCommunityToken), IJBTerminal(address(communityTerminal))
        );

        goalToken.mint(address(this), 1 ether);
        goalToken.approve(address(router), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildExitRouter.MAX_COMMUNITY_HOPS_EXCEEDED.selector, router.MAX_COMMUNITY_HOPS())
        );
        router.exitToCobuildToken(GOAL_ID, 1 ether, 0, address(this), block.timestamp + 1, bytes("goal-exit"));
    }

    function _configureGoal(uint256 paymentRevnetId, address paymentToken) internal {
        goalTreasury.setCobuildRevnetId(paymentRevnetId);
        goalTreasury.setStakeVault(address(stakeVault));
        stakeVault.setCobuildToken(paymentToken);
    }
}

contract CobuildExitRouterMockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;
    mapping(uint256 => IJBController) internal _controllerOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }

    function setController(uint256 projectId, IJBController controller_) external {
        _controllerOf[projectId] = controller_;
    }

    function controllerOf(uint256 projectId) external view returns (IJBController) {
        return _controllerOf[projectId];
    }
}

contract CobuildExitRouterMockTokens {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract CobuildExitRouterMockController {
    CobuildExitRouterMockTokens internal immutable _tokens;

    constructor(CobuildExitRouterMockTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (CobuildExitRouterMockTokens) {
        return _tokens;
    }
}

contract CobuildExitRouterMockGoalDeploymentRegistry {
    mapping(uint256 => address) internal _goalTreasuryOf;

    function setGoalTreasury(uint256 goalId, address goalTreasury) external {
        _goalTreasuryOf[goalId] = goalTreasury;
    }

    function goalTreasuryOf(uint256 goalId) external view returns (address) {
        return _goalTreasuryOf[goalId];
    }
}

contract CobuildExitRouterMockGoalTreasury {
    uint256 public cobuildRevnetId;
    address public stakeVault;

    function setCobuildRevnetId(uint256 cobuildRevnetId_) external {
        cobuildRevnetId = cobuildRevnetId_;
    }

    function setStakeVault(address stakeVault_) external {
        stakeVault = stakeVault_;
    }
}

contract CobuildExitRouterMockStakeVault {
    address public cobuildToken;

    function setCobuildToken(address cobuildToken_) external {
        cobuildToken = cobuildToken_;
    }
}

contract CobuildExitRouterMockCommunityTerminal is ICobuildCommunityTerminal, IJBCashOutTerminal {
    CobuildExitRouterMockTokens internal immutable _tokens;

    struct CommunityConfig {
        address paymentToken;
        uint256 paymentSourceRevnetId;
        bool directNativeAllowed;
        bool exists;
    }

    mapping(uint256 => CommunityConfig) internal _configOf;

    constructor(CobuildExitRouterMockTokens tokens_) {
        _tokens = tokens_;
    }

    receive() external payable {}

    function setConfig(
        uint256 communityRevnetId,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed,
        bool exists
    ) external {
        _configOf[communityRevnetId] = CommunityConfig({
            paymentToken: paymentToken,
            paymentSourceRevnetId: paymentSourceRevnetId,
            directNativeAllowed: directNativeAllowed,
            exists: exists
        });
    }

    function communityConfigOf(uint256 communityRevnetId)
        external
        view
        returns (
            ICobuildSplitHook splitHook,
            address paymentToken,
            uint256 paymentSourceRevnetId,
            bool directNativeAllowed,
            bool exists
        )
    {
        CommunityConfig memory config = _configOf[communityRevnetId];
        splitHook = ICobuildSplitHook(address(0));
        paymentToken = config.paymentToken;
        paymentSourceRevnetId = config.paymentSourceRevnetId;
        directNativeAllowed = config.directNativeAllowed;
        exists = config.exists;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICobuildCommunityTerminal).interfaceId
            || interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId;
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    ) external override returns (uint256 reclaimAmount) {
        CobuildExitRouterMockToken(_tokens.tokenOf(projectId)).burn(holder, cashOutCount);
        reclaimAmount = cashOutCount;
        require(reclaimAmount >= minTokensReclaimed, "MIN");

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: reclaimAmount}("");
            require(success, "NATIVE");
        } else {
            CobuildExitRouterMockToken(tokenToReclaim).mint(beneficiary, reclaimAmount);
        }

        emit CashOutTokens(1, 1, projectId, holder, beneficiary, cashOutCount, 0, reclaimAmount, metadata, msg.sender);
    }

    function accountingContextForTokenOf(uint256, address token)
        external
        pure
        override
        returns (JBAccountingContext memory context)
    {
        context = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256, uint256)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata)
        external
        payable
        override
    {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(uint256, address, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        override
        returns (uint256)
    {
        return amount;
    }
}

contract CobuildExitRouterMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract CobuildExitRouterMockCashOutTerminal is IJBCashOutTerminal {
    CobuildExitRouterMockToken internal immutable _projectToken;

    constructor(CobuildExitRouterMockToken projectToken_) {
        _projectToken = projectToken_;
    }

    receive() external payable {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBCashOutTerminal).interfaceId || interfaceId == type(IJBTerminal).interfaceId;
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    ) external override returns (uint256 reclaimAmount) {
        _projectToken.burn(holder, cashOutCount);
        reclaimAmount = cashOutCount;
        require(reclaimAmount >= minTokensReclaimed, "MIN");

        if (tokenToReclaim == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: reclaimAmount}("");
            require(success, "NATIVE");
        } else {
            CobuildExitRouterMockToken(tokenToReclaim).mint(beneficiary, reclaimAmount);
        }

        emit CashOutTokens(1, 1, projectId, holder, beneficiary, cashOutCount, 0, reclaimAmount, metadata, msg.sender);
    }

    function accountingContextForTokenOf(uint256, address token)
        external
        pure
        override
        returns (JBAccountingContext memory context)
    {
        context = JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](0);
    }

    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256, uint256)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata)
        external
        payable
        override
    {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(uint256, address, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        override
        returns (uint256)
    {
        return amount;
    }
}
