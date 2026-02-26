// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IArbitrable } from "../interfaces/IArbitrable.sol";
import { IGeneralizedTCR } from "../interfaces/IGeneralizedTCR.sol";
import { ISubmissionDepositStrategy } from "../interfaces/ISubmissionDepositStrategy.sol";
import { ISubmissionDepositStrategyCapabilities } from "../interfaces/ISubmissionDepositStrategyCapabilities.sol";

contract PrizePoolSubmissionDepositStrategy is ISubmissionDepositStrategy, ISubmissionDepositStrategyCapabilities {
    error PRIZE_POOL_ZERO();

    IERC20 public immutable override token;
    address public immutable prizePool;

    constructor(IERC20 token_, address prizePool_) {
        if (prizePool_ == address(0)) revert PRIZE_POOL_ZERO();
        token = token_;
        prizePool = prizePool_;
    }

    function getSubmissionDepositAction(
        bytes32 /* itemID */,
        IGeneralizedTCR.Status requestType,
        IArbitrable.Party ruling,
        address /* manager */,
        address requester,
        address challenger,
        uint256 /* depositAmount */
    ) external view override returns (DepositAction action, address recipient) {
        // Only registration submission deposits are handled here.
        if (requestType != IGeneralizedTCR.Status.RegistrationRequested) {
            return (DepositAction.Hold, address(0));
        }

        if (ruling == IArbitrable.Party.Requester) {
            // Accepted => fund prize pool.
            return (DepositAction.Transfer, prizePool);
        }

        if (ruling == IArbitrable.Party.Challenger) {
            // Rejected => slash to challenger.
            address to = challenger != address(0) ? challenger : requester;
            return (DepositAction.Transfer, to);
        }

        // Party.None => refund requester.
        return (DepositAction.Transfer, requester);
    }

    function supportsEscrowBonding() external pure override returns (bool) {
        return false;
    }
}
