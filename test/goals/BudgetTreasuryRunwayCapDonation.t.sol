// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";

/// @dev Minimal SuperToken stub for `BudgetTreasury.treasuryBalance()` in tests.
contract MockSuperToken {
    mapping(address => uint256) internal _balance;

    function setBalance(address account, uint256 amount) external {
        _balance[account] = amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balance[account];
    }
}

contract MockParentFlow {
    function getMemberFlowRate(address) external pure returns (int96) {
        return 0;
    }
}

/// @dev Minimal Flow stub for `BudgetTreasury.initialize` checks.
contract MockFlow {
    address internal _superToken;
    address internal _flowOperator;
    address internal _sweeper;
    address internal _parent;

    constructor(address superToken_, address parent_) {
        _superToken = superToken_;
        _parent = parent_;
    }

    function setAuthorities(address flowOperator_, address sweeper_) external {
        _flowOperator = flowOperator_;
        _sweeper = sweeper_;
    }

    function superToken() external view returns (address) {
        return _superToken;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function sweeper() external view returns (address) {
        return _sweeper;
    }

    function parent() external view returns (address) {
        return _parent;
    }
}

contract MockPremiumEscrow {
    // Intentionally empty; BudgetTreasury.initialize only checks code length.

    }

contract BudgetTreasuryRunwayCapDonationTest is Test, SpendPolicyTestUtils {
    function test_donationsStillAllowedBeyondRunwayCap() public {
        BudgetTreasury implementation = new BudgetTreasury();
        address treasuryAddr = Clones.clone(address(implementation));
        BudgetTreasury treasury = BudgetTreasury(treasuryAddr);
        address spendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));

        MockSuperToken superToken = new MockSuperToken();
        MockParentFlow parentFlow = new MockParentFlow();
        MockFlow flow = new MockFlow(address(superToken), address(parentFlow));
        flow.setAuthorities(treasuryAddr, treasuryAddr);

        MockPremiumEscrow premiumEscrow = new MockPremiumEscrow();

        // Configure with a runway cap, then set the flow's token balance above it.
        IBudgetTreasury.BudgetConfig memory config = IBudgetTreasury.BudgetConfig({
            flow: address(flow),
            premiumEscrow: address(premiumEscrow),
            fundingDeadline: uint64(block.timestamp + 7 days),
            executionDuration: uint64(30 days),
            activationThreshold: 100,
            runwayCap: 1_000,
            successResolver: address(0xBEEF),
            successAssertionLiveness: 1,
            successAssertionBond: 0,
            successOracleSpecHash: bytes32(uint256(1)),
            successAssertionPolicyHash: bytes32(uint256(2)),
            spendPolicy: spendPolicy
        });

        treasury.initialize(address(this), config);

        // Simulate treasury already holding more than the runway cap.
        superToken.setBalance(address(flow), 1_001);

        // Donation entrypoint should not be gated by runway cap.
        assertTrue(treasury.canAcceptFunding());

        // Use zero-amount donation to avoid needing a full SuperToken upgrade + transfer setup.
        uint256 received = treasury.donateUnderlyingAndUpgrade(0);
        assertEq(received, 0);
    }
}
