// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { CobuildSwap } from "src/swaps/CobuildSwap.sol";
import { ICobuildSwap } from "src/interfaces/ICobuildSwap.sol";

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildSwapUnitTest is Test {
    using Math for uint256;

    uint16 internal constant FEE_BPS = 200;
    uint256 internal constant MIN_FEE_ABSOLUTE = 0;
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal executor = makeAddr("executor");
    address internal feeCollector = makeAddr("feeCollector");
    address internal weth9 = makeAddr("weth9");

    MockERC20 internal usdc;
    MockERC20 internal zora;
    MockERC20 internal tokenOut;
    MockERC20 internal projectToken;

    Mock0xRouter internal router;
    MockJBDirectory internal jbDirectory;
    MockJBTokens internal jbTokens;

    CobuildSwap internal cobuildSwap;

    function setUp() public {
        MockPermit2 permit2 = new MockPermit2();
        vm.etch(PERMIT2_ADDRESS, address(permit2).code);

        usdc = new MockERC20("USDC", "USDC", 6);
        zora = new MockERC20("Zora", "ZORA", 18);
        tokenOut = new MockERC20("Creator", "CRT", 18);
        projectToken = new MockERC20("Project", "PRJ", 18);

        router = new Mock0xRouter();
        jbDirectory = new MockJBDirectory();
        jbTokens = new MockJBTokens();

        CobuildSwap implementation = new CobuildSwap();
        bytes memory initData = abi.encodeCall(
            CobuildSwap.initialize,
            (
                address(usdc),
                address(zora),
                address(router),
                address(jbDirectory),
                address(jbTokens),
                weth9,
                executor,
                feeCollector,
                FEE_BPS,
                MIN_FEE_ABSOLUTE
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        cobuildSwap = CobuildSwap(payable(address(proxy)));

        cobuildSwap.setSpenderAllowed(address(router), true);
    }

    function test_executeBatch0x_exactSpend_distributesProRataAndSweepsDust() public {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");
        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");

        uint256 amountA = 700_000;
        uint256 amountB = 300_000;
        uint256 totalGross = amountA + amountB;
        uint256 totalFee = (totalGross * FEE_BPS) / 10_000;
        uint256 totalNet = totalGross - totalFee;

        _mintAndApproveUsdc(userA, amountA);
        _mintAndApproveUsdc(userB, amountB);

        uint256 outAmount = 101;
        tokenOut.mint(address(router), outAmount);
        router.configure(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, outAmount, false);

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](2);
        payees[0] = ICobuildSwap.Payee({ user: userA, recipient: recipientA, amountIn: amountA });
        payees[1] = ICobuildSwap.Payee({ user: userB, recipient: recipientB, amountIn: amountB });

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut),
            100,
            address(router),
            address(router),
            payees
        );

        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);

        uint256 expectedA = Math.mulDiv(outAmount, amountA, totalGross);
        uint256 expectedB = Math.mulDiv(outAmount, amountB, totalGross);
        uint256 expectedRemainder = outAmount - expectedA - expectedB;

        assertEq(tokenOut.balanceOf(recipientA), expectedA, "recipient A payout mismatch");
        assertEq(tokenOut.balanceOf(recipientB), expectedB, "recipient B payout mismatch");
        assertEq(tokenOut.balanceOf(feeCollector), expectedRemainder, "fee collector dust mismatch");

        assertEq(usdc.balanceOf(feeCollector), totalFee, "fee collector USDC fee mismatch");
        assertEq(usdc.allowance(address(cobuildSwap), address(router)), 0, "router allowance not cleared");
        assertEq(usdc.balanceOf(address(cobuildSwap)), 0, "USDC dust retained on contract");
        assertEq(tokenOut.balanceOf(address(cobuildSwap)), 0, "tokenOut dust retained on contract");
    }

    function test_executeBatch0x_underSpend_refundsUnusedNetToFeeCollector() public {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");

        uint256 amountA = 700_000;
        uint256 amountB = 300_000;
        uint256 totalGross = amountA + amountB;
        uint256 totalFee = (totalGross * FEE_BPS) / 10_000;
        uint256 totalNet = totalGross - totalFee;
        uint256 spentByRouter = 900_000;
        uint256 refundToCollector = totalNet - spentByRouter;

        _mintAndApproveUsdc(userA, amountA);
        _mintAndApproveUsdc(userB, amountB);

        uint256 outAmount = 200;
        tokenOut.mint(address(router), outAmount);
        router.configure(IERC20(address(usdc)), IERC20(address(tokenOut)), spentByRouter, outAmount, false);

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](2);
        payees[0] = ICobuildSwap.Payee({ user: userA, recipient: userA, amountIn: amountA });
        payees[1] = ICobuildSwap.Payee({ user: userB, recipient: userB, amountIn: amountB });

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut),
            outAmount,
            address(router),
            address(router),
            payees
        );

        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);

        assertEq(
            usdc.balanceOf(feeCollector),
            totalFee + refundToCollector,
            "fee collector should receive fee + unused net refund"
        );
        assertEq(usdc.allowance(address(cobuildSwap), address(router)), 0, "router allowance not cleared");
        assertEq(usdc.balanceOf(address(cobuildSwap)), 0, "USDC dust retained on contract");
    }

    function test_executeBatch0x_revertsWhenCallerNotExecutor() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("user"), recipient: makeAddr("recipient"), amountIn: 1 });

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut),
            1,
            address(router),
            address(router),
            payees
        );

        vm.expectRevert(ICobuildSwap.NOT_EXECUTOR.selector);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsWhenSpenderDiffersFromCallTarget() public {
        address user = makeAddr("user");
        _mintAndApproveUsdc(user, 1_000_000);

        address allowedSpender = makeAddr("allowedSpender");
        cobuildSwap.setSpenderAllowed(allowedSpender, true);

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: user, recipient: user, amountIn: 1_000_000 });

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut),
            1,
            allowedSpender,
            address(router),
            payees
        );

        vm.expectRevert(ICobuildSwap.SPENDER_NOT_ALLOWED.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);
    }

    function test_executeBatch0x_revertsOnSlippageAndPreservesAllowanceInvariant() public {
        address userA = makeAddr("userA");
        address userB = makeAddr("userB");

        uint256 amountA = 700_000;
        uint256 amountB = 300_000;
        uint256 totalGross = amountA + amountB;
        uint256 totalFee = (totalGross * FEE_BPS) / 10_000;
        uint256 totalNet = totalGross - totalFee;

        _mintAndApproveUsdc(userA, amountA);
        _mintAndApproveUsdc(userB, amountB);

        uint256 outAmount = 100;
        tokenOut.mint(address(router), outAmount);
        router.configure(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, outAmount, false);

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](2);
        payees[0] = ICobuildSwap.Payee({ user: userA, recipient: userA, amountIn: amountA });
        payees[1] = ICobuildSwap.Payee({ user: userB, recipient: userB, amountIn: amountB });

        ICobuildSwap.OxOneToMany memory s = _buildOxOrder(
            address(tokenOut),
            outAmount + 1,
            address(router),
            address(router),
            payees
        );

        vm.expectRevert(ICobuildSwap.SLIPPAGE.selector);
        vm.prank(executor);
        cobuildSwap.executeBatch0x(address(router), s);

        assertEq(usdc.allowance(address(cobuildSwap), address(router)), 0, "allowance should remain zero after revert");
    }

    function test_executeZoraCreatorCoinOneToMany_success_distributesAndChargesFee() public {
        address userA = makeAddr("zoraUserA");
        address userB = makeAddr("zoraUserB");
        address recipientA = makeAddr("zoraRecipientA");
        address recipientB = makeAddr("zoraRecipientB");

        uint256 amountA = 700_000;
        uint256 amountB = 300_000;
        uint256 totalGross = amountA + amountB;
        uint256 totalFee = (totalGross * FEE_BPS) / 10_000;
        uint256 totalNet = totalGross - totalFee;

        _mintAndApproveUsdc(userA, amountA);
        _mintAndApproveUsdc(userB, amountB);

        uint256 creatorOut = 503;
        tokenOut.mint(address(router), creatorOut);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(tokenOut)), totalNet, creatorOut, 0, false);

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](2);
        payees[0] = ICobuildSwap.Payee({ user: userA, recipient: recipientA, amountIn: amountA });
        payees[1] = ICobuildSwap.Payee({ user: userB, recipient: recipientB, amountIn: amountB });

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(zora)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = ICobuildSwap.ZoraCreatorCoinOneToMany({
            key: key,
            v3Fee: 3000,
            deadline: block.timestamp + 1 days,
            minZoraOut: 1,
            minCreatorOut: uint128(creatorOut),
            payees: payees
        });

        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);

        uint256 expectedA = Math.mulDiv(creatorOut, amountA, totalGross);
        uint256 expectedB = Math.mulDiv(creatorOut, amountB, totalGross);
        uint256 expectedRemainder = creatorOut - expectedA - expectedB;

        assertEq(tokenOut.balanceOf(recipientA), expectedA, "recipient A payout mismatch");
        assertEq(tokenOut.balanceOf(recipientB), expectedB, "recipient B payout mismatch");
        assertEq(tokenOut.balanceOf(feeCollector), expectedRemainder, "creator token dust mismatch");
        assertEq(usdc.balanceOf(feeCollector), totalFee, "USDC fee mismatch");
        assertEq(usdc.balanceOf(address(cobuildSwap)), 0, "USDC dust retained");
        assertEq(tokenOut.balanceOf(address(cobuildSwap)), 0, "creator dust retained");
    }

    function test_executeJuiceboxPayMany_success_fansOutMintedAndChargesFee() public {
        address userA = makeAddr("jbUserA");
        address userB = makeAddr("jbUserB");
        address recipientA = makeAddr("jbRecipientA");
        address recipientB = makeAddr("jbRecipientB");

        uint256 amountA = 700_000;
        uint256 amountB = 300_000;
        uint256 totalGross = amountA + amountB;
        uint256 totalFee = (totalGross * FEE_BPS) / 10_000;
        uint256 totalNet = totalGross - totalFee;

        _mintAndApproveUsdc(userA, amountA);
        _mintAndApproveUsdc(userB, amountB);

        uint256 ethOut = 2 ether;
        uint256 mintedOut = 1_001;
        vm.deal(address(router), ethOut);
        router.configureExecute(IERC20(address(usdc)), IERC20(address(0)), totalNet, 0, ethOut, false);

        jbTokens.setProjectId(address(projectToken), 1);
        MockJBTerminal terminal = new MockJBTerminal();
        terminal.configure(projectToken, mintedOut);
        jbDirectory.setPrimaryTerminal(1, JBConstants.NATIVE_TOKEN, IJBTerminal(address(terminal)));

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](2);
        payees[0] = ICobuildSwap.Payee({ user: userA, recipient: recipientA, amountIn: amountA });
        payees[1] = ICobuildSwap.Payee({ user: userB, recipient: recipientB, amountIn: amountB });

        ICobuildSwap.JuiceboxPayMany memory s = ICobuildSwap.JuiceboxPayMany({
            universalRouter: address(router),
            v3Fee: 500,
            deadline: block.timestamp + 1 days,
            projectToken: address(projectToken),
            minEthOut: ethOut,
            memo: "memo",
            metadata: "",
            payees: payees
        });

        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);

        uint256 expectedA = Math.mulDiv(mintedOut, amountA, totalGross);
        uint256 expectedB = Math.mulDiv(mintedOut, amountB, totalGross);
        uint256 expectedRemainder = mintedOut - expectedA - expectedB;

        assertEq(projectToken.balanceOf(recipientA), expectedA, "recipient A minted payout mismatch");
        assertEq(projectToken.balanceOf(recipientB), expectedB, "recipient B minted payout mismatch");
        assertEq(projectToken.balanceOf(feeCollector), expectedRemainder, "mint dust mismatch");
        assertEq(usdc.balanceOf(feeCollector), totalFee, "USDC fee mismatch");
        assertEq(usdc.balanceOf(address(cobuildSwap)), 0, "USDC dust retained");
        assertEq(projectToken.balanceOf(address(cobuildSwap)), 0, "project token dust retained");
    }

    function test_computeFeeAndNet_prefersAbsoluteFloorWhenHigherThanPct() public {
        cobuildSwap.setMinFeeAbsolute(1_000);

        (uint256 feeFloorDominates, uint256 netFloorDominates) = cobuildSwap.computeFeeAndNet(10_000);
        assertEq(feeFloorDominates, 1_000, "absolute floor should dominate");
        assertEq(netFloorDominates, 9_000, "net mismatch when floor dominates");

        (uint256 feePctDominates, uint256 netPctDominates) = cobuildSwap.computeFeeAndNet(1_000_000);
        assertEq(feePctDominates, 20_000, "percentage should dominate");
        assertEq(netPctDominates, 980_000, "net mismatch when percentage dominates");
    }

    function test_executeJuiceboxPayMany_revertsWhenProjectTokenUnavailable() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("payer"), recipient: makeAddr("recipient"), amountIn: 1 });

        ICobuildSwap.JuiceboxPayMany memory s = ICobuildSwap.JuiceboxPayMany({
            universalRouter: address(router),
            v3Fee: 500,
            deadline: block.timestamp + 1 days,
            projectToken: address(projectToken),
            minEthOut: 1,
            memo: "memo",
            metadata: "",
            payees: payees
        });

        vm.expectRevert(ICobuildSwap.JB_TOKEN_UNAVAILABLE.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenCallerNotExecutor() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("payer"), recipient: makeAddr("recipient"), amountIn: 1 });

        ICobuildSwap.JuiceboxPayMany memory s = ICobuildSwap.JuiceboxPayMany({
            universalRouter: address(router),
            v3Fee: 500,
            deadline: block.timestamp + 1 days,
            projectToken: address(projectToken),
            minEthOut: 1,
            memo: "memo",
            metadata: "",
            payees: payees
        });

        vm.expectRevert(ICobuildSwap.NOT_EXECUTOR.selector);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeJuiceboxPayMany_revertsWhenNoEthTerminal() public {
        jbTokens.setProjectId(address(projectToken), 1);

        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("payer"), recipient: makeAddr("recipient"), amountIn: 1 });

        ICobuildSwap.JuiceboxPayMany memory s = ICobuildSwap.JuiceboxPayMany({
            universalRouter: address(router),
            v3Fee: 500,
            deadline: block.timestamp + 1 days,
            projectToken: address(projectToken),
            minEthOut: 1,
            memo: "memo",
            metadata: "",
            payees: payees
        });

        vm.expectRevert(ICobuildSwap.NO_ETH_TERMINAL.selector);
        vm.prank(executor);
        cobuildSwap.executeJuiceboxPayMany(s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenPoolMissingZora() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("payer"), recipient: makeAddr("recipient"), amountIn: 1 });

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(tokenOut)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = ICobuildSwap.ZoraCreatorCoinOneToMany({
            key: key,
            v3Fee: 3000,
            deadline: block.timestamp + 1 days,
            minZoraOut: 1,
            minCreatorOut: 1,
            payees: payees
        });

        vm.expectRevert(ICobuildSwap.PATH_IN_MISMATCH.selector);
        vm.prank(executor);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function test_executeZoraCreatorCoinOneToMany_revertsWhenCallerNotExecutor() public {
        ICobuildSwap.Payee[] memory payees = new ICobuildSwap.Payee[](1);
        payees[0] = ICobuildSwap.Payee({ user: makeAddr("payer"), recipient: makeAddr("recipient"), amountIn: 1 });

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(zora)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        ICobuildSwap.ZoraCreatorCoinOneToMany memory s = ICobuildSwap.ZoraCreatorCoinOneToMany({
            key: key,
            v3Fee: 3000,
            deadline: block.timestamp + 1 days,
            minZoraOut: 1,
            minCreatorOut: 1,
            payees: payees
        });

        vm.expectRevert(ICobuildSwap.NOT_EXECUTOR.selector);
        cobuildSwap.executeZoraCreatorCoinOneToMany(address(router), s);
    }

    function _buildOxOrder(
        address tokenOutAddr,
        uint256 minAmountOut,
        address spender,
        address callTarget,
        ICobuildSwap.Payee[] memory payees
    )
        internal
        view
        returns (ICobuildSwap.OxOneToMany memory)
    {
        return ICobuildSwap.OxOneToMany({
            tokenOut: tokenOutAddr,
            minAmountOut: minAmountOut,
            spender: spender,
            callTarget: callTarget,
            callData: abi.encodeWithSelector(Mock0xRouter.swap.selector),
            value: 0,
            deadline: block.timestamp + 1 days,
            payees: payees
        });
    }

    function _mintAndApproveUsdc(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(cobuildSwap), type(uint256).max);
    }
}

