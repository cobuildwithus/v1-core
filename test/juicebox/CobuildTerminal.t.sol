// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { CobuildTerminal } from "src/juicebox/CobuildTerminal.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildTerminalTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 138;
    uint256 internal constant GOAL_REVNET_ID = 777;

    MockMintableERC20 internal cobuildToken;
    MockDirectory internal directory;
    MockCobuildEthTerminal internal sourceTerminal;
    MockDestinationTerminal internal destinationTerminal;
    CobuildTerminal internal cobuildTerminal;

    function setUp() public {
        cobuildToken = new MockMintableERC20();
        directory = new MockDirectory();
        sourceTerminal = new MockCobuildEthTerminal(cobuildToken);
        destinationTerminal = new MockDestinationTerminal(cobuildToken);

        directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal)));
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(destinationTerminal)));

        cobuildTerminal = new CobuildTerminal(IJBDirectory(address(directory)), address(cobuildToken), COBUILD_REVNET_ID);
    }

    function test_payWithEth_routesThroughCobuildAndDestination() public {
        uint256 ethAmount = 2 ether;

        uint256 beneficiaryTokenCount = cobuildTerminal.pay{ value: ethAmount }(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            ethAmount,
            address(this),
            0,
            "memo",
            bytes("")
        );

        assertEq(sourceTerminal.lastPaidAmount(), ethAmount);
        assertEq(sourceTerminal.lastMinReturnedTokens(), 1);
        assertEq(destinationTerminal.lastReceivedCobuild(), ethAmount);
        assertEq(beneficiaryTokenCount, ethAmount);
    }

    function test_payWithCobuild_forwardsDirectPayment() public {
        uint256 cobuildAmount = 1234;
        cobuildToken.mint(address(this), cobuildAmount);
        cobuildToken.approve(address(cobuildTerminal), cobuildAmount);

        uint256 beneficiaryTokenCount = cobuildTerminal.pay(
            GOAL_REVNET_ID,
            address(cobuildToken),
            cobuildAmount,
            address(this),
            0,
            "memo",
            bytes("")
        );

        assertEq(destinationTerminal.lastReceivedCobuild(), cobuildAmount);
        assertEq(beneficiaryTokenCount, cobuildAmount);
    }

    function test_payWithCobuild_succeedsWithoutCobuildEthSourceTerminal() public {
        uint256 cobuildAmount = 5678;
        directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));
        cobuildToken.mint(address(this), cobuildAmount);
        cobuildToken.approve(address(cobuildTerminal), cobuildAmount);

        uint256 beneficiaryTokenCount = cobuildTerminal.pay(
            GOAL_REVNET_ID,
            address(cobuildToken),
            cobuildAmount,
            address(this),
            0,
            "memo",
            bytes("")
        );

        assertEq(destinationTerminal.lastReceivedCobuild(), cobuildAmount);
        assertEq(beneficiaryTokenCount, cobuildAmount);
    }

    function test_payWithEth_revertsWhenCobuildEthTerminalMissing() public {
        directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));

        vm.expectRevert(CobuildTerminal.NO_COBUILD_ETH_TERMINAL.selector);
        cobuildTerminal.pay{ value: 1 ether }(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "memo",
            bytes("")
        );
    }

    function test_payWithEth_revertsWhenCobuildConversionReturnsZero() public {
        MockCobuildEthTerminalNoMint zeroOutTerminal = new MockCobuildEthTerminalNoMint();
        directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(zeroOutTerminal)));

        vm.expectRevert(CobuildTerminal.ZERO_COBUILD_OUT.selector);
        cobuildTerminal.pay{ value: 1 ether }(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "memo",
            bytes("")
        );
    }

    function test_payWithEth_revertsWhenCobuildTerminalReturnsAmountWithoutMinting() public {
        MockCobuildEthTerminalReturnsAmountNoMint zeroBalanceTerminal = new MockCobuildEthTerminalReturnsAmountNoMint();
        directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(zeroBalanceTerminal)));

        vm.expectRevert(CobuildTerminal.ZERO_COBUILD_OUT.selector);
        cobuildTerminal.pay{ value: 1 ether }(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "memo",
            bytes("")
        );
    }

    function test_pay_revertsWhenDestinationTerminalMissing() public {
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(0)));

        vm.expectRevert(CobuildTerminal.NO_DEST_TERMINAL.selector);
        cobuildTerminal.pay{ value: 1 ether }(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "memo",
            bytes("")
        );
    }

    function test_pay_revertsWhenUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildTerminal.UNSUPPORTED_TOKEN.selector, address(0xBEEF)));
        cobuildTerminal.pay(GOAL_REVNET_ID, address(0xBEEF), 1, address(this), 0, "memo", bytes(""));
    }

    function test_payWithCobuild_revertsWhenZeroCobuildTransferred() public {
        vm.expectRevert(CobuildTerminal.ZERO_COBUILD_OUT.selector);
        cobuildTerminal.pay(GOAL_REVNET_ID, address(cobuildToken), 0, address(this), 0, "memo", bytes(""));
    }

    function test_payWithCobuild_revertsWhenNonZeroAmountTransfersZero() public {
        MockNoTransferCobuildToken noTransferToken = new MockNoTransferCobuildToken();
        CobuildTerminal localTerminal =
            new CobuildTerminal(IJBDirectory(address(directory)), address(noTransferToken), COBUILD_REVNET_ID);
        directory.setPrimaryTerminal(
            GOAL_REVNET_ID, address(noTransferToken), IJBTerminal(address(new MockDestinationTerminalNoop()))
        );

        vm.expectRevert(CobuildTerminal.ZERO_COBUILD_OUT.selector);
        localTerminal.pay(GOAL_REVNET_ID, address(noTransferToken), 1 ether, address(this), 0, "memo", bytes(""));
    }

    function test_payWithEth_revertsWhenDestinationIsSelf() public {
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(cobuildTerminal)));

        vm.expectRevert(CobuildTerminal.DEST_TERMINAL_IS_SELF.selector);
        cobuildTerminal.pay{ value: 1 ether }(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "memo",
            bytes("")
        );
    }

    function test_addToBalanceOf_revertsUnsupportedCall() public {
        vm.expectRevert(CobuildTerminal.UNSUPPORTED_CALL.selector);
        cobuildTerminal.addToBalanceOf{ value: 1 }(GOAL_REVNET_ID, JBConstants.NATIVE_TOKEN, 1, false, "memo", bytes(""));
    }
}

