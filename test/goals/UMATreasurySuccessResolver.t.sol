// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { UMATreasurySuccessResolver } from "src/goals/UMATreasurySuccessResolver.sol";
import { ISuccessAssertionTreasury } from "src/interfaces/ISuccessAssertionTreasury.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import { OptimisticOracleV3CallbackRecipientInterface } from "src/interfaces/uma/OptimisticOracleV3CallbackRecipientInterface.sol";

contract UMATreasurySuccessResolverTest is Test {
    MockUSDC internal usdc;
    MockOptimisticOracleV3 internal mockOracle;
    UMATreasurySuccessResolver internal resolver;
    MockGoalAssertionTreasury internal goalTreasury;
    MockBudgetAssertionTreasury internal budgetTreasury;

    address internal constant ASSERTER = address(0xA11CE);
    bytes32 internal constant SPEC_HASH = keccak256("goal-spec");
    bytes32 internal constant POLICY_HASH = keccak256("goal-policy");

    function setUp() public {
        usdc = new MockUSDC();
        mockOracle = new MockOptimisticOracleV3(IERC20(address(usdc)));
        resolver = new UMATreasurySuccessResolver(
            OptimisticOracleV3Interface(address(mockOracle)), IERC20(address(usdc)), address(0), bytes32(0)
        );

        goalTreasury = new MockGoalAssertionTreasury();
        goalTreasury.configure({
            resolver_: address(resolver),
            liveness_: 12 hours,
            bond_: 100e6,
            specHash_: SPEC_HASH,
            policyHash_: POLICY_HASH,
            deadline_: uint64(block.timestamp + 7 days)
        });

        budgetTreasury = new MockBudgetAssertionTreasury();
        budgetTreasury.configure({
            resolver_: address(resolver),
            liveness_: 8 hours,
            bond_: 200e6,
            specHash_: keccak256("budget-spec"),
            policyHash_: keccak256("budget-policy"),
            fundingDeadline_: uint64(block.timestamp + 1 days),
            deadline_: uint64(block.timestamp + 8 days)
        });

        usdc.mint(ASSERTER, 1_000_000e6);
        vm.prank(ASSERTER);
        usdc.approve(address(resolver), type(uint256).max);

        mockOracle.setMinimumBond(250e6);
    }

    function test_constructor_revertsWhenOracleAddressIsZero() public {
        vm.expectRevert(UMATreasurySuccessResolver.ADDRESS_ZERO.selector);
        new UMATreasurySuccessResolver(
            OptimisticOracleV3Interface(address(0)),
            IERC20(address(usdc)),
            address(0),
            bytes32(0)
        );
    }

    function test_constructor_revertsWhenAssertionCurrencyIsZero() public {
        vm.expectRevert(UMATreasurySuccessResolver.ADDRESS_ZERO.selector);
        new UMATreasurySuccessResolver(
            OptimisticOracleV3Interface(address(mockOracle)),
            IERC20(address(0)),
            address(0),
            bytes32(0)
        );
    }

    function test_assertSuccess_registersGoalAssertionAndClampsBondToMinimum() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://goal-evidence");

        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), assertionId);
        assertEq(goalTreasury.pendingSuccessAssertionId(), assertionId);

        (
            address treasury,
            address asserter,
            uint64 assertedAt,
            ISuccessAssertionTreasury.TreasuryKind kind,
            bool disputed,
            bool resolved_,
            bool truthful,
            bool finalized
        ) = resolver.assertionMeta(assertionId);

        assertEq(treasury, address(goalTreasury));
        assertEq(asserter, ASSERTER);
        assertEq(assertedAt, uint64(block.timestamp));
        assertEq(uint8(kind), uint8(ISuccessAssertionTreasury.TreasuryKind.Goal));
        assertFalse(disputed);
        assertFalse(resolved_);
        assertFalse(truthful);
        assertFalse(finalized);

        assertEq(mockOracle.lastBond(), 250e6);
        assertEq(usdc.balanceOf(address(mockOracle)), 250e6);
        assertEq(mockOracle.lastIdentifier(), bytes32("ASSERT_TRUTH2"));
        assertEq(mockOracle.lastSyncedIdentifier(), bytes32("ASSERT_TRUTH2"));
        assertEq(mockOracle.lastSyncedCurrency(), address(usdc));
        assertEq(usdc.allowance(address(resolver), address(mockOracle)), 0);

        string memory claim = mockOracle.lastClaim();
        assertTrue(_contains(claim, "type: GOAL"));
        assertTrue(_contains(claim, "ipfs://goal-evidence"));
    }

    function test_assertSuccess_revertsOnEvidenceTooLong() public {
        string memory longEvidence = _stringOfLength(2049);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.EVIDENCE_TOO_LONG.selector,
                uint256(2048),
                uint256(2049)
            )
        );
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(goalTreasury), longEvidence);
    }

    function test_assertSuccess_revertsWhenAssertionAlreadyActive() public {
        vm.startPrank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://first");

        vm.expectRevert(
            abi.encodeWithSelector(UMATreasurySuccessResolver.ASSERTION_ALREADY_ACTIVE.selector, assertionId)
        );
        resolver.assertSuccess(address(goalTreasury), "ipfs://second");
        vm.stopPrank();
    }

    function test_assertSuccess_revertsWhenTreasuryIsZeroAddress() public {
        vm.expectRevert(UMATreasurySuccessResolver.INVALID_TREASURY.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(0), "ipfs://invalid-treasury");
    }

    function test_assertSuccess_revertsWhenTreasuryHasNoCode() public {
        vm.expectRevert(UMATreasurySuccessResolver.INVALID_TREASURY.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(0xBEEF), "ipfs://no-code");
    }

    function test_assertSuccess_revertsWhenTreasuryResolverIsMismatched() public {
        goalTreasury.configure({
            resolver_: address(0xCAFE),
            liveness_: goalTreasury.successAssertionLiveness(),
            bond_: goalTreasury.successAssertionBond(),
            specHash_: goalTreasury.successOracleSpecHash(),
            policyHash_: goalTreasury.successAssertionPolicyHash(),
            deadline_: goalTreasury.deadline()
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.TREASURY_NOT_CONFIGURED_FOR_RESOLVER.selector,
                address(resolver),
                address(0xCAFE)
            )
        );
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(goalTreasury), "ipfs://resolver-mismatch");
    }

    function test_assertSuccess_revertsWhenAssertionConfigIsInvalid() public {
        goalTreasury.configure({
            resolver_: address(resolver),
            liveness_: 0,
            bond_: goalTreasury.successAssertionBond(),
            specHash_: goalTreasury.successOracleSpecHash(),
            policyHash_: goalTreasury.successAssertionPolicyHash(),
            deadline_: goalTreasury.deadline()
        });

        vm.expectRevert(UMATreasurySuccessResolver.INVALID_ASSERTION_CONFIG.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(goalTreasury), "ipfs://invalid-config");
    }

    function test_assertSuccess_revertsWhenTreasuryKindIsUnknown() public {
        address unknownKindTreasury = address(0xBEEF);
        vm.etch(unknownKindTreasury, hex"60006000fd");
        vm.mockCall(
            unknownKindTreasury,
            abi.encodeWithSelector(ISuccessAssertionTreasury.treasuryKind.selector),
            abi.encode(ISuccessAssertionTreasury.TreasuryKind.Unknown)
        );

        vm.expectRevert(UMATreasurySuccessResolver.INVALID_TREASURY.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(unknownKindTreasury, "ipfs://invalid-kind");

        assertEq(resolver.activeAssertionOfTreasury(unknownKindTreasury), bytes32(0));
        assertEq(usdc.balanceOf(address(mockOracle)), 0);
    }

    function test_assertSuccess_revertsWhenTreasuryKindIsOutOfRange() public {
        address invalidKindTreasury = address(0xC0DE);
        vm.etch(invalidKindTreasury, hex"60006000fd");
        vm.mockCall(
            invalidKindTreasury,
            abi.encodeWithSelector(ISuccessAssertionTreasury.treasuryKind.selector),
            abi.encode(uint8(3))
        );

        vm.expectRevert(UMATreasurySuccessResolver.INVALID_TREASURY.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(invalidKindTreasury, "ipfs://invalid-kind-out-of-range");
    }

    function test_assertSuccess_revertsWhenTreasuryKindCallReverts() public {
        address revertingKindTreasury = address(0xDEAD);
        vm.etch(revertingKindTreasury, hex"60006000fd");

        vm.expectRevert(UMATreasurySuccessResolver.INVALID_TREASURY.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(revertingKindTreasury, "ipfs://kind-call-revert");
    }

    function test_assertSuccess_revertsWhenTreasuryKindReturnDataLengthIsInvalid() public {
        address malformedKindTreasury = address(0xF00D);
        vm.etch(malformedKindTreasury, hex"60016000f3");

        vm.expectRevert(UMATreasurySuccessResolver.INVALID_TREASURY.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(malformedKindTreasury, "ipfs://kind-return-size-invalid");

        assertEq(resolver.activeAssertionOfTreasury(malformedKindTreasury), bytes32(0));
        assertEq(usdc.balanceOf(address(mockOracle)), 0);
    }

    function test_settleAndFinalize_truthful_appliesTreasurySuccess() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://truthful");

        mockOracle.setSettlementOutcome(assertionId, true, true);
        bool applied = resolver.settleAndFinalize(assertionId);

        assertTrue(applied);
        assertEq(goalTreasury.resolveSuccessCalls(), 1);
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 0);
        assertEq(goalTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), bytes32(0));

        (,,,, bool disputed, bool resolved_, bool truthful, bool finalized) = resolver.assertionMeta(assertionId);
        assertTrue(disputed);
        assertTrue(resolved_);
        assertTrue(truthful);
        assertTrue(finalized);
    }

    function test_settleAndFinalize_false_clearsPendingWithoutApplying() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://false-claim");

        mockOracle.setSettlementOutcome(assertionId, false, false);
        bool applied = resolver.settleAndFinalize(assertionId);

        assertFalse(applied);
        assertEq(goalTreasury.resolveSuccessCalls(), 0);
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 1);
        assertEq(goalTreasury.pendingSuccessAssertionId(), bytes32(0));
    }

    function test_settleAndFinalize_false_afterDeadline_cannotReassertSameTransaction() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://false-claim");
        mockOracle.setSettlementOutcome(assertionId, false, false);

        vm.warp(goalTreasury.deadline());
        bool applied = resolver.settleAndFinalize(assertionId);
        assertFalse(applied);
        assertEq(goalTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), bytes32(0));

        vm.expectRevert(MockGoalAssertionTreasury.INVALID_STATE.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(goalTreasury), "ipfs://reassert-after-deadline");
    }

    function test_settleAndFinalize_false_afterBudgetDeadline_cannotReassertSameTransaction() public {
        vm.warp(budgetTreasury.fundingDeadline());
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(budgetTreasury), "ipfs://budget-false-claim");
        mockOracle.setSettlementOutcome(assertionId, false, false);

        vm.warp(budgetTreasury.deadline());
        bool applied = resolver.settleAndFinalize(assertionId);
        assertFalse(applied);
        assertEq(budgetTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(resolver.activeAssertionOfTreasury(address(budgetTreasury)), bytes32(0));

        vm.expectRevert(MockBudgetAssertionTreasury.INVALID_STATE.selector);
        vm.prank(ASSERTER);
        resolver.assertSuccess(address(budgetTreasury), "ipfs://budget-reassert-after-deadline");
    }

    function test_settleAndFinalize_truthfulRevertsWhenTreasuryResolveFails_rollsBackSettlementState() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://truthful-revert");

        mockOracle.setSettlementOutcome(assertionId, true, false);
        goalTreasury.setResolveSuccessShouldRevert(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.TREASURY_RESOLVE_SUCCESS_FAILED.selector,
                address(goalTreasury),
                assertionId
            )
        );
        resolver.settleAndFinalize(assertionId);

        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), assertionId);
        assertEq(goalTreasury.pendingSuccessAssertionId(), assertionId);
        assertEq(goalTreasury.resolveSuccessCalls(), 0);
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 0);

        (,,,, bool disputed, bool resolved_, bool truthful, bool finalized) = resolver.assertionMeta(assertionId);
        assertFalse(disputed);
        assertFalse(resolved_);
        assertFalse(truthful);
        assertFalse(finalized);

        goalTreasury.setResolveSuccessShouldRevert(false);
        bool applied = resolver.settleAndFinalize(assertionId);
        assertTrue(applied);
    }

    function test_finalize_truthfulRevertsWhenTreasuryResolveFails() public {
        bytes32 assertionId = _assertSuccessAndSettle("ipfs://blocked", true, false);
        goalTreasury.setResolveSuccessShouldRevert(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.TREASURY_RESOLVE_SUCCESS_FAILED.selector,
                address(goalTreasury),
                assertionId
            )
        );
        resolver.finalize(assertionId);

        _assertResolverAndTreasuryStillPending(assertionId);
        assertEq(goalTreasury.resolveSuccessCalls(), 0);
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 0);
    }

    function test_finalize_falseRevertsWhenTreasuryClearFails() public {
        bytes32 assertionId = _assertSuccessAndSettle("ipfs://clear-blocked", false, false);
        goalTreasury.setClearSuccessAssertionShouldRevert(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.TREASURY_CLEAR_ASSERTION_FAILED.selector,
                address(goalTreasury),
                assertionId
            )
        );
        resolver.finalize(assertionId);

        _assertResolverAndTreasuryStillPending(assertionId);
        assertEq(goalTreasury.resolveSuccessCalls(), 0);
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 0);
    }

    function test_finalize_whenTreasuryPendingAssertionAlreadyCleared_skipsTreasuryCalls() public {
        bytes32 assertionId = _assertSuccessAndSettle("ipfs://precleared", true, false);

        vm.prank(address(resolver));
        goalTreasury.clearSuccessAssertion(assertionId);
        assertEq(goalTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 1);

        bool applied = resolver.finalize(assertionId);

        assertFalse(applied);
        assertEq(goalTreasury.resolveSuccessCalls(), 0);
        assertEq(goalTreasury.clearSuccessAssertionCalls(), 1);
        assertEq(goalTreasury.pendingSuccessAssertionId(), bytes32(0));
        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), bytes32(0));

        (,,,, bool disputed, bool resolved_, bool truthful, bool finalized) = resolver.assertionMeta(assertionId);
        assertFalse(disputed);
        assertTrue(resolved_);
        assertTrue(truthful);
        assertTrue(finalized);
    }

    function test_finalize_revertsWhenTreasuryPendingAssertionMismatches() public {
        bytes32 assertionId = _assertSuccessAndSettle("ipfs://mismatch", false, false);

        bytes32 otherAssertionId = keccak256("other-assertion");
        vm.startPrank(address(resolver));
        goalTreasury.clearSuccessAssertion(assertionId);
        goalTreasury.registerSuccessAssertion(otherAssertionId);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.TREASURY_PENDING_ASSERTION_MISMATCH.selector,
                assertionId,
                otherAssertionId
            )
        );
        resolver.finalize(assertionId);

        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), assertionId);
        assertEq(goalTreasury.pendingSuccessAssertionId(), otherAssertionId);
        (,,,,,,, bool finalized) = resolver.assertionMeta(assertionId);
        assertFalse(finalized);
    }

    function test_finalize_revertsWhenAssertionIsMissing() public {
        vm.expectRevert(UMATreasurySuccessResolver.ASSERTION_NOT_FOUND.selector);
        resolver.finalize(keccak256("missing-assertion"));
    }

    function test_finalize_revertsWhenAssertionIsNotResolved() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://not-resolved");

        vm.expectRevert(UMATreasurySuccessResolver.ASSERTION_NOT_RESOLVED.selector);
        resolver.finalize(assertionId);
    }

    function test_finalize_revertsWhenAssertionAlreadyFinalized() public {
        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(goalTreasury), "ipfs://double-finalize");
        mockOracle.setSettlementOutcome(assertionId, false, false);
        resolver.settleAndFinalize(assertionId);

        vm.expectRevert(UMATreasurySuccessResolver.ASSERTION_ALREADY_FINALIZED.selector);
        resolver.finalize(assertionId);
    }

    function test_finalize_revertsWhenAssertionIsNotActiveOnTreasury() public {
        bytes32 assertionId = _assertSuccessAndSettle("ipfs://inactive-assertion", true, false);
        bytes32 differentAssertionId = keccak256("different-active-assertion");

        bytes32 activeSlot = _findActiveAssertionStorageSlot(address(goalTreasury), assertionId);
        vm.store(address(resolver), activeSlot, differentAssertionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                UMATreasurySuccessResolver.ASSERTION_NOT_ACTIVE.selector,
                assertionId,
                differentAssertionId
            )
        );
        resolver.finalize(assertionId);
    }

    function test_settleAndFinalize_revertsWhenAssertionIsMissing() public {
        vm.expectRevert(UMATreasurySuccessResolver.ASSERTION_NOT_FOUND.selector);
        resolver.settleAndFinalize(keccak256("missing-assertion"));
    }

    function test_assertionResolvedCallback_revertsWhenCallerIsNotOracle() public {
        vm.expectRevert(UMATreasurySuccessResolver.ONLY_ORACLE.selector);
        resolver.assertionResolvedCallback(keccak256("not-oracle"), true);
    }

    function test_assertionResolvedCallback_noopsWhenAssertionIsUnknown() public {
        vm.prank(address(mockOracle));
        resolver.assertionResolvedCallback(keccak256("unknown"), true);
    }

    function test_assertionDisputedCallback_revertsWhenCallerIsNotOracle() public {
        vm.expectRevert(UMATreasurySuccessResolver.ONLY_ORACLE.selector);
        resolver.assertionDisputedCallback(keccak256("not-oracle"));
    }

    function test_assertionDisputedCallback_noopsWhenAssertionIsUnknown() public {
        vm.prank(address(mockOracle));
        resolver.assertionDisputedCallback(keccak256("unknown"));
    }

    function test_assertSuccess_detectsBudgetTreasuryKind() public {
        vm.warp(budgetTreasury.fundingDeadline());

        vm.prank(ASSERTER);
        bytes32 assertionId = resolver.assertSuccess(address(budgetTreasury), "ipfs://budget-proof");

        (,,, ISuccessAssertionTreasury.TreasuryKind kind,,,,) = resolver.assertionMeta(assertionId);
        assertEq(uint8(kind), uint8(ISuccessAssertionTreasury.TreasuryKind.Budget));

        string memory claim = mockOracle.lastClaim();
        assertTrue(_contains(claim, "type: BUDGET"));
    }

    function test_finalize_blocksCrossFunctionReentrancyAcrossGuardedEntrypoints() public {
        MockGoalAssertionTreasury assertTargetTreasury = _newConfiguredGoalTreasury();
        MockGoalAssertionTreasury settleTargetTreasury = _newConfiguredGoalTreasury();
        MockGoalAssertionTreasury finalizeTargetTreasury = _newConfiguredGoalTreasury();
        MockGoalAssertionTreasury settleAndFinalizeTargetTreasury = _newConfiguredGoalTreasury();

        MockReentrantGoalAssertionTreasury reentrantTreasury = new MockReentrantGoalAssertionTreasury(address(resolver));
        reentrantTreasury.configure({
            resolver_: address(resolver),
            liveness_: 12 hours,
            bond_: 100e6,
            specHash_: SPEC_HASH,
            policyHash_: POLICY_HASH,
            deadline_: uint64(block.timestamp + 7 days)
        });

        usdc.mint(address(reentrantTreasury), 1_000e6);
        reentrantTreasury.approveAssertionCurrency(IERC20(address(usdc)), address(resolver), type(uint256).max);

        vm.startPrank(ASSERTER);
        bytes32 settleTargetAssertionId = resolver.assertSuccess(address(settleTargetTreasury), "ipfs://settle-target");
        bytes32 finalizeTargetAssertionId = resolver.assertSuccess(address(finalizeTargetTreasury), "ipfs://finalize-target");
        bytes32 settleAndFinalizeTargetAssertionId =
            resolver.assertSuccess(address(settleAndFinalizeTargetTreasury), "ipfs://settle-and-finalize-target");
        vm.stopPrank();

        mockOracle.setSettlementOutcome(finalizeTargetAssertionId, true, false);
        resolver.settle(finalizeTargetAssertionId);

        vm.prank(ASSERTER);
        bytes32 outerAssertionId = resolver.assertSuccess(address(reentrantTreasury), "ipfs://outer");
        mockOracle.setSettlementOutcome(outerAssertionId, true, false);
        resolver.settle(outerAssertionId);

        reentrantTreasury.configureReentryTargets({
            assertSuccessTargetTreasury_: address(assertTargetTreasury),
            settleTargetAssertionId_: settleTargetAssertionId,
            finalizeTargetAssertionId_: finalizeTargetAssertionId,
            settleAndFinalizeTargetAssertionId_: settleAndFinalizeTargetAssertionId
        });

        bool applied = resolver.finalize(outerAssertionId);
        assertTrue(applied);

        assertTrue(reentrantTreasury.reentryAttempted());
        assertTrue(reentrantTreasury.assertSuccessBlocked());
        assertTrue(reentrantTreasury.settleBlocked());
        assertTrue(reentrantTreasury.finalizeBlocked());
        assertTrue(reentrantTreasury.settleAndFinalizeBlocked());

        assertEq(resolver.activeAssertionOfTreasury(address(assertTargetTreasury)), bytes32(0));
        assertEq(assertTargetTreasury.pendingSuccessAssertionId(), bytes32(0));

        assertEq(resolver.activeAssertionOfTreasury(address(settleTargetTreasury)), settleTargetAssertionId);
        assertEq(settleTargetTreasury.pendingSuccessAssertionId(), settleTargetAssertionId);
        (,,,, bool settleDisputed, bool settleResolved, bool settleTruthful, bool settleFinalized) =
            resolver.assertionMeta(settleTargetAssertionId);
        assertFalse(settleDisputed);
        assertFalse(settleResolved);
        assertFalse(settleTruthful);
        assertFalse(settleFinalized);

        assertEq(resolver.activeAssertionOfTreasury(address(finalizeTargetTreasury)), finalizeTargetAssertionId);
        assertEq(finalizeTargetTreasury.pendingSuccessAssertionId(), finalizeTargetAssertionId);
        assertEq(finalizeTargetTreasury.resolveSuccessCalls(), 0);
        (,,,, bool finalizeDisputed, bool finalizeResolved, bool finalizeTruthful, bool finalizeFinalized) =
            resolver.assertionMeta(finalizeTargetAssertionId);
        assertFalse(finalizeDisputed);
        assertTrue(finalizeResolved);
        assertTrue(finalizeTruthful);
        assertFalse(finalizeFinalized);

        assertEq(
            resolver.activeAssertionOfTreasury(address(settleAndFinalizeTargetTreasury)),
            settleAndFinalizeTargetAssertionId
        );
        assertEq(
            settleAndFinalizeTargetTreasury.pendingSuccessAssertionId(),
            settleAndFinalizeTargetAssertionId
        );
        (,,,, bool settleAndFinalizeDisputed, bool settleAndFinalizeResolved, bool settleAndFinalizeTruthful, bool
            settleAndFinalizeFinalized) = resolver.assertionMeta(settleAndFinalizeTargetAssertionId);
        assertFalse(settleAndFinalizeDisputed);
        assertFalse(settleAndFinalizeResolved);
        assertFalse(settleAndFinalizeTruthful);
        assertFalse(settleAndFinalizeFinalized);
    }

    function _stringOfLength(uint256 length) internal pure returns (string memory value) {
        bytes memory buffer = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            buffer[i] = bytes1("a");
        }
        value = string(buffer);
    }

    function _newConfiguredGoalTreasury() internal returns (MockGoalAssertionTreasury treasury) {
        treasury = new MockGoalAssertionTreasury();
        treasury.configure({
            resolver_: address(resolver),
            liveness_: 12 hours,
            bond_: 100e6,
            specHash_: SPEC_HASH,
            policyHash_: POLICY_HASH,
            deadline_: uint64(block.timestamp + 7 days)
        });
    }

    function _assertSuccessAndSettle(string memory evidence, bool truthful, bool disputed)
        internal
        returns (bytes32 assertionId)
    {
        vm.prank(ASSERTER);
        assertionId = resolver.assertSuccess(address(goalTreasury), evidence);
        mockOracle.setSettlementOutcome(assertionId, truthful, disputed);
        resolver.settle(assertionId);
    }

    function _assertResolverAndTreasuryStillPending(bytes32 assertionId) internal view {
        assertEq(resolver.activeAssertionOfTreasury(address(goalTreasury)), assertionId);
        assertEq(goalTreasury.pendingSuccessAssertionId(), assertionId);
        (,,,,,,, bool finalized) = resolver.assertionMeta(assertionId);
        assertFalse(finalized);
    }

    function _findActiveAssertionStorageSlot(address treasury, bytes32 expectedAssertionId)
        internal
        view
        returns (bytes32 slot)
    {
        for (uint256 mappingSlot = 0; mappingSlot < 8; mappingSlot++) {
            bytes32 candidate = keccak256(abi.encode(treasury, mappingSlot));
            if (vm.load(address(resolver), candidate) == expectedAssertionId) {
                return candidate;
            }
        }

        revert("ACTIVE_ASSERTION_SLOT_NOT_FOUND");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;

        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matchFound = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) return true;
        }
        return false;
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockOptimisticOracleV3 {
    error ASSERTION_NOT_FOUND();
    error ALREADY_SETTLED();

    struct Assertion {
        address callbackRecipient;
        bool truthful;
        bool disputed;
        bool settled;
    }

    IERC20 public immutable token;
    uint256 public minimumBond = 1;

    uint64 public lastLiveness;
    uint256 public lastBond;
    bytes32 public lastIdentifier;
    bytes32 public lastDomainId;
    address public lastAsserter;
    address public lastEscalationManager;
    bytes public lastClaimBytes;

    bytes32 public lastSyncedIdentifier;
    address public lastSyncedCurrency;

    uint256 internal _nonce;
    mapping(bytes32 => Assertion) internal _assertions;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setMinimumBond(uint256 minimumBond_) external {
        minimumBond = minimumBond_;
    }

    function setSettlementOutcome(bytes32 assertionId, bool truthful, bool disputed) external {
        Assertion storage assertion = _assertions[assertionId];
        if (assertion.callbackRecipient == address(0)) revert ASSERTION_NOT_FOUND();

        assertion.truthful = truthful;
        assertion.disputed = disputed;
    }

    function lastClaim() external view returns (string memory) {
        return string(lastClaimBytes);
    }

    function syncUmaParams(bytes32 identifier, address currency) external {
        lastSyncedIdentifier = identifier;
        lastSyncedCurrency = currency;
    }

    function getMinimumBond(address) external view returns (uint256) {
        return minimumBond;
    }

    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId) {
        currency.transferFrom(msg.sender, address(this), bond);

        _nonce += 1;
        assertionId = keccak256(abi.encodePacked("assertion", _nonce));
        _assertions[assertionId] = Assertion({
            callbackRecipient: callbackRecipient,
            truthful: true,
            disputed: false,
            settled: false
        });

        lastClaimBytes = claim;
        lastAsserter = asserter;
        lastEscalationManager = escalationManager;
        lastLiveness = liveness;
        lastBond = bond;
        lastIdentifier = identifier;
        lastDomainId = domainId;
    }

    function settleAssertion(bytes32 assertionId) external {
        Assertion storage assertion = _assertions[assertionId];
        if (assertion.callbackRecipient == address(0)) revert ASSERTION_NOT_FOUND();
        if (assertion.settled) revert ALREADY_SETTLED();

        assertion.settled = true;

        if (assertion.disputed) {
            OptimisticOracleV3CallbackRecipientInterface(assertion.callbackRecipient).assertionDisputedCallback(assertionId);
        }
        OptimisticOracleV3CallbackRecipientInterface(assertion.callbackRecipient).assertionResolvedCallback(
            assertionId, assertion.truthful
        );
    }
}

