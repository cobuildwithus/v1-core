// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CobuildPaymentTerminal} from "src/juicebox/CobuildPaymentTerminal.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildPaymentTerminalTest is Test {
    uint256 internal constant PAYMENT_SOURCE_REVNET_ID = 138;
    uint256 internal constant COMMUNITY_REVNET_ID = 777;

    CobuildPaymentTerminalMockToken internal paymentToken;
    CobuildPaymentTerminalMockDirectory internal directory;
    CobuildPaymentTerminalMockTokens internal tokens;
    CobuildPaymentTerminalMockGoalRegistry internal goalRegistry;
    CobuildPaymentTerminalMockSplitHook internal splitHook;
    CobuildPaymentTerminalMockController internal controller;
    CobuildPaymentTerminalMockPaymentSourceTerminal internal sourceTerminal;
    CobuildPaymentTerminal internal paymentTerminal;

    function setUp() public {
        paymentToken = new CobuildPaymentTerminalMockToken("Payment", "PAY");
        directory = new CobuildPaymentTerminalMockDirectory();
        tokens = new CobuildPaymentTerminalMockTokens();
        goalRegistry = new CobuildPaymentTerminalMockGoalRegistry(
            address(this), IJBDirectory(address(directory)), COMMUNITY_REVNET_ID, address(paymentToken)
        );
        splitHook = new CobuildPaymentTerminalMockSplitHook(COMMUNITY_REVNET_ID, address(paymentToken), address(goalRegistry));
        controller = new CobuildPaymentTerminalMockController(splitHook, tokens);
        sourceTerminal = new CobuildPaymentTerminalMockPaymentSourceTerminal(paymentToken);
        paymentTerminal = new CobuildPaymentTerminal(IJBDirectory(address(directory)));

        splitHook.setRouteSetter(address(paymentTerminal));
        tokens.setTokenOf(PAYMENT_SOURCE_REVNET_ID, address(paymentToken));
        tokens.setTokenOf(COMMUNITY_REVNET_ID, address(paymentToken));

        directory.setController(PAYMENT_SOURCE_REVNET_ID, IJBController(address(controller)));
        directory.setController(COMMUNITY_REVNET_ID, IJBController(address(controller)));
        directory.setProjectOwner(COMMUNITY_REVNET_ID, address(this));
        directory.setPrimaryTerminal(
            PAYMENT_SOURCE_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal))
        );
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(paymentTerminal)));
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, address(paymentToken), IJBTerminal(address(paymentTerminal)));
    }

    function test_registerCommunity_storesConfig() public {
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );

        (
            ICobuildSplitHook storedSplitHook,
            address storedPaymentToken,
            uint256 storedPaymentSourceRevnetId,
            bool directNativeAllowed,
            bool exists
        ) = paymentTerminal.communityConfigOf(COMMUNITY_REVNET_ID);

        assertEq(address(storedSplitHook), address(splitHook));
        assertEq(storedPaymentToken, address(paymentToken));
        assertEq(storedPaymentSourceRevnetId, PAYMENT_SOURCE_REVNET_ID);
        assertFalse(directNativeAllowed);
        assertTrue(exists);
    }

    function test_registerCommunity_revertsWhenCallerIsNotGoalRegistryOwner() public {
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.UNAUTHORIZED.selector, address(this), makeAddr("not-owner"))
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_registerCommunity_revertsWhenGoalRegistryDirectoryMismatch() public {
        CobuildPaymentTerminalMockGoalRegistry mismatchedRegistry = new CobuildPaymentTerminalMockGoalRegistry(
            address(this), IJBDirectory(address(new CobuildPaymentTerminalMockDirectory())), COMMUNITY_REVNET_ID, address(paymentToken)
        );
        CobuildPaymentTerminalMockSplitHook mismatchedHook =
            new CobuildPaymentTerminalMockSplitHook(COMMUNITY_REVNET_ID, address(paymentToken), address(mismatchedRegistry));
        mismatchedHook.setRouteSetter(address(paymentTerminal));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_DIRECTORY.selector, address(directory), address(mismatchedRegistry.directory())
            )
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(mismatchedHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenPaymentSourceTokenMismatch() public {
        tokens.setTokenOf(PAYMENT_SOURCE_REVNET_ID, address(new CobuildPaymentTerminalMockToken("Wrong", "WRONG")));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_PAYMENT_SOURCE.selector,
                PAYMENT_SOURCE_REVNET_ID,
                address(paymentToken),
                tokens.tokenOf(PAYMENT_SOURCE_REVNET_ID)
            )
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_registerCommunity_revertsWhenSplitHookRouteSetterDiffersFromSharedTerminal() public {
        address otherSetter = makeAddr("other-setter");
        splitHook.setRouteSetter(otherSetter);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.INVALID_ROUTE_SETTER.selector, address(paymentTerminal), otherSetter)
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_registerCommunity_revertsWhenCanonicalNativeTerminalIsNotSharedTerminal() public {
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_NATIVE_TERMINAL.selector, address(paymentTerminal), address(sourceTerminal)
            )
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_registerCommunity_revertsWhenCanonicalPaymentTerminalIsNotSharedTerminal() public {
        directory.setPrimaryTerminal(
            COMMUNITY_REVNET_ID, address(paymentToken), IJBTerminal(address(new CobuildPaymentTerminalMockTerminal()))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_PAYMENT_TERMINAL.selector,
                address(paymentTerminal),
                directory.primaryTerminalOf(COMMUNITY_REVNET_ID, address(paymentToken))
            )
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_registerCommunity_revertsWhenAlreadyRegistered() public {
        _registerCommunity(false);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.COMMUNITY_ALREADY_REGISTERED.selector, COMMUNITY_REVNET_ID)
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_registerCommunity_revertsWhenSelfPaymentSourceCommunityIsNotRegistered() public {
        directory.setPrimaryTerminal(PAYMENT_SOURCE_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(paymentTerminal)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.PAYMENT_SOURCE_NOT_REGISTERED.selector, PAYMENT_SOURCE_REVNET_ID
            )
        );
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID, ICobuildSplitHook(address(splitHook)), address(paymentToken), PAYMENT_SOURCE_REVNET_ID, false
        );
    }

    function test_accountingContextForTokenOf_acceptsNativeAndErc20BeforeRegistration() public view {
        JBAccountingContext memory nativeContext =
            paymentTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN);
        JBAccountingContext memory paymentContext =
            paymentTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, address(paymentToken));

        assertEq(nativeContext.token, JBConstants.NATIVE_TOKEN);
        assertEq(nativeContext.decimals, 18);
        assertEq(nativeContext.currency, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertEq(paymentContext.token, address(paymentToken));
        assertEq(paymentContext.decimals, paymentToken.decimals());
        assertEq(paymentContext.currency, uint32(uint160(address(paymentToken))));
    }

    function test_accountingContexts_returnNativeAndPaymentTokenContextsAfterRegistration() public {
        _registerCommunity(false);

        JBAccountingContext memory nativeContext =
            paymentTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN);
        JBAccountingContext memory paymentContext =
            paymentTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, address(paymentToken));
        JBAccountingContext[] memory contexts = paymentTerminal.accountingContextsOf(COMMUNITY_REVNET_ID);

        assertEq(nativeContext.token, JBConstants.NATIVE_TOKEN);
        assertEq(nativeContext.decimals, 18);
        assertEq(nativeContext.currency, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertEq(paymentContext.token, address(paymentToken));
        assertEq(paymentContext.decimals, paymentToken.decimals());
        assertEq(paymentContext.currency, uint32(uint160(address(paymentToken))));

        assertEq(contexts.length, 2);
        assertEq(contexts[0].token, nativeContext.token);
        assertEq(contexts[1].token, paymentContext.token);
        assertEq(contexts[1].decimals, paymentContext.decimals);
        assertEq(contexts[1].currency, paymentContext.currency);
    }

    function test_currentSurplusOf_tracksHeldNativeBalanceAfterDirectNativePay() public {
        _registerCommunity(true);
        controller.setReturnedTokenCount(1 ether);

        paymentTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, 2 ether, address(this), 0, "community-pay", bytes("")
        );

        uint256 surplus = paymentTerminal.currentSurplusOf(
            COMMUNITY_REVNET_ID, new JBAccountingContext[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        assertEq(surplus, 2 ether);
    }

    function test_currentSurplusOf_tracksHeldPaymentTokenBalanceAfterTokenPay() public {
        _registerCommunity(false);
        paymentToken.mint(address(this), 5 ether);
        paymentToken.approve(address(paymentTerminal), 5 ether);

        paymentTerminal.pay(COMMUNITY_REVNET_ID, address(paymentToken), 5 ether, address(this), 0, "memo", bytes(""));

        uint256 surplus = paymentTerminal.currentSurplusOf(
            COMMUNITY_REVNET_ID, new JBAccountingContext[](0), paymentToken.decimals(), uint32(uint160(address(paymentToken)))
        );

        assertEq(surplus, 5 ether);
    }

    function test_addToBalanceOf_andMigrateBalanceOf_nativeTransfersHeldBalanceToDestination() public {
        _registerCommunity(true);
        CobuildPaymentTerminalMockBalanceDestination destination =
            new CobuildPaymentTerminalMockBalanceDestination(JBConstants.NATIVE_TOKEN);

        paymentTerminal.addToBalanceOf{value: 3 ether}(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, 3 ether, false, "top-up", bytes("")
        );

        assertEq(
            paymentTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID, new JBAccountingContext[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
            ),
            3 ether
        );

        uint256 migrated =
            paymentTerminal.migrateBalanceOf(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(destination)));

        assertEq(migrated, 3 ether);
        assertEq(
            paymentTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID, new JBAccountingContext[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
            ),
            0
        );
        assertEq(destination.lastProjectId(), COMMUNITY_REVNET_ID);
        assertEq(destination.lastToken(), JBConstants.NATIVE_TOKEN);
        assertEq(destination.lastAmount(), 3 ether);
        assertEq(destination.lastValue(), 3 ether);
    }

    function test_addToBalanceOf_andMigrateBalanceOf_paymentTokenTransfersHeldBalanceToDestination() public {
        _registerCommunity(false);
        CobuildPaymentTerminalMockBalanceDestination destination =
            new CobuildPaymentTerminalMockBalanceDestination(address(paymentToken));
        paymentToken.mint(address(this), 7 ether);
        paymentToken.approve(address(paymentTerminal), 7 ether);

        paymentTerminal.addToBalanceOf(COMMUNITY_REVNET_ID, address(paymentToken), 7 ether, false, "top-up", bytes(""));

        assertEq(
            paymentTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID,
                new JBAccountingContext[](0),
                paymentToken.decimals(),
                uint32(uint160(address(paymentToken)))
            ),
            7 ether
        );

        uint256 migrated =
            paymentTerminal.migrateBalanceOf(COMMUNITY_REVNET_ID, address(paymentToken), IJBTerminal(address(destination)));

        assertEq(migrated, 7 ether);
        assertEq(
            paymentTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID,
                new JBAccountingContext[](0),
                paymentToken.decimals(),
                uint32(uint160(address(paymentToken)))
            ),
            0
        );
        assertEq(paymentToken.balanceOf(address(paymentTerminal)), 0);
        assertEq(paymentToken.balanceOf(address(destination)), 7 ether);
        assertEq(destination.lastProjectId(), COMMUNITY_REVNET_ID);
        assertEq(destination.lastToken(), address(paymentToken));
        assertEq(destination.lastAmount(), 7 ether);
        assertEq(destination.lastValue(), 0);
    }

    function test_payWithEth_routesThroughPaymentSourceAndFlushesReservedTokens() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(1 ether);

        uint256[] memory goalIds = new uint256[](2);
        goalIds[0] = 11;
        goalIds[1] = 22;

        uint32[] memory weights = new uint32[](2);
        weights[0] = 1;
        weights[1] = 2;

        uint256 beneficiaryTokenCount = paymentTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            2 ether,
            address(this),
            5,
            "community-pay",
            abi.encode(goalIds, weights)
        );

        assertEq(beneficiaryTokenCount, 1 ether);
        assertEq(sourceTerminal.lastPaidAmount(), 2 ether);
        assertEq(sourceTerminal.lastMinReturnedTokens(), 1);
        assertEq(controller.lastMintProjectId(), COMMUNITY_REVNET_ID);
        assertEq(controller.lastMintTokenCount(), 2 ether);
        assertEq(controller.lastMintBeneficiary(), address(this));
        assertTrue(controller.lastUseReservedPercent());
        assertEq(splitHook.beginPendingRouteCallCount(), 1);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(splitHook.lastBacklogTokenCount(), 0);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_payWithPaymentToken_revertsWhenExplicitRouteIsNotConsumed() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(0.5 ether);
        controller.setConsumePendingRouteOnSend(false);
        paymentToken.mint(address(this), 1 ether);
        paymentToken.approve(address(paymentTerminal), 1 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.expectRevert(CobuildPaymentTerminal.ROUTE_NOT_CONSUMED.selector);
        paymentTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            1 ether,
            address(this),
            0,
            "community-pay",
            abi.encode(goalIds, weights)
        );
    }

    function test_payWithPaymentToken_withoutMetadataFlushesReservedTokensWithoutPendingRoute() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(2 ether);
        paymentToken.mint(address(this), 5 ether);
        paymentToken.approve(address(paymentTerminal), 5 ether);

        uint256 beneficiaryTokenCount = paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(paymentToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 2 ether);
        assertEq(controller.lastMintTokenCount(), 5 ether);
        assertEq(splitHook.beginPendingRouteCallCount(), 0);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_payWithPaymentToken_withoutMetadataDoesNotFlushWhenNoReservedTokensWereCreated() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(5 ether);
        paymentToken.mint(address(this), 5 ether);
        paymentToken.approve(address(paymentTerminal), 5 ether);

        uint256 beneficiaryTokenCount = paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(paymentToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 5 ether);
        assertEq(splitHook.beginPendingRouteCallCount(), 0);
        assertEq(splitHook.cancelPendingRouteCallCount(), 0);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 0);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_pay_revertsWhenCommunityIsNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildPaymentTerminal.COMMUNITY_NOT_REGISTERED.selector, COMMUNITY_REVNET_ID));
        paymentTerminal.pay(COMMUNITY_REVNET_ID, address(paymentToken), 1 ether, address(this), 0, "memo", bytes(""));
    }

    function test_payWithEth_directNativeAllowedMintsOnSharedTerminalWithoutPaymentSourceHop() public {
        _registerCommunity(true);
        controller.setReturnedTokenCount(1 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        uint256 beneficiaryTokenCount = paymentTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            2 ether,
            address(this),
            0,
            "native-community-pay",
            abi.encode(goalIds, weights)
        );

        assertEq(beneficiaryTokenCount, 1 ether);
        assertEq(sourceTerminal.lastPaidAmount(), 0);
        assertEq(controller.lastMintProjectId(), COMMUNITY_REVNET_ID);
        assertEq(controller.lastMintTokenCount(), 2 ether);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertFalse(splitHook.hasPendingRoute());
    }

    function _registerCommunity(bool directNativeAllowed) internal {
        paymentTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            directNativeAllowed
        );
    }
}

contract CobuildPaymentTerminalMockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;
    mapping(uint256 => IJBController) internal _controllerOf;
    CobuildPaymentTerminalMockProjects internal _projects = new CobuildPaymentTerminalMockProjects();

    function PROJECTS() external view returns (CobuildPaymentTerminalMockProjects) {
        return _projects;
    }

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

    function setProjectOwner(uint256 projectId, address owner) external {
        _projects.setOwner(projectId, owner);
    }
}

contract CobuildPaymentTerminalMockProjects {
    mapping(uint256 => address) internal _ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }
}

contract CobuildPaymentTerminalMockTokens {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract CobuildPaymentTerminalMockGoalRegistry {
    address public owner;
    IJBDirectory public directory;
    uint256 public communityRevnetId;
    address public communityToken;

    constructor(address owner_, IJBDirectory directory_, uint256 communityRevnetId_, address communityToken_) {
        owner = owner_;
        directory = directory_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
    }
}

contract CobuildPaymentTerminalMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract CobuildPaymentTerminalMockPaymentSourceTerminal {
    CobuildPaymentTerminalMockToken internal immutable _token;
    uint256 internal _lastPaidAmount;
    uint256 internal _lastMinReturnedTokens;

    constructor(CobuildPaymentTerminalMockToken token_) {
        _token = token_;
    }

    function pay(
        uint256,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    ) external payable returns (uint256) {
        require(token == JBConstants.NATIVE_TOKEN, "token");
        require(msg.value == amount, "value");

        _lastPaidAmount = amount;
        _lastMinReturnedTokens = minReturnedTokens;
        _token.mint(beneficiary, amount);
        return amount;
    }

    function lastPaidAmount() external view returns (uint256) {
        return _lastPaidAmount;
    }

    function lastMinReturnedTokens() external view returns (uint256) {
        return _lastMinReturnedTokens;
    }
}

contract CobuildPaymentTerminalMockBalanceDestination is IJBTerminal {
    address public immutable acceptedToken;

    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public lastValue;

    constructor(address acceptedToken_) {
        acceptedToken = acceptedToken_;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }

    function accountingContextForTokenOf(
        uint256,
        address token
    ) external view override returns (JBAccountingContext memory context) {
        if (token != acceptedToken) {
            return JBAccountingContext({token: address(0), decimals: 0, currency: 0});
        }

        return JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
    }

    function accountingContextsOf(uint256) external view override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
    }

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata,
        bytes calldata
    ) external payable override {
        lastProjectId = projectId;
        lastToken = token;
        lastAmount = amount;
        lastValue = msg.value;

        if (token == JBConstants.NATIVE_TOKEN) return;

        require(ERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256,
        address,
        uint256 amount,
        address,
        uint256,
        string calldata,
        bytes calldata
    ) external payable override returns (uint256) {
        return amount;
    }
}

