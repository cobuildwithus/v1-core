// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract MockRevertingERC20 is IERC20, IVotes {
    string public name = "RevertingToken";
    string public symbol = "RVT";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("TRANSFER_REVERT");
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOW");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        uint256 bal = balanceOf[from];
        require(bal >= amount, "BAL");
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function getVotes(address account) external view returns (uint256) {
        return balanceOf[account];
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        return balanceOf[account];
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return totalSupply;
    }

    function delegates(address account) external pure returns (address) {
        return account;
    }

    function delegate(address) external {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external {}

    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }
}
