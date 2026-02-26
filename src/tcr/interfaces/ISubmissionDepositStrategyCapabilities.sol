// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface ISubmissionDepositStrategyCapabilities {
    /// @notice True when strategy semantics match escrow-bond handling in `BudgetTCRFactory`.
    function supportsEscrowBonding() external view returns (bool);
}
