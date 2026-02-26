// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { ICobuildSwap } from "src/interfaces/ICobuildSwap.sol";

import { CobuildSwapUnitTest, Mock0xRouter, MockERC20, MockJBTerminal } from "test/swaps/CobuildSwap.t.sol";

contract CobuildSwapBranchCoverageTest is CobuildSwapUnitTest {
    function test_setExecutor_revertsOnZeroAddress() public {
        vm.expectRevert(ICobuildSwap.ZERO_ADDR.selector);
        cobuildSwap.setExecutor(address(0));
    }

    function test_setFeeBps_revertsWhenAboveHardCap() public {
        vm.expectRevert(ICobuildSwap.FEE_TOO_HIGH.selector);
        cobuildSwap.setFeeBps(501);
    }

    function test_setFeeCollector_revertsOnZeroAddress() public {
        vm.expectRevert(ICobuildSwap.ZERO_ADDR.selector);
        cobuildSwap.setFeeCollector(address(0));
    }

    function test_setJuiceboxAddresses_revertsOnZeroAddress() public {
        vm.expectRevert(ICobuildSwap.ZERO_ADDR.selector);
        cobuildSwap.setJuiceboxAddresses(address(0), address(jbTokens));

        vm.expectRevert(ICobuildSwap.ZERO_ADDR.selector);
        cobuildSwap.setJuiceboxAddresses(address(jbDirectory), address(0));
    }

    function test_setSpenderAllowed_disallowPathRevokesExistingAllowance() public {
        vm.prank(address(cobuildSwap));
        usdc.approve(address(router), 123);
        assertEq(usdc.allowance(address(cobuildSwap), address(router)), 123);

        cobuildSwap.setSpenderAllowed(address(router), false);

        assertEq(usdc.allowance(address(cobuildSwap), address(router)), 0);
        assertFalse(cobuildSwap.allowedSpenders(address(router)));
    }

    function test_rescueETH_revertsWhenTransferFails() public {
        RejectETHReceiver rejector = new RejectETHReceiver();
        vm.deal(address(cobuildSwap), 1 ether);

        vm.expectRevert(ICobuildSwap.ETH_TRANSFER_FAIL.selector);
        cobuildSwap.rescueETH(payable(address(rejector)), 1 ether);
    }

    function test_computeFeeAndNet_revertsWhenFeeIsGteAmount() public {
        cobuildSwap.setFeeBps(0);
        cobuildSwap.setMinFeeAbsolute(1_000);

        vm.expectRevert(ICobuildSwap.AMOUNT_LT_MIN_FEE.selector);
        cobuildSwap.computeFeeAndNet(1_000);
    }

    function test_executeBatch0x_revertsWhenRouterNotAllowed() public {
        address user = makeAddr("batch-not-allowed-user");
        _mintAndApproveUsdc(user, 1);
        cobuildSwap.setRouterAllowed(address(router), false);

        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(tokenOut), 0, address(router), address(router), _singlePayee(user, user, 1));

        vm.expectRevert(ICobuildSwap.ROUTER_NOT_ALLOWED.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenDeadlineExpired() public {
        address user = makeAddr("batch-expired-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(tokenOut), 0, address(router), address(router), _singlePayee(user, user, 1));
        s.deadline = block.timestamp - 1;

        vm.expectRevert(ICobuildSwap.EXPIRED_DEADLINE.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenTokenOutIsZero() public {
        address user = makeAddr("batch-token-out-zero-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(0), 0, address(router), address(router), _singlePayee(user, user, 1));

        vm.expectRevert(ICobuildSwap.INVALID_TOKEN_OUT.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenValueIsNonZero() public {
        address user = makeAddr("batch-value-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(tokenOut), 0, address(router), address(router), _singlePayee(user, user, 1));
        s.value = 1;

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenCallTargetMismatch() public {
        address user = makeAddr("batch-call-target-mismatch-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(tokenOut), 0, address(router), makeAddr("other-call-target"), _singlePayee(user, user, 1));

        vm.expectRevert(ICobuildSwap.ROUTER_NOT_ALLOWED.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenTokenOutIsUSDC() public {
        address user = makeAddr("batch-usdc-out-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(usdc), 0, address(router), address(router), _singlePayee(user, user, 1));

        vm.expectRevert(ICobuildSwap.INVALID_TOKEN_OUT.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenBatchSizeIsZero() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](0);
        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(address(tokenOut), 0, address(router), address(router), payees);

        vm.expectRevert(ICobuildSwap.BAD_BATCH_SIZE.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenPayeeAddressInvalid() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("batch-payee-user"), recipient: address(0), amountIn: 1 });
        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(address(tokenOut), 0, address(router), address(router), payees);

        vm.expectRevert(ICobuildSwap.INVALID_ADDRESS.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenPayeeAmountIsZero() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("batch-payee-user"), recipient: makeAddr("batch-recipient"), amountIn: 0 });
        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(address(tokenOut), 0, address(router), address(router), payees);

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_bubblesRouterRevertData() public {
        address user = makeAddr("batch-router-revert-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;
        router.configure(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, 100, true);

        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(tokenOut), 0, address(router), address(router), _singlePayee(user, user, amountIn));

        vm.expectRevert(Mock0xRouter.ForcedRevert.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenRouterIncreasesUSDCBalance() public {
        MockRouterUSDCRebate rebateRouter = new MockRouterUSDCRebate();
        cobuildSwap.setRouterAllowed(address(rebateRouter), true);
        cobuildSwap.setSpenderAllowed(address(rebateRouter), true);

        address user = makeAddr("batch-usdc-increase-user");
        _mintAndApproveUsdc(user, 1_000_000);
        usdc.mint(address(rebateRouter), 1);
        rebateRouter.configure(IERC20(address(usdc)), 1);

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut), 0, address(rebateRouter), address(rebateRouter), _singlePayee(user, user, 1_000_000)
        );

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(rebateRouter), s);
    }

    function test_executeBatch0x_revertsWhenSpentExceedsNet() public {
        MockRouterOverSpender overSpender = new MockRouterOverSpender();
        cobuildSwap.setRouterAllowed(address(overSpender), true);
        cobuildSwap.setSpenderAllowed(address(overSpender), true);

        address user = makeAddr("batch-over-spend-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;
        overSpender.configure(usdc, totalNet + 1);

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut), 0, address(overSpender), address(overSpender), _singlePayee(user, user, amountIn)
        );

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(overSpender), s);
    }

    function test_executeBatch0x_sweepsPreexistingTokenOutDust() public {
        address user = makeAddr("batch-dust-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;
        uint256 swapOut = 100;
        uint256 preexistingDust = 7;

        tokenOut.mint(address(cobuildSwap), preexistingDust);
        tokenOut.mint(address(router), swapOut);
        router.configure(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, swapOut, false);

        ICobuildSwap.OxOneToMany memory s =
            _buildOxOrder(address(tokenOut), swapOut, address(router), address(router), _singlePayee(user, user, amountIn));

        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);

        assertEq(tokenOut.balanceOf(feeCollector), preexistingDust, "preexisting dust should be swept");
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenRouterNotAllowed() public {
        address user = makeAddr("zora-router-not-allowed-user");
        _mintAndApproveUsdc(user, 1);
        cobuildSwap.setRouterAllowed(address(router), false);

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(_singlePayee(user, user, 1), 0);

        vm.expectRevert(ICobuildSwap.ROUTER_NOT_ALLOWED.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenExpired() public {
        address user = makeAddr("zora-expired-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(_singlePayee(user, user, 1), 0);
        s.deadline = block.timestamp - 1;

        vm.expectRevert(ICobuildSwap.EXPIRED_DEADLINE.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenBatchSizeIsZero() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](0);
        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(payees, 0);

        vm.expectRevert(ICobuildSwap.BAD_BATCH_SIZE.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenTokenOutInvalid() public {
        address user = makeAddr("zora-invalid-token-out-user");
        _mintAndApproveUsdc(user, 1);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(zora)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = ICobuildSwap.ZoraCreatorCoinOneToMany({
            key: key,
            v3Fee: 3000,
            deadline: block.timestamp + 1 days,
            minZoraOut: 1,
            minCreatorOut: 0,
            payees: _singlePayee(user, user, 1)
        });

        vm.expectRevert(ICobuildSwap.INVALID_TOKEN_OUT.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenPayeeAddressInvalid() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("zora-user"), recipient: address(0), amountIn: 1 });
        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(payees, 0);

        vm.expectRevert(ICobuildSwap.INVALID_ADDRESS.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenPayeeAmountIsZero() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("zora-user"), recipient: makeAddr("zora-recipient"), amountIn: 0 });
        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(payees, 0);

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenSpentMismatchesTotalNet() public {
        address user = makeAddr("zora-spent-mismatch-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;
        tokenOut.mint(address(router), 10);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet - 1, 10, 0, false);

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(_singlePayee(user, user, amountIn), 1);

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenRouterIncreasesUSDCBalance() public {
        MockRouterUSDCRebate rebateRouter = new MockRouterUSDCRebate();
        cobuildSwap.setRouterAllowed(address(rebateRouter), true);

        address user = makeAddr("zora-usdc-increase-user");
        _mintAndApproveUsdc(user, 1_000_000);
        usdc.mint(address(rebateRouter), 1);
        rebateRouter.configure(IERC20(address(usdc)), 1);

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(_singlePayee(user, user, 1_000_000), 0);

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(rebateRouter), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsOnCreatorSlippage() public {
        address user = makeAddr("zora-slippage-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;
        tokenOut.mint(address(router), 1);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, 1, 0, false);

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(_singlePayee(user, user, amountIn), 2);

        vm.expectRevert(ICobuildSwap.SLIPPAGE.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_sweepsPreexistingDust() public {
        address user = makeAddr("zora-dust-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;
        uint256 creatorOut = 100;
        uint256 preexistingDust = 5;

        tokenOut.mint(address(cobuildSwap), preexistingDust);
        tokenOut.mint(address(router), creatorOut);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, creatorOut, 0, false);

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = _defaultZoraOrder(_singlePayee(user, user, amountIn), 1);

        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);

        assertEq(tokenOut.balanceOf(feeCollector), preexistingDust, "preexisting creator dust should be swept");
    }

    function test_executeJuiceboxPayMany_revertsWhenRouterNotAllowed() public {
        address user = makeAddr("jb-router-not-allowed-user");
        _mintAndApproveUsdc(user, 1);
        cobuildSwap.setRouterAllowed(address(router), false);

        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, 1), address(projectToken), 1, 500);

        vm.expectRevert(ICobuildSwap.ROUTER_NOT_ALLOWED.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenExpired() public {
        address user = makeAddr("jb-expired-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, 1), address(projectToken), 1, 500);
        s.deadline = block.timestamp - 1;

        vm.expectRevert(ICobuildSwap.EXPIRED_DEADLINE.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenBatchSizeIsZero() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](0);
        ICobuildSwap.JuiceboxPayMany memory s = _defaultJuiceboxOrder(payees, address(projectToken), 1, 500);

        vm.expectRevert(ICobuildSwap.BAD_BATCH_SIZE.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsOnInvalidV3Fee() public {
        address user = makeAddr("jb-invalid-v3-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, 1), address(projectToken), 1, 42);

        vm.expectRevert(ICobuildSwap.INVALID_V3_FEE.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsOnZeroMinEthOut() public {
        address user = makeAddr("jb-min-out-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, 1), address(projectToken), 0, 500);

        vm.expectRevert(ICobuildSwap.INVALID_MIN_OUT.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsOnZeroProjectToken() public {
        address user = makeAddr("jb-project-zero-user");
        _mintAndApproveUsdc(user, 1);
        ICobuildSwap.JuiceboxPayMany memory s = _defaultJuiceboxOrder(_singlePayee(user, user, 1), address(0), 1, 500);

        vm.expectRevert(ICobuildSwap.INVALID_ADDRESS.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenPayeeAddressInvalid() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("jb-user"), recipient: address(0), amountIn: 1 });
        ICobuildSwap.JuiceboxPayMany memory s = _defaultJuiceboxOrder(payees, address(projectToken), 1, 500);

        _configureProjectTerminal(IJBTerminal(address(new MockJBTerminal())));

        vm.expectRevert(ICobuildSwap.INVALID_ADDRESS.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenPayeeAmountIsZero() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("jb-user"), recipient: makeAddr("jb-recipient"), amountIn: 0 });
        ICobuildSwap.JuiceboxPayMany memory s = _defaultJuiceboxOrder(payees, address(projectToken), 1, 500);

        _configureProjectTerminal(IJBTerminal(address(new MockJBTerminal())));

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenSpentMismatchesTotalNet() public {
        address user = makeAddr("jb-spent-mismatch-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;

        vm.deal(address(router), 1 ether);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(0)), totalNet - 1, 0, 1 ether, false);

        MockJBTerminal terminal = new MockJBTerminal();
        terminal.configure(projectToken, 1);
        _configureProjectTerminal(IJBTerminal(address(terminal)));

        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, amountIn), address(projectToken), 1 ether, 500);

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenRouterIncreasesUSDCBalance() public {
        MockRouterUSDCRebate rebateRouter = new MockRouterUSDCRebate();
        cobuildSwap.setRouterAllowed(address(rebateRouter), true);

        address user = makeAddr("jb-usdc-increase-user");
        _mintAndApproveUsdc(user, 1_000_000);
        usdc.mint(address(rebateRouter), 1);
        rebateRouter.configure(IERC20(address(usdc)), 1);

        MockJBTerminal terminal = new MockJBTerminal();
        terminal.configure(projectToken, 1);
        _configureProjectTerminal(IJBTerminal(address(terminal)));

        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, 1_000_000), address(projectToken), 1, 500);

        vm.expectRevert(ICobuildSwap.INVALID_AMOUNTS.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsOnEthSlippage() public {
        address user = makeAddr("jb-eth-slippage-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;

        vm.deal(address(router), 0.5 ether);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(0)), totalNet, 0, 0.5 ether, false);

        MockJBTerminal terminal = new MockJBTerminal();
        terminal.configure(projectToken, 1);
        _configureProjectTerminal(IJBTerminal(address(terminal)));

        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, amountIn), address(projectToken), 1 ether, 500);

        vm.expectRevert(ICobuildSwap.SLIPPAGE.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenMintedAmountIsZero() public {
        address user = makeAddr("jb-zero-mint-user");
        uint256 amountIn = 1_000_000;
        _mintAndApproveUsdc(user, amountIn);

        uint256 totalFee = (amountIn * FEE_BPS) / 10_000;
        uint256 totalNet = amountIn - totalFee;

        vm.deal(address(router), 1 ether);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(0)), totalNet, 0, 1 ether, false);

        _configureProjectTerminal(IJBTerminal(address(new MockJBTerminalZeroMint())));

        ICobuildSwap.JuiceboxPayMany memory s =
            _defaultJuiceboxOrder(_singlePayee(user, user, amountIn), address(projectToken), 1 ether, 500);

        vm.expectRevert(ICobuildSwap.ZERO_MINT_TO_BENEFICIARY.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function _singlePayee(
        address user,
        address recipient,
        uint256 amountIn
    )
        internal
        pure
        returns (ICobuildSwap.Payee[] memory payees)
    {
        payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: user, recipient: recipient, amountIn: amountIn });
    }

    function _defaultZoraOrder(
        ICobuildSwap.Payee[] memory payees,
        uint128 minCreatorOut
    )
        internal
        view
        returns (ICobuildSwap.ZoraCreatorCoinOneToMany memory)
    {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(zora)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        return ICobuildSwap.ZoraCreatorCoinOneToMany({
            key: key,
            v3Fee: 3000,
            deadline: block.timestamp + 1 days,
            minZoraOut: 1,
            minCreatorOut: minCreatorOut,
            payees: payees
        });
    }

    function _defaultJuiceboxOrder(
        ICobuildSwap.Payee[] memory payees,
        address projectTokenAddress,
        uint256 minEthOut,
        uint24 v3Fee
    )
        internal
        view
        returns (ICobuildSwap.JuiceboxPayMany memory)
    {
        return ICobuildSwap.JuiceboxPayMany({
            universalRouter: address(router),
            v3Fee: v3Fee,
            deadline: block.timestamp + 1 days,
            projectToken: projectTokenAddress,
            minEthOut: minEthOut,
            memo: "memo",
            metadata: "",
            payees: payees
        });
    }

    function _configureProjectTerminal(IJBTerminal terminal) internal {
        jbTokens.setProjectId(address(projectToken), 1);
        jbDirectory.setPrimaryTerminal(1, JBConstants.NATIVE_TOKEN, terminal);
    }
}

contract RejectETHReceiver {
    receive() external payable {
        revert("REJECT_ETH");
    }
}

contract MockRouterUSDCRebate {
    IERC20 internal _tokenIn;
    uint256 internal _rebateAmount;

    function configure(IERC20 tokenIn_, uint256 rebateAmount_) external {
        _tokenIn = tokenIn_;
        _rebateAmount = rebateAmount_;
    }

    function swap() external {
        if (_rebateAmount != 0) _tokenIn.transfer(msg.sender, _rebateAmount);
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        if (_rebateAmount != 0) _tokenIn.transfer(msg.sender, _rebateAmount);
    }
}

contract MockRouterOverSpender {
    MockERC20 internal _tokenIn;
    uint256 internal _extraSpend;

    function configure(MockERC20 tokenIn_, uint256 extraSpend_) external {
        _tokenIn = tokenIn_;
        _extraSpend = extraSpend_;
    }

    function swap() external {
        if (_extraSpend != 0) _tokenIn.forceTransferFrom(msg.sender, address(this), _extraSpend);
    }
}

contract MockJBTerminalZeroMint {
    function pay(uint256, address, uint256, address, uint256, string calldata, bytes calldata)
        external
        payable
        returns (uint256)
    {
        return 0;
    }
}