contract MockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract MockMintableERC20 is ERC20 {
    constructor() ERC20("Cobuild", "CBD") { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract MockCobuildEthTerminal {
    MockMintableERC20 internal immutable _token;
    uint256 internal _lastPaidAmount;
    uint256 internal _lastMinReturnedTokens;

    constructor(MockMintableERC20 token_) {
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
    )
        external
        payable
        returns (uint256)
    {
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

contract MockDestinationTerminal {
    MockMintableERC20 internal immutable _token;
    uint256 internal _lastReceivedCobuild;

    constructor(MockMintableERC20 token_) {
        _token = token_;
    }

    function pay(uint256, address token, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        returns (uint256)
    {
        require(token == address(_token), "token");
        _token.transferFrom(msg.sender, address(this), amount);
        _lastReceivedCobuild = amount;
        return amount;
    }

    function lastReceivedCobuild() external view returns (uint256) {
        return _lastReceivedCobuild;
    }
}

contract MockCobuildEthTerminalNoMint {
    function pay(uint256, address token, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        returns (uint256)
    {
        require(token == JBConstants.NATIVE_TOKEN, "token");
        require(msg.value == amount, "value");
        return 0;
    }
}

contract MockCobuildEthTerminalReturnsAmountNoMint {
    function pay(uint256, address token, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        returns (uint256)
    {
        require(token == JBConstants.NATIVE_TOKEN, "token");
        require(msg.value == amount, "value");
        return amount;
    }
}

contract MockNoTransferCobuildToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockDestinationTerminalNoop {
    function pay(uint256, address, uint256 amount, address, uint256, string calldata, bytes calldata)
        external
        payable
        returns (uint256)
    {
        return amount;
    }
}
