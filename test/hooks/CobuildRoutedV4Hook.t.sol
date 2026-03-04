// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {CobuildRoutedV4Hook} from "src/hooks/CobuildRoutedV4Hook.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v5/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v5/structs/JBRulesetMetadata.sol";

import {IUniswapV3Factory} from "src/interfaces/external/uniswap-v3/IUniswapV3Factory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract CobuildRoutedV4HookTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant BACKING_TOKEN = address(0xBACC);
    uint24 internal constant V3_FEE_TIER = 3_000;

    CobuildRoutedV4HookHarness internal hook;
    MockTokens internal tokens;
    MockV3Factory internal v3Factory;

    function setUp() public {
        tokens = new MockTokens();
        v3Factory = new MockV3Factory();

        hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(new DummyContract())),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            BACKING_TOKEN,
            1 hours
        );
    }

    function test_afterInitialize_revertsWhenPoolHasNoBackingToken() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(CobuildRoutedV4Hook.NOT_BACKING_PAIR.selector);
        hook.exposedAfterInitialize(key, 0);
    }

    function test_afterInitialize_revertsWhenProjectTokenIsNotJuiceboxToken() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(BACKING_TOKEN),
            currency1: Currency.wrap(address(0x3000)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(CobuildRoutedV4Hook.NOT_JB_PROJECT_TOKEN.selector);
        hook.exposedAfterInitialize(key, 0);
    }

    function test_afterInitialize_initializesOracleStateForValidPair() public {
        address projectToken = address(0x3000);
        tokens.setProjectId(projectToken, 42);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(BACKING_TOKEN),
            currency1: Currency.wrap(projectToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        bytes4 selector = hook.exposedAfterInitialize(key, 123);
        assertEq(selector, BaseHook.afterInitialize.selector);

        PoolId poolId = key.toId();
        (uint16 index, uint16 cardinality, bool initialized) = hook.oracleStates(poolId);
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertTrue(initialized);

        (uint32 timestamp, int24 tick, int56 cumulative, bool observationInitialized) = hook.observations(poolId, 0);
        assertEq(timestamp, uint32(block.timestamp));
        assertEq(tick, 123);
        assertEq(cumulative, 0);
        assertTrue(observationInitialized);
    }

    function test_decodeAmountOutMin_handlesEmptyAndEncodedData() public view {
        assertEq(hook.exposedDecodeAmountOutMin(bytes("")), 0);
        assertEq(hook.exposedDecodeAmountOutMin(abi.encode(uint256(123_456))), 123_456);
        assertEq(hook.exposedDecodeAmountOutMin(abi.encode(uint256(1), uint256(654_321))), 654_321);
    }

    function test_decodeAmountOutMin_revertsOnInvalidLength() public {
        vm.expectRevert(CobuildRoutedV4Hook.INVALID_HOOKDATA.selector);
        hook.exposedDecodeAmountOutMin(bytes(hex"cafe"));
    }

    function test_decodeAmountOutMin_revertsOnInvalidVersionedData() public {
        vm.expectRevert(CobuildRoutedV4Hook.INVALID_HOOKDATA.selector);
        hook.exposedDecodeAmountOutMin(abi.encode(uint256(2), uint256(123)));
    }

    function test_selectRoute_prefersV4ThenV3AndFallsBackToJb() public view {
        assertEq(hook.exposedSelectRoute(0, 0, 0), 0); // JB
        assertEq(hook.exposedSelectRoute(10, 10, 10), 2); // V4 tie-break
        assertEq(hook.exposedSelectRoute(5, 7, 0), 1); // V3
        assertEq(hook.exposedSelectRoute(9, 0, 0), 0); // JB only
    }

    function test_createSwapDelta_setsSpecifiedPositiveAndUnspecifiedNegative() public view {
        BeforeSwapDelta delta = hook.exposedCreateSwapDelta(100, 77);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 100);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), -77);
    }

    function test_uniswapV3SwapCallback_revertsWhenCallerIsNotExpectedPool() public {
        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        (address token0, address token1) = _sort(address(tokenA), address(tokenB));
        v3Factory.setPool(token0, token1, V3_FEE_TIER, address(0xBEEF));

        vm.prank(address(0xCAFE));
        vm.expectRevert(CobuildRoutedV4Hook.V3_CALLBACK_UNAUTHORIZED.selector);
        hook.uniswapV3SwapCallback(1, 0, abi.encode(address(tokenA), address(tokenB), V3_FEE_TIER));
    }

    function test_uniswapV3SwapCallback_transfersToken0WhenAmount0DeltaPositive() public {
        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        (address token0, address token1) = _sort(address(tokenA), address(tokenB));
        v3Factory.setPool(token0, token1, V3_FEE_TIER, address(this));

        uint256 transferAmount = 50;
        MockERC20(token0).mint(address(hook), transferAmount);

        hook.uniswapV3SwapCallback(
            int256(transferAmount), 0, abi.encode(address(tokenA), address(tokenB), V3_FEE_TIER)
        );

        assertEq(MockERC20(token0).balanceOf(address(this)), transferAmount);
        assertEq(MockERC20(token0).balanceOf(address(hook)), 0);
    }

    function test_uniswapV3SwapCallback_transfersToken1WhenAmount1DeltaPositive() public {
        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        (address token0, address token1) = _sort(address(tokenA), address(tokenB));
        v3Factory.setPool(token0, token1, V3_FEE_TIER, address(this));

        uint256 transferAmount = 75;
        MockERC20(token1).mint(address(hook), transferAmount);

        hook.uniswapV3SwapCallback(
            0, int256(transferAmount), abi.encode(address(tokenA), address(tokenB), V3_FEE_TIER)
        );

        assertEq(MockERC20(token1).balanceOf(address(this)), transferAmount);
        assertEq(MockERC20(token1).balanceOf(address(hook)), 0);
    }

    function test_beforeSwap_revertsForExactOutput() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(BACKING_TOKEN),
            currency1: Currency.wrap(address(0x3000)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0 });

        vm.expectRevert(CobuildRoutedV4Hook.EXACT_OUTPUT_UNSUPPORTED.selector);
        hook.exposedBeforeSwap(key, params, bytes(""));
    }

    function test_beforeSwap_revertsWhenSwapPairDoesNotIncludeBackingToken() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0 });

        vm.expectRevert(CobuildRoutedV4Hook.NOT_BACKING_PAIR.selector);
        hook.exposedBeforeSwap(key, params, bytes(""));
    }

    function test_beforeSwap_revertsWhenProjectTokenNotJuiceboxToken() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(BACKING_TOKEN),
            currency1: Currency.wrap(address(0x3000)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0 });

        vm.expectRevert(CobuildRoutedV4Hook.NOT_JB_PROJECT_TOKEN.selector);
        hook.exposedBeforeSwap(key, params, bytes(""));
    }

    function test_beforeSwap_v3ExecutionFailureFallsBackToV4WhenAvailable() public {
        address projectToken = address(0x3000);
        uint256 projectId = 77;
        uint256 amountIn = 1_000;
        uint256 amountOutMin = 500;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolRevertingSwap v3Pool = new MockV3PoolRevertingSwap();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        localV3Factory.setPool(projectToken, backingTokenAddress, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 10_000, // keep V4 quote slightly below V3 quote so selection starts at V3
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);
        backingToken.mint(address(poolManager), amountIn);
        vm.warp(1_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) =
            localHook.exposedBeforeSwap(key, params, abi.encode(amountOutMin));

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        assertEq(lpFeeOverride, 0);

        // Input was pulled for the attempted custom route and then settled back for native V4 fallback.
        assertEq(poolManager.takeCalls(), 1);
        assertEq(poolManager.syncCalls(), 1);
        assertEq(poolManager.settleCalls(), 1);
        assertEq(backingToken.balanceOf(address(poolManager)), amountIn);
        assertEq(backingToken.balanceOf(address(localHook)), 0);
        assertTrue(localHook.exposedEnforceAfterSwapMinOut(poolId));
    }

    function test_beforeSwap_takeFailureFallsBackToV4WhenAvailable() public {
        address projectToken = address(0x3001);
        uint256 projectId = 78;
        uint256 amountIn = 1_000;
        uint256 amountOutMin = 500;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolRevertingSwap v3Pool = new MockV3PoolRevertingSwap();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        localV3Factory.setPool(projectToken, backingTokenAddress, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 10_000, // keep V4 quote slightly below V3 quote so selection starts at V3
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);
        vm.warp(1_000);

        // No backingToken minted to poolManager => take() fails.
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) =
            localHook.exposedBeforeSwap(key, params, abi.encode(amountOutMin));

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        assertEq(lpFeeOverride, 0);
        assertEq(poolManager.takeCalls(), 0);
        assertEq(poolManager.syncCalls(), 0);
        assertEq(poolManager.settleCalls(), 0);
        assertTrue(localHook.exposedEnforceAfterSwapMinOut(poolId));
    }

    function test_beforeSwap_takeFailureFallsBackToV4WhenJbRouteSelected() public {
        address projectToken = address(0x3007);
        uint256 projectId = 84;
        uint256 amountIn = 1_000;
        uint256 amountOutMin = 500;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectoryWithController directory = new MockDirectoryWithController();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        // If the JB route executes this reverts on min-return check. take() failure should force V4 fallback instead.
        MockPayTerminalWithSlippage terminal = new MockPayTerminalWithSlippage(0);
        directory.setController(
            projectId,
            address(new MockControllerRuleset(1e18, uint32(uint160(backingTokenAddress)), 0, 1e24))
        );
        directory.setPrimaryTerminal(projectId, backingTokenAddress, address(terminal));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 10_000, // keep V4 estimate below JB estimate so route selection starts at JB.
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);
        vm.warp(1_000);

        // No backingToken minted to poolManager => take() fails.
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) =
            localHook.exposedBeforeSwap(key, params, abi.encode(amountOutMin));

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        assertEq(lpFeeOverride, 0);
        assertEq(poolManager.takeCalls(), 0);
        assertEq(poolManager.syncCalls(), 0);
        assertEq(poolManager.settleCalls(), 0);
        assertTrue(localHook.exposedEnforceAfterSwapMinOut(poolId));
    }

    function test_beforeSwap_takeFailureFallbackDoesNotEnableMinOutWhenHookDataEmpty() public {
        address projectToken = address(0x3009);
        uint256 projectId = 86;
        uint256 amountIn = 1_000;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolRevertingSwap v3Pool = new MockV3PoolRevertingSwap();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        localV3Factory.setPool(projectToken, backingTokenAddress, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 10_000, // keep V4 quote slightly below V3 quote so selection starts at V3
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);
        vm.warp(1_000);

        // No backingToken minted to poolManager => take() fails.
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = localHook.exposedBeforeSwap(key, params, bytes(""));

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        assertEq(lpFeeOverride, 0);
        assertEq(poolManager.takeCalls(), 0);
        assertEq(poolManager.syncCalls(), 0);
        assertEq(poolManager.settleCalls(), 0);
        assertFalse(localHook.exposedEnforceAfterSwapMinOut(poolId));
    }

    function test_beforeSwap_revertsWhenCustomRouteInputUnavailableAndNoV4Fallback() public {
        address projectToken = address(0x3002);
        uint256 projectId = 79;
        uint256 amountIn = 1_000;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolRevertingSwap v3Pool = new MockV3PoolRevertingSwap();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        localV3Factory.setPool(projectToken, backingTokenAddress, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, 0, uint160(FixedPoint96.Q96), 0); // V4 unavailable
        vm.warp(1_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        vm.expectRevert(CobuildRoutedV4Hook.CUSTOM_ROUTE_INPUT_UNAVAILABLE.selector);
        localHook.exposedBeforeSwap(key, params, bytes(""));
    }

    function test_beforeSwap_v3RouteSlippageReverts() public {
        address projectToken = address(0x3003);
        uint256 projectId = 80;
        uint256 amountIn = 1_000;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolFixedSwap v3Pool = new MockV3PoolFixedSwap(700);
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        localV3Factory.setPool(projectToken, backingTokenAddress, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 10_000, // prefer V3 for estimate
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);
        backingToken.mint(address(poolManager), amountIn);
        vm.warp(1_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        vm.expectRevert(CobuildRoutedV4Hook.SLIPPAGE.selector);
        localHook.exposedBeforeSwap(key, params, abi.encode(uint256(701)));
    }

    function test_beforeSwap_jbRouteSlippageBubblesFromTerminal() public {
        address projectToken = address(new MockERC20());
        uint256 projectId = 81;
        uint256 amountIn = 1_000;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectoryWithController directory = new MockDirectoryWithController();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        MockPayTerminalWithSlippage terminal = new MockPayTerminalWithSlippage(700);
        directory.setController(projectId, address(new MockControllerRuleset(1e18, uint32(uint160(backingTokenAddress)), 0, 1e24)));
        directory.setPrimaryTerminal(projectId, backingTokenAddress, address(terminal));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, 0, uint160(FixedPoint96.Q96), 0); // keep V4 unavailable so JB is used.
        backingToken.mint(address(poolManager), amountIn);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        vm.expectRevert(bytes("MIN_RETURNED"));
        localHook.exposedBeforeSwap(key, params, abi.encode(uint256(701)));
    }

    function test_beforeSwap_customRouteDoesNotMutatePoolPrice() public {
        address projectToken = address(new MockERC20());
        uint256 projectId = 82;
        uint256 amountIn = 1_000;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolFixedSwap v3Pool = new MockV3PoolFixedSwap(800);
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        localV3Factory.setPool(projectToken, backingTokenAddress, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 10_000, // keep V4 estimate below V3 estimate
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        uint160 sqrtPriceBefore = uint160(FixedPoint96.Q96 + 1234);
        int24 tickBefore = 15;
        poolManager.setPoolState(poolId, uint128(1), sqrtPriceBefore, tickBefore);
        backingToken.mint(address(poolManager), amountIn);
        MockERC20(projectToken).mint(address(localHook), 800);
        vm.warp(1_000);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        localHook.exposedBeforeSwap(key, params, bytes(""));

        (uint160 sqrtPriceAfter, int24 tickAfter) = poolManager.slot0For(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceBefore);
        assertEq(tickAfter, tickBefore);
    }

    function test_afterSwap_v4RouteSlippageReverts() public {
        address projectToken = address(0x3006);
        uint256 projectId = 83;
        uint256 amountIn = 1_000;
        uint256 minOut = 500;

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        localHook.exposedBeforeSwap(key, params, abi.encode(minOut));
        assertTrue(localHook.exposedEnforceAfterSwapMinOut(poolId));

        vm.expectRevert(CobuildRoutedV4Hook.SLIPPAGE.selector);
        localHook.exposedAfterSwap(key, params, toBalanceDelta(0, 499), abi.encode(minOut));
    }

    function test_afterSwap_v4RouteMinOutSupportsVersionedHookData() public {
        address projectToken = address(0x3008);
        uint256 projectId = 85;
        uint256 amountIn = 1_000;
        uint256 minOut = 500;
        bytes memory hookData = abi.encode(uint256(1), minOut);

        tokens.setProjectId(projectToken, projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory localV3Factory = new MockV3Factory();
        MockERC20 backingToken = new MockERC20();
        address backingTokenAddress = address(backingToken);

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            backingTokenAddress,
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(backingTokenAddress),
            currency1: Currency.wrap(projectToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        localHook.exposedBeforeSwap(key, params, hookData);
        assertTrue(localHook.exposedEnforceAfterSwapMinOut(poolId));

        (bytes4 selector, int128 hookDelta) = localHook.exposedAfterSwap(key, params, toBalanceDelta(0, 500), hookData);
        assertEq(selector, BaseHook.afterSwap.selector);
        assertEq(hookDelta, 0);
        assertFalse(localHook.exposedEnforceAfterSwapMinOut(poolId));
    }

    function test_expectedOutFromPay_usesCanonical32BitCurrencyId() public {
        uint256 projectId = 99;
        uint256 amountIn = 25e18;
        MockERC20Metadata paymentToken = new MockERC20Metadata(18);

        MockDirectoryWithController directory = new MockDirectoryWithController();
        MockPricesConstant prices = new MockPricesConstant(2e18);

        tokens.setProjectId(address(paymentToken), projectId);
        directory.setController(projectId, address(new MockControllerRuleset(1e18, uint32(uint160(address(paymentToken))), 0, 1e24)));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(directory)),
            IJBPrices(address(prices)),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            BACKING_TOKEN,
            1 hours
        );

        uint256 out = localHook.exposedExpectedOutFromPay(projectId, address(paymentToken), amountIn);

        // With the canonical currency-id branch this equals amountIn.
        // Before the fix, the hook called PRICES and returned amountIn / 2 from MockPricesConstant.
        assertEq(out, amountIn);
    }

    function test_expectedOutFromPay_pricesPathUsesCanonical32BitCurrencyId() public {
        uint256 projectId = 100;
        uint256 amountIn = 25e18;
        MockERC20Metadata paymentToken = new MockERC20Metadata(18);

        uint32 canonicalCurrency = uint32(uint160(address(paymentToken)));
        uint32 baseCurrency = canonicalCurrency ^ uint32(1); // force non-matching base currency branch
        MockPricesExpectingCanonicalCurrency prices = new MockPricesExpectingCanonicalCurrency(canonicalCurrency, 2e18);

        MockDirectoryWithController directory = new MockDirectoryWithController();
        directory.setController(projectId, address(new MockControllerRuleset(1e18, baseCurrency, 0, 1e24)));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(directory)),
            IJBPrices(address(prices)),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            BACKING_TOKEN,
            1 hours
        );

        uint256 out = localHook.exposedExpectedOutFromPay(projectId, address(paymentToken), amountIn);

        assertEq(out, amountIn / 2);
    }

    function test_expectedOutFromCashOut_usesTerminalAccountingContextCurrency() public {
        uint256 projectId = 111;
        uint256 tokenAmountIn = 5e18;

        MockDirectoryWithController directory = new MockDirectoryWithController();
        MockControllerRuleset controller = new MockControllerRuleset(1e18, 1, 0, 100e18);
        directory.setController(projectId, address(controller));

        MockERC20Metadata outputToken = new MockERC20Metadata(18);
        StrictCurrencyTerminal terminal =
            new StrictCurrencyTerminal(address(outputToken), 18, uint32(uint160(address(outputToken))), 80e18, 12e18);

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            BACKING_TOKEN,
            1 hours
        );

        uint256 reclaimable = localHook.exposedExpectedOutFromCashOut(
            projectId, tokenAmountIn, address(outputToken), IJBTerminal(address(terminal))
        );

        // Before the fix this was 0 because currency was passed as uint160(token), causing currentSurplusOf revert.
        assertEq(reclaimable, 12e18);
    }

    function test_estimateV4Out_doesNotOverflowWhenSqrtPriceAboveUint128() public {
        MockPoolManager poolManager = new MockPoolManager();
        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(new DummyContract())),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            BACKING_TOKEN,
            1 hours
        );

        address projectToken = address(0xCAFE);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(BACKING_TOKEN),
            currency1: Currency.wrap(projectToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });
        PoolId poolId = key.toId();

        uint160 largeSqrtPriceX96 = uint160(type(uint128).max) + 1;
        poolManager.setPoolState(poolId, uint128(1), largeSqrtPriceX96, 0);

        uint256 out = localHook.exposedEstimateV4Out(key, true, 1e18);
        assertGt(out, 0);
    }

    function test_estimateV3Out_doesNotOverflowWhenTickNearMax() public {
        MockV3Factory localV3Factory = new MockV3Factory();
        MockV3PoolHighTick v3Pool = new MockV3PoolHighTick();
        address tokenIn = address(0x1000);
        address tokenOut = address(0x2000);
        localV3Factory.setPool(tokenIn, tokenOut, V3_FEE_TIER, address(v3Pool));

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(new DummyContract())),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(localV3Factory)),
            BACKING_TOKEN,
            1 hours
        );

        vm.warp(1_000);
        uint256 out = localHook.exposedEstimateV3Out(tokenIn, tokenOut, 1e18);
        assertGt(out, 0);
    }

    function test_expectedOutFromCashOut_succeedsWhenOutputTokenHasNoDecimalsMethod() public {
        uint256 projectId = 123;
        uint256 tokenAmountIn = 5e18;

        MockDirectoryWithController directory = new MockDirectoryWithController();
        MockControllerRuleset controller = new MockControllerRuleset(1e18, 1, 0, 100e18);
        directory.setController(projectId, address(controller));

        MockNoDecimalsToken outputToken = new MockNoDecimalsToken();
        StrictCurrencyTerminal terminal = new StrictCurrencyTerminal(
            address(outputToken), 18, uint32(uint160(address(outputToken))), 80e18, 12e18
        );

        CobuildRoutedV4HookHarness localHook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            BACKING_TOKEN,
            1 hours
        );

        uint256 reclaimable = localHook.exposedExpectedOutFromCashOut(
            projectId, tokenAmountIn, address(outputToken), IJBTerminal(address(terminal))
        );
        assertEq(reclaimable, 12e18);
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        if (a < b) return (a, b);
        return (b, a);
    }
}

