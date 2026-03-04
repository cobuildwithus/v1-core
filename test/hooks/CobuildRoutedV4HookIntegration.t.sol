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

contract CobuildRoutedV4HookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant V3_FEE_TIER = 3_000;

    function test_beforeSwap_prefersJbPay_whenCanonicalCurrencyMatches() public {
        uint256 projectId = 101;
        uint256 amountIn = 25e18;

        MockERC20 backingToken = new MockERC20();
        MockERC20 projectToken = new MockERC20();

        MockTokens tokens = new MockTokens();
        tokens.setProjectId(address(projectToken), projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory v3Factory = new MockV3Factory();
        RevertingPrices prices = new RevertingPrices();

        PayTerminal terminal = new PayTerminal(address(projectToken), amountIn);
        directory.setPrimaryTerminal(projectId, address(backingToken), address(terminal));
        directory.setController(
            projectId, address(new MockControllerRuleset(1e18, uint32(uint160(address(backingToken))), 0, 1e24))
        );

        CobuildRoutedV4HookHarness hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(prices)),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            address(backingToken),
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(backingToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: V3_FEE_TIER,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.setPoolState(key.toId(), uint128(1), uint160(FixedPoint96.Q96), 0); // v4 quote ~= 0.997x input
        backingToken.mint(address(poolManager), amountIn);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.exposedBeforeSwap(key, params, "");

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(lpFeeOverride, 0);
        assertEq(terminal.payCalls(), 1);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(int256(amountIn)));
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), -int128(int256(amountIn)));
    }

    function test_beforeSwap_prefersJbCashOut_whenTerminalContextCurrencyMatches() public {
        uint256 projectId = 202;
        uint256 amountIn = 10e18;
        uint256 reclaimableOut = 12e18;

        MockERC20 backingToken = new MockERC20();
        MockERC20 projectToken = new MockERC20();

        MockTokens tokens = new MockTokens();
        tokens.setProjectId(address(projectToken), projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory v3Factory = new MockV3Factory();

        ConstantStore store = new ConstantStore(reclaimableOut);
        CashOutTerminal terminal =
            new CashOutTerminal(address(backingToken), uint32(uint160(address(backingToken))), address(store), reclaimableOut);

        directory.setPrimaryTerminal(projectId, address(backingToken), address(terminal));
        directory.setController(projectId, address(new MockControllerRuleset(1e18, 1, 0, 100e18)));

        CobuildRoutedV4HookHarness hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            address(backingToken),
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(backingToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: V3_FEE_TIER,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // keep v4 route valid but strictly worse than JB reclaim path.
        poolManager.setPoolState(key.toId(), uint128(1), uint160(FixedPoint96.Q96), 0); // ~9.97e18 output for 10e18 input
        projectToken.mint(address(poolManager), amountIn);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.exposedBeforeSwap(key, params, "");

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(lpFeeOverride, 0);
        assertEq(terminal.cashOutCalls(), 1);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(int256(amountIn)));
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), -int128(int256(reclaimableOut)));
    }

    function test_beforeSwap_doesNotOverflow_whenV4SqrtPriceExceedsUint128() public {
        uint256 projectId = 303;
        uint256 amountIn = 1e18;

        MockERC20 backingToken = new MockERC20();
        MockERC20 projectToken = new MockERC20();

        MockTokens tokens = new MockTokens();
        tokens.setProjectId(address(projectToken), projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory v3Factory = new MockV3Factory();

        CobuildRoutedV4HookHarness hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            address(backingToken),
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(backingToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: V3_FEE_TIER,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        uint160 highSqrtPriceX96 = uint160(uint256(type(uint128).max) + 1);
        poolManager.setPoolState(key.toId(), uint128(1), highSqrtPriceX96, 0);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.exposedBeforeSwap(key, params, "");
        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(lpFeeOverride, 0);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
    }

    function test_beforeSwap_takeFailureFallsBackToV4WhenJbRouteSelected() public {
        uint256 projectId = 404;
        uint256 amountIn = 25e18;
        uint256 amountOutMin = 10e18;

        MockERC20 backingToken = new MockERC20();
        MockERC20 projectToken = new MockERC20();

        MockTokens tokens = new MockTokens();
        tokens.setProjectId(address(projectToken), projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory v3Factory = new MockV3Factory();

        // If JB route executes this counter increments.
        PayTerminal terminal = new PayTerminal(address(projectToken), amountIn);
        directory.setPrimaryTerminal(projectId, address(backingToken), address(terminal));
        directory.setController(
            projectId, address(new MockControllerRuleset(1e18, uint32(uint160(address(backingToken))), 0, 1e24))
        );

        CobuildRoutedV4HookHarness hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            address(backingToken),
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(backingToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 10_000, // keep V4 estimate below JB estimate.
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();
        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);

        // No backing token minted to poolManager => take() fails before custom route executes.
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) =
            hook.exposedBeforeSwap(key, params, abi.encode(amountOutMin));

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0);
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        assertEq(lpFeeOverride, 0);
        assertEq(terminal.payCalls(), 0);
        assertTrue(hook.exposedEnforceAfterSwapMinOut(poolId));
    }

    function test_beforeSwap_revertsWhenTakeFailsAndV4Unavailable() public {
        uint256 projectId = 405;
        uint256 amountIn = 25e18;

        MockERC20 backingToken = new MockERC20();
        MockERC20 projectToken = new MockERC20();

        MockTokens tokens = new MockTokens();
        tokens.setProjectId(address(projectToken), projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory v3Factory = new MockV3Factory();

        PayTerminal terminal = new PayTerminal(address(projectToken), amountIn);
        directory.setPrimaryTerminal(projectId, address(backingToken), address(terminal));
        directory.setController(
            projectId, address(new MockControllerRuleset(1e18, uint32(uint160(address(backingToken))), 0, 1e24))
        );

        CobuildRoutedV4HookHarness hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            address(backingToken),
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(backingToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolManager.setPoolState(key.toId(), 0, uint160(FixedPoint96.Q96), 0); // no V4 fallback available.

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        vm.expectRevert(CobuildRoutedV4Hook.CUSTOM_ROUTE_INPUT_UNAVAILABLE.selector);
        hook.exposedBeforeSwap(key, params, bytes(""));
    }

    function test_afterSwap_v4RouteMinOutSupportsVersionedHookData() public {
        uint256 projectId = 406;
        uint256 amountIn = 1_000;
        uint256 amountOutMin = 500;

        MockERC20 backingToken = new MockERC20();
        MockERC20 projectToken = new MockERC20();

        MockTokens tokens = new MockTokens();
        tokens.setProjectId(address(projectToken), projectId);

        MockPoolManager poolManager = new MockPoolManager();
        MockDirectory directory = new MockDirectory();
        MockV3Factory v3Factory = new MockV3Factory();

        CobuildRoutedV4HookHarness hook = new CobuildRoutedV4HookHarness(
            IPoolManager(address(poolManager)),
            IJBDirectory(address(directory)),
            IJBPrices(address(new DummyContract())),
            IJBTokens(address(tokens)),
            IUniswapV3Factory(address(v3Factory)),
            address(backingToken),
            1 hours
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(backingToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();
        poolManager.setPoolState(poolId, uint128(1), uint160(FixedPoint96.Q96), 0);

        bytes memory hookData = abi.encode(uint256(1), amountOutMin);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});
        hook.exposedBeforeSwap(key, params, hookData);
        assertTrue(hook.exposedEnforceAfterSwapMinOut(poolId));

        (bytes4 selector, int128 returnedDelta) = hook.exposedAfterSwap(key, params, toBalanceDelta(0, 500), hookData);
        assertEq(selector, BaseHook.afterSwap.selector);
        assertEq(returnedDelta, 0);
        assertFalse(hook.exposedEnforceAfterSwapMinOut(poolId));
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

    function exposedBeforeSwap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(msg.sender, key, params, hookData);
    }

    function exposedAfterSwap(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        returns (bytes4, int128)
    {
        return _afterSwap(msg.sender, key, params, delta, hookData);
    }

    function exposedEnforceAfterSwapMinOut(PoolId poolId) external view returns (bool) {
        return _enforceAfterSwapMinOut[poolId];
    }

    function validateHookAddress(BaseHook) internal pure override {}
}

contract DummyContract {}

contract MockTokens {
    mapping(address token => uint256 projectId) internal _projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(address token) external view returns (uint256) {
        return _projectIdOf[token];
    }
}

contract MockDirectory {
    mapping(uint256 projectId => address controller) internal _controllerOf;
    mapping(uint256 projectId => mapping(address token => address terminal)) internal _primaryTerminalOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function setPrimaryTerminal(uint256 projectId, address token, address terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return IJBTerminal(_primaryTerminalOf[projectId][token]);
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

contract RevertingPrices {
    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        revert("NO_PRICE_FEED");
    }
}

contract MockV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract PayTerminal {
    address internal immutable _tokenOut;
    uint256 internal immutable _amountOut;
    uint256 internal _payCalls;

    constructor(address tokenOut, uint256 amountOut) {
        _tokenOut = tokenOut;
        _amountOut = amountOut;
    }

    function pay(uint256, address, uint256, address beneficiary, uint256, string calldata, bytes calldata)
        external
        returns (uint256)
    {
        _payCalls++;
        MockERC20(_tokenOut).mint(beneficiary, _amountOut);
        return _amountOut;
    }

    function payCalls() external view returns (uint256) {
        return _payCalls;
    }
}

contract ConstantStore {
    uint256 internal immutable _reclaimable;

    constructor(uint256 reclaimable) {
        _reclaimable = reclaimable;
    }

    function currentReclaimableSurplusOf(uint256, uint256, uint256, uint256) external view returns (uint256) {
        return _reclaimable;
    }
}

contract CashOutTerminal {
    address internal immutable _tokenOut;
    JBAccountingContext internal _context;
    ConstantStore internal immutable _store;
    uint256 internal immutable _amountOut;
    uint256 internal _cashOutCalls;

    constructor(address tokenOut, uint32 currency, address store, uint256 amountOut) {
        _tokenOut = tokenOut;
        _context = JBAccountingContext({token: tokenOut, decimals: 18, currency: currency});
        _store = ConstantStore(store);
        _amountOut = amountOut;
    }

    function STORE() external view returns (ConstantStore) {
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
        return 100e18;
    }

    function cashOutTokensOf(address holder, uint256, uint256, address, uint256, address payable, bytes calldata)
        external
        returns (uint256)
    {
        _cashOutCalls++;
        MockERC20(_tokenOut).mint(holder, _amountOut);
        return _amountOut;
    }

    function cashOutCalls() external view returns (uint256) {
        return _cashOutCalls;
    }
}

contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 slot => bytes32 value) internal _extsloadValues;

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

    function sync(Currency) external {}

    function take(Currency currency, address to, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function settle() external payable returns (uint256 paid) {
        return msg.value;
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

    function transfer(address to, uint256 amount) external returns (bool) {
        address owner = msg.sender;
        uint256 ownerBalance = _balanceOf[owner];
        require(ownerBalance >= amount, "INSUFFICIENT_BALANCE");
        unchecked {
            _balanceOf[owner] = ownerBalance - amount;
            _balanceOf[to] += amount;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 fromBalance = _balanceOf[from];
        require(fromBalance >= amount, "INSUFFICIENT_BALANCE");
        unchecked {
            _balanceOf[from] = fromBalance - amount;
            _balanceOf[to] += amount;
        }
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }
}
