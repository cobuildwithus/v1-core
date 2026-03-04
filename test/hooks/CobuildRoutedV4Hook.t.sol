// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {CobuildRoutedV4Hook} from "src/hooks/CobuildRoutedV4Hook.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v5/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";

import {IUniswapV3Factory} from "src/interfaces/external/uniswap-v3/IUniswapV3Factory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract CobuildRoutedV4HookTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant BACKING_TOKEN = address(0xBACC);

    CobuildRoutedV4HookHarness internal hook;
    MockTokens internal tokens;

    function setUp() public {
        tokens = new MockTokens();

        hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(new DummyContract())),
            IJBDirectory(address(new DummyContract())),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(new DummyContract())),
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

contract DummyContract {}
