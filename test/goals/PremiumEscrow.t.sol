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
    address internal constant GOAL_FUNDING_PATH = address(0xF00D);

    PremiumEscrowMockToken internal premiumToken;
    PremiumEscrowMockBudgetStakeLedger internal ledger;
    PremiumEscrowMockBudgetTreasury internal budgetTreasury;
    PremiumEscrowMockRouter internal router;
    PremiumEscrow internal escrow;

    function setUp() public {
        premiumToken = new PremiumEscrowMockToken();
        ledger = new PremiumEscrowMockBudgetStakeLedger();
        budgetTreasury = new PremiumEscrowMockBudgetTreasury(address(premiumToken));
        router = new PremiumEscrowMockRouter();

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(
            address(budgetTreasury),
            address(ledger),
            GOAL_FUNDING_PATH,
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

    function test_slashRevertsWhenBudgetWasNeverActivated() public {
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Expired, 0, 20);

        vm.expectRevert(PremiumEscrow.NOT_SLASHABLE.selector);
        escrow.slash(ALICE);
    }

    function test_orphanPremiumIsRecycledWhenCoverageIsZero() public {
        premiumToken.mint(address(escrow), 77e18);
        escrow.checkpoint(ALICE);

        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(GOAL_FUNDING_PATH), 77e18);
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
