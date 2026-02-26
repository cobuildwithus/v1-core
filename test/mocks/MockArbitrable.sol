// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";

/// @dev Simple arbitrable used to unit-test the arbitrator in isolation.
contract MockArbitrable is IArbitrable {
    IERC20 public immutable token;
    IArbitrator public arbitrator;

    uint256 public lastDisputeID;
    uint256 public lastRuling;
    bool public wasRuled;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setArbitrator(IArbitrator arbitrator_) external {
        arbitrator = arbitrator_;
    }

    function approveArbitrator(uint256 amount) external {
        token.approve(address(arbitrator), amount);
    }

    function createDispute(uint256 choices, bytes calldata extraData) external returns (uint256) {
        return arbitrator.createDispute(choices, extraData);
    }

    function rule(uint256 _disputeID, uint256 _ruling) external override {
        lastDisputeID = _disputeID;
        lastRuling = _ruling;
        wasRuled = true;
    }
}