contract MockGoalAssertionTreasury is ISuccessAssertionTreasury {
    error ONLY_RESOLVER();
    error INVALID_STATE();

    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;

    uint64 public deadline;
    uint64 public minRaiseDeadline;
    uint64 public pendingSuccessAssertionAt;

    bytes32 internal _pendingAssertionId;
    bool public resolveSuccessShouldRevert;
    bool public clearSuccessAssertionShouldRevert;

    uint256 public resolveSuccessCalls;
    uint256 public clearSuccessAssertionCalls;

    function configure(
        address resolver_,
        uint64 liveness_,
        uint256 bond_,
        bytes32 specHash_,
        bytes32 policyHash_,
        uint64 deadline_
    ) external {
        successResolver = resolver_;
        successAssertionLiveness = liveness_;
        successAssertionBond = bond_;
        successOracleSpecHash = specHash_;
        successAssertionPolicyHash = policyHash_;
        deadline = deadline_;
        minRaiseDeadline = deadline_ - 1;
    }

    function setResolveSuccessShouldRevert(bool value) external {
        resolveSuccessShouldRevert = value;
    }

    function setClearSuccessAssertionShouldRevert(bool value) external {
        clearSuccessAssertionShouldRevert = value;
    }

    function pendingSuccessAssertionId() external view returns (bytes32) {
        return _pendingAssertionId;
    }

    function treasuryKind() external pure override returns (ISuccessAssertionTreasury.TreasuryKind) {
        return ISuccessAssertionTreasury.TreasuryKind.Goal;
    }

    function registerSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (assertionId == bytes32(0)) revert INVALID_STATE();
        if (_pendingAssertionId != bytes32(0)) revert INVALID_STATE();
        if (block.timestamp >= deadline) revert INVALID_STATE();

        _pendingAssertionId = assertionId;
        pendingSuccessAssertionAt = uint64(block.timestamp);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (clearSuccessAssertionShouldRevert) revert INVALID_STATE();
        if (_pendingAssertionId != assertionId) revert INVALID_STATE();

        delete _pendingAssertionId;
        delete pendingSuccessAssertionAt;
        clearSuccessAssertionCalls += 1;
    }

    function resolveSuccess() external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (resolveSuccessShouldRevert) revert INVALID_STATE();
        if (_pendingAssertionId == bytes32(0)) revert INVALID_STATE();

        delete _pendingAssertionId;
        delete pendingSuccessAssertionAt;
        resolveSuccessCalls += 1;
    }
}

