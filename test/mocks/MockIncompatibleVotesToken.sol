// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { MockVotesToken } from "./MockVotesToken.sol";

/// @dev Votes token with non-18 decimals to test arbitration-cost/unit assumptions.
contract MockVotesToken6Decimals is MockVotesToken {
    constructor(string memory name_, string memory symbol_) MockVotesToken(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Minimal IVotes implementation without ERC20 surface.
contract MockNonERC20Votes is IVotes {
    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external {}

    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber";
    }
}