contract CobuildPaymentTerminalMockController {
    CobuildPaymentTerminalMockSplitHook internal immutable _splitHook;
    CobuildPaymentTerminalMockTokens internal immutable _tokens;

    bool internal _consumePendingRouteOnSend = true;
    uint256 internal _sendReservedTokensToSplitsCallCount;
    uint256 internal _returnedTokenCount = type(uint256).max;
    uint256 internal _lastMintProjectId;
    uint256 internal _lastMintTokenCount;
    address internal _lastMintBeneficiary;
    bool internal _lastUseReservedPercent;
    mapping(uint256 => uint256) internal _pendingReservedTokenBalanceOf;

    constructor(CobuildPaymentTerminalMockSplitHook splitHook_, CobuildPaymentTerminalMockTokens tokens_) {
        _splitHook = splitHook_;
        _tokens = tokens_;
    }

    function TOKENS() external view returns (CobuildPaymentTerminalMockTokens) {
        return _tokens;
    }

    function setConsumePendingRouteOnSend(bool shouldConsume) external {
        _consumePendingRouteOnSend = shouldConsume;
    }

    function setReturnedTokenCount(uint256 returnedTokenCount_) external {
        _returnedTokenCount = returnedTokenCount_;
    }

    function setPendingReservedTokenBalance(uint256 projectId, uint256 amount) external {
        _pendingReservedTokenBalanceOf[projectId] = amount;
    }

    function recordReservedTokens(uint256 projectId, uint256 amount) external {
        _pendingReservedTokenBalanceOf[projectId] += amount;
    }

    function pendingReservedTokenBalanceOf(uint256 projectId) external view returns (uint256) {
        return _pendingReservedTokenBalanceOf[projectId];
    }

    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        string calldata,
        bool useReservedPercent
    ) external returns (uint256 beneficiaryTokenCount) {
        _lastMintProjectId = projectId;
        _lastMintTokenCount = tokenCount;
        _lastMintBeneficiary = beneficiary;
        _lastUseReservedPercent = useReservedPercent;

        beneficiaryTokenCount = _returnedTokenCount == type(uint256).max ? tokenCount : _returnedTokenCount;
        require(beneficiaryTokenCount <= tokenCount, "returned");

        uint256 reservedTokenCount = tokenCount - beneficiaryTokenCount;
        if (reservedTokenCount != 0) {
            _pendingReservedTokenBalanceOf[projectId] += reservedTokenCount;
        }
    }

    function sendReservedTokensToSplitsOf(uint256 projectId) external returns (uint256 tokenCount) {
        _sendReservedTokensToSplitsCallCount += 1;
        tokenCount = _pendingReservedTokenBalanceOf[projectId];
        _pendingReservedTokenBalanceOf[projectId] = 0;

        if (_consumePendingRouteOnSend && _splitHook.hasPendingRoute()) {
            _splitHook.consumePendingRoute();
        }
    }

    function sendReservedTokensToSplitsCallCount() external view returns (uint256) {
        return _sendReservedTokensToSplitsCallCount;
    }

    function lastMintProjectId() external view returns (uint256) {
        return _lastMintProjectId;
    }

    function lastMintTokenCount() external view returns (uint256) {
        return _lastMintTokenCount;
    }

    function lastMintBeneficiary() external view returns (address) {
        return _lastMintBeneficiary;
    }

    function lastUseReservedPercent() external view returns (bool) {
        return _lastUseReservedPercent;
    }
}

