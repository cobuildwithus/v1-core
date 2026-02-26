// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISuperfluid } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";

import { GoalFactory } from "src/goals/GoalFactory.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";

import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { BudgetTCRValidator } from "src/tcr/BudgetTCRValidator.sol";
import { BudgetTCRStackComponentDeployer } from "src/tcr/library/BudgetTCRStackDeploymentLib.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";

contract DeployGoalFactory is Script {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address revDeployer = vm.envOr("REV_DEPLOYER", address(0x2cA27BDe7e7D33E353b44c27aCfCf6c78ddE251d));
        address sfHost = vm.envOr("SUPERFLUID_HOST", address(0x4C073B3baB6d8826b8C5b229f3cfdC1eC6E47E74));
        address cobuildToken = vm.envOr("COBUILD_TOKEN", address(0x62f05B1aD94c5d7B9f989A294d2A0f36a1AE10Fb));
        uint256 cobuildRevnetId = vm.envOr("COBUILD_REVNET_ID", uint256(138));

        uint256 escrowBondBps = vm.envOr("ESCROW_BOND_BPS", uint256(5000));
        address defaultGovernor = vm.envOr("DEFAULT_BUDGET_TCR_GOVERNOR", BURN);
        address invalidRoundRewardsSink = vm.envOr("DEFAULT_INVALID_ROUND_REWARDS_SINK", BURN);

        vm.startBroadcast(pk);

        IGoalTreasury.GoalConfig memory emptyGoalConfig;
        GoalTreasury goalTreasuryImpl = new GoalTreasury(address(0), emptyGoalConfig);
        CustomFlow flowImpl = new CustomFlow();
        GoalRevnetSplitHook splitHookImpl =
            new GoalRevnetSplitHook(IJBDirectory(address(0)), IGoalTreasury(address(0)), IFlow(address(0)), 0);

        BudgetTCRStackComponentDeployer stackComponentDeployer = new BudgetTCRStackComponentDeployer();
        BudgetTCRDeployer stackDeployerImpl = new BudgetTCRDeployer(address(stackComponentDeployer));
        BudgetTCRValidator itemValidatorImpl = new BudgetTCRValidator();
        BudgetTCR budgetTcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbitratorImpl = new ERC20VotesArbitrator();

        BudgetTCRFactory budgetTcrFactory = new BudgetTCRFactory(
            address(budgetTcrImpl),
            address(arbitratorImpl),
            address(stackDeployerImpl),
            address(itemValidatorImpl),
            escrowBondBps
        );

        PrizePoolSubmissionDepositStrategy depositStrategy =
            new PrizePoolSubmissionDepositStrategy(IERC20(cobuildToken), BURN);

        GoalFactory goalFactory = new GoalFactory(
            IREVDeployer(revDeployer),
            ISuperfluid(sfHost),
            budgetTcrFactory,
            cobuildToken,
            cobuildRevnetId,
            address(goalTreasuryImpl),
            address(flowImpl),
            address(splitHookImpl),
            address(depositStrategy),
            defaultGovernor,
            invalidRoundRewardsSink
        );

        vm.stopBroadcast();

        console2.log("Deployer:", deployer);
        console2.log("--- Core addresses ---");
        console2.log("REV_DEPLOYER:", revDeployer);
        console2.log("SUPERFLUID_HOST:", sfHost);
        console2.log("COBUILD_TOKEN:", cobuildToken);
        console2.log("COBUILD_REVNET_ID:", cobuildRevnetId);
        console2.log("--- Impl addresses ---");
        console2.log("GoalTreasury impl:", address(goalTreasuryImpl));
        console2.log("CustomFlow impl:", address(flowImpl));
        console2.log("GoalRevnetSplitHook impl:", address(splitHookImpl));
        console2.log("--- BudgetTCR stack ---");
        console2.log("BudgetTCRFactory:", address(budgetTcrFactory));
        console2.log("DepositStrategy:", address(depositStrategy));
        console2.log("--- Goal factory ---");
        console2.log("GoalFactory:", address(goalFactory));
    }
}