contract CobuildRoutedV4HookHarness is CobuildRoutedV4Hook {
    constructor(
        IPoolManager poolManager_,
        IJBDirectory directory_,
        IJBPrices prices_,
        IJBTokens tokens_,
        IUniswapV3Factory v3Factory_,
        address backingToken_,
        uint32 twapWindow_
    ) CobuildRoutedV4Hook(poolManager_, directory_, prices_, tokens_, v3Factory_, backingToken_, twapWindow_) {}

    // Permit arbitrary local deployment in tests without mined low-bit hook addresses.
    function validateHookAddress(BaseHook) internal pure override {}

    function exposedAfterInitialize(PoolKey calldata key, int24 tick) external returns (bytes4) {
        return _afterInitialize(address(this), key, 0, tick);
    }

    function exposedDecodeAmountOutMin(bytes calldata hookData) external pure returns (uint256) {
        return _decodeAmountOutMin(hookData);
    }

    function exposedSelectRoute(uint256 jbOut, uint256 v3Out, uint256 v4Out) external pure returns (uint8) {
        return uint8(_selectRoute(jbOut, v3Out, v4Out));
    }

    function exposedCreateSwapDelta(uint256 amountIn, uint256 amountOut) external pure returns (BeforeSwapDelta) {
        return _createSwapDelta(amountIn, amountOut);
    }

    function exposedBeforeSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(address(this), key, params, hookData);
    }

    function exposedAfterSwap(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        returns (bytes4, int128)
    {
        return _afterSwap(address(this), key, params, delta, hookData);
    }

    function exposedEnforceAfterSwapMinOut(PoolId poolId) external view returns (bool) {
        return _enforceAfterSwapMinOut[poolId];
    }

    function exposedExpectedOutFromPay(uint256 projectId, address paymentToken, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        return _expectedOutFromPay(projectId, paymentToken, amountIn);
    }

    function exposedExpectedOutFromCashOut(
        uint256 projectId,
        uint256 tokenAmountIn,
        address outputToken,
        IJBTerminal terminal
    ) external view returns (uint256) {
        return _expectedOutFromCashOut(projectId, tokenAmountIn, outputToken, terminal);
    }

    function exposedEstimateV4Out(PoolKey calldata key, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        return _estimateV4Out(key, zeroForOne, amountIn);
    }

    function exposedEstimateV3Out(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        return _estimateV3Out(tokenIn, tokenOut, amountIn);
    }
}

