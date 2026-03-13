// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { BudgetTCRTest } from "test/BudgetTCR.t.sol";

import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetStackDeployer } from "src/goals/BudgetStackDeployer.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IBudgetStackTopologyReader } from "src/interfaces/IBudgetStackTopologyReader.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";

contract BudgetTCRPremiumOnlyActivationAuditTest is BudgetTCRTest {
    function test_activateRegisteredBudget_premiumOnlyConfig_keepsPremiumEscrow_withoutUnderwriterRouter() public {
        (
            BudgetTCR freshTcr,
            IBudgetTCR.InitConfig memory registryConfig,
            IBudgetTCR.DeploymentConfig memory deploymentConfig
        ) = _freshInitializeConfigWithFreshArbitrator();

        address freshStackDeployer = address(_deployBudgetTcrDeployer());
        _initializeOpenBudgetTcrDeployer(BudgetStackDeployer(freshStackDeployer), address(freshTcr), premiumEscrowImplementation);

        deploymentConfig.stackDeployer = freshStackDeployer;
        deploymentConfig.riskModuleRouting.budgetGatePolicy = address(0);
        deploymentConfig.riskModuleRouting.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetSlashPpm = 0;

        freshTcr.initialize(registryConfig, deploymentConfig);
        goalFlow.setRecipientAdmin(address(freshTcr));

        (uint256 addCost,,,,) = freshTcr.getTotalCosts();
        vm.prank(requester);
        depositToken.approve(address(freshTcr), addCost);

        vm.prank(requester);
        bytes32 itemID = freshTcr.addItem(abi.encode(_defaultListing()));

        _warpRoll(block.timestamp + challengePeriodDuration + 1);
        freshTcr.executeRequest(itemID);
        assertTrue(freshTcr.isRegistrationPending(itemID));

        freshTcr.activateRegisteredBudget(itemID);

        (address childFlow, bool removed) = goalFlow.recipients(itemID);
        address budgetTreasury = budgetStakeLedger.budgetForRecipient(itemID);
        address premiumEscrow = IBudgetTreasury(budgetTreasury).premiumEscrow();
        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            freshTcr.budgetStackTopology(itemID);

        assertFalse(removed);
        assertTrue(active);
        assertEq(freshTcr.underwriterSlasherRouter(), address(0));
        assertTrue(childFlow != address(0));
        assertTrue(budgetTreasury != address(0));
        assertTrue(premiumEscrow != address(0));
        assertEq(topology.childFlow, childFlow);
        assertEq(topology.budgetTreasury, budgetTreasury);
        assertEq(topology.premiumEscrow, premiumEscrow);
        assertEq(IFlow(childFlow).managerRewardPool(), premiumEscrow);
        assertEq(IFlow(childFlow).managerRewardPoolFlowRatePpm(), deploymentConfig.budgetPremiumPpm);
        assertEq(address(PremiumEscrow(premiumEscrow).managerRewardPool()), address(IFlow(childFlow).managerRewardDistributionPool()));
    }
}