contract MockBudgetAssertionTreasury is ISuccessAssertionTreasury {
    error ONLY_RESOLVER();
    error INVALID_STATE();

    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;

    uint64 public fundingDeadline;
    uint64 public deadline;
    uint64 public pendingSuccessAssertionAt;

    bytes32 internal _pendingAssertionId;

    function configure(
        address resolver_,
        uint64 liveness_,
        uint256 bond_,
        bytes32 specHash_,
        bytes32 policyHash_,
        uint64 fundingDeadline_,
        uint64 deadline_
    ) external {
        successResolver = resolver_;
        successAssertionLiveness = liveness_;
        successAssertionBond = bond_;
        successOracleSpecHash = specHash_;
        successAssertionPolicyHash = policyHash_;
        fundingDeadline = fundingDeadline_;
        deadline = deadline_;
    }

    function pendingSuccessAssertionId() external view returns (bytes32) {
        return _pendingAssertionId;
    }

    function treasuryKind() external pure override returns (ISuccessAssertionTreasury.TreasuryKind) {
        return ISuccessAssertionTreasury.TreasuryKind.Budget;
    }

    function registerSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (assertionId == bytes32(0)) revert INVALID_STATE();
        if (_pendingAssertionId != bytes32(0)) revert INVALID_STATE();
        if (block.timestamp < fundingDeadline || block.timestamp >= deadline) revert INVALID_STATE();

        _pendingAssertionId = assertionId;
        pendingSuccessAssertionAt = uint64(block.timestamp);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (_pendingAssertionId != assertionId) revert INVALID_STATE();

        delete _pendingAssertionId;
        delete pendingSuccessAssertionAt;
    }

    function resolveSuccess() external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (_pendingAssertionId == bytes32(0)) revert INVALID_STATE();

        delete _pendingAssertionId;
        delete pendingSuccessAssertionAt;
    }
}

