// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { MechanismFundingEscrow } from "src/escrow/MechanismFundingEscrow.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    RoundTestSuperToken,
    RoundTestManagedFlow,
    RoundTestBudgetTreasury,
    RoundTestGoalTreasury,
    RoundTestStakeVault,
    RoundTestBudgetStakeLedger,
    RoundTestJurorSlasher,
    RoundTestArbitrator
} from "test/rounds/helpers/RoundTestMocks.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract AllocationMechanismTCRTest is Test {
    MockVotesToken internal underlying;
    RoundTestSuperToken internal superToken;

    RoundTestBudgetStakeLedger internal ledger;
    RoundTestJurorSlasher internal jurorSlasher;

    RoundTestManagedFlow internal goalFlow;
    RoundTestManagedFlow internal budgetFlow;
    RoundTestGoalTreasury internal goalTreasury;
    RoundTestStakeVault internal stakeVault;
    RoundTestBudgetTreasury internal budgetTreasury;

    RoundFactory internal roundFactory;

    AllocationMechanismTCR internal mechanism;
    EscrowSubmissionDepositStrategy internal mechanismDepositStrategy;
    RoundTestArbitrator internal mechanismArbitrator;

    address internal roundOperator = address(0x0F00);
    address internal governor = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal constant MOCK_DISTRIBUTION_POOL = address(0xD157);

    uint256 internal constant ARBITRATION_COST = 1e14;

    function setUp() public {
        underlying = new MockVotesToken("Goal", "GOAL");
        superToken = new RoundTestSuperToken("SuperGoal", "sGOAL", underlying);

        ledger = new RoundTestBudgetStakeLedger();
        jurorSlasher = new RoundTestJurorSlasher();

        goalFlow = new RoundTestManagedFlow(address(0xDEAD), address(0), address(0), address(0));
        stakeVault = new RoundTestStakeVault(underlying, address(0), address(jurorSlasher));
        goalTreasury = new RoundTestGoalTreasury(address(goalFlow), address(ledger), address(stakeVault));
        stakeVault.setGoalTreasury(address(goalTreasury));
        goalFlow.setFlowOperator(address(goalTreasury));

        budgetFlow = new RoundTestManagedFlow(address(0), address(0xB0), address(goalFlow), address(superToken));
        budgetTreasury = new RoundTestBudgetTreasury(address(budgetFlow));

        roundFactory = new RoundFactory();

        mechanismDepositStrategy = new EscrowSubmissionDepositStrategy(underlying);
        AllocationMechanismTCR mechanismImplementation = new AllocationMechanismTCR();
        mechanism = AllocationMechanismTCR(Clones.clone(address(mechanismImplementation)));

        budgetFlow.setRecipientAdmin(address(mechanism));

        mechanismArbitrator = new RoundTestArbitrator(
            IVotes(address(underlying)),
            address(mechanism),
            1,
            1,
            1,
            ARBITRATION_COST
        );

        AllocationMechanismTCR.RoundDefaults memory defaults = _roundDefaults();
        AllocationMechanismTCR.RegistryConfig memory mechanismTcrCfg = _mechanismRegistryConfig(mechanismArbitrator);

        mechanism.initialize(address(budgetTreasury), address(roundFactory), defaults, mechanismTcrCfg);

        underlying.mint(alice, 1000e18);
        vm.prank(alice);
        underlying.approve(address(mechanism), type(uint256).max);
    }

    function _validListing(
        uint64 startAt,
        uint64 endAt
    ) internal pure returns (AllocationMechanismTCR.RoundMechanismListing memory listing) {
        listing = AllocationMechanismTCR.RoundMechanismListing({
            metadata: FlowTypes.RecipientMetadata({
                title: "Test Round",
                description: "Desc",
                image: "ipfs://image",
                tagline: "tag",
                url: "https://example.com"
            }),
            startAt: startAt,
            endAt: endAt,
            fundingDeadline: 0,
            minBudgetFunding: 0,
            maxBudgetFunding: 0
        });
    }

    function _roundDefaults() internal view returns (AllocationMechanismTCR.RoundDefaults memory defaults) {
        defaults = AllocationMechanismTCR.RoundDefaults({
            arbitratorExtraData: "",
            registrationMetaEvidence: "round-reg",
            clearingMetaEvidence: "round-clr",
            governor: governor,
            submissionBaseDeposit: 1e18,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            challengePeriodDuration: 1 days,
            votingPeriod: 1,
            votingDelay: 1,
            revealPeriod: 1,
            arbitrationCost: ARBITRATION_COST,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0,
            roundOperator: roundOperator
        });
    }

    function _mechanismRegistryConfig(
        RoundTestArbitrator arbitrator_
    ) internal view returns (AllocationMechanismTCR.RegistryConfig memory cfg) {
        cfg = AllocationMechanismTCR.RegistryConfig({
            arbitrator: arbitrator_,
            arbitratorExtraData: "",
            registrationMetaEvidence: "mech-reg",
            clearingMetaEvidence: "mech-clr",
            governor: governor,
            votingToken: IVotes(address(underlying)),
            submissionBaseDeposit: 0,
            submissionDepositStrategy: mechanismDepositStrategy,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            challengePeriodDuration: 1 days
        });
    }

    function _warpPastChallengePeriod() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
    }

    function _registerAndActivate(
        AllocationMechanismTCR.RoundMechanismListing memory listing
    ) internal returns (bytes32 itemId, AllocationMechanismTCR.RoundDeployment memory deployment) {
        vm.prank(alice);
        itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        mechanism.activateRound(itemId);

        deployment = mechanism.roundDeployment(itemId);
    }

    function _mockEscrowTotalReceived(address escrow, uint256 totalReceived) internal {
        vm.mockCall(address(budgetFlow), abi.encodeWithSignature("distributionPool()"), abi.encode(MOCK_DISTRIBUTION_POOL));
        vm.mockCall(
            MOCK_DISTRIBUTION_POOL,
            abi.encodeWithSignature("getTotalAmountReceivedByMember(address)", escrow),
            abi.encode(totalReceived)
        );
    }

    function test_initialize_revertsWhenBudgetFlowRecipientAdminMismatch() public {
        AllocationMechanismTCR mechanismImplementation = new AllocationMechanismTCR();
        AllocationMechanismTCR mechanism2 = AllocationMechanismTCR(Clones.clone(address(mechanismImplementation)));
        RoundTestArbitrator arbitrator2 = new RoundTestArbitrator(
            IVotes(address(underlying)),
            address(mechanism2),
            1,
            1,
            1,
            ARBITRATION_COST
        );

        AllocationMechanismTCR.RoundDefaults memory defaults = _roundDefaults();
        AllocationMechanismTCR.RegistryConfig memory mechanismTcrCfg = _mechanismRegistryConfig(arbitrator2);

        vm.expectRevert(AllocationMechanismTCR.BUDGET_FLOW_MISMATCH.selector);
        mechanism2.initialize(address(budgetTreasury), address(roundFactory), defaults, mechanismTcrCfg);
    }

    function test_verifyItemData_rejectsBadMetadata() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp),
            uint64(block.timestamp + 1)
        );
        listing.metadata.title = "";

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_verifyItemData_rejectsMalformedListingPayload() public {
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(hex"1234");
    }

    function test_verifyItemData_rejectsInvalidTimeWindow() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(200, 100);

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_verifyItemData_rejectsInvalidFundingPolicy_maxBelowMin() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(100, 200);
        listing.minBudgetFunding = 10e18;
        listing.maxBudgetFunding = 9e18;

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function testFuzz_verifyItemData_rejectsMalformedShortPayloads(bytes calldata payload) public {
        // Valid encoded listings are significantly larger than this bound.
        vm.assume(payload.length < 224);

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        mechanism.addItem(payload);
    }

    function test_registerQueuesActivation() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.activationQueued(itemId));
        assertFalse(mechanism.removalQueued(itemId));

        (, IGeneralizedTCR.Status status,) = mechanism.getItemInfo(itemId);
        assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Registered));
    }

    function test_removeBeforeActivationDoesNotQueueRemoval() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertFalse(mechanism.activationQueued(itemId));
        assertFalse(mechanism.removalQueued(itemId));
    }

    function test_setRoundDefaults_onlyGovernor() public {
        AllocationMechanismTCR.RoundDefaults memory next = _roundDefaults();
        next.registrationMetaEvidence = "round-reg-2";
        next.clearingMetaEvidence = "round-clr-2";
        next.submissionBaseDeposit = 2e18;

        vm.prank(alice);
        vm.expectRevert(AllocationMechanismTCR.ONLY_GOVERNOR.selector);
        mechanism.setRoundDefaults(next);

        vm.prank(governor);
        mechanism.setRoundDefaults(next);

        (,,,, uint256 submissionBaseDeposit,,,,,,,,,,,) = mechanism.roundDefaults();
        assertEq(submissionBaseDeposit, 2e18);
    }

    function test_activateAndFinalizeRemoval_endToEnd() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        RoundFactory.DeployedRound memory deployed = mechanism.activateRound(itemId);
        AllocationMechanismTCR.RoundDeployment memory deployment = mechanism.roundDeployment(itemId);

        assertTrue(deployment.active);
        assertTrue(deployed.prizeVault.code.length > 0);
        assertTrue(deployed.submissionTCR.code.length > 0);
        assertEq(budgetFlow.recipientById(itemId), deployment.fundingEscrow);
        assertTrue(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(MechanismFundingEscrow(deployment.fundingEscrow).recipient(), deployed.prizeVault);
        assertEq(MechanismFundingEscrow(deployment.fundingEscrow).refundRecipient(), address(budgetFlow));
        assertEq(MechanismFundingEscrow(deployment.fundingEscrow).controller(), address(mechanism));

        uint256 escrowedBeforeRemoval = 7e18;
        superToken.mint(deployment.fundingEscrow, escrowedBeforeRemoval);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.removalQueued(itemId));

        mechanism.finalizeRemovedRound(itemId);
        AllocationMechanismTCR.RoundDeployment memory afterDeployment = mechanism.roundDeployment(itemId);
        assertFalse(afterDeployment.active);
        assertFalse(budgetFlow.recipientExists(deployment.fundingEscrow));
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowedBeforeRemoval);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
    }

    function test_addItem_revertsWhileRemovalFinalizationPending() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );

        vm.prank(alice);
        bytes32 itemId = mechanism.addItem(abi.encode(listing));

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);
        mechanism.activateRound(itemId);

        vm.prank(alice);
        mechanism.removeItem(itemId, "");

        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.removalQueued(itemId));

        vm.prank(alice);
        vm.expectRevert(AllocationMechanismTCR.REMOVAL_FINALIZATION_PENDING.selector);
        mechanism.addItem(abi.encode(listing));
    }

    function test_releaseRoundFunds_revertsBelowMinBudgetFunding() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 7 days);

        (bytes32 itemId, AllocationMechanismTCR.RoundDeployment memory deployment) = _registerAndActivate(listing);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);

        vm.expectRevert(
            abi.encodeWithSelector(AllocationMechanismTCR.ROUND_BELOW_MIN_FUNDING.selector, listing.minBudgetFunding, 99e18)
        );
        mechanism.releaseRoundFunds(itemId, 0);
    }

    function test_releaseRoundFunds_revertsWhenExpiredUnderfunded() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 3 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 2 days);

        (bytes32 itemId, AllocationMechanismTCR.RoundDeployment memory deployment) = _registerAndActivate(listing);
        vm.warp(uint256(listing.fundingDeadline) + 1);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                AllocationMechanismTCR.ROUND_EXPIRED_UNDERFUNDED.selector,
                listing.fundingDeadline,
                listing.minBudgetFunding,
                99e18
            )
        );
        mechanism.releaseRoundFunds(itemId, 0);
    }

    function test_releaseRoundFunds_sweepsEscrowToPrizeVaultWhenMinMet() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 7 days);

        (bytes32 itemId, AllocationMechanismTCR.RoundDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 5e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.minBudgetFunding);

        uint256 released = mechanism.releaseRoundFunds(itemId, 0);
        assertEq(released, escrowed);
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(deployment.prizeVault), escrowed);
    }

    function test_syncRoundFunding_refundsEscrowWhenExpiredUnderfundedEvenAfterEndAt() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2 days)
        );
        listing.minBudgetFunding = 100e18;
        listing.fundingDeadline = uint64(block.timestamp + 2 days);

        (bytes32 itemId, AllocationMechanismTCR.RoundDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 3e18;
        superToken.mint(deployment.fundingEscrow, escrowed);

        vm.warp(uint256(listing.endAt) + 1);
        _mockEscrowTotalReceived(deployment.fundingEscrow, 99e18);
        mechanism.syncRoundFunding(itemId);

        AllocationMechanismTCR.RoundDeployment memory afterSync = mechanism.roundDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), 0);
        assertEq(superToken.balanceOf(address(budgetFlow)), escrowed);
    }

    function test_syncRoundFunding_stopsAtCapWithoutRefundingEscrow() public {
        AllocationMechanismTCR.RoundMechanismListing memory listing = _validListing(
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 30 days)
        );
        listing.maxBudgetFunding = 250e18;

        (bytes32 itemId, AllocationMechanismTCR.RoundDeployment memory deployment) = _registerAndActivate(listing);
        uint256 escrowed = 2e18;
        superToken.mint(deployment.fundingEscrow, escrowed);
        _mockEscrowTotalReceived(deployment.fundingEscrow, listing.maxBudgetFunding);

        mechanism.syncRoundFunding(itemId);

        AllocationMechanismTCR.RoundDeployment memory afterSync = mechanism.roundDeployment(itemId);
        assertFalse(afterSync.active);
        assertEq(budgetFlow.recipientById(itemId), address(0));
        assertEq(superToken.balanceOf(deployment.fundingEscrow), escrowed);
        assertEq(superToken.balanceOf(address(budgetFlow)), 0);
    }
}
