// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { BeforeSwapDeltaLibrary, toBeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBPrices } from "@bananapus/core-v5/interfaces/IJBPrices.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBTerminalStore } from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";
import { JBAccountingContext } from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { JBRulesetMetadata } from "@bananapus/core-v5/structs/JBRulesetMetadata.sol";

import { IUniswapV3Factory } from "src/interfaces/external/uniswap-v3/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "src/interfaces/external/uniswap-v3/IUniswapV3Pool.sol";
import { IUniswapV3SwapCallback } from "src/interfaces/external/uniswap-v3/IUniswapV3SwapCallback.sol";

interface IJBMultiTerminalLike {
    function STORE() external view returns (IJBTerminalStore);
    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    ) external returns (uint256 reclaimAmount);
}

/// @notice Routes GOAL <-> COBUILD swaps to the best expected output across:
/// - Juicebox issuance/cashout path
/// - Canonical Uniswap v3 GOAL/COBUILD pool
/// - The active Uniswap v4 GOAL/COBUILD pool
/// @dev Designed for pools where one side is `BACKING_TOKEN` (COBUILD) and the other side is a JB project token.
contract CobuildRoutedV4Hook is BaseHook, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint24 public constant V3_FEE_TIER = 3_000;
    uint16 internal constant ORACLE_CARDINALITY = 256;
    uint256 internal constant Q192 = FixedPoint96.Q96 * FixedPoint96.Q96;

    IJBDirectory public immutable DIRECTORY;
    IJBPrices public immutable PRICES;
    IJBTokens public immutable TOKENS;
    IUniswapV3Factory public immutable V3_FACTORY;
    address public immutable BACKING_TOKEN;
    uint32 public immutable TWAP_WINDOW;

    struct Observation {
        uint32 timestamp;
        int24 tick;
        int56 tickCumulative;
        bool initialized;
    }

    struct OracleState {
        uint16 index;
        uint16 cardinality;
        bool initialized;
    }

    struct CallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
    }

    mapping(PoolId poolId => Observation[ORACLE_CARDINALITY] observations) public observations;
    mapping(PoolId poolId => OracleState state) public oracleStates;
    mapping(PoolId poolId => bool enforceAfterSwapMinOut) internal _enforceAfterSwapMinOut;

    error EXACT_OUTPUT_UNSUPPORTED();
    error NOT_BACKING_PAIR();
    error NOT_JB_PROJECT_TOKEN();
    error NO_TERMINAL();
    error INVALID_HOOKDATA();
    error SLIPPAGE();
    error V3_CALLBACK_UNAUTHORIZED();
    error V3_POOL_NOT_FOUND();
    error INVALID_TWAP_TICK();
    error CUSTOM_ROUTE_INPUT_UNAVAILABLE();

    enum Route {
        JB,
        V3,
        V4
    }

    constructor(
        IPoolManager poolManager_,
        IJBDirectory directory_,
        IJBPrices prices_,
        IJBTokens tokens_,
        IUniswapV3Factory v3Factory_,
        address backingToken_,
        uint32 twapWindow_
    ) BaseHook(poolManager_) {
        if (
            address(directory_) == address(0) ||
            address(prices_) == address(0) ||
            address(tokens_) == address(0) ||
            address(v3Factory_) == address(0)
        ) revert NO_TERMINAL();
        if (backingToken_ == address(0)) revert NOT_BACKING_PAIR();
        if (twapWindow_ == 0) revert INVALID_HOOKDATA();

        DIRECTORY = directory_;
        PRICES = prices_;
        TOKENS = tokens_;
        V3_FACTORY = v3Factory_;
        BACKING_TOKEN = backingToken_;
        TWAP_WINDOW = twapWindow_;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        (address token0, address token1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (token0 != BACKING_TOKEN && token1 != BACKING_TOKEN) revert NOT_BACKING_PAIR();

        address projectToken = token0 == BACKING_TOKEN ? token1 : token0;
        if (TOKENS.projectIdOf(IJBToken(projectToken)) == 0) revert NOT_JB_PROJECT_TOKEN();

        _initializeOracle(key.toId(), tick);
        return BaseHook.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _recordObservation(key.toId());
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _recordObservation(key.toId());
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (params.amountSpecified >= 0) revert EXACT_OUTPUT_UNSUPPORTED();

        uint256 amountIn = uint256(-params.amountSpecified);
        // `amountOutMin` is the route-agnostic slippage guard for custom-accounted routes.
        // JB terminals do not expose a `sqrtPriceLimitX96` input.
        uint256 amountOutMin = _decodeAmountOutMin(hookData);

        address tokenIn = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        address tokenOut = Currency.unwrap(params.zeroForOne ? key.currency1 : key.currency0);

        if (tokenIn != BACKING_TOKEN && tokenOut != BACKING_TOKEN) revert NOT_BACKING_PAIR();

        address projectToken = tokenIn == BACKING_TOKEN ? tokenOut : tokenIn;
        uint256 projectId = TOKENS.projectIdOf(IJBToken(projectToken));
        if (projectId == 0) revert NOT_JB_PROJECT_TOKEN();

        bool buyingProjectToken = tokenOut == projectToken;

        IJBTerminal jbTerminal = DIRECTORY.primaryTerminalOf(projectId, BACKING_TOKEN);

        uint256 expectedJbOut;
        if (address(jbTerminal) != address(0)) {
            if (buyingProjectToken) {
                expectedJbOut = _expectedOutFromPay(projectId, BACKING_TOKEN, amountIn);
            } else {
                expectedJbOut = _expectedOutFromCashOut(projectId, amountIn, BACKING_TOKEN, jbTerminal);
            }
        }

        uint256 expectedV3Out = _estimateV3Out(tokenIn, tokenOut, amountIn);

        uint256 expectedV4Out;
        PoolId poolId = key.toId();
        if (poolManager.getLiquidity(poolId) != 0) {
            expectedV4Out = _estimateV4Out(key, params.zeroForOne, amountIn);
        }

        Route route = _selectRoute(expectedJbOut, expectedV3Out, expectedV4Out);
        _enforceAfterSwapMinOut[poolId] = route == Route.V4 && amountOutMin != 0;

        if (route == Route.V4) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // For custom-accounted routes, source the input from PoolManager first.
        // If input cannot be borrowed (e.g. thin/empty pool balances), continue with V4 when possible.
        if (!_tryTakeInput(Currency.wrap(tokenIn), amountIn)) {
            if (expectedV4Out != 0) {
                return _fallbackToV4(poolId, amountOutMin);
            }
            revert CUSTOM_ROUTE_INPUT_UNAVAILABLE();
        }

        uint256 outputReceived;
        if (route == Route.V3) {
            (bool v3Success, uint256 v3Output) = _routeThroughV3(key, params, tokenIn, tokenOut, amountIn);

            if (v3Success) {
                outputReceived = v3Output;
                if (amountOutMin != 0 && outputReceived < amountOutMin) revert SLIPPAGE();
            } else {
                if (expectedV4Out != 0) {
                    // Return custom-accounting input to PoolManager, then continue as a native v4 pool swap.
                    _settleOutput(Currency.wrap(tokenIn), amountIn);
                    return _fallbackToV4(poolId, amountOutMin);
                }

                if (address(jbTerminal) == address(0)) revert NO_TERMINAL();

                if (buyingProjectToken) {
                    outputReceived = _routeThroughJuiceboxPay(jbTerminal, projectId, tokenIn, amountIn, amountOutMin);
                } else {
                    outputReceived = _routeThroughJuiceboxCashOut(
                        jbTerminal,
                        projectId,
                        amountIn,
                        tokenOut,
                        amountOutMin
                    );
                }
            }
        } else {
            if (address(jbTerminal) == address(0)) revert NO_TERMINAL();

            if (buyingProjectToken) {
                outputReceived = _routeThroughJuiceboxPay(jbTerminal, projectId, tokenIn, amountIn, amountOutMin);
            } else {
                outputReceived = _routeThroughJuiceboxCashOut(jbTerminal, projectId, amountIn, tokenOut, amountOutMin);
            }
        }

        _settleOutput(Currency.wrap(tokenOut), outputReceived);
        return (BaseHook.beforeSwap.selector, _createSwapDelta(amountIn, outputReceived), 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        _recordObservation(key.toId());

        PoolId poolId = key.toId();
        if (_enforceAfterSwapMinOut[poolId]) {
            _enforceAfterSwapMinOut[poolId] = false;
            uint256 amountOutMin = _decodeAmountOutMin(hookData);
            int128 outDelta = params.zeroForOne
                ? BalanceDeltaLibrary.amount1(delta)
                : BalanceDeltaLibrary.amount0(delta);
            if (outDelta <= 0 || _positiveInt128ToUint256(outDelta) < amountOutMin) revert SLIPPAGE();
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _selectRoute(uint256 jbOut, uint256 v3Out, uint256 v4Out) internal pure returns (Route) {
        if (jbOut == 0 && v3Out == 0 && v4Out == 0) return Route.JB;
        if (v4Out != 0 && v4Out >= v3Out && v4Out >= jbOut) return Route.V4;
        if (v3Out != 0 && v3Out >= jbOut) return Route.V3;
        return Route.JB;
    }

    function _decodeAmountOutMin(bytes calldata hookData) internal pure returns (uint256) {
        if (hookData.length == 0) return 0;
        if (hookData.length < 32) revert INVALID_HOOKDATA();

        uint256 firstWord;
        assembly ("memory-safe") {
            firstWord := calldataload(hookData.offset)
        }

        // Backward compatibility for legacy versioned encoding: abi.encode(uint256(1), amountOutMin)
        if (hookData.length == 64 && firstWord == 1) {
            assembly ("memory-safe") {
                firstWord := calldataload(add(hookData.offset, 32))
            }
        }

        return firstWord;
    }

    function _fallbackToV4(PoolId poolId, uint256 amountOutMin) internal returns (bytes4, BeforeSwapDelta, uint24) {
        _enforceAfterSwapMinOut[poolId] = amountOutMin != 0;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _tryTakeInput(Currency inCur, uint256 amountIn) internal returns (bool) {
        try poolManager.take(inCur, address(this), amountIn) {
            return true;
        } catch {
            return false;
        }
    }

    function _createSwapDelta(uint256 amountIn, uint256 amountOut) internal pure returns (BeforeSwapDelta) {
        return toBeforeSwapDelta(amountIn.toInt128(), -amountOut.toInt128());
    }

    function _routeThroughJuiceboxPay(
        IJBTerminal terminal,
        uint256 projectId,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 out) {
        IERC20(tokenIn).forceApprove(address(terminal), 0);
        IERC20(tokenIn).forceApprove(address(terminal), amountIn);

        out = terminal.pay(projectId, tokenIn, amountIn, address(this), amountOutMin, "", bytes(""));

        IERC20(tokenIn).forceApprove(address(terminal), 0);
    }

    function _routeThroughJuiceboxCashOut(
        IJBTerminal terminal,
        uint256 projectId,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin
    ) internal returns (uint256 out) {
        out = IJBMultiTerminalLike(address(terminal)).cashOutTokensOf(
            address(this),
            projectId,
            amountIn,
            tokenOut,
            amountOutMin,
            payable(address(this)),
            bytes("")
        );
    }

    function _routeThroughV3(
        PoolKey calldata key,
        SwapParams calldata params,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (bool success, uint256 out) {
        address pool = _getV3Pool(tokenIn, tokenOut, V3_FEE_TIER);
        if (pool == address(0)) return (false, 0);

        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimit = _resolveV3SqrtPriceLimit(key, params, zeroForOne);

        try
            IUniswapV3Pool(pool).swap(
                address(this),
                zeroForOne,
                amountIn.toInt256(),
                sqrtPriceLimit,
                abi.encode(CallbackData({ tokenIn: tokenIn, tokenOut: tokenOut, fee: V3_FEE_TIER }))
            )
        returns (int256 amount0, int256 amount1) {
            out = zeroForOne ? _negativeInt256ToUint256(amount1) : _negativeInt256ToUint256(amount0);
            success = true;
        } catch {
            return (false, 0);
        }
    }

    function _resolveV3SqrtPriceLimit(
        PoolKey calldata key,
        SwapParams calldata params,
        bool v3ZeroForOne
    ) internal pure returns (uint160) {
        uint160 defaultLimit = v3ZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint160 requestedLimit = params.sqrtPriceLimitX96;
        if (requestedLimit == 0) return defaultLimit;

        (address ordered0, address ordered1, ) = _order(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        bool orderingMatchesV3 = Currency.unwrap(key.currency0) == ordered0 &&
            Currency.unwrap(key.currency1) == ordered1;
        if (!orderingMatchesV3) return defaultLimit;

        return requestedLimit;
    }

    function _settleOutput(Currency outCur, uint256 amount) internal {
        if (amount == 0) return;

        if (outCur.isAddressZero()) {
            poolManager.settle{ value: amount }();
        } else {
            poolManager.sync(outCur);
            IERC20(Currency.unwrap(outCur)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _estimateV3Out(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        address pool = _getV3Pool(tokenIn, tokenOut, V3_FEE_TIER);
        if (pool == address(0)) return 0;

        (, , , , , , bool unlocked) = IUniswapV3Pool(pool).slot0();
        if (!unlocked) return 0;

        uint32 secondsAgo = _effectiveV3TwapWindow(pool);
        if (secondsAgo == 0) return 0;

        int24 twapTick = _consult(pool, secondsAgo);
        uint256 quoteMid = _getQuoteAtTick(twapTick, amountIn, tokenIn, tokenOut);
        uint256 feeAmount = FullMath.mulDiv(quoteMid, V3_FEE_TIER, 1_000_000);
        return quoteMid - feeAmount;
    }

    function _effectiveV3TwapWindow(address pool) internal view returns (uint32) {
        uint32 oldest = _getOldestObservationSecondsAgo(pool);
        if (oldest == 0) return 0;
        return TWAP_WINDOW > oldest ? oldest : TWAP_WINDOW;
    }

    function _getOldestObservationSecondsAgo(address pool) internal view returns (uint32 secondsAgo) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = IUniswapV3Pool(pool).slot0();
        if (observationCardinality == 0) return 0;

        uint256 oldestIndex = (uint256(observationIndex) + 1) % observationCardinality;
        (uint32 oldestTimestamp, , , ) = IUniswapV3Pool(pool).observations(oldestIndex);
        if (oldestTimestamp == 0) {
            (oldestTimestamp, , , ) = IUniswapV3Pool(pool).observations(0);
            if (oldestTimestamp == 0) return 0;
        }

        uint32 nowTs = uint32(block.timestamp);
        if (nowTs <= oldestTimestamp) return 0;

        secondsAgo = nowTs - oldestTimestamp;
    }

    function _consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 divisor = int56(uint56(secondsAgo));

        arithmeticMeanTick = _toInt24Checked(tickDelta / divisor);
        if (tickDelta < 0 && (tickDelta % divisor != 0)) arithmeticMeanTick--;
    }

    function _getQuoteAtTick(
        int24 tick,
        uint256 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        quoteAmount = _quoteFromSqrtPriceX96(sqrtPriceX96, baseAmount, baseToken < quoteToken);
    }

    function _getV3Pool(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        (address token0, address token1, ) = _order(tokenA, tokenB);
        return V3_FACTORY.getPool(token0, token1, fee);
    }

    function _estimateV4Out(PoolKey calldata key, bool zeroForOne, uint256 amountIn) internal view returns (uint256) {
        PoolId poolId = key.toId();
        (uint160 spotSqrtPriceX96, int24 spotTick, , ) = poolManager.getSlot0(poolId);
        if (poolManager.getLiquidity(poolId) == 0) return 0;

        uint160 sqrtPriceX96 = _getTWAPSqrtPrice(poolId, spotTick);
        if (sqrtPriceX96 == 0) sqrtPriceX96 = spotSqrtPriceX96;
        uint256 out = _quoteFromSqrtPriceX96(sqrtPriceX96, amountIn, zeroForOne);

        uint256 feeAmount = FullMath.mulDiv(out, key.fee, 1_000_000);
        return out - feeAmount;
    }

    function _quoteFromSqrtPriceX96(
        uint160 sqrtPriceX96,
        uint256 amountIn,
        bool multiplyByPrice
    ) internal pure returns (uint256 out) {
        // Avoid overflow for high ticks when squaring sqrtPriceX96 directly.
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            out = multiplyByPrice
                ? FullMath.mulDiv(amountIn, ratioX192, Q192)
                : FullMath.mulDiv(amountIn, Q192, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            out = multiplyByPrice
                ? FullMath.mulDiv(amountIn, ratioX128, 1 << 128)
                : FullMath.mulDiv(amountIn, 1 << 128, ratioX128);
        }
    }

    function _getTWAPSqrtPrice(PoolId poolId, int24 currentTick) internal view returns (uint160) {
        OracleState memory state = oracleStates[poolId];
        if (!state.initialized || state.cardinality < 2) return 0;

        Observation memory latest = observations[poolId][state.index];
        if (!latest.initialized) return 0;

        uint32 nowTs = uint32(block.timestamp);
        (bool hasWindow, uint32 targetTs) = _effectiveV4TwapTargetTimestamp(poolId, state, nowTs);
        if (!hasWindow) return 0;

        (bool found, Observation memory past) = _findObservationAtOrBefore(poolId, state, targetTs);
        if (!found) return 0;

        int56 nowCumulative = _currentTickCumulative(latest, currentTick, nowTs);
        uint32 elapsed = nowTs - past.timestamp;
        if (elapsed == 0) return 0;

        int56 delta = nowCumulative - past.tickCumulative;
        int56 divisor = int56(uint56(elapsed));
        int24 twapTick = _toInt24Checked(delta / divisor);
        if (delta < 0 && (delta % divisor != 0)) twapTick--;

        return TickMath.getSqrtPriceAtTick(twapTick);
    }

    function _effectiveV4TwapTargetTimestamp(
        PoolId poolId,
        OracleState memory state,
        uint32 nowTs
    ) internal view returns (bool hasWindow, uint32 targetTs) {
        Observation memory oldest = _oldestObservation(poolId, state);
        if (!oldest.initialized || nowTs <= oldest.timestamp) return (false, 0);

        uint32 available = nowTs - oldest.timestamp;
        uint32 window = TWAP_WINDOW > available ? available : TWAP_WINDOW;
        if (window == 0) return (false, 0);

        return (true, nowTs - window);
    }

    function _oldestObservation(
        PoolId poolId,
        OracleState memory state
    ) internal view returns (Observation memory oldest) {
        uint16 oldestIndex = state.cardinality < ORACLE_CARDINALITY
            ? 0
            : uint16((uint256(state.index) + 1) % ORACLE_CARDINALITY);
        oldest = observations[poolId][oldestIndex];
    }

    function _findObservationAtOrBefore(
        PoolId poolId,
        OracleState memory state,
        uint32 targetTs
    ) internal view returns (bool found, Observation memory observation) {
        for (uint16 i; i < state.cardinality; i++) {
            uint16 idx = _backwardIndex(state.index, i, state.cardinality);
            Observation memory candidate = observations[poolId][idx];
            if (!candidate.initialized) continue;
            if (candidate.timestamp <= targetTs) return (true, candidate);
        }
        return (false, observation);
    }

    function _backwardIndex(uint16 start, uint16 offset, uint16 cardinality) internal pure returns (uint16) {
        if (offset <= start) return start - offset;
        return cardinality - (offset - start);
    }

    function _currentTickCumulative(
        Observation memory latest,
        int24 currentTick,
        uint32 nowTs
    ) internal pure returns (int56) {
        if (nowTs <= latest.timestamp) return latest.tickCumulative;
        uint32 elapsed = nowTs - latest.timestamp;
        return latest.tickCumulative + int56(int24(currentTick)) * int56(uint56(elapsed));
    }

    function _expectedOutFromPay(
        uint256 projectId,
        address paymentToken,
        uint256 amountIn
    ) internal view returns (uint256) {
        address controllerAddress = address(DIRECTORY.controllerOf(projectId));
        if (controllerAddress == address(0)) return 0;

        IJBController controller = IJBController(controllerAddress);

        JBRuleset memory ruleset;
        JBRulesetMetadata memory metadata;
        try controller.currentRulesetOf(projectId) returns (
            JBRuleset memory currentRuleset,
            JBRulesetMetadata memory currentMetadata
        ) {
            ruleset = currentRuleset;
            metadata = currentMetadata;
        } catch {
            return 0;
        }

        uint256 weight = ruleset.weight;
        uint256 baseCurrency = metadata.baseCurrency;
        uint256 reservedPercent = metadata.reservedPercent;

        // Juicebox encodes ERC-20 currencies as the low 32 bits of the token address.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 paymentCurrency = uint32(uint160(paymentToken));
        uint8 paymentDecimals = IERC20Metadata(paymentToken).decimals();

        uint256 weightRatio;
        if (uint256(paymentCurrency) == baseCurrency) {
            weightRatio = 10 ** paymentDecimals;
        } else if (paymentToken == JBConstants.NATIVE_TOKEN && baseCurrency == 1) {
            weightRatio = 10 ** 18;
        } else {
            try PRICES.pricePerUnitOf(projectId, uint256(paymentCurrency), baseCurrency, paymentDecimals) returns (
                uint256 quotedWeightRatio
            ) {
                weightRatio = quotedWeightRatio;
            } catch {
                return 0;
            }
        }

        if (weightRatio == 0) return 0;

        uint256 total = FullMath.mulDiv(amountIn, weight, weightRatio);
        if (reservedPercent != 0) {
            total -= FullMath.mulDiv(total, reservedPercent, JBConstants.MAX_RESERVED_PERCENT);
        }

        return total;
    }

    function _expectedOutFromCashOut(
        uint256 projectId,
        uint256 tokenAmountIn,
        address outputToken,
        IJBTerminal terminal
    ) internal view returns (uint256) {
        address controllerAddress = address(DIRECTORY.controllerOf(projectId));
        if (controllerAddress == address(0)) return 0;

        uint256 totalSupply;
        try IJBController(controllerAddress).totalTokenSupplyWithReservedTokensOf(projectId) returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            return 0;
        }

        IJBTerminalStore store;
        try IJBMultiTerminalLike(address(terminal)).STORE() returns (IJBTerminalStore terminalStore) {
            store = terminalStore;
        } catch {
            return 0;
        }

        JBAccountingContext memory accountingContext;
        try terminal.accountingContextForTokenOf(projectId, outputToken) returns (JBAccountingContext memory context) {
            accountingContext = context;
        } catch {
            return 0;
        }

        if (accountingContext.token != outputToken) return 0;

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = accountingContext;

        uint8 decimals = accountingContext.decimals;
        uint256 currency = accountingContext.currency;

        uint256 surplus;
        try terminal.currentSurplusOf(projectId, contexts, decimals, currency) returns (uint256 currentSurplus) {
            surplus = currentSurplus;
        } catch {
            return 0;
        }

        try store.currentReclaimableSurplusOf(projectId, tokenAmountIn, totalSupply, surplus) returns (
            uint256 reclaimable
        ) {
            return reclaimable;
        } catch {
            return 0;
        }
    }

    function _initializeOracle(PoolId poolId, int24 tick) internal {
        oracleStates[poolId] = OracleState({ index: 0, cardinality: 1, initialized: true });
        observations[poolId][0] = Observation({
            timestamp: uint32(block.timestamp),
            tick: tick,
            tickCumulative: 0,
            initialized: true
        });
    }

    function _recordObservation(PoolId poolId) internal {
        OracleState storage state = oracleStates[poolId];
        if (!state.initialized) return;
        (, int24 tick, , ) = poolManager.getSlot0(poolId);
        _writeObservation(poolId, tick);
    }

    function _writeObservation(PoolId poolId, int24 tick) internal {
        OracleState storage state = oracleStates[poolId];
        uint16 index = state.index;
        Observation storage last = observations[poolId][index];
        uint32 nowTs = uint32(block.timestamp);

        if (last.timestamp == nowTs) {
            last.tick = tick;
            return;
        }

        int56 cumulative = last.tickCumulative;
        if (nowTs > last.timestamp) {
            uint32 elapsed = nowTs - last.timestamp;
            cumulative += int56(int24(last.tick)) * int56(uint56(elapsed));
        }

        uint16 nextIndex = index + 1;
        if (nextIndex >= ORACLE_CARDINALITY) nextIndex = 0;

        observations[poolId][nextIndex] = Observation({
            timestamp: nowTs,
            tick: tick,
            tickCumulative: cumulative,
            initialized: true
        });

        state.index = nextIndex;
        if (state.cardinality < ORACLE_CARDINALITY) state.cardinality++;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        CallbackData memory cb = abi.decode(data, (CallbackData));
        address expectedPool = _getV3Pool(cb.tokenIn, cb.tokenOut, cb.fee);
        if (msg.sender != expectedPool) revert V3_CALLBACK_UNAUTHORIZED();

        if (amount0Delta > 0) {
            (address token0, , ) = _order(cb.tokenIn, cb.tokenOut);
            IERC20(token0).safeTransfer(msg.sender, _positiveInt256ToUint256(amount0Delta));
        } else if (amount1Delta > 0) {
            (, address token1, ) = _order(cb.tokenIn, cb.tokenOut);
            IERC20(token1).safeTransfer(msg.sender, _positiveInt256ToUint256(amount1Delta));
        }
    }

    function _toInt24Checked(int56 value) internal pure returns (int24 result) {
        if (value < type(int24).min || value > type(int24).max) revert INVALID_TWAP_TICK();
        assembly ("memory-safe") {
            result := value
        }
    }

    function _positiveInt128ToUint256(int128 value) internal pure returns (uint256) {
        return uint256(SafeCast.toUint128(value));
    }

    function _positiveInt256ToUint256(int256 value) internal pure returns (uint256) {
        if (value <= 0) return 0;
        return uint256(SafeCast.toUint128(SafeCast.toInt128(value)));
    }

    function _negativeInt256ToUint256(int256 value) internal pure returns (uint256) {
        if (value >= 0) return 0;
        return uint256(SafeCast.toUint128(SafeCast.toInt128(-value)));
    }

    function _order(address a, address b) internal pure returns (address token0, address token1, bool aIsToken0) {
        if (a < b) return (a, b, true);
        return (b, a, false);
    }
}
