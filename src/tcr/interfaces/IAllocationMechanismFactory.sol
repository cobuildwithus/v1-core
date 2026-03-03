// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

/// @notice Generic mechanism-factory surface for allocation mechanism registries.
interface IAllocationMechanismFactory {
    struct DeployedMechanism {
        /// @notice Canonical mechanism contract deployed for this listing.
        address mechanism;
        /// @notice Recipient that should receive released budget-flow funds.
        address payoutRecipient;
        /// @notice Optional arbitrator associated with deployed mechanism.
        address arbitrator;
        /// @notice Optional auxiliary deployment address (factory-defined).
        address auxiliary;
    }

    /// @notice Deploy mechanism stack for a budget context using opaque factory config.
    /// @param mechanismId Canonical mechanism identifier (recommended: parent listing itemID).
    /// @param budgetTreasury Budget treasury for context/wiring.
    /// @param mechanismConfig Opaque factory-specific init config payload.
    function deployForBudget(
        bytes32 mechanismId,
        address budgetTreasury,
        bytes calldata mechanismConfig
    ) external returns (DeployedMechanism memory out);
}
