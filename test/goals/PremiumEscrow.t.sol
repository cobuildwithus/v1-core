// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract PremiumEscrowTest is Test {
    uint32 internal constant SLASH_PPM = 200_000; // 20%

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    PremiumEscrowMockToken internal premiumToken;
    PremiumEscrowMockBudgetStakeLedger internal ledger;
    PremiumEscrowMockBudgetTreasury internal budgetTreasury;
    PremiumEscrowMockGoalFlow internal goalFlow;
    PremiumEscrowMockRouter internal router;
    PremiumEscrow internal escrow;

    function setUp() public {
        premiumToken = new PremiumEscrowMockToken();
        ledger = new PremiumEscrowMockBudgetStakeLedger();
        budgetTreasury = new PremiumEscrowMockBudgetTreasury(address(premiumToken));
        goalFlow = new PremiumEscrowMockGoalFlow(address(premiumToken));
        router = new PremiumEscrowMockRouter();

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(
            address(budgetTreasury),
            address(ledger),
            address(goalFlow),
            address(router),
            SLASH_PPM
        );
    }

    function test_initializeRevertsWhenSuperTokenMismatch() public {
        PremiumEscrowMockToken otherToken = new PremiumEscrowMockToken();
        PremiumEscrowMockBudgetTreasury mismatchedBudgetTreasury = new PremiumEscrowMockBudgetTreasury(address(otherToken));

        PremiumEscrow implementation = new PremiumEscrow();
        PremiumEscrow mismatchedEscrow = PremiumEscrow(Clones.clone(address(implementation)));

        vm.expectRevert(
            abi.encodeWithSelector(
                PremiumEscrow.SUPER_TOKEN_MISMATCH.selector, address(premiumToken), address(otherToken)
            )
        );
        mismatchedEscrow.initialize(
            address(mismatchedBudgetTreasury),
            address(ledger),
            address(goalFlow),
            address(router),
            SLASH_PPM
        );
    }

    function test_premiumAccrualCoverageIncreaseDecrease_splitsCorrectly() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        ledger.setCoverage(BOB, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);
        assertEq(escrow.totalCoverage(), 200);

        premiumToken.mint(address(escrow), 200e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        ledger.setCoverage(ALICE, address(budgetTreasury), 150);
        escrow.checkpoint(ALICE);
        assertEq(escrow.totalCoverage(), 250);

        premiumToken.mint(address(escrow), 250e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        ledger.setCoverage(ALICE, address(budgetTreasury), 50);
        escrow.checkpoint(ALICE);
        assertEq(escrow.totalCoverage(), 150);

        premiumToken.mint(address(escrow), 150e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        vm.prank(ALICE);
        uint256 aliceClaim = escrow.claim(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = escrow.claim(BOB);

        assertEq(aliceClaim, 300e18);
        assertEq(bobClaim, 300e18);
        assertEq(premiumToken.balanceOf(ALICE), 300e18);
        assertEq(premiumToken.balanceOf(BOB), 300e18);
    }

    function test_premiumFairnessUnderChurn_alternatingCoverageMatchesArrivalPeriodShares() public {
        // Period 1: ALICE 100%, BOB 0%.
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        ledger.setCoverage(BOB, address(budgetTreasury), 0);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 100e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        // Period 2: ALICE 25%, BOB 75%.
        ledger.setCoverage(ALICE, address(budgetTreasury), 25);
        ledger.setCoverage(BOB, address(budgetTreasury), 75);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 200e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        // Period 3: ALICE 80%, BOB 20%.
        ledger.setCoverage(ALICE, address(budgetTreasury), 80);
        ledger.setCoverage(BOB, address(budgetTreasury), 20);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 300e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        // Period 4: ALICE 0%, BOB 100%.
        ledger.setCoverage(ALICE, address(budgetTreasury), 0);
        ledger.setCoverage(BOB, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 400e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        uint256 aliceExpected = 390e18; // 100 + 50 + 240 + 0
        uint256 bobExpected = 610e18; // 0 + 150 + 60 + 400

        assertEq(escrow.claimable(ALICE), aliceExpected);
        assertEq(escrow.claimable(BOB), bobExpected);

        vm.prank(ALICE);
        uint256 aliceClaim = escrow.claim(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = escrow.claim(BOB);

        assertEq(aliceClaim, aliceExpected);
        assertEq(bobClaim, bobExpected);
        assertEq(premiumToken.balanceOf(ALICE), aliceExpected);
        assertEq(premiumToken.balanceOf(BOB), bobExpected);
    }

    function test_premiumIndexUsesOldTotalCoverageOnCheckpoint() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        ledger.setCoverage(BOB, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 200e18);

        // Coverage change is already written in ledger before checkpoint.
        ledger.setCoverage(ALICE, address(budgetTreasury), 0);

        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        assertEq(escrow.claimable(ALICE), 100e18);
        assertEq(escrow.claimable(BOB), 100e18);
    }

    function test_claimIsIdempotentAndNeverOverpays() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        premiumToken.mint(address(escrow), 50e18);

        vm.prank(ALICE);
        uint256 firstClaim = escrow.claim(ALICE);
        vm.prank(ALICE);
        uint256 secondClaim = escrow.claim(ALICE);

        assertEq(firstClaim, 50e18);
        assertEq(secondClaim, 0);
        assertEq(premiumToken.balanceOf(ALICE), 50e18);

        premiumToken.mint(address(escrow), 25e18);
        vm.prank(ALICE);
        uint256 thirdClaim = escrow.claim(ALICE);

        assertEq(thirdClaim, 25e18);
        assertEq(premiumToken.balanceOf(ALICE), 75e18);
    }

    function test_exposureIntegralTracksPiecewiseCoverageAndClampsOnClose() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        budgetTreasury.setActivatedAt(10);

        vm.warp(15);
        escrow.checkpoint(ALICE);
        assertEq(escrow.exposureIntegral(ALICE), 500);

        ledger.setCoverage(ALICE, address(budgetTreasury), 40);
        escrow.checkpoint(ALICE);

        vm.warp(25);
        escrow.checkpoint(ALICE);
        assertEq(escrow.exposureIntegral(ALICE), 900);

        vm.warp(35);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 30);

        escrow.checkpoint(ALICE);
        assertEq(escrow.exposureIntegral(ALICE), 1100);
    }

    function test_slashComputesAverageCoverageWeightAndIsIdempotent() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        budgetTreasury.setActivatedAt(10);

        vm.warp(20);
        ledger.setCoverage(ALICE, address(budgetTreasury), 200);
        escrow.checkpoint(ALICE);

        vm.warp(35);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 30);

        uint256 firstSlash = escrow.slash(ALICE);
        uint256 secondSlash = escrow.slash(ALICE);

        // E = 100*(20-10) + 200*(30-20) = 3000; D = 20; avg = 150; slash = avg * 20% = 30.
        assertEq(firstSlash, 30);
        assertEq(secondSlash, 0);
        assertEq(escrow.exposureIntegral(ALICE), 3000);
        assertTrue(escrow.slashed(ALICE));

        assertEq(router.slashCalls(), 1);
        assertEq(router.lastUnderwriter(), ALICE);
        assertEq(router.lastWeight(), 30);
    }

    function test_slashFairness_withCoverageIncreaseAndDecrease_matchesAverageCoverageTimesSlashPpm() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        vm.warp(20);
        escrow.checkpoint(ALICE);
        ledger.setCoverage(ALICE, address(budgetTreasury), 220);
        escrow.checkpoint(ALICE);

        vm.warp(35);
        escrow.checkpoint(ALICE);
        ledger.setCoverage(ALICE, address(budgetTreasury), 40);
        escrow.checkpoint(ALICE);

        vm.warp(45);
        escrow.checkpoint(ALICE);
        ledger.setCoverage(ALICE, address(budgetTreasury), 160);
        escrow.checkpoint(ALICE);

        vm.warp(70);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 70);

        uint256 slashWeight = escrow.slash(ALICE);

        uint256 expectedExposure = 100 * 10 + 220 * 15 + 40 * 10 + 160 * 25; // 8,700
        uint256 expectedDuration = 60;
        uint256 expectedAverageCoverage = expectedExposure / expectedDuration; // 145
        uint256 expectedSlashWeight = (expectedAverageCoverage * SLASH_PPM) / 1_000_000; // 29

        assertEq(escrow.exposureIntegral(ALICE), expectedExposure);
        assertEq(slashWeight, expectedSlashWeight);
        assertEq(router.slashCalls(), 1);
        assertEq(router.lastWeight(), expectedSlashWeight);
    }

    function test_slashRevertsWhenBudgetWasNeverActivated() public {
        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Expired, 0, 20);

        vm.expectRevert(PremiumEscrow.NOT_SLASHABLE.selector);
        escrow.slash(ALICE);
    }

    function test_closeOnlyBudgetTreasury_idempotentForSameArgs_revertsForMismatchedReplay() public {
        vm.warp(20);

        vm.expectRevert(PremiumEscrow.ONLY_BUDGET_TREASURY.selector);
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        assertTrue(escrow.closed());
        assertEq(uint256(escrow.finalState()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertEq(escrow.activatedAt(), 10);
        assertEq(escrow.closedAt(), 20);

        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 20);

        vm.expectRevert(PremiumEscrow.ALREADY_CLOSED.selector);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 10, 21);
    }

    function test_closeRejectsInvalidStateTimestampAndWindow() public {
        vm.warp(50);

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_STATE.selector, IBudgetTreasury.BudgetState.Active)
        );
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Active, 10, 40);

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_TIMESTAMP.selector, uint64(0)));
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 0);

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_TIMESTAMP.selector, uint64(51)));
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 51);

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_CLOSE_WINDOW.selector, uint64(41), uint64(40)));
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 41, 40);
    }

    function test_closeCheckpointsPendingPremiumBeforeFreeze() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        ledger.setCoverage(BOB, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 200e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.prank(ALICE);
        uint256 aliceClaim = escrow.claim(ALICE);
        vm.prank(BOB);
        uint256 bobClaim = escrow.claim(BOB);

        assertEq(aliceClaim, 100e18);
        assertEq(bobClaim, 100e18);
        assertEq(premiumToken.balanceOf(address(escrow)), 0);
    }

    function test_postClosePremium_characterization_recycledAndDoesNotIncreaseClaimable() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        ledger.setCoverage(BOB, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        premiumToken.mint(address(escrow), 200e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);
        assertEq(escrow.claimable(ALICE), 100e18);
        assertEq(escrow.claimable(BOB), 100e18);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        uint256 aliceBefore = escrow.claimable(ALICE);
        uint256 bobBefore = escrow.claimable(BOB);
        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));

        // Strict invariant: premium that arrives after close should not accrue to underwriters.
        premiumToken.mint(address(escrow), 80e18);
        escrow.checkpoint(ALICE);
        escrow.checkpoint(BOB);

        assertEq(escrow.claimable(ALICE), aliceBefore);
        assertEq(escrow.claimable(BOB), bobBefore);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 80e18);
    }

    function test_claimHandlesEscrowBalanceShortfallWithoutOverpaying() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        premiumToken.mint(address(escrow), 100e18);
        escrow.checkpoint(ALICE);
        assertEq(escrow.claimable(ALICE), 100e18);

        deal(address(premiumToken), address(escrow), 40e18);

        vm.prank(ALICE);
        uint256 firstClaim = escrow.claim(ALICE);
        assertEq(firstClaim, 40e18);
        assertEq(escrow.claimable(ALICE), 60e18);
        assertEq(escrow.accountedBalance(), 0);

        premiumToken.mint(address(escrow), 60e18);

        vm.prank(ALICE);
        uint256 secondClaim = escrow.claim(ALICE);
        assertEq(secondClaim, 60e18);
        assertEq(escrow.claimable(ALICE), 60e18);
        assertEq(premiumToken.balanceOf(ALICE), 100e18);
    }

    function test_slashRevertsWhenNotClosed_orWhenFinalStateNotSlashable() public {
        vm.expectRevert(PremiumEscrow.NOT_CLOSED.selector);
        escrow.slash(ALICE);

        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(10);

        vm.warp(20);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Succeeded, 10, 20);

        vm.expectRevert(PremiumEscrow.NOT_SLASHABLE.selector);
        escrow.slash(ALICE);
    }

    function test_slashZeroDurationMarksUnderwriterWithoutRouterCall() public {
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);
        budgetTreasury.setActivatedAt(20);

        vm.warp(25);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Failed, 20, 20);

        uint256 slashWeight = escrow.slash(ALICE);
        assertEq(slashWeight, 0);
        assertTrue(escrow.slashed(ALICE));
        assertEq(router.slashCalls(), 0);
    }

    function test_orphanPremiumIsRecycledWhenCoverageIsZero() public {
        premiumToken.mint(address(escrow), 77e18);
        escrow.checkpoint(ALICE);

        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(address(goalFlow)), 77e18);
        assertEq(escrow.accountedBalance(), 0);
    }
}

