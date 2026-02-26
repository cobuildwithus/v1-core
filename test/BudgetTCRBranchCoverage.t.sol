// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { stdStorage, StdStorage } from "forge-std/Test.sol";

import { BudgetTCRTest } from "test/BudgetTCR.t.sol";
import { MockGoalTreasuryForBudgetTCR, MockRewardEscrowForBudgetTCR, MockBudgetChildFlow } from
    "test/mocks/MockBudgetTCRSystem.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";

contract BudgetTCRBranchCoverageTest is BudgetTCRTest {
    using stdStorage for StdStorage;

    function test_initialize_reverts_when_budget_success_resolver_is_zero() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();
        deploymentConfig.budgetSuccessResolver = address(0);

        vm.expectRevert(IGeneralizedTCR.ADDRESS_ZERO.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_initialize_reverts_when_reward_escrow_not_configured() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.RegistryConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfig();

        MockGoalTreasuryForBudgetTCR treasuryWithoutEscrow = new MockGoalTreasuryForBudgetTCR(uint64(block.timestamp + 30 days));
        treasuryWithoutEscrow.setRewardEscrow(address(0));
        deploymentConfig.goalTreasury = IGoalTreasury(address(treasuryWithoutEscrow));

        vm.expectRevert(IBudgetTCR.REWARD_ESCROW_NOT_CONFIGURED.selector);
        freshTcr.initialize(registryConfig, deploymentConfig);
    }

    function test_retryRemovedBudgetResolution_reverts_when_item_not_deployed() public {
        vm.expectRevert(IBudgetTCR.ITEM_NOT_DEPLOYED.selector);
        budgetTcr.retryRemovedBudgetResolution(keccak256("unknown-item"));
    }

    function test_activateRegisteredBudget_reverts_when_budget_stake_ledger_not_configured() public {
        _approveAddCost(requester);
        bytes32 itemID = _submitListing(requester, _defaultListing());
        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemID);

        goalTreasury.setRewardEscrow(address(new MockRewardEscrowForBudgetTCR(address(0))));

        vm.expectRevert(IBudgetTCR.BUDGET_STAKE_LEDGER_NOT_CONFIGURED.selector);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function test_activateRegisteredBudget_reverts_when_pending_but_item_not_registered() public {
        bytes32 itemID = keccak256("pending-not-registered");
        stdstore.target(address(budgetTcr)).sig("isRegistrationPending(bytes32)").with_key(itemID).checked_write(true);

        vm.expectRevert(IBudgetTCR.ITEM_NOT_REGISTERED.selector);
        budgetTcr.activateRegisteredBudget(itemID);
    }

    function test_finalizeRemovedBudget_reverts_when_pending_but_item_not_removed() public {
        bytes32 itemID = _registerDefaultListing();
        stdstore.target(address(budgetTcr)).sig("isRemovalPending(bytes32)").with_key(itemID).checked_write(true);

        vm.expectRevert(IBudgetTCR.ITEM_NOT_REMOVED.selector);
        budgetTcr.finalizeRemovedBudget(itemID);
    }

    function test_finalizeRemovedBudget_returns_true_when_pending_and_stack_already_inactive() public {
        bytes32 itemID = _registerDefaultListing();

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        budgetTcr.finalizeRemovedBudget(itemID);

        stdstore.target(address(budgetTcr)).sig("isRemovalPending(bytes32)").with_key(itemID).checked_write(true);
        assertTrue(budgetTcr.finalizeRemovedBudget(itemID));
        assertFalse(budgetTcr.isRemovalPending(itemID));
    }

    function test_finalizeRemovedBudget_force_zeroing_can_resolve_after_funding_deadline() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = MockBudgetChildFlow(childFlow).recipientAdmin();

        _warpRoll(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);

        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);

        assertTrue(budgetTcr.finalizeRemovedBudget(itemID));
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
    }

    function test_retryRemovedBudgetResolution_returns_true_when_treasury_already_resolved() public {
        bytes32 itemID = _registerDefaultListing();
        (address childFlow,) = goalFlow.recipients(itemID);
        address budgetTreasury = MockBudgetChildFlow(childFlow).recipientAdmin();

        _warpRoll(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);
        _queueRemovalRequest(itemID);
        budgetTcr.executeRequest(itemID);
        assertTrue(budgetTcr.finalizeRemovedBudget(itemID));
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());

        assertTrue(budgetTcr.retryRemovedBudgetResolution(itemID));
    }
}
