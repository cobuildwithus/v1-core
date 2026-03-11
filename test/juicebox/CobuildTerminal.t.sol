// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CobuildTerminal} from "src/juicebox/CobuildTerminal.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildTerminalTest is Test {
    uint256 internal constant PAYMENT_REVNET_ID = 138;
    uint256 internal constant GOAL_REVNET_ID = 777;

    MockMintableERC20 internal paymentToken;
    MockDirectory internal directory;
    MockGoalDeploymentRegistry internal goalDeploymentRegistry;
    MockGoalTreasury internal goalTreasury;
    MockStakeVault internal stakeVault;
    MockPaymentEthTerminal internal sourceTerminal;
    MockDestinationTerminal internal destinationTerminal;
    CobuildTerminal internal cobuildTerminal;

    function setUp() public {
        paymentToken = new MockMintableERC20();
        directory = new MockDirectory();
        goalDeploymentRegistry = new MockGoalDeploymentRegistry();
        stakeVault = new MockStakeVault(paymentToken);
        goalTreasury = new MockGoalTreasury(PAYMENT_REVNET_ID, address(stakeVault));
        sourceTerminal = new MockPaymentEthTerminal(paymentToken);
        destinationTerminal = new MockDestinationTerminal(paymentToken);

        goalDeploymentRegistry.setGoalTreasury(GOAL_REVNET_ID, address(goalTreasury));
        directory.setPrimaryTerminal(PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal)));
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(paymentToken), IJBTerminal(address(destinationTerminal)));

        cobuildTerminal = new CobuildTerminal(IJBDirectory(address(directory)), IGoalDeploymentRegistry(address(goalDeploymentRegistry)));
    }

    function test_payWithEth_routesThroughResolvedFundingContext() public {
        uint256 ethAmount = 2 ether;

        uint256 beneficiaryTokenCount = cobuildTerminal.pay{value: ethAmount}(
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
        assertEq(destinationTerminal.lastReceivedPayment(), ethAmount);
        assertEq(beneficiaryTokenCount, ethAmount);
    }

    function test_payWithPaymentToken_forwardsDirectPayment() public {
        uint256 paymentAmount = 1234;
        paymentToken.mint(address(this), paymentAmount);
        paymentToken.approve(address(cobuildTerminal), paymentAmount);

        uint256 beneficiaryTokenCount = cobuildTerminal.pay(
            GOAL_REVNET_ID,
            address(paymentToken),
            paymentAmount,
            address(this),
            0,
            "memo",
            bytes("")
        );

        assertEq(destinationTerminal.lastReceivedPayment(), paymentAmount);
        assertEq(beneficiaryTokenCount, paymentAmount);
    }

    function test_payWithPaymentToken_succeedsWithoutPaymentSourceTerminal() public {
        uint256 paymentAmount = 5678;
        directory.setPrimaryTerminal(PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));
        paymentToken.mint(address(this), paymentAmount);
        paymentToken.approve(address(cobuildTerminal), paymentAmount);

        uint256 beneficiaryTokenCount = cobuildTerminal.pay(
            GOAL_REVNET_ID,
            address(paymentToken),
            paymentAmount,
            address(this),
            0,
            "memo",
            bytes("")
        );

        assertEq(destinationTerminal.lastReceivedPayment(), paymentAmount);
        assertEq(beneficiaryTokenCount, paymentAmount);
    }

    function test_payWithEth_revertsWhenGoalIsNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(CobuildTerminal.GOAL_NOT_REGISTERED.selector, 999));
        cobuildTerminal.pay{value: 1 ether}(999, JBConstants.NATIVE_TOKEN, 1 ether, address(this), 0, "memo", bytes(""));
    }

    function test_payWithEth_revertsWhenPaymentEthTerminalMissing() public {
        directory.setPrimaryTerminal(PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(0)));

        vm.expectRevert(abi.encodeWithSelector(CobuildTerminal.NO_PAYMENT_ETH_TERMINAL.selector, PAYMENT_REVNET_ID));
        cobuildTerminal.pay{value: 1 ether}(
            GOAL_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            address(this),
            0,
            "memo",
            bytes("")
        );
    }

    function test_payWithEth_revertsWhenPaymentConversionReturnsZero() public {
        MockPaymentEthTerminalNoMint zeroOutTerminal = new MockPaymentEthTerminalNoMint();
        directory.setPrimaryTerminal(PAYMENT_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(zeroOutTerminal)));

        vm.expectRevert(CobuildTerminal.ZERO_PAYMENT_TOKEN_OUT.selector);
        cobuildTerminal.pay{value: 1 ether}(
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
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(paymentToken), IJBTerminal(address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(CobuildTerminal.NO_DEST_TERMINAL.selector, GOAL_REVNET_ID, address(paymentToken))
        );
        cobuildTerminal.pay{value: 1 ether}(
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

    function test_payWithPaymentToken_revertsWhenZeroPaymentTransferred() public {
        vm.expectRevert(CobuildTerminal.ZERO_PAYMENT_TOKEN_OUT.selector);
        cobuildTerminal.pay(GOAL_REVNET_ID, address(paymentToken), 0, address(this), 0, "memo", bytes(""));
    }

    function test_payWithEth_revertsWhenDestinationIsSelf() public {
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(paymentToken), IJBTerminal(address(cobuildTerminal)));

        vm.expectRevert(CobuildTerminal.DEST_TERMINAL_IS_SELF.selector);
        cobuildTerminal.pay{value: 1 ether}(
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
        cobuildTerminal.addToBalanceOf{value: 1}(GOAL_REVNET_ID, JBConstants.NATIVE_TOKEN, 1, false, "memo", bytes(""));
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

contract MockGoalDeploymentRegistry {
    mapping(uint256 => address) internal _goalTreasuryOf;

    function setGoalTreasury(uint256 goalId, address goalTreasury) external {
        _goalTreasuryOf[goalId] = goalTreasury;
    }

    function goalTreasuryOf(uint256 goalId) external view returns (address goalTreasury) {
        return _goalTreasuryOf[goalId];
    }
}

contract MockGoalTreasury {
    uint256 public immutable cobuildRevnetId;
    address public immutable stakeVault;

    constructor(uint256 cobuildRevnetId_, address stakeVault_) {
        cobuildRevnetId = cobuildRevnetId_;
        stakeVault = stakeVault_;
    }
}

contract MockStakeVault {
    MockMintableERC20 public immutable cobuildToken;

    constructor(MockMintableERC20 cobuildToken_) {
        cobuildToken = cobuildToken_;
    }
}

contract MockMintableERC20 is ERC20 {
    constructor() ERC20("Payment", "PAY") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract MockPaymentEthTerminal {
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

contract MockDestinationTerminal {
    MockMintableERC20 internal immutable _token;
    uint256 internal _lastReceivedPayment;

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
        _lastReceivedPayment = amount;
        return amount;
    }

    function lastReceivedPayment() external view returns (uint256) {
        return _lastReceivedPayment;
    }
}

contract MockPaymentEthTerminalNoMint {
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
