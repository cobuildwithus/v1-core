// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

library BudgetTCRValidationLib {
    function verifyItemData(
        bytes calldata item,
        IBudgetTCR.BudgetValidationBounds memory budgetBounds,
        uint64 goalDeadline
    ) internal view returns (bool) {
        IBudgetTCR.BudgetListing memory listing = abi.decode(item, (IBudgetTCR.BudgetListing));

        if (bytes(listing.metadata.title).length == 0) return false;
        if (bytes(listing.metadata.description).length == 0) return false;
        if (bytes(listing.metadata.image).length == 0) return false;

        uint256 currentTimestamp = block.timestamp;

        if (listing.fundingDeadline <= currentTimestamp) return false;
        if (listing.fundingDeadline < currentTimestamp + budgetBounds.minFundingLeadTime) return false;
        if (
            budgetBounds.maxFundingHorizon != 0 &&
            listing.fundingDeadline > currentTimestamp + budgetBounds.maxFundingHorizon
        ) {
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

        if (listing.oracleConfig.oracleSpecHash == bytes32(0)) return false;
        if (listing.oracleConfig.assertionPolicyHash == bytes32(0)) return false;

        return true;
    }
}
