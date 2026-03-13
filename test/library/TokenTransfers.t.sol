// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {TokenTransfers} from "src/library/TokenTransfers.sol";

contract TokenTransfersTest is Test {
    uint8 private constant MODE_NONE = 0;
    uint8 private constant MODE_TRANSFER_FROM_RECIPIENT_DECREASE = 1;
    uint8 private constant MODE_TRANSFER_SENDER_INCREASE = 2;
    uint8 private constant MODE_TRANSFER_RECIPIENT_DECREASE = 3;

    TokenTransfersHarness private harness;
    TokenTransfersInconsistentBalanceToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        harness = new TokenTransfersHarness();
        token = new TokenTransfersInconsistentBalanceToken();
    }

    function test_balanceOf_readsNativeAndErc20Balances() public {
        vm.deal(alice, 2 ether);
        token.mint(bob, 7);

        assertEq(harness.balanceOf(JBConstants.NATIVE_TOKEN, alice), 2 ether);
        assertEq(harness.balanceOf(address(token), bob), 7);
    }

    function test_safeTransferFromReceived_revertsWhenRecipientBalanceUnexpectedlyDecreases() public {
        token.mint(alice, 100);
        token.mint(bob, 1);
        token.setMode(MODE_TRANSFER_FROM_RECIPIENT_DECREASE);

        vm.prank(alice);
        token.approve(address(harness), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfers.BALANCE_DECREASED_UNEXPECTEDLY.selector, address(token), bob, uint256(1), uint256(0)
            )
        );
        harness.safeTransferFromReceived(IERC20(address(token)), alice, bob, 10);
    }

    function test_safeTransferSpentAndReceived_revertsWhenSenderBalanceUnexpectedlyIncreases() public {
        token.mint(address(harness), 100);
        token.setMode(MODE_TRANSFER_SENDER_INCREASE);

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfers.BALANCE_INCREASED_UNEXPECTEDLY.selector,
                address(token),
                address(harness),
                uint256(100),
                uint256(101)
            )
        );
        harness.safeTransferSpentAndReceived(IERC20(address(token)), bob, 10);
    }

    function test_safeTransferReceived_revertsWhenRecipientBalanceUnexpectedlyDecreases() public {
        token.mint(address(harness), 100);
        token.mint(bob, 1);
        token.setMode(MODE_TRANSFER_RECIPIENT_DECREASE);

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfers.BALANCE_DECREASED_UNEXPECTEDLY.selector, address(token), bob, uint256(1), uint256(0)
            )
        );
        harness.safeTransferReceived(IERC20(address(token)), bob, 10);
    }

    function test_safeTransferSpentAndReceived_baselineStillWorksWithoutSpoofing() public {
        token.mint(address(harness), 100);
        token.setMode(MODE_NONE);

        (uint256 spent, uint256 received) = harness.safeTransferSpentAndReceived(IERC20(address(token)), bob, 10);
        assertEq(spent, 10);
        assertEq(received, 10);
        assertEq(token.balanceOf(address(harness)), 90);
        assertEq(token.balanceOf(bob), 10);
    }

    function test_safeTransfer_nativeNoopsForZeroAmount() public {
        CountingNativeReceiver receiver = new CountingNativeReceiver();

        harness.safeTransfer(JBConstants.NATIVE_TOKEN, address(receiver), 0);

        assertEq(receiver.callCount(), 0);
        assertEq(address(receiver).balance, 0);
    }

    function test_safeTransfer_revertsWhenNativeTransferFails() public {
        RejectingNativeReceiver receiver = new RejectingNativeReceiver();
        vm.deal(address(harness), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfers.NATIVE_TRANSFER_FAILED.selector, address(receiver), 1 ether)
        );
        harness.safeTransfer(JBConstants.NATIVE_TOKEN, address(receiver), 1 ether);
    }
}

contract TokenTransfersHarness {
    using TokenTransfers for IERC20;

    receive() external payable {}

    function balanceOf(address token, address account) external view returns (uint256) {
        return TokenTransfers.balanceOf(token, account);
    }

    function safeTransfer(address token, address to, uint256 amount) external {
        TokenTransfers.safeTransfer(token, to, amount);
    }

    function safeTransferFromReceived(IERC20 token, address from, address to, uint256 amount)
        external
        returns (uint256 received)
    {
        return token.safeTransferFromReceived(from, to, amount);
    }

    function safeTransferSpentAndReceived(IERC20 token, address to, uint256 amount)
        external
        returns (uint256 spent, uint256 received)
    {
        return token.safeTransferSpentAndReceived(to, amount);
    }

    function safeTransferReceived(IERC20 token, address to, uint256 amount) external returns (uint256 received) {
        return token.safeTransferReceived(to, amount);
    }
}

contract TokenTransfersInconsistentBalanceToken is ERC20 {
    uint8 private _mode;
    bool private _spoofActive;
    address private _spoofAccount;
    uint256 private _spoofValue;

    error PRECONDITION_FAILED();

    constructor() ERC20("Inconsistent", "INC") {}

    function setMode(uint8 mode_) external {
        _mode = mode_;
        _spoofActive = false;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (_mode == 2) {
            uint256 senderBalanceBefore = super.balanceOf(msg.sender);
            _setSpoof(msg.sender, senderBalanceBefore + 1);
        } else if (_mode == 3) {
            uint256 recipientBalanceBefore = super.balanceOf(to);
            if (recipientBalanceBefore == 0) revert PRECONDITION_FAILED();
            _setSpoof(to, recipientBalanceBefore - 1);
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (_mode == 1) {
            uint256 recipientBalanceBefore = super.balanceOf(to);
            if (recipientBalanceBefore == 0) revert PRECONDITION_FAILED();
            _setSpoof(to, recipientBalanceBefore - 1);
        }
        return super.transferFrom(from, to, value);
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_spoofActive && account == _spoofAccount) return _spoofValue;
        return super.balanceOf(account);
    }

    function _setSpoof(address account, uint256 value) private {
        _spoofActive = true;
        _spoofAccount = account;
        _spoofValue = value;
    }
}

contract CountingNativeReceiver {
    uint256 private _callCount;

    receive() external payable {
        _callCount++;
    }

    function callCount() external view returns (uint256) {
        return _callCount;
    }
}

contract RejectingNativeReceiver {
    error TRANSFER_REJECTED();

    receive() external payable {
        revert TRANSFER_REJECTED();
    }
}
