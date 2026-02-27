// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AllocationMechanismTCR } from "src/tcr/AllocationMechanismTCR.sol";
import { RoundFactory } from "src/rounds/RoundFactory.sol";
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
    RoundTestRewardEscrow,
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
    RoundTestRewardEscrow internal rewardEscrow;
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

    uint256 internal constant ARBITRATION_COST = 1e14;

    function setUp() public {
        underlying = new MockVotesToken("Goal", "GOAL");
        superToken = new RoundTestSuperToken("SuperGoal", "sGOAL", underlying);

        ledger = new RoundTestBudgetStakeLedger();
        rewardEscrow = new RoundTestRewardEscrow(address(ledger));
        jurorSlasher = new RoundTestJurorSlasher();

        goalFlow = new RoundTestManagedFlow(address(0xDEAD), address(0), address(0), address(0));
        stakeVault = new RoundTestStakeVault(underlying, address(0), address(jurorSlasher));
        goalTreasury = new RoundTestGoalTreasury(address(goalFlow), address(rewardEscrow), address(stakeVault));
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
            endAt: endAt
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
        assertEq(budgetFlow.recipientById(itemId), deployed.prizeVault);
        assertTrue(budgetFlow.recipientExists(deployed.prizeVault));

        vm.prank(alice);
        mechanism.removeItem(itemId, "");
        _warpPastChallengePeriod();
        mechanism.executeRequest(itemId);

        assertTrue(mechanism.removalQueued(itemId));

        mechanism.finalizeRemovedRound(itemId);
        AllocationMechanismTCR.RoundDeployment memory afterDeployment = mechanism.roundDeployment(itemId);
        assertFalse(afterDeployment.active);
        assertFalse(budgetFlow.recipientExists(deployed.prizeVault));
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
}