contract CobuildPaymentTerminalMockTerminal {}

contract CobuildPaymentTerminalMockSplitHook is ICobuildSplitHook {
    uint256 public immutable override communityRevnetId;
    address public immutable override communityToken;

    address public override routeSetter;
    address public override goalRegistry;
    uint256 public override historicalBacklogAmount;
    bool internal _hasPendingRoute;

    uint256 public beginPendingRouteCallCount;
    uint256 public cancelPendingRouteCallCount;
    uint256 public lastBacklogTokenCount;
    address public lastPayer;
    address public lastBeneficiary;
    uint256[] internal _lastGoalIds;
    uint32[] internal _lastWeights;

    constructor(uint256 communityRevnetId_, address communityToken_, address goalRegistry_) {
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
        goalRegistry = goalRegistry_;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }

    function observedVolumeOf(uint256) external pure override returns (uint256) {
        return 0;
    }

    function cumulativeObservedVolume() external pure override returns (uint256) {
        return 0;
    }

    function currentHistoricalTotalVolume() external pure override returns (uint256) {
        return 0;
    }

    function selectableGoalIds() external pure override returns (uint256[] memory goalIds) {
        goalIds = new uint256[](0);
    }

    function historicalRoute() external pure override returns (uint256[] memory goalIds, uint256[] memory volumes) {
        goalIds = new uint256[](0);
        volumes = new uint256[](0);
    }

    function historicalBacklogProgress()
        external
        pure
        override
        returns (HistoricalBacklogProgressView memory progress)
    {
        progress = HistoricalBacklogProgressView({
            active: false,
            epoch: 0,
            remainingAmount: 0,
            processedGoalCount: 0
        });
    }

    function pendingRoute() external view override returns (PendingRouteView memory out) {
        out = PendingRouteView({
            payer: lastPayer,
            beneficiary: lastBeneficiary,
            createdAt: 0,
            backlogTokenCount: lastBacklogTokenCount,
            goalIds: _copyUint256Array(_lastGoalIds),
            weights: _copyUint32Array(_lastWeights)
        });
    }

    function hasPendingRoute() public view override returns (bool) {
        return _hasPendingRoute;
    }

    function beginPendingRoute(
        address payer,
        address beneficiary,
        uint256 backlogTokenCount,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) external override {
        beginPendingRouteCallCount += 1;
        _hasPendingRoute = true;
        lastBacklogTokenCount = backlogTokenCount;
        lastPayer = payer;
        lastBeneficiary = beneficiary;
        _lastGoalIds = _copyUint256Calldata(goalIds);
        _lastWeights = _copyUint32Calldata(weights);
    }

    function cancelPendingRoute() external override {
        cancelPendingRouteCallCount += 1;
        _hasPendingRoute = false;
    }

    function flushHistoricalBacklog(uint256) external override returns (uint256 routedAmount) {
        routedAmount = historicalBacklogAmount;
        historicalBacklogAmount = 0;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {}

    function setRouteSetter(address routeSetter_) external {
        routeSetter = routeSetter_;
    }

    function consumePendingRoute() external {
        _hasPendingRoute = false;
    }

    function _copyUint256Calldata(uint256[] calldata source) private pure returns (uint256[] memory copied) {
        copied = new uint256[](source.length);
        for (uint256 i = 0; i < source.length; i++) {
            copied[i] = source[i];
        }
    }

    function _copyUint32Calldata(uint32[] calldata source) private pure returns (uint32[] memory copied) {
        copied = new uint32[](source.length);
        for (uint256 i = 0; i < source.length; i++) {
            copied[i] = source[i];
        }
    }

    function _copyUint256Array(uint256[] storage source) private view returns (uint256[] memory copied) {
        copied = new uint256[](source.length);
        for (uint256 i = 0; i < source.length; i++) {
            copied[i] = source[i];
        }
    }

    function _copyUint32Array(uint32[] storage source) private view returns (uint32[] memory copied) {
        copied = new uint32[](source.length);
        for (uint256 i = 0; i < source.length; i++) {
            copied[i] = source[i];
        }
    }
}
