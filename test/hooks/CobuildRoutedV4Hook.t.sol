// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {CobuildRoutedV4Hook} from "src/hooks/CobuildRoutedV4Hook.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v5/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";

import {IUniswapV3Factory} from "src/interfaces/external/uniswap-v3/IUniswapV3Factory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
    }

    function test_decodeAmountOutMin_revertsOnInvalidLength() public {
        vm.expectRevert(CobuildRoutedV4Hook.INVALID_HOOKDATA.selector);
        hook.exposedDecodeAmountOutMin(bytes(hex"cafe"));
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

    function exposedEnforceAfterSwapMinOut(PoolId poolId) external view returns (bool) {
        return _enforceAfterSwapMinOut[poolId];
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

contract MockDirectory {
    function primaryTerminalOf(uint256, address) external pure returns (IJBTerminal) {
        return IJBTerminal(address(0));
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
}

contract DummyContract {}
