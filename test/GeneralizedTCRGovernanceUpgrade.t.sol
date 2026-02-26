// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "test/GeneralizedTCR.t.sol";
import { GeneralizedTCR } from "src/tcr/GeneralizedTCR.sol";

contract GeneralizedTCRGovernanceUpgradeTest is GeneralizedTCRTestBase {
    function test_setGovernor_has_no_direct_setter() public {
        address initialGovernor = tcr.governor();

        _assertMissingSelector(abi.encodeWithSignature("setGovernor(address)", makeAddr("newGov")));
        _assertMissingSelectorAs(governor, abi.encodeWithSignature("setGovernor(address)", makeAddr("anotherGov")));

        assertEq(tcr.governor(), initialGovernor);
    }

    function test_setArbitrator_has_no_direct_setter() public {
        ERC20VotesArbitrator arbImpl2 = new ERC20VotesArbitrator();
        bytes memory arbInit2 = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), address(tcr), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        ERC20VotesArbitrator newArb = ERC20VotesArbitrator(_deployProxy(address(arbImpl2), arbInit2));

        address initialArbitrator = address(tcr.arbitrator());
        bytes memory initialExtraData = tcr.arbitratorExtraData();
        uint256 initialDisputeTimeout = tcr.disputeTimeout();

        _assertMissingSelector(abi.encodeWithSignature("setArbitrator(address,bytes)", address(newArb), bytes("newExtra")));
        _assertMissingSelectorAs(
            governor,
            abi.encodeWithSignature("setArbitrator(address,bytes)", address(newArb), bytes("newExtra"))
        );

        assertEq(address(tcr.arbitrator()), initialArbitrator);
        assertEq(tcr.arbitratorExtraData(), initialExtraData);
        assertEq(tcr.disputeTimeout(), initialDisputeTimeout);
    }

    function test_initialize_reverts_when_arbitrator_arbitrable_mismatch() public {
        MockVotesArbitrator mismatched = new MockVotesArbitrator(IVotes(address(token)), address(0xBEEF));
        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                IArbitrator(address(mismatched)),
                bytes(""),
                "ipfs://regMeta",
                "ipfs://clearMeta",
                governor,
                IVotes(address(token)),
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                defaultSubmissionDepositStrategy
            )
        );

        vm.expectRevert(IGeneralizedTCR.ARBITRATOR_ARBITRABLE_MISMATCH.selector);
        _deployProxy(address(tcrImpl), tcrInit);
    }

    function test_getTotalCosts_reflects_init_values_when_deposit_setters_are_absent() public {
        (uint256 addItemCost, uint256 removeItemCost, uint256 challengeSubmissionCost, uint256 challengeRemovalCost,) =
            tcr.getTotalCosts();
        assertEq(addItemCost, submissionBaseDeposit + arbitrationCost);
        assertEq(removeItemCost, removalBaseDeposit + arbitrationCost);
        assertEq(challengeSubmissionCost, submissionChallengeBaseDeposit + arbitrationCost);
        assertEq(challengeRemovalCost, removalChallengeBaseDeposit + arbitrationCost);

        _assertMissingSelectorAs(governor, abi.encodeWithSignature("setSubmissionBaseDeposit(uint256)", type(uint256).max));

        (uint256 addItemCostAfter,,,,) = tcr.getTotalCosts();
        assertEq(addItemCostAfter, addItemCost);
    }

    function test_tcr_upgrade_reverts_when_nonupgradeable() public {
        MockGeneralizedTCRUpgradeMock newImpl = new MockGeneralizedTCRUpgradeMock();

        vm.expectRevert(GeneralizedTCR.NON_UPGRADEABLE.selector);
        tcr.upgradeToAndCall(address(newImpl), bytes(""));

        vm.prank(governor);
        vm.expectRevert(GeneralizedTCR.NON_UPGRADEABLE.selector);
        tcr.upgradeToAndCall(address(newImpl), bytes(""));
    }

    function test_disputeTimeout_has_no_direct_setter() public {
        uint256 initialDisputeTimeout = tcr.disputeTimeout();

        _assertMissingSelectorAs(governor, abi.encodeWithSignature("setDisputeTimeout(uint256)", 456));

        assertEq(tcr.disputeTimeout(), initialDisputeTimeout);
    }

    function test_challengePeriodDuration_is_init_only() public {
        assertEq(tcr.challengePeriodDuration(), challengePeriodDuration);

        _assertMissingSelectorAs(governor, abi.encodeWithSignature("setChallengePeriodDuration(uint256)", 123));

        assertEq(tcr.challengePeriodDuration(), challengePeriodDuration);
    }

    function test_deposit_params_are_init_only_with_no_runtime_setters() public {
        uint256 initialSubmissionBaseDeposit = tcr.submissionBaseDeposit();
        uint256 initialRemovalBaseDeposit = tcr.removalBaseDeposit();
        uint256 initialSubmissionChallengeBaseDeposit = tcr.submissionChallengeBaseDeposit();
        uint256 initialRemovalChallengeBaseDeposit = tcr.removalChallengeBaseDeposit();

        bytes[] memory setterCalls = new bytes[](4);
        setterCalls[0] = abi.encodeWithSignature("setSubmissionBaseDeposit(uint256)", 777);
        setterCalls[1] = abi.encodeWithSignature("setRemovalBaseDeposit(uint256)", 555);
        setterCalls[2] = abi.encodeWithSignature("setSubmissionChallengeBaseDeposit(uint256)", 999);
        setterCalls[3] = abi.encodeWithSignature("setRemovalChallengeBaseDeposit(uint256)", 888);

        for (uint256 i; i < setterCalls.length; i++) {
            _assertMissingSelector(setterCalls[i]);
            _assertMissingSelectorAs(governor, setterCalls[i]);
        }

        assertEq(tcr.submissionBaseDeposit(), initialSubmissionBaseDeposit);
        assertEq(tcr.removalBaseDeposit(), initialRemovalBaseDeposit);
        assertEq(tcr.submissionChallengeBaseDeposit(), initialSubmissionChallengeBaseDeposit);
        assertEq(tcr.removalChallengeBaseDeposit(), initialRemovalChallengeBaseDeposit);
    }

    function test_metaEvidence_is_init_only_with_no_direct_setter() public {
        string memory initialRegistrationMetaEvidence = tcr.registrationMetaEvidence();
        string memory initialClearingMetaEvidence = tcr.clearingMetaEvidence();

        _assertMissingSelectorAs(
            governor,
            abi.encodeWithSignature("setMetaEvidenceURIs(string,string)", "ipfs://reg2", "ipfs://clear2")
        );

        assertEq(tcr.registrationMetaEvidence(), initialRegistrationMetaEvidence);
        assertEq(tcr.clearingMetaEvidence(), initialClearingMetaEvidence);

        // Registration requests continue to use initial meta evidence ID 0.
        _approveAddItemCost(requester);
        bytes32 itemID1;
        vm.prank(requester);
        itemID1 = tcr.addItem(abi.encodePacked("item-meta-1"));

        (,,,,,,,,, uint256 meta1) = tcr.getRequestInfo(itemID1, 0);
        assertEq(meta1, 0);

        // Additional registrations continue to use initial meta evidence ID 0.
        _approveAddItemCost(requester);
        bytes32 itemID2;
        vm.prank(requester);
        itemID2 = tcr.addItem(abi.encodePacked("item-meta-2"));

        (,,,,,,,,, uint256 meta2) = tcr.getRequestInfo(itemID2, 0);
        assertEq(meta2, 0);

        // Clearing requests continue to use initial meta evidence ID 1.
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        tcr.executeRequest(itemID2);

        _approveRemoveCost(requester);
        vm.prank(requester);
        tcr.removeItem(itemID2, "");

        (,,,,,,,,, uint256 meta3) = tcr.getRequestInfo(itemID2, 1);
        assertEq(meta3, 1);
    }

    function test_metaEvidenceUpdates_getter_selector_is_removed() public {
        bytes memory callData = abi.encodeWithSignature("metaEvidenceUpdates()");
        _assertMissingSelector(callData);
        _assertMissingSelectorAs(governor, callData);
    }

    function _assertMissingSelector(bytes memory callData) internal {
        (bool success, bytes memory revertData) = address(tcr).call(callData);
        assertFalse(success);
        assertEq(revertData.length, 0);
    }

    function _assertMissingSelectorAs(address caller, bytes memory callData) internal {
        vm.prank(caller);
        _assertMissingSelector(callData);
    }

}
