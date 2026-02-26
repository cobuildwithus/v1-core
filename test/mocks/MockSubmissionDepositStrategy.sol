// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

contract MockSubmissionDepositStrategy is ISubmissionDepositStrategy {
    IERC20 public immutable override token;

    uint8 public rawAction;
    address public recipient;
    bool public shouldRevert;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setAction(uint8 rawAction_, address recipient_) external {
        rawAction = rawAction_;
        recipient = recipient_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getSubmissionDepositAction(
        bytes32,
        IGeneralizedTCR.Status,
        IArbitrable.Party,
        address,
        address,
        address,
        uint256
    ) external view override returns (DepositAction action, address recipient_) {
        if (shouldRevert) revert("MOCK_STRATEGY_REVERT");
        action = DepositAction(rawAction);
        recipient_ = recipient;
    }
}
