// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import {
    SharedMockCFA,
    SharedMockSuperfluidHost,
    SharedMockFlow,
    SharedMockStakeVault,
    SharedMockSuperToken,
    SharedMockUnderlying
} from "test/goals/helpers/TreasurySharedMocks.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract BudgetTreasuryRunwayCapActivationRegressionTest is Test {
    address internal controller = address(0xA11CE);

    SharedMockUnderlying internal underlyingToken;
    SharedMockSuperToken internal superToken;
    SharedMockFlow internal flow;
    SharedMockFlow internal parentFlow;
    SharedMockStakeVault internal stakeVault;
    BudgetTreasury internal budgetTreasuryImplementation;
    BudgetTreasury internal treasury;

    function setUp() public {
        underlyingToken = new SharedMockUnderlying();
        superToken = new SharedMockSuperToken(address(underlyingToken));

        SharedMockSuperfluidHost host = new SharedMockSuperfluidHost();
        SharedMockCFA cfa = new SharedMockCFA();
        cfa.setDepositPerFlowRate(1);
        host.setCFA(address(cfa));
        superToken.setHost(address(host));

        flow = new SharedMockFlow(ISuperToken(address(superToken)));
        parentFlow = new SharedMockFlow(ISuperToken(address(superToken)));
        flow.setParent(address(parentFlow));
        flow.setMaxSafeFlowRate(type(int96).max);

        stakeVault = new SharedMockStakeVault();
        budgetTreasuryImplementation = new BudgetTreasury();
        treasury = BudgetTreasury(Clones.clone(address(budgetTreasuryImplementation)));

        flow.setFlowOperator(address(treasury));
        flow.setSweeper(address(treasury));
        stakeVault.setGoalTreasury(address(treasury));

        treasury.initialize(
            controller,
            IBudgetTreasury.BudgetConfig({
                flow: address(flow),
                stakeVault: address(stakeVault),
                fundingDeadline: uint64(block.timestamp + 3 days),
                executionDuration: uint64(30 days),
                activationThreshold: 100e18,
                runwayCap: 500e18,
                successResolver: controller,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("budget-oracle-spec"),
                successAssertionPolicyHash: keccak256("budget-assertion-policy")
            })
        );
    }

    function test_sync_activatesWhenRunwayCapAlreadyExceeded() public {
        superToken.mint(address(flow), treasury.runwayCap() + 1);
        parentFlow.setMemberFlowRate(address(flow), 250);

        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertEq(treasury.deadline(), uint64(uint256(treasury.fundingDeadline()) + uint256(treasury.executionDuration())));
        assertGt(flow.targetOutflowRate(), 0);
    }
}