contract PremiumEscrowMockToken is ERC20 {
    constructor() ERC20("PremiumToken", "PRM") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PremiumEscrowMockBudgetStakeLedger {
    mapping(address => mapping(address => uint256)) internal _coverageByBudget;
    mapping(address => uint256) internal _totalCoverageByBudget;

    function setCoverage(address account, address budget, uint256 coverage) external {
        uint256 current = _coverageByBudget[account][budget];
        if (coverage > current) {
            _totalCoverageByBudget[budget] += coverage - current;
        } else if (current > coverage) {
            _totalCoverageByBudget[budget] -= current - coverage;
        }
        _coverageByBudget[account][budget] = coverage;
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256) {
        return _coverageByBudget[account][budget];
    }

    function budgetTotalAllocatedStake(address budget) external view returns (uint256) {
        return _totalCoverageByBudget[budget];
    }
}

contract PremiumEscrowMockBudgetTreasury {
    ISuperToken internal _superToken;
    uint64 public activatedAt;

    constructor(address superToken_) {
        _superToken = ISuperToken(superToken_);
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        activatedAt = activatedAt_;
    }
}

contract PremiumEscrowMockGoalFlow {
    ISuperToken internal _superToken;

    constructor(address superToken_) {
        _superToken = ISuperToken(superToken_);
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }
}

contract PremiumEscrowMockRouter {
    address public lastUnderwriter;
    uint256 public lastWeight;
    uint256 public slashCalls;

    function slashUnderwriter(address underwriter, uint256 weight) external {
        lastUnderwriter = underwriter;
        lastWeight = weight;
        slashCalls++;
    }
}
