// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { RoundPrizeVault } from "src/rounds/RoundPrizeVault.sol";
import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { RoundTestArbitrator, RoundTestSuperToken } from "test/rounds/helpers/RoundTestMocks.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract RoundPrizeVaultTest is Test {
    MockVotesToken internal underlying;
    RoundTestSuperToken internal superToken;

    RoundSubmissionTCR internal submissions;
    EscrowSubmissionDepositStrategy internal depositStrategy;
    RoundTestArbitrator internal arbitrator;

    RoundPrizeVault internal vault;

    address internal operator = address(0x0F00);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant CHALLENGE_PERIOD = 1 days;
    bytes32 internal constant DEFAULT_POST_ID = bytes32("post");

    function setUp() public {
        underlying = new MockVotesToken("Goal", "GOAL");
        superToken = new RoundTestSuperToken("SuperGoal", "sGOAL", underlying);
        depositStrategy = new EscrowSubmissionDepositStrategy(underlying);

        RoundSubmissionTCR submissionsImplementation = new RoundSubmissionTCR();
        submissions = RoundSubmissionTCR(Clones.clone(address(submissionsImplementation)));
        arbitrator = new RoundTestArbitrator(IVotes(address(underlying)), address(submissions), 1, 1, 1, ARBITRATION_COST);

        RoundSubmissionTCR.RoundConfig memory roundCfg = RoundSubmissionTCR.RoundConfig({
            roundId: bytes32("round"),
            startAt: uint64(block.timestamp - 1),
            endAt: uint64(block.timestamp + 7 days),
            prizeVault: address(0)
        });
        IGeneralizedTCRConfig.RegistryConfig memory regCfg = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: arbitrator,
            votingToken: IVotes(address(underlying)),
            submissionDepositStrategy: depositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                submissionBaseDeposit: 0,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: CHALLENGE_PERIOD
            })
        });
        submissions.initialize(roundCfg, regCfg);

        RoundPrizeVault prizeVaultImplementation = new RoundPrizeVault();
        vault = _cloneVault(prizeVaultImplementation);
        vault.initialize(underlying, ISuperToken(address(superToken)), submissions, operator);

        underlying.mint(alice, 1000e18);
        vm.prank(alice);
        underlying.approve(address(submissions), type(uint256).max);
        underlying.mint(bob, 1000e18);
        vm.prank(bob);
        underlying.approve(address(submissions), type(uint256).max);
    }

    function _submitAndRegister() internal returns (bytes32 itemId) {
        bytes memory item = _submissionItem(alice);
        vm.prank(alice);
        itemId = submissions.addItem(item);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(itemId);
    }

    function _submissionItem(address recipient) internal pure returns (bytes memory) {
        return abi.encode(uint8(0), DEFAULT_POST_ID, recipient);
    }

    function _cloneVault(RoundPrizeVault implementation) internal returns (RoundPrizeVault cloned) {
        cloned = RoundPrizeVault(Clones.clone(address(implementation)));
    }

    function test_implementation_isInitializationLocked() public {
        RoundPrizeVault implementation = new RoundPrizeVault();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(underlying, ISuperToken(address(superToken)), submissions, operator);
    }

    function test_initialize_revertsOnZeroAddresses() public {
        RoundPrizeVault implementation = new RoundPrizeVault();
        RoundPrizeVault vault0 = _cloneVault(implementation);
        vm.expectRevert(RoundPrizeVault.ADDRESS_ZERO.selector);
        vault0.initialize(MockVotesToken(address(0)), ISuperToken(address(superToken)), submissions, operator);

        RoundPrizeVault vault1 = _cloneVault(implementation);
        vm.expectRevert(RoundPrizeVault.ADDRESS_ZERO.selector);
        vault1.initialize(underlying, ISuperToken(address(superToken)), RoundSubmissionTCR(address(0)), operator);

        RoundPrizeVault vault2 = _cloneVault(implementation);
        vm.expectRevert(RoundPrizeVault.ADDRESS_ZERO.selector);
        vault2.initialize(underlying, ISuperToken(address(superToken)), submissions, address(0));
    }

    function test_initialize_revertsOnReinitializeClone() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(underlying, ISuperToken(address(superToken)), submissions, operator);
    }

    function test_setOperator_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(RoundPrizeVault.ONLY_OPERATOR.selector);
        vault.setOperator(alice);

        vm.prank(operator);
        vm.expectRevert(RoundPrizeVault.ADDRESS_ZERO.selector);
        vault.setOperator(address(0));

        vm.prank(operator);
        vault.setOperator(bob);
        assertEq(vault.operator(), bob);
    }

    function test_setEntitlement_revertsWhenSubmissionNotRegistered() public {
        bytes memory item = _submissionItem(alice);
        vm.prank(alice);
        bytes32 id = submissions.addItem(item);

        vm.prank(operator);
        vm.expectRevert(RoundPrizeVault.SUBMISSION_NOT_REGISTERED.selector);
        vault.setEntitlement(id, 100);
    }

    function test_setEntitlement_guardsClaimed() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 100);
        assertEq(vault.entitlementOf(id), 100);

        underlying.mint(address(vault), 100);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RoundPrizeVault.ENTITLEMENT_LT_CLAIMED.selector, 99, 100));
        vault.setEntitlement(id, 99);
    }

    function test_setEntitlement_zero_allowsClearingWhenSubmissionNotRegistered() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 100);

        vm.prank(alice);
        submissions.removeItem(id, "");
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(operator);
        vault.setEntitlement(id, 0);
        assertEq(vault.entitlementOf(id), 0);
    }

    function test_setEntitlements_lengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32("a");
        ids[1] = bytes32("b");
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(operator);
        vm.expectRevert(RoundPrizeVault.LENGTH_MISMATCH.selector);
        vault.setEntitlements(ids, amounts);
    }

    function test_claim_revertsWhenNotSubmitter() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 100);

        underlying.mint(address(vault), 100);

        vm.prank(bob);
        vm.expectRevert(RoundPrizeVault.ONLY_SUBMITTER.selector);
        vault.claim(id);
    }

    function test_claim_succeedsWhenSubmissionRemovedAfterEntitlementSet() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 100);
        underlying.mint(address(vault), 100);

        vm.prank(alice);
        submissions.removeItem(id, "");

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);
    }

    function test_claim_succeedsWhenSubmissionIsPendingRemoval() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 100);
        underlying.mint(address(vault), 100);

        vm.prank(alice);
        submissions.removeItem(id, "");

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);
    }

    function test_claim_revertsWhenNothingToClaim() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 1);

        underlying.mint(address(vault), 1);

        vm.prank(alice);
        vault.claim(id);

        vm.prank(alice);
        vm.expectRevert(RoundPrizeVault.NOTHING_TO_CLAIM.selector);
        vault.claim(id);
    }

    function test_claim_transfersUnderlyingAndAdvancesClaimed() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 250);
        underlying.mint(address(vault), 250);

        uint256 aliceBefore = underlying.balanceOf(alice);

        vm.prank(alice);
        vault.claim(id);

        assertEq(underlying.balanceOf(alice) - aliceBefore, 250);
        assertEq(vault.claimedOf(id), 250);
        assertEq(vault.entitlementOf(id), 250);
    }

    function test_claim_onlyTransfersEntitledAmount_andLeavesExcessInVault() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 250);

        underlying.mint(address(vault), 1000);

        vm.prank(alice);
        vault.claim(id);

        assertEq(vault.claimedOf(id), 250);
        assertEq(underlying.balanceOf(address(vault)), 750);

        vm.prank(alice);
        vm.expectRevert(RoundPrizeVault.NOTHING_TO_CLAIM.selector);
        vault.claim(id);
        assertEq(underlying.balanceOf(address(vault)), 750);
    }

    function test_claim_supportsIncrementalEntitlements() public {
        bytes32 id = _submitAndRegister();

        underlying.mint(address(vault), 500);

        vm.prank(operator);
        vault.setEntitlement(id, 100);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);

        vm.prank(operator);
        vault.setEntitlement(id, 175);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 175);
    }

    function test_claim_downgradesSuperTokenWhenUnderlyingInsufficient() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 1000);

        underlying.mint(address(superToken), 1000);
        superToken.mint(address(vault), 1000);

        uint256 aliceBefore = underlying.balanceOf(alice);

        vm.prank(alice);
        vault.claim(id);

        assertEq(vault.claimedOf(id), 1000);
        assertEq(underlying.balanceOf(alice) - aliceBefore, 1000);
        assertEq(superToken.balanceOf(address(vault)), 0);
    }

    function test_claim_revertsWhenInsufficientUnderlyingAndSuperToken() public {
        bytes32 id = _submitAndRegister();

        vm.prank(operator);
        vault.setEntitlement(id, 10);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RoundPrizeVault.INSUFFICIENT_UNDERLYING.selector, 10, 0));
        vault.claim(id);
    }

    function test_downgrade_revertsWhenSuperTokenNotConfigured() public {
        RoundPrizeVault implementation = new RoundPrizeVault();
        RoundPrizeVault vault2 = _cloneVault(implementation);
        vault2.initialize(underlying, ISuperToken(address(0)), submissions, operator);

        vm.expectRevert(RoundPrizeVault.SUPER_TOKEN_NOT_CONFIGURED.selector);
        vault2.downgrade(1);
    }

    function test_copyCalldataFrontRun_doesNotHijackVaultClaimRecipient() public {
        bytes memory item = _submissionItem(alice);
        vm.prank(bob);
        bytes32 id = submissions.addItem(item);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(operator);
        vault.setEntitlement(id, 100);
        underlying.mint(address(vault), 100);

        vm.prank(bob);
        vm.expectRevert(RoundPrizeVault.ONLY_SUBMITTER.selector);
        vault.claim(id);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);
    }

    function test_claim_snapshotRecipient_blocksRemoveAndReAddTakeover() public {
        bytes memory item = _submissionItem(alice);
        vm.prank(alice);
        bytes32 id = submissions.addItem(item);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(operator);
        vault.setEntitlement(id, 100);
        underlying.mint(address(vault), 100);

        vm.prank(bob);
        submissions.removeItem(id, "");

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        bytes memory attackerItem = _submissionItem(bob);
        vm.prank(bob);
        submissions.addItem(attackerItem);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(bob);
        vm.expectRevert(RoundPrizeVault.ONLY_SUBMITTER.selector);
        vault.claim(id);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);
    }

    function test_claim_snapshotRecipient_staysPinnedAfterManagerMutation_andEntitlementIncrease() public {
        bytes memory item = _submissionItem(alice);
        vm.prank(alice);
        bytes32 id = submissions.addItem(item);

        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(operator);
        vault.setEntitlement(id, 100);
        assertEq(vault.payoutRecipientOf(id), alice);
        underlying.mint(address(vault), 175);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 100);

        vm.prank(bob);
        submissions.removeItem(id, "");
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        bytes memory attackerItem = _submissionItem(bob);
        vm.prank(bob);
        submissions.addItem(attackerItem);
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_PERIOD + 1);
        submissions.executeRequest(id);

        vm.prank(operator);
        vault.setEntitlement(id, 175);
        assertEq(vault.payoutRecipientOf(id), alice);

        vm.prank(bob);
        vm.expectRevert(RoundPrizeVault.ONLY_SUBMITTER.selector);
        vault.claim(id);

        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.claimedOf(id), 175);
    }
}