contract MockReentrantGoalAssertionTreasury is ISuccessAssertionTreasury {
    error ONLY_RESOLVER();
    error INVALID_STATE();
    error INVALID_REENTRY_RESULTS();

    bytes4 internal constant REENTRANCY_GUARD_REENTRANT_CALL_SELECTOR =
        bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;

    uint64 public deadline;
    uint64 public pendingSuccessAssertionAt;

    bytes32 internal _pendingAssertionId;

    address public assertSuccessTargetTreasury;
    bytes32 public settleTargetAssertionId;
    bytes32 public finalizeTargetAssertionId;
    bytes32 public settleAndFinalizeTargetAssertionId;

    bool public reentryAttempted;
    bool public assertSuccessBlocked;
    bool public settleBlocked;
    bool public finalizeBlocked;
    bool public settleAndFinalizeBlocked;

    uint256 public resolveSuccessCalls;
    uint256 public clearSuccessAssertionCalls;

    constructor(address resolver_) {
        successResolver = resolver_;
    }

    function configure(
        address resolver_,
        uint64 liveness_,
        uint256 bond_,
        bytes32 specHash_,
        bytes32 policyHash_,
        uint64 deadline_
    ) external {
        successResolver = resolver_;
        successAssertionLiveness = liveness_;
        successAssertionBond = bond_;
        successOracleSpecHash = specHash_;
        successAssertionPolicyHash = policyHash_;
        deadline = deadline_;
    }

    function configureReentryTargets(
        address assertSuccessTargetTreasury_,
        bytes32 settleTargetAssertionId_,
        bytes32 finalizeTargetAssertionId_,
        bytes32 settleAndFinalizeTargetAssertionId_
    ) external {
        assertSuccessTargetTreasury = assertSuccessTargetTreasury_;
        settleTargetAssertionId = settleTargetAssertionId_;
        finalizeTargetAssertionId = finalizeTargetAssertionId_;
        settleAndFinalizeTargetAssertionId = settleAndFinalizeTargetAssertionId_;
    }

    function approveAssertionCurrency(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function pendingSuccessAssertionId() external view returns (bytes32) {
        return _pendingAssertionId;
    }

    function treasuryKind() external pure override returns (ISuccessAssertionTreasury.TreasuryKind) {
        return ISuccessAssertionTreasury.TreasuryKind.Goal;
    }

    function registerSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (assertionId == bytes32(0)) revert INVALID_STATE();
        if (_pendingAssertionId != bytes32(0)) revert INVALID_STATE();
        if (block.timestamp >= deadline) revert INVALID_STATE();

        _pendingAssertionId = assertionId;
        pendingSuccessAssertionAt = uint64(block.timestamp);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (_pendingAssertionId != assertionId) revert INVALID_STATE();

        delete _pendingAssertionId;
        delete pendingSuccessAssertionAt;
        clearSuccessAssertionCalls += 1;
    }

    function resolveSuccess() external override {
        if (msg.sender != successResolver) revert ONLY_RESOLVER();
        if (_pendingAssertionId == bytes32(0)) revert INVALID_STATE();

        reentryAttempted = true;
        assertSuccessBlocked = _attemptReentry(
            abi.encodeCall(
                UMATreasurySuccessResolver.assertSuccess,
                (assertSuccessTargetTreasury, "ipfs://reentry-assert-success")
            )
        );
        settleBlocked =
            _attemptReentry(abi.encodeCall(UMATreasurySuccessResolver.settle, (settleTargetAssertionId)));
        finalizeBlocked =
            _attemptReentry(abi.encodeCall(UMATreasurySuccessResolver.finalize, (finalizeTargetAssertionId)));
        settleAndFinalizeBlocked = _attemptReentry(
            abi.encodeCall(
                UMATreasurySuccessResolver.settleAndFinalize,
                (settleAndFinalizeTargetAssertionId)
            )
        );
        if (!(assertSuccessBlocked && settleBlocked && finalizeBlocked && settleAndFinalizeBlocked)) {
            revert INVALID_REENTRY_RESULTS();
        }

        delete _pendingAssertionId;
        delete pendingSuccessAssertionAt;
        resolveSuccessCalls += 1;
    }

    function _attemptReentry(bytes memory payload) internal returns (bool blockedByReentrancyGuard) {
        (bool success, bytes memory returnData) = successResolver.call(payload);
        if (success || returnData.length < 4) return false;

        bytes4 selector;
        assembly {
            selector := mload(add(returnData, 32))
        }
        blockedByReentrancyGuard = selector == REENTRANCY_GUARD_REENTRANT_CALL_SELECTOR;
    }
}