contract MockERC20 is ERC20 {
    uint8 internal immutable _tokenDecimals;

    constructor(string memory name, string memory symbol, uint8 tokenDecimals) ERC20(name, symbol) {
        _tokenDecimals = tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function forceTransferFrom(address from, address to, uint256 amount) external {
        _transfer(from, to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}

contract Mock0xRouter {
    IERC20 internal tokenIn;
    IERC20 internal tokenOut;
    uint256 internal spendAmount;
    uint256 internal outAmount;
    uint256 internal ethOut;
    bool internal shouldRevert;

    error ForcedRevert();

    function configure(IERC20 tokenIn_, IERC20 tokenOut_, uint256 spendAmount_, uint256 outAmount_, bool shouldRevert_)
        external
    {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        spendAmount = spendAmount_;
        outAmount = outAmount_;
        ethOut = 0;
        shouldRevert = shouldRevert_;
    }

    function configureExecute(
        IERC20 tokenIn_,
        IERC20 tokenOut_,
        uint256 spendAmount_,
        uint256 outAmount_,
        uint256 ethOut_,
        bool shouldRevert_
    )
        external
    {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        spendAmount = spendAmount_;
        outAmount = outAmount_;
        ethOut = ethOut_;
        shouldRevert = shouldRevert_;
    }

    function swap() external {
        if (shouldRevert) revert ForcedRevert();
        if (spendAmount != 0) tokenIn.transferFrom(msg.sender, address(this), spendAmount);
        if (outAmount != 0) tokenOut.transfer(msg.sender, outAmount);
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        if (shouldRevert) revert ForcedRevert();
        if (spendAmount != 0) MockERC20(address(tokenIn)).forceTransferFrom(msg.sender, address(this), spendAmount);
        if (outAmount != 0) tokenOut.transfer(msg.sender, outAmount);
        if (ethOut != 0) {
            (bool ok, ) = payable(msg.sender).call{ value: ethOut }("");
            require(ok, "ETH_TRANSFER_FAILED");
        }
    }

    receive() external payable {}
}

contract MockJBTokens {
    mapping(address token => uint256 projectId) internal _projectIds;

    function setProjectId(address token, uint256 projectId) external {
        _projectIds[token] = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIds[address(token)];
    }
}

contract MockJBDirectory {
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _terminals;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _terminals[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _terminals[projectId][token];
    }
}

contract MockJBTerminal {
    MockERC20 internal _projectToken;
    uint256 internal _mintedAmount;

    function configure(MockERC20 projectToken_, uint256 mintedAmount_) external {
        _projectToken = projectToken_;
        _mintedAmount = mintedAmount_;
    }

    function pay(
        uint256,
        address,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        uint256 minted = _mintedAmount == 0 ? amount : _mintedAmount;
        _projectToken.mint(beneficiary, minted);
        return minted;
    }
}

contract MockPermit2 {
    function approve(address, address, uint160, uint48) external {}
}
