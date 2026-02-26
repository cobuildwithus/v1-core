// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IArbitrable } from "../interfaces/IArbitrable.sol";
import { IGeneralizedTCR } from "../interfaces/IGeneralizedTCR.sol";
import { ISubmissionDepositStrategy } from "../interfaces/ISubmissionDepositStrategy.sol";
import { ISubmissionDepositStrategyCapabilities } from "../interfaces/ISubmissionDepositStrategyCapabilities.sol";

contract EscrowSubmissionDepositStrategy is ISubmissionDepositStrategy, ISubmissionDepositStrategyCapabilities {
    IERC20 public immutable override token;

    constructor(IERC20 token_) {
        token = token_;
    }

    function getSubmissionDepositAction(
        bytes32 /* itemID */,
        IGeneralizedTCR.Status requestType,
        IArbitrable.Party ruling,
        address manager,
        address requester,
        address challenger,
        uint256 /* depositAmount */
    ) external view override returns (DepositAction action, address recipient) {
        // Registration: deposit is posted, then:
        // - If accepted: keep bond locked
        // - If rejected: slash to challenger (or refund requester on Party.None)
        if (requestType == IGeneralizedTCR.Status.RegistrationRequested) {
            if (ruling == IArbitrable.Party.Requester) {
                return (DepositAction.Hold, address(0));
            }

            if (ruling == IArbitrable.Party.Challenger) {
                address to = challenger != address(0) ? challenger : requester;
                return (DepositAction.Transfer, to);
            }

            // Party.None => refund requester.
            return (DepositAction.Transfer, requester);
        }

        // Clearing: if removal succeeds (Requester wins), release bond:
        // - If manager removed themselves: refund manager
        // - Otherwise: slash to remover (the clearing requester)
        if (requestType == IGeneralizedTCR.Status.ClearingRequested) {
            if (ruling == IArbitrable.Party.Requester) {
                address to = requester == manager ? manager : requester;
                return (DepositAction.Transfer, to);
            }

            // Removal failed / tie => keep bond locked.
            return (DepositAction.Hold, address(0));
        }

        // For completeness: hold in any other state.
        return (DepositAction.Hold, address(0));
    }

    function supportsEscrowBonding() external pure override returns (bool) {
        return true;
    }
}