contract MockTokens {
    mapping(address => uint256) internal _projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(address token) external view returns (uint256) {
        return _projectIdOf[token];
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) internal _poolOf;

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        _poolOf[_key(token0, token1, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _poolOf[_key(tokenA, tokenB, fee)];
    }

    function _key(address token0, address token1, uint24 fee) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1, fee));
    }
}

contract MockV3PoolRevertingSwap {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(FixedPoint96.Q96), 0, 0, 1, 1, 0, true);
    }

    function observations(uint256 index) external view returns (uint32, int56, uint160, bool) {
        if (index != 0) return (0, 0, 0, false);
        return (uint32(block.timestamp - 1), 0, 0, true);
    }

    function observe(uint32[] calldata) external pure returns (int56[] memory, uint160[] memory) {
        int56[] memory tickCumulatives = new int56[](2);
        uint160[] memory secondsPerLiquidity = new uint160[](2);
        return (tickCumulatives, secondsPerLiquidity);
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert("V3_SWAP_FAILED");
    }
}

contract MockV3PoolFixedSwap {
    uint256 internal immutable _amountOut;

    constructor(uint256 amountOut_) {
        _amountOut = amountOut_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(FixedPoint96.Q96), 0, 0, 1, 1, 0, true);
    }

    function observations(uint256 index) external view returns (uint32, int56, uint160, bool) {
        if (index != 0) return (0, 0, 0, false);
        return (uint32(block.timestamp - 1), 0, 0, true);
    }

    function observe(uint32[] calldata) external pure returns (int56[] memory, uint160[] memory) {
        int56[] memory tickCumulatives = new int56[](2);
        uint160[] memory secondsPerLiquidity = new uint160[](2);
        return (tickCumulatives, secondsPerLiquidity);
    }

    function swap(address, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external
        view
        returns (int256 amount0, int256 amount1)
    {
        if (zeroForOne) {
            amount0 = amountSpecified;
            amount1 = -int256(_amountOut);
        } else {
            amount0 = -int256(_amountOut);
            amount1 = amountSpecified;
        }
    }
}

