// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

library BudgetTCRValidationLib {
    uint8 internal constant ORACLE_TYPE_UMA_OOV3 = 1;

    function verifyItemData(
        bytes calldata item,
        IBudgetTCR.BudgetValidationBounds memory budgetBounds,
        IBudgetTCR.OracleValidationBounds memory oracleBounds,
        uint64 goalDeadline
    ) internal view returns (bool valid) {
        IBudgetTCR.BudgetListing memory listing = abi.decode(item, (IBudgetTCR.BudgetListing));

        if (bytes(listing.metadata.title).length == 0) return false;
        if (bytes(listing.metadata.description).length == 0) return false;
        if (bytes(listing.metadata.image).length == 0) return false;

        uint256 nowTs = block.timestamp;

        if (listing.fundingDeadline <= nowTs) return false;
        if (listing.fundingDeadline < nowTs + budgetBounds.minFundingLeadTime) return false;
        if (budgetBounds.maxFundingHorizon != 0 && listing.fundingDeadline > nowTs + budgetBounds.maxFundingHorizon) {
            return false;
        }
        if (listing.fundingDeadline > goalDeadline) return false;

        if (
            listing.executionDuration < budgetBounds.minExecutionDuration ||
            listing.executionDuration > budgetBounds.maxExecutionDuration
        ) {
            return false;
        }

        uint256 worstCaseEnd = uint256(listing.fundingDeadline) + uint256(listing.executionDuration);
        if (worstCaseEnd > goalDeadline) return false;

        if (
            listing.activationThreshold < budgetBounds.minActivationThreshold ||
            listing.activationThreshold > budgetBounds.maxActivationThreshold
        ) {
            return false;
        }

        if (listing.runwayCap != 0) {
            if (listing.runwayCap < listing.activationThreshold) return false;
            if (budgetBounds.maxRunwayCap != 0 && listing.runwayCap > budgetBounds.maxRunwayCap) return false;
        }

        if (
            listing.oracleConfig.oracleType != ORACLE_TYPE_UMA_OOV3
                || listing.oracleConfig.oracleType > oracleBounds.maxOracleType
        ) {
            return false;
        }

        if (listing.oracleConfig.oracleSpecHash == bytes32(0)) return false;
        if (listing.oracleConfig.assertionPolicyHash == bytes32(0)) return false;

        return true;
    }
}
