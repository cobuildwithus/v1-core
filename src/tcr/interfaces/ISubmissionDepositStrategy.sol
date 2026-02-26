// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IArbitrable } from "./IArbitrable.sol";
import { IGeneralizedTCR } from "./IGeneralizedTCR.sol";

interface ISubmissionDepositStrategy {
    enum DepositAction {
        Hold, // Keep deposit locked inside the TCR.
        Transfer // Transfer the full deposit to recipient and clear it in the TCR.
    }

    /// @notice ERC20 token used for deposits.
    function token() external view returns (IERC20);

    /// @notice Determines what to do with the current submission deposit upon request resolution.
    /// @dev This must be a pure/view policy; it must NOT assume token custody.
    /// @param itemID The item identifier.
    /// @param requestType The item status BEFORE resolution (RegistrationRequested or ClearingRequested).
    /// @param ruling Final ruling for the request.
    /// @param manager Current item.manager.
    /// @param requester Request requester (registration requester or removal requester).
    /// @param challenger Request challenger, if any.
    /// @param depositAmount Current deposit amount held for the item in the TCR.
    /// @return action Hold or Transfer.
    /// @return recipient Recipient for Transfer (ignored for Hold).
    function getSubmissionDepositAction(
        bytes32 itemID,
        IGeneralizedTCR.Status requestType,
        IArbitrable.Party ruling,
        address manager,
        address requester,
        address challenger,
        uint256 depositAmount
    ) external view returns (DepositAction action, address recipient);
}