contract MockV3PoolHighTick {
    int24 internal constant HIGH_TICK = 887_272;

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(FixedPoint96.Q96), HIGH_TICK, 0, 1, 1, 0, true);
    }

    function observations(uint256 index) external view returns (uint32, int56, uint160, bool) {
        if (index != 0) return (0, 0, 0, false);
        return (uint32(block.timestamp - 1), 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external pure returns (int56[] memory, uint160[] memory) {
        int56[] memory tickCumulatives = new int56[](2);
        uint160[] memory secondsPerLiquidity = new uint160[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(int24(HIGH_TICK)) * int56(uint56(secondsAgos[0]));
        return (tickCumulatives, secondsPerLiquidity);
    }
}

contract MockDirectory {
    function primaryTerminalOf(uint256, address) external pure returns (IJBTerminal) {
        return IJBTerminal(address(0));
    }
}

contract MockDirectoryWithController {
    mapping(uint256 => address) internal _controllerOf;
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function setPrimaryTerminal(uint256 projectId, address token, address terminal) external {
        _primaryTerminalOf[projectId][token] = IJBTerminal(terminal);
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract MockControllerRuleset {
    JBRuleset internal _ruleset;
    JBRulesetMetadata internal _metadata;
    uint256 internal _totalSupply;

    constructor(uint112 weight, uint32 baseCurrency, uint16 reservedPercent, uint256 totalSupply) {
        _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: weight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        _metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: 0,
            baseCurrency: baseCurrency,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        _totalSupply = totalSupply;
    }

    function currentRulesetOf(uint256) external view returns (JBRuleset memory, JBRulesetMetadata memory) {
        return (_ruleset, _metadata);
    }

    function totalTokenSupplyWithReservedTokensOf(uint256) external view returns (uint256) {
        return _totalSupply;
    }
}

contract MockPricesConstant {
    uint256 internal immutable _price;

    constructor(uint256 price_) {
        _price = price_;
    }

    function pricePerUnitOf(uint256, uint256, uint256, uint256) external view returns (uint256) {
        return _price;
    }
}

contract MockPricesExpectingCanonicalCurrency {
    uint32 internal immutable _expectedPricingCurrency;
    uint256 internal immutable _price;

    constructor(uint32 expectedPricingCurrency_, uint256 price_) {
        _expectedPricingCurrency = expectedPricingCurrency_;
        _price = price_;
    }

    function pricePerUnitOf(uint256, uint256 pricingCurrency, uint256, uint256) external view returns (uint256) {
        require(pricingCurrency == _expectedPricingCurrency, "NON_CANONICAL_CURRENCY");
        return _price;
    }
}

contract MockERC20Metadata {
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract MockNoDecimalsToken {}

contract StrictCurrencyTerminal {
    JBAccountingContext internal _context;
    uint256 internal _surplus;
    StrictCurrencyTerminalStore internal _store;

    constructor(address token, uint8 decimals, uint32 currency, uint256 surplus, uint256 reclaimable) {
        _context = JBAccountingContext({token: token, decimals: decimals, currency: currency});
        _surplus = surplus;
        _store = new StrictCurrencyTerminalStore(reclaimable);
    }

    function STORE() external view returns (StrictCurrencyTerminalStore) {
        return _store;
    }

    function accountingContextForTokenOf(uint256, address) external view returns (JBAccountingContext memory) {
        return _context;
    }

    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256 decimals, uint256 currency)
        external
        view
        returns (uint256)
    {
        require(decimals == _context.decimals, "BAD_DECIMALS");
        require(currency == _context.currency, "BAD_CURRENCY");
        return _surplus;
    }
}

contract StrictCurrencyTerminalStore {
    uint256 internal immutable _reclaimable;

    constructor(uint256 reclaimable_) {
        _reclaimable = reclaimable_;
    }

    function currentReclaimableSurplusOf(uint256, uint256, uint256, uint256) external view returns (uint256) {
        return _reclaimable;
    }
}

contract MockPayTerminalWithSlippage {
    uint256 internal immutable _out;

    constructor(uint256 out_) {
        _out = out_;
    }

    function pay(uint256, address, uint256, address, uint256 minReturnedTokens, string calldata, bytes calldata)
        external
        view
        returns (uint256)
    {
        if (_out < minReturnedTokens) revert("MIN_RETURNED");
        return _out;
    }
}

contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 slot => bytes32 value) internal _extsloadValues;

    uint256 internal _takeCalls;
    uint256 internal _syncCalls;
    uint256 internal _settleCalls;

    function setPoolState(PoolId poolId, uint128 liquidity, uint160 sqrtPriceX96, int24 tick) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
        _extsloadValues[stateSlot] = _packSlot0(sqrtPriceX96, tick, 0, 0);
        _extsloadValues[bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _extsloadValues[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; i++) {
            values[i] = _extsloadValues[bytes32(uint256(startSlot) + i)];
        }
    }

    function sync(Currency) external {
        _syncCalls++;
    }

    function take(Currency currency, address to, uint256 amount) external {
        _takeCalls++;
        MockERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function settle() external payable returns (uint256 paid) {
        _settleCalls++;
        return msg.value;
    }

    function takeCalls() external view returns (uint256) {
        return _takeCalls;
    }

    function syncCalls() external view returns (uint256) {
        return _syncCalls;
    }

    function settleCalls() external view returns (uint256) {
        return _settleCalls;
    }

    function _packSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (bytes32 packed)
    {
        uint256 tickBits = uint24(uint32(int32(tick)));
        uint256 word = uint256(sqrtPriceX96);
        word |= tickBits << 160;
        word |= uint256(protocolFee) << 184;
        word |= uint256(lpFee) << 208;
        packed = bytes32(word);
    }

    function slot0For(PoolId poolId) external view returns (uint160 sqrtPriceX96, int24 tick) {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
        bytes32 packed = _extsloadValues[stateSlot];
        sqrtPriceX96 = uint160(uint256(packed));
        tick = int24(uint24(uint256(packed >> 160)));
    }
}

contract MockERC20 {
    mapping(address => uint256) internal _balanceOf;

    function mint(address account, uint256 amount) external {
        _balanceOf[account] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 balance = _balanceOf[msg.sender];
        require(balance >= amount, "INSUFFICIENT_BALANCE");
        unchecked {
            _balanceOf[msg.sender] = balance - amount;
        }
        _balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract DummyContract {}
