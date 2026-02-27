// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTCRValidationLib } from "src/tcr/library/BudgetTCRValidationLib.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

contract BudgetTCRValidationHarness {
    function verifyItemData(
        bytes calldata item,
        IBudgetTCR.BudgetValidationBounds calldata budgetBounds,
        uint64 goalDeadline
    ) external view returns (bool) {
        return BudgetTCRValidationLib.verifyItemData(item, budgetBounds, goalDeadline);
    }
}

contract BudgetTCRValidatorTest is Test {
    BudgetTCRValidationHarness internal validationHarness;

    function setUp() public {
        validationHarness = new BudgetTCRValidationHarness();
    }

    function test_verifyItemData_returnsTrueForValidListing() public view {
        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        assertTrue(_verify(listing, _defaultBudgetBounds(), uint64(block.timestamp + 60 days)));
    }

    function test_verifyItemData_rejectsEmptyMetadataFields() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();
        uint64 goalDeadline = uint64(block.timestamp + 60 days);

        IBudgetTCR.BudgetListing memory missingTitle = _defaultListing();
        missingTitle.metadata.title = "";
        assertFalse(_verify(missingTitle, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory missingDescription = _defaultListing();
        missingDescription.metadata.description = "";
        assertFalse(_verify(missingDescription, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory missingImage = _defaultListing();
        missingImage.metadata.image = "";
        assertFalse(_verify(missingImage, budgetBounds, goalDeadline));
    }

    function test_verifyItemData_rejectsFundingDeadlineBounds() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();
        uint64 goalDeadline = uint64(block.timestamp + 60 days);

        IBudgetTCR.BudgetListing memory atNow = _defaultListing();
        atNow.fundingDeadline = uint64(block.timestamp);
        assertFalse(_verify(atNow, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory belowLead = _defaultListing();
        belowLead.fundingDeadline = uint64(block.timestamp + budgetBounds.minFundingLeadTime - 1);
        assertFalse(_verify(belowLead, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory aboveHorizon = _defaultListing();
        aboveHorizon.fundingDeadline = uint64(block.timestamp + budgetBounds.maxFundingHorizon + 1);
        assertFalse(_verify(aboveHorizon, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory aboveGoalDeadline = _defaultListing();
        aboveGoalDeadline.fundingDeadline = goalDeadline + 1;
        assertFalse(_verify(aboveGoalDeadline, budgetBounds, goalDeadline));
    }

    function test_verifyItemData_allowsOpenHorizonWhenMaxFundingHorizonIsZero() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();
        budgetBounds.maxFundingHorizon = 0;

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        listing.fundingDeadline = uint64(block.timestamp + 120 days);

        assertTrue(_verify(listing, budgetBounds, uint64(block.timestamp + 180 days)));
    }

    function test_verifyItemData_rejectsExecutionDurationAndWorstCaseEnd() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();

        IBudgetTCR.BudgetListing memory tooShort = _defaultListing();
        tooShort.executionDuration = budgetBounds.minExecutionDuration - 1;
        assertFalse(_verify(tooShort, budgetBounds, uint64(block.timestamp + 60 days)));

        IBudgetTCR.BudgetListing memory tooLong = _defaultListing();
        tooLong.executionDuration = budgetBounds.maxExecutionDuration + 1;
        assertFalse(_verify(tooLong, budgetBounds, uint64(block.timestamp + 60 days)));

        IBudgetTCR.BudgetListing memory worstCasePastGoal = _defaultListing();
        worstCasePastGoal.fundingDeadline = uint64(block.timestamp + 6 days);
        worstCasePastGoal.executionDuration = 5 days;
        assertFalse(_verify(worstCasePastGoal, budgetBounds, uint64(block.timestamp + 10 days)));
    }

    function test_verifyItemData_rejectsActivationThresholdAndRunwayCapBounds() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();
        uint64 goalDeadline = uint64(block.timestamp + 60 days);

        IBudgetTCR.BudgetListing memory belowMinThreshold = _defaultListing();
        belowMinThreshold.activationThreshold = budgetBounds.minActivationThreshold - 1;
        assertFalse(_verify(belowMinThreshold, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory aboveMaxThreshold = _defaultListing();
        aboveMaxThreshold.activationThreshold = budgetBounds.maxActivationThreshold + 1;
        assertFalse(_verify(aboveMaxThreshold, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory runwayBelowActivation = _defaultListing();
        runwayBelowActivation.runwayCap = runwayBelowActivation.activationThreshold - 1;
        assertFalse(_verify(runwayBelowActivation, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory runwayAboveCap = _defaultListing();
        runwayAboveCap.runwayCap = budgetBounds.maxRunwayCap + 1;
        assertFalse(_verify(runwayAboveCap, budgetBounds, goalDeadline));
    }

    function test_verifyItemData_allowsUnlimitedRunwayCapWhenBoundIsZero() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();
        budgetBounds.maxRunwayCap = 0;

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        listing.runwayCap = listing.activationThreshold + 1_000_000e18;

        assertTrue(_verify(listing, budgetBounds, uint64(block.timestamp + 60 days)));
    }

    function test_verifyItemData_rejectsOracleHashes() public view {
        IBudgetTCR.BudgetValidationBounds memory budgetBounds = _defaultBudgetBounds();
        uint64 goalDeadline = uint64(block.timestamp + 60 days);

        IBudgetTCR.BudgetListing memory missingOracleSpecHash = _defaultListing();
        missingOracleSpecHash.oracleConfig.oracleSpecHash = bytes32(0);
        assertFalse(_verify(missingOracleSpecHash, budgetBounds, goalDeadline));

        IBudgetTCR.BudgetListing memory missingAssertionPolicyHash = _defaultListing();
        missingAssertionPolicyHash.oracleConfig.assertionPolicyHash = bytes32(0);
        assertFalse(_verify(missingAssertionPolicyHash, budgetBounds, goalDeadline));
    }

    function _verify(
        IBudgetTCR.BudgetListing memory listing,
        IBudgetTCR.BudgetValidationBounds memory budgetBounds,
        uint64 goalDeadline
    )
        internal
        view
        returns (bool)
    {
        return validationHarness.verifyItemData(abi.encode(listing), budgetBounds, goalDeadline);
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing = IBudgetTCR.BudgetListing({
            metadata: FlowTypes.RecipientMetadata({
                title: "Budget",
                description: "Budget description",
                image: "ipfs://image",
                tagline: "",
                url: ""
            }),
            fundingDeadline: uint64(block.timestamp + 2 days),
            executionDuration: 2 days,
            activationThreshold: 200e18,
            runwayCap: 600e18,
            oracleConfig: IBudgetTCR.OracleConfig({
                oracleSpecHash: keccak256("oracle-spec"),
                assertionPolicyHash: keccak256("assertion-policy")
            })
        });
    }

    function _defaultBudgetBounds() internal pure returns (IBudgetTCR.BudgetValidationBounds memory bounds) {
        bounds = IBudgetTCR.BudgetValidationBounds({
            minFundingLeadTime: 1 days,
            maxFundingHorizon: 30 days,
            minExecutionDuration: 1 days,
            maxExecutionDuration: 10 days,
            minActivationThreshold: 100e18,
            maxActivationThreshold: 1_000e18,
            maxRunwayCap: 5_000e18
        });
    }
}
