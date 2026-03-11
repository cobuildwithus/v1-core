// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CobuildCommunityTerminal} from "src/juicebox/CobuildCommunityTerminal.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {MockTerminalStore} from "test/juicebox/helpers/MockTerminalStore.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v5/interfaces/IJBPayHook.sol";
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v5/structs/JBAfterPayRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v5/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildCommunityTerminalTest is Test {
    uint256 internal constant PAYMENT_SOURCE_REVNET_ID = 138;
    uint256 internal constant COMMUNITY_REVNET_ID = 777;

    CobuildCommunityTerminalMockToken internal paymentToken;
    CobuildCommunityTerminalMockDirectory internal directory;
    CobuildCommunityTerminalMockTokens internal tokens;
    CobuildCommunityTerminalMockGoalRegistry internal goalRegistry;
    CobuildCommunityTerminalMockSplitHook internal splitHook;
    CobuildCommunityTerminalMockController internal controller;
    CobuildCommunityTerminalMockPaymentSourceTerminal internal sourceTerminal;
    MockTerminalStore internal store;
    CobuildCommunityTerminal internal communityTerminal;

    function setUp() public {
        paymentToken = new CobuildCommunityTerminalMockToken("Payment", "PAY");
        directory = new CobuildCommunityTerminalMockDirectory();
        tokens = new CobuildCommunityTerminalMockTokens();
        goalRegistry = new CobuildCommunityTerminalMockGoalRegistry(
            IJBDirectory(address(directory)), COMMUNITY_REVNET_ID, address(paymentToken)
        );
        splitHook = new CobuildCommunityTerminalMockSplitHook(
            COMMUNITY_REVNET_ID, address(paymentToken), address(goalRegistry)
        );
        controller = new CobuildCommunityTerminalMockController(splitHook, tokens);
        sourceTerminal = new CobuildCommunityTerminalMockPaymentSourceTerminal(paymentToken);
        store = new MockTerminalStore(IJBDirectory(address(directory)));
        communityTerminal =
            new CobuildCommunityTerminal(IJBDirectory(address(directory)), IJBTerminalStore(address(store)), address(0));

        splitHook.setRouteSetter(address(communityTerminal));
        tokens.setTokenOf(PAYMENT_SOURCE_REVNET_ID, address(paymentToken));
        tokens.setTokenOf(COMMUNITY_REVNET_ID, address(paymentToken));
        controller.setLiveReservedSplit(
            COMMUNITY_REVNET_ID, IJBSplitHook(address(splitHook)), uint32(JBConstants.SPLITS_TOTAL_PERCENT)
        );

        directory.setController(PAYMENT_SOURCE_REVNET_ID, IJBController(address(controller)));
        directory.setController(COMMUNITY_REVNET_ID, IJBController(address(controller)));
        directory.setProjectOwner(COMMUNITY_REVNET_ID, address(this));
        directory.setPrimaryTerminal(
            PAYMENT_SOURCE_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal))
        );
        directory.setPrimaryTerminal(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(communityTerminal))
        );
        directory.setPrimaryTerminal(
            COMMUNITY_REVNET_ID, address(paymentToken), IJBTerminal(address(communityTerminal))
        );
    }

    function test_constructor_revertsWhenApprovedFactoryIsNotContract() public {
        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminal.NOT_A_CONTRACT.selector, address(0xBEEF))
        );
        new CobuildCommunityTerminal(
            IJBDirectory(address(directory)), IJBTerminalStore(address(store)), address(0xBEEF)
        );
    }

    function test_registerCommunity_storesConfig() public {
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );

        (
            ICobuildSplitHook storedSplitHook,
            address storedPaymentToken,
            uint256 storedPaymentSourceRevnetId,
            bool directNativeAllowed,
            bool exists
        ) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);

        assertEq(address(storedSplitHook), address(splitHook));
        assertEq(storedPaymentToken, address(paymentToken));
        assertEq(storedPaymentSourceRevnetId, PAYMENT_SOURCE_REVNET_ID);
        assertFalse(directNativeAllowed);
        assertTrue(exists);
    }

    function test_registerCommunity_revertsWhenDirectNativePaymentSourceDoesNotMatchCommunity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_DIRECT_NATIVE_PAYMENT_SOURCE.selector,
                COMMUNITY_REVNET_ID,
                PAYMENT_SOURCE_REVNET_ID
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            true
        );
    }

    function test_registerCommunity_revertsWhenCallerIsNotCommunityProjectOwner() public {
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminal.UNAUTHORIZED.selector, address(this), makeAddr("not-owner"))
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenGoalRegistryDirectoryMismatch() public {
        CobuildCommunityTerminalMockGoalRegistry mismatchedRegistry = new CobuildCommunityTerminalMockGoalRegistry(
            IJBDirectory(address(new CobuildCommunityTerminalMockDirectory())),
            COMMUNITY_REVNET_ID,
            address(paymentToken)
        );
        CobuildCommunityTerminalMockSplitHook mismatchedHook = new CobuildCommunityTerminalMockSplitHook(
            COMMUNITY_REVNET_ID, address(paymentToken), address(mismatchedRegistry)
        );
        mismatchedHook.setRouteSetter(address(communityTerminal));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_DIRECTORY.selector,
                address(directory),
                address(mismatchedRegistry.directory())
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(mismatchedHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenPaymentSourceTokenMismatch() public {
        tokens.setTokenOf(PAYMENT_SOURCE_REVNET_ID, address(new CobuildCommunityTerminalMockToken("Wrong", "WRONG")));

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_PAYMENT_SOURCE.selector,
                PAYMENT_SOURCE_REVNET_ID,
                address(paymentToken),
                tokens.tokenOf(PAYMENT_SOURCE_REVNET_ID)
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenSplitHookRouteSetterDiffersFromSharedTerminal() public {
        address otherSetter = makeAddr("other-setter");
        splitHook.setRouteSetter(otherSetter);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_ROUTE_SETTER.selector, address(communityTerminal), otherSetter
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenCanonicalNativeTerminalIsNotSharedTerminal() public {
        directory.setPrimaryTerminal(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_NATIVE_TERMINAL.selector,
                address(communityTerminal),
                address(sourceTerminal)
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenCanonicalPaymentTerminalIsNotSharedTerminal() public {
        directory.setPrimaryTerminal(
            COMMUNITY_REVNET_ID, address(paymentToken), IJBTerminal(address(new CobuildCommunityTerminalMockTerminal()))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_PAYMENT_TERMINAL.selector,
                address(communityTerminal),
                directory.primaryTerminalOf(COMMUNITY_REVNET_ID, address(paymentToken))
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenLiveReservedSplitGroupOmitsRegisteredHook() public {
        CobuildCommunityTerminalMockSplitHook otherHook = new CobuildCommunityTerminalMockSplitHook(
            COMMUNITY_REVNET_ID, address(paymentToken), address(goalRegistry)
        );
        otherHook.setRouteSetter(address(communityTerminal));
        controller.setLiveReservedSplit(
            COMMUNITY_REVNET_ID, IJBSplitHook(address(otherHook)), uint32(JBConstants.SPLITS_TOTAL_PERCENT)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(0)
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_allowsFractionalLiveReservedSplitForRegisteredHook() public {
        controller.setLiveReservedSplit(COMMUNITY_REVNET_ID, IJBSplitHook(address(splitHook)), 999_999_999);

        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );

        (, , , , bool exists) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertTrue(exists);
    }

    function test_registerCommunity_revertsWhenLiveReservedSplitIsUnset() public {
        controller.clearLiveReservedSplit(COMMUNITY_REVNET_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(0)
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_allowsMixedReservedSplitGroupWhenHookAppearsOnce() public {
        CobuildCommunityTerminalMockSplitHook otherHook = new CobuildCommunityTerminalMockSplitHook(
            COMMUNITY_REVNET_ID, address(paymentToken), address(goalRegistry)
        );
        otherHook.setRouteSetter(address(communityTerminal));

        IJBSplitHook[] memory hooks = new IJBSplitHook[](2);
        hooks[0] = IJBSplitHook(address(splitHook));
        hooks[1] = IJBSplitHook(address(otherHook));

        uint32[] memory percents = new uint32[](2);
        percents[0] = 500_000_000;
        percents[1] = 500_000_000;

        controller.setLiveReservedSplits(COMMUNITY_REVNET_ID, hooks, percents);

        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );

        (, , , , bool exists) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertTrue(exists);
    }

    function test_registerCommunity_revertsWhenLiveReservedSplitGroupContainsMultipleMatchingHookSplits() public {
        IJBSplitHook[] memory hooks = new IJBSplitHook[](2);
        hooks[0] = IJBSplitHook(address(splitHook));
        hooks[1] = IJBSplitHook(address(splitHook));

        uint32[] memory percents = new uint32[](2);
        percents[0] = 400_000_000;
        percents[1] = 600_000_000;

        controller.setLiveReservedSplits(COMMUNITY_REVNET_ID, hooks, percents);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(2)
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenAlreadyRegistered() public {
        _registerCommunity(false);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminal.COMMUNITY_ALREADY_REGISTERED.selector, COMMUNITY_REVNET_ID)
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_registerCommunity_revertsWhenSelfPaymentSourceCommunityIsNotRegistered() public {
        directory.setPrimaryTerminal(
            PAYMENT_SOURCE_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(communityTerminal))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.PAYMENT_SOURCE_NOT_REGISTERED.selector, PAYMENT_SOURCE_REVNET_ID
            )
        );
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            PAYMENT_SOURCE_REVNET_ID,
            false
        );
    }

    function test_accountingContextForTokenOf_acceptsNativeAndErc20BeforeRegistration() public view {
        JBAccountingContext memory nativeContext =
            communityTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN);
        JBAccountingContext memory paymentContext =
            communityTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, address(paymentToken));

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
            communityTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN);
        JBAccountingContext memory paymentContext =
            communityTerminal.accountingContextForTokenOf(COMMUNITY_REVNET_ID, address(paymentToken));
        JBAccountingContext[] memory contexts = communityTerminal.accountingContextsOf(COMMUNITY_REVNET_ID);

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

        communityTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, 2 ether, address(this), 0, "community-pay", bytes("")
        );

        uint256 surplus = communityTerminal.currentSurplusOf(
            COMMUNITY_REVNET_ID, new JBAccountingContext[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        assertEq(surplus, 2 ether);
    }

    function test_currentSurplusOf_tracksHeldPaymentTokenBalanceAfterTokenPay() public {
        _registerCommunity(false);
        paymentToken.mint(address(this), 5 ether);
        paymentToken.approve(address(communityTerminal), 5 ether);

        communityTerminal.pay(COMMUNITY_REVNET_ID, address(paymentToken), 5 ether, address(this), 0, "memo", bytes(""));

        uint256 surplus = communityTerminal.currentSurplusOf(
            COMMUNITY_REVNET_ID,
            new JBAccountingContext[](0),
            paymentToken.decimals(),
            uint32(uint160(address(paymentToken)))
        );

        assertEq(surplus, 5 ether);
    }

    function test_pay_usesTerminalStoreRecordedTokenCountInsteadOfRawPaymentAmount() public {
        _registerCommunity(true);
        store.setRecordedTokenCount(COMMUNITY_REVNET_ID, 3 ether);
        controller.setReturnedTokenCount(1.5 ether);

        uint256 beneficiaryTokenCount = communityTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, 2 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 1.5 ether);
        assertEq(controller.lastMintTokenCount(), 3 ether);
    }

    function test_pay_revertsWhenTerminalStorePausesPayments() public {
        _registerCommunity(false);
        store.setPaymentsPaused(true);
        paymentToken.mint(address(this), 1 ether);
        paymentToken.approve(address(communityTerminal), 1 ether);

        vm.expectRevert(MockTerminalStore.PAYMENT_PAUSED.selector);
        communityTerminal.pay(COMMUNITY_REVNET_ID, address(paymentToken), 1 ether, address(this), 0, "memo", bytes(""));
    }

    function test_addToBalanceOf_andMigrateBalanceOf_nativeTransfersHeldBalanceToDestination() public {
        _registerCommunity(true);
        CobuildCommunityTerminalMockBalanceDestination destination =
            new CobuildCommunityTerminalMockBalanceDestination(JBConstants.NATIVE_TOKEN);

        communityTerminal.addToBalanceOf{value: 3 ether}(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, 3 ether, false, "top-up", bytes("")
        );

        assertEq(
            communityTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID, new JBAccountingContext[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
            ),
            3 ether
        );

        uint256 migrated = communityTerminal.migrateBalanceOf(
            COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(destination))
        );

        assertEq(migrated, 3 ether);
        assertEq(
            communityTerminal.currentSurplusOf(
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
        CobuildCommunityTerminalMockBalanceDestination destination =
            new CobuildCommunityTerminalMockBalanceDestination(address(paymentToken));
        paymentToken.mint(address(this), 7 ether);
        paymentToken.approve(address(communityTerminal), 7 ether);

        communityTerminal.addToBalanceOf(
            COMMUNITY_REVNET_ID, address(paymentToken), 7 ether, false, "top-up", bytes("")
        );

        assertEq(
            communityTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID,
                new JBAccountingContext[](0),
                paymentToken.decimals(),
                uint32(uint160(address(paymentToken)))
            ),
            7 ether
        );

        uint256 migrated = communityTerminal.migrateBalanceOf(
            COMMUNITY_REVNET_ID, address(paymentToken), IJBTerminal(address(destination))
        );

        assertEq(migrated, 7 ether);
        assertEq(
            communityTerminal.currentSurplusOf(
                COMMUNITY_REVNET_ID,
                new JBAccountingContext[](0),
                paymentToken.decimals(),
                uint32(uint160(address(paymentToken)))
            ),
            0
        );
        assertEq(paymentToken.balanceOf(address(communityTerminal)), 0);
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

        uint256 beneficiaryTokenCount = communityTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            2 ether,
            address(this),
            5,
            "community-pay",
            _communityPayMetadata(goalIds, weights, bytes(""))
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
        paymentToken.approve(address(communityTerminal), 1 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.expectRevert(CobuildCommunityTerminal.ROUTE_NOT_CONSUMED.selector);
        communityTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            1 ether,
            address(this),
            0,
            "community-pay",
            _communityPayMetadata(goalIds, weights, bytes(""))
        );
    }

    function test_payWithPaymentToken_revertsWhenLiveReservedSplitGroupDriftsAfterRegistration() public {
        _registerCommunity(false);

        IJBSplitHook[] memory hooks = new IJBSplitHook[](2);
        hooks[0] = IJBSplitHook(address(splitHook));
        hooks[1] = IJBSplitHook(address(splitHook));

        uint32[] memory percents = new uint32[](2);
        percents[0] = 400_000_000;
        percents[1] = 600_000_000;

        controller.setLiveReservedSplits(COMMUNITY_REVNET_ID, hooks, percents);
        paymentToken.mint(address(this), 1 ether);
        paymentToken.approve(address(communityTerminal), 1 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(2)
            )
        );
        communityTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            1 ether,
            address(this),
            0,
            "community-pay",
            _communityPayMetadata(goalIds, weights, bytes(""))
        );
    }

    function test_payWithPaymentToken_cancelsPendingRouteWhenHookSliceRoundsDownToZero() public {
        CobuildCommunityTerminalMockSplitHook otherHook = new CobuildCommunityTerminalMockSplitHook(
            COMMUNITY_REVNET_ID, address(paymentToken), address(goalRegistry)
        );

        IJBSplitHook[] memory hooks = new IJBSplitHook[](2);
        hooks[0] = IJBSplitHook(address(splitHook));
        hooks[1] = IJBSplitHook(address(otherHook));

        uint32[] memory percents = new uint32[](2);
        percents[0] = 1;
        percents[1] = uint32(JBConstants.SPLITS_TOTAL_PERCENT - 1);

        controller.setLiveReservedSplits(COMMUNITY_REVNET_ID, hooks, percents);
        _registerCommunity(false);

        controller.setReturnedTokenCount(0);
        paymentToken.mint(address(this), 100);
        paymentToken.approve(address(communityTerminal), 100);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        uint256 beneficiaryTokenCount = communityTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            100,
            address(this),
            0,
            "community-pay",
            _communityPayMetadata(goalIds, weights, bytes(""))
        );

        assertEq(beneficiaryTokenCount, 0);
        assertEq(splitHook.beginPendingRouteCallCount(), 1);
        assertEq(splitHook.lastBacklogTokenCount(), 0);
        assertEq(splitHook.cancelPendingRouteCallCount(), 1);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_payWithPaymentToken_forwardsEmbeddedJbMetadataToTerminalStoreAndPayHook() public {
        _registerCommunity(false);

        CobuildCommunityTerminalMockPayHook payHook = new CobuildCommunityTerminalMockPayHook();
        bytes memory hookMetadata = abi.encodePacked("hook-metadata");
        bytes memory jbMetadata = abi.encodePacked("payer-metadata");

        store.setPayHookSpecification(COMMUNITY_REVNET_ID, IJBPayHook(address(payHook)), 0.25 ether, hookMetadata);
        paymentToken.mint(address(this), 1 ether);
        paymentToken.approve(address(communityTerminal), 1 ether);

        communityTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            1 ether,
            address(this),
            0,
            "community-pay",
            _communityPayMetadata(new uint256[](0), new uint32[](0), jbMetadata)
        );

        assertEq(keccak256(store.lastMetadata()), keccak256(jbMetadata));
        assertEq(keccak256(payHook.lastPayerMetadata()), keccak256(jbMetadata));
        assertEq(keccak256(payHook.lastHookMetadata()), keccak256(hookMetadata));
        assertEq(payHook.lastForwardedAmount(), 0.25 ether);
    }

    function test_payWithPaymentToken_revertsWhenHookSplitPercentDriftsMidPay() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(0.5 ether);

        CobuildCommunityTerminalMockSplitMutatingPayHook payHook =
            new CobuildCommunityTerminalMockSplitMutatingPayHook(controller, COMMUNITY_REVNET_ID, splitHook, 500_000_000);
        store.setPayHookSpecification(COMMUNITY_REVNET_ID, IJBPayHook(address(payHook)), 1, bytes("hook-metadata"));

        paymentToken.mint(address(this), 1 ether);
        paymentToken.approve(address(communityTerminal), 1 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_PERCENT.selector,
                uint256(JBConstants.SPLITS_TOTAL_PERCENT),
                uint256(500_000_000)
            )
        );
        communityTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            1 ether,
            address(this),
            0,
            "community-pay",
            _communityPayMetadata(goalIds, weights, bytes(""))
        );
    }

    function test_payWithDirectNative_forwardsEmbeddedJbMetadataToTerminalStoreAndPayHook() public {
        _registerCommunity(true);

        CobuildCommunityTerminalMockPayHook payHook = new CobuildCommunityTerminalMockPayHook();
        bytes memory hookMetadata = abi.encodePacked("hook-metadata");
        bytes memory jbMetadata = abi.encodePacked("payer-metadata");

        store.setPayHookSpecification(COMMUNITY_REVNET_ID, IJBPayHook(address(payHook)), 0.25 ether, hookMetadata);

        communityTerminal.pay{value: 1 ether}(
            COMMUNITY_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "native-community-pay",
            _communityPayMetadata(new uint256[](0), new uint32[](0), jbMetadata)
        );

        assertEq(keccak256(store.lastMetadata()), keccak256(jbMetadata));
        assertEq(keccak256(payHook.lastPayerMetadata()), keccak256(jbMetadata));
        assertEq(keccak256(payHook.lastHookMetadata()), keccak256(hookMetadata));
        assertEq(payHook.lastForwardedAmount(), 0.25 ether);
    }

    function test_payWithPaymentToken_emitsPayEventWithEmbeddedJbMetadata() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(1 ether);
        paymentToken.mint(address(this), 2 ether);
        paymentToken.approve(address(communityTerminal), 2 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;
        bytes memory jbMetadata = abi.encodePacked("payer-metadata");

        vm.recordLogs();
        communityTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(paymentToken),
            2 ether,
            address(this),
            0,
            "community-pay",
            _communityPayMetadata(goalIds, weights, jbMetadata)
        );

        assertEq(keccak256(_metadataFromPayEvent(vm.getRecordedLogs())), keccak256(jbMetadata));
    }

    function test_payWithPaymentToken_withoutMetadataFlushesReservedTokensWithoutPendingRoute() public {
        _registerCommunity(false);
        controller.setReturnedTokenCount(2 ether);
        paymentToken.mint(address(this), 5 ether);
        paymentToken.approve(address(communityTerminal), 5 ether);

        uint256 beneficiaryTokenCount = communityTerminal.pay(
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
        paymentToken.approve(address(communityTerminal), 5 ether);

        uint256 beneficiaryTokenCount = communityTerminal.pay(
            COMMUNITY_REVNET_ID, address(paymentToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 5 ether);
        assertEq(splitHook.beginPendingRouteCallCount(), 0);
        assertEq(splitHook.cancelPendingRouteCallCount(), 0);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 0);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_payWithPaymentToken_resetsHookAllowanceAfterCallback() public {
        _registerCommunity(false);

        CobuildCommunityTerminalMockPayHook payHook = new CobuildCommunityTerminalMockPayHook();
        store.setPayHookSpecification(
            COMMUNITY_REVNET_ID, IJBPayHook(address(payHook)), 1 ether, bytes("hook-metadata")
        );

        uint256 seedAllowance = 123;
        vm.prank(address(communityTerminal));
        paymentToken.approve(address(payHook), seedAllowance);
        assertEq(paymentToken.allowance(address(communityTerminal), address(payHook)), seedAllowance);

        paymentToken.mint(address(this), 5 ether);
        paymentToken.approve(address(communityTerminal), 5 ether);

        communityTerminal.pay(
            COMMUNITY_REVNET_ID, address(paymentToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(payHook.callCount(), 1);
        assertEq(payHook.lastObservedAllowance(), seedAllowance + 1 ether);
        assertEq(paymentToken.allowance(address(communityTerminal), address(payHook)), 0);
    }

    function test_pay_revertsWhenCommunityIsNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminal.COMMUNITY_NOT_REGISTERED.selector, COMMUNITY_REVNET_ID)
        );
        communityTerminal.pay(COMMUNITY_REVNET_ID, address(paymentToken), 1 ether, address(this), 0, "memo", bytes(""));
    }

    function test_payWithEth_directNativeAllowedMintsOnSharedTerminalWithoutPaymentSourceHop() public {
        _registerCommunity(true);
        controller.setReturnedTokenCount(1 ether);

        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;
        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        uint256 beneficiaryTokenCount = communityTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            2 ether,
            address(this),
            0,
            "native-community-pay",
            _communityPayMetadata(goalIds, weights, bytes(""))
        );

        assertEq(beneficiaryTokenCount, 1 ether);
        assertEq(sourceTerminal.lastPaidAmount(), 0);
        assertEq(controller.lastMintProjectId(), COMMUNITY_REVNET_ID);
        assertEq(controller.lastMintTokenCount(), 2 ether);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertFalse(splitHook.hasPendingRoute());
    }

    function _registerCommunity(bool directNativeAllowed) internal {
        communityTerminal.registerCommunity(
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(paymentToken),
            directNativeAllowed ? COMMUNITY_REVNET_ID : PAYMENT_SOURCE_REVNET_ID,
            directNativeAllowed
        );
    }

    function _communityPayMetadata(uint256[] memory goalIds, uint32[] memory weights, bytes memory jbMetadata)
        internal
        pure
        returns (bytes memory metadata)
    {
        metadata = abi.encode(goalIds, weights, jbMetadata);
    }

    function _metadataFromPayEvent(Vm.Log[] memory logs) internal pure returns (bytes memory metadata) {
        bytes32 payEventSig =
            keccak256("Pay(uint256,uint256,uint256,address,address,uint256,uint256,string,bytes,address)");
        uint256 logsLength = logs.length;
        for (uint256 i; i < logsLength; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length != 4 || entry.topics[0] != payEventSig) continue;

            (,,,,, metadata,) = abi.decode(entry.data, (address, address, uint256, uint256, string, bytes, address));
            return metadata;
        }

        revert("PAY_EVENT_NOT_FOUND");
    }
}

contract CobuildCommunityTerminalMockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;
    mapping(uint256 => IJBController) internal _controllerOf;
    CobuildCommunityTerminalMockProjects internal _projects = new CobuildCommunityTerminalMockProjects();

    function PROJECTS() external view returns (CobuildCommunityTerminalMockProjects) {
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

contract CobuildCommunityTerminalMockProjects {
    mapping(uint256 => address) internal _ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }
}

contract CobuildCommunityTerminalMockTokens {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract CobuildCommunityTerminalMockGoalRegistry {
    IJBDirectory public directory;
    uint256 public communityRevnetId;
    address public communityToken;

    constructor(IJBDirectory directory_, uint256 communityRevnetId_, address communityToken_) {
        directory = directory_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
    }
}

contract CobuildCommunityTerminalMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract CobuildCommunityTerminalMockPaymentSourceTerminal {
    CobuildCommunityTerminalMockToken internal immutable _token;
    uint256 internal _lastPaidAmount;
    uint256 internal _lastMinReturnedTokens;

    constructor(CobuildCommunityTerminalMockToken token_) {
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

contract CobuildCommunityTerminalMockBalanceDestination is IJBTerminal {
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

    function accountingContextForTokenOf(uint256, address token)
        external
        view
        override
        returns (JBAccountingContext memory context)
    {
        if (token != acceptedToken) {
            return JBAccountingContext({token: address(0), decimals: 0, currency: 0});
        }

        return JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
    }

    function accountingContextsOf(uint256) external view override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] =
            JBAccountingContext({token: acceptedToken, decimals: 18, currency: uint32(uint160(acceptedToken))});
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

    function addToBalanceOf(uint256 projectId, address token, uint256 amount, bool, string calldata, bytes calldata)
        external
        payable
        override
    {
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

    function pay(uint256, address, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        override
        returns (uint256)
    {
        return amount;
    }
}

contract CobuildCommunityTerminalMockSplits {
    uint256 internal constant FALLBACK_RULESET_ID = 0;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;

    mapping(uint256 projectId => mapping(uint256 rulesetId => JBSplit[])) internal _reservedSplitsOf;

    function setReservedSplit(uint256 projectId, uint256 rulesetId, IJBSplitHook hook, uint32 percent) external {
        IJBSplitHook[] memory hooks = new IJBSplitHook[](1);
        hooks[0] = hook;

        uint32[] memory percents = new uint32[](1);
        percents[0] = percent;

        this.setReservedSplits(projectId, rulesetId, hooks, percents);
    }

    function setReservedSplits(
        uint256 projectId,
        uint256 rulesetId,
        IJBSplitHook[] memory hooks,
        uint32[] memory percents
    ) external {
        require(hooks.length == percents.length, "LENGTH_MISMATCH");

        delete _reservedSplitsOf[projectId][rulesetId];

        for (uint256 i; i < hooks.length; i++) {
            _reservedSplitsOf[projectId][rulesetId].push(
                JBSplit({
                    percent: percents[i],
                    projectId: 0,
                    beneficiary: payable(address(0)),
                    preferAddToBalance: false,
                    lockedUntil: 0,
                    hook: hooks[i]
                })
            );
        }
    }

    function clearReservedSplits(uint256 projectId, uint256 rulesetId) external {
        delete _reservedSplitsOf[projectId][rulesetId];
    }

    function splitsOf(uint256 projectId, uint256 rulesetId, uint256 groupId)
        external
        view
        returns (JBSplit[] memory splits)
    {
        if (groupId != RESERVED_TOKENS_GROUP_ID) return new JBSplit[](0);

        splits = _copyReservedSplits(projectId, rulesetId);

        if (splits.length == 0 && rulesetId != FALLBACK_RULESET_ID) {
            splits = _copyReservedSplits(projectId, FALLBACK_RULESET_ID);
        }
    }

    function _copyReservedSplits(uint256 projectId, uint256 rulesetId) internal view returns (JBSplit[] memory splits) {
        JBSplit[] storage storedSplits = _reservedSplitsOf[projectId][rulesetId];
        uint256 splitCount = storedSplits.length;
        splits = new JBSplit[](splitCount);

        for (uint256 i; i < splitCount; i++) {
            splits[i] = storedSplits[i];
        }
    }
}

contract CobuildCommunityTerminalMockController {
    uint48 internal constant CURRENT_RULESET_ID = 1;

    CobuildCommunityTerminalMockSplitHook internal immutable _splitHook;
    CobuildCommunityTerminalMockTokens internal immutable _tokens;
    CobuildCommunityTerminalMockSplits internal immutable _splits;

    bool internal _consumePendingRouteOnSend = true;
    uint256 internal _sendReservedTokensToSplitsCallCount;
    uint256 internal _returnedTokenCount = type(uint256).max;
    uint256 internal _lastMintProjectId;
    uint256 internal _lastMintTokenCount;
    address internal _lastMintBeneficiary;
    bool internal _lastUseReservedPercent;
    mapping(uint256 => uint256) internal _pendingReservedTokenBalanceOf;

    constructor(CobuildCommunityTerminalMockSplitHook splitHook_, CobuildCommunityTerminalMockTokens tokens_) {
        _splitHook = splitHook_;
        _tokens = tokens_;
        _splits = new CobuildCommunityTerminalMockSplits();
    }

    function TOKENS() external view returns (CobuildCommunityTerminalMockTokens) {
        return _tokens;
    }

    function SPLITS() external view returns (CobuildCommunityTerminalMockSplits) {
        return _splits;
    }

    function currentRulesetOf(uint256) external view returns (JBRuleset memory ruleset, JBRulesetMetadata memory) {
        ruleset.id = CURRENT_RULESET_ID;
        ruleset.cycleNumber = uint48(CURRENT_RULESET_ID);
        ruleset.start = uint48(block.timestamp);
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

    function setLiveReservedSplit(uint256 projectId, IJBSplitHook hook, uint32 percent) external {
        _splits.setReservedSplit(projectId, uint256(CURRENT_RULESET_ID), hook, percent);
    }

    function setLiveReservedSplits(uint256 projectId, IJBSplitHook[] memory hooks, uint32[] memory percents) external {
        _splits.setReservedSplits(projectId, uint256(CURRENT_RULESET_ID), hooks, percents);
    }

    function clearLiveReservedSplit(uint256 projectId) external {
        _splits.clearReservedSplits(projectId, uint256(CURRENT_RULESET_ID));
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

        if (_consumePendingRouteOnSend && _splitHook.hasPendingRoute() && _hookReservedTokenShareOf(projectId, tokenCount) != 0)
        {
            _splitHook.consumePendingRoute();
        }
    }

    function _hookReservedTokenShareOf(uint256 projectId, uint256 tokenCount) internal view returns (uint256 hookTokenCount) {
        if (tokenCount == 0) return 0;

        JBSplit[] memory reservedSplits = _splits.splitsOf(projectId, uint256(CURRENT_RULESET_ID), 1);

        for (uint256 i; i < reservedSplits.length; i++) {
            JBSplit memory reservedSplit = reservedSplits[i];
            if (address(reservedSplit.hook) != address(_splitHook)) continue;

            hookTokenCount += (tokenCount * reservedSplit.percent) / uint256(JBConstants.SPLITS_TOTAL_PERCENT);
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

contract CobuildCommunityTerminalMockTerminal {}

contract CobuildCommunityTerminalMockSplitHook is ICobuildSplitHook {
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

    function routingScoreOf(uint256) external pure override returns (uint256) {
        return 0;
    }

    function currentRoutingMass() external pure override returns (uint256) {
        return 0;
    }

    function selectableGoalIds() external pure override returns (uint256[] memory goalIds) {
        goalIds = new uint256[](0);
    }

    function historicalRoute() external pure override returns (uint256[] memory goalIds, uint256[] memory routingScores) {
        goalIds = new uint256[](0);
        routingScores = new uint256[](0);
    }

    function historicalBacklogProgress()
        external
        pure
        override
        returns (HistoricalBacklogProgressView memory progress)
    {
        progress = HistoricalBacklogProgressView({active: false, epoch: 0, remainingAmount: 0, processedGoalCount: 0});
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

    contract CobuildCommunityTerminalMockPayHook is IJBPayHook {
        uint256 internal _callCount;
        uint256 internal _lastObservedAllowance;
        bytes internal _lastPayerMetadata;
        bytes internal _lastHookMetadata;
        uint256 internal _lastForwardedAmount;

        function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
            return interfaceId == type(IJBPayHook).interfaceId;
        }

        function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
            _callCount += 1;
            if (context.amount.token.code.length != 0) {
                _lastObservedAllowance = ERC20(context.amount.token).allowance(msg.sender, address(this));
            } else {
                _lastObservedAllowance = 0;
            }
            _lastPayerMetadata = context.payerMetadata;
            _lastHookMetadata = context.hookMetadata;
            _lastForwardedAmount = context.forwardedAmount.value;
        }

        function callCount() external view returns (uint256) {
            return _callCount;
        }

        function lastObservedAllowance() external view returns (uint256) {
            return _lastObservedAllowance;
        }

        function lastPayerMetadata() external view returns (bytes memory) {
            return _lastPayerMetadata;
        }

        function lastHookMetadata() external view returns (bytes memory) {
            return _lastHookMetadata;
        }

        function lastForwardedAmount() external view returns (uint256) {
            return _lastForwardedAmount;
        }
    }

    contract CobuildCommunityTerminalMockSplitMutatingPayHook is IJBPayHook {
        CobuildCommunityTerminalMockController internal immutable _controller;
        uint256 internal immutable _projectId;
        CobuildCommunityTerminalMockSplitHook internal immutable _splitHook;
        uint32 internal immutable _newPercent;

        constructor(
            CobuildCommunityTerminalMockController controller_,
            uint256 projectId_,
            CobuildCommunityTerminalMockSplitHook splitHook_,
            uint32 newPercent_
        ) {
            _controller = controller_;
            _projectId = projectId_;
            _splitHook = splitHook_;
            _newPercent = newPercent_;
        }

        function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
            return interfaceId == type(IJBPayHook).interfaceId;
        }

        function afterPayRecordedWith(JBAfterPayRecordedContext calldata) external payable override {
            _controller.setLiveReservedSplit(_projectId, IJBSplitHook(address(_splitHook)), _newPercent);
        }
    }
