// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ISuperfluid, ISuperToken, ISuperTokenFactory } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";

import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalFlowAllocationLedgerPipeline } from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { StakeVault } from "src/goals/StakeVault.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

library GoalFactoryCoreStackDeploy {
    struct CoreStackRequest {
        GoalTreasury goalTreasury;
        GoalRevnetSplitHook splitHook;
        CustomFlow goalFlow;
        address flowImpl;
        ISuperfluid superfluidHost;
        address budgetTcrFactory;
        address cobuildToken;
        uint8 cobuildDecimals;
        uint256 goalRevnetId;
        address goalToken;
        address predictedBudgetTcr;
        IJBRulesets rulesets;
        IJBDirectory directory;
        string revnetName;
        string revnetTicker;
        string flowTitle;
        string flowDescription;
        string flowImage;
        string flowTagline;
        string flowUrl;
        uint32 managerRewardPoolFlowRatePpm;
        address rentRecipient;
        uint256 rentWadPerSecond;
        address burnAddress;
        uint64 minRaiseDeadline;
        uint256 minRaise;
        uint32 successSettlementRewardEscrowPpm;
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
    }

    struct CoreStackResult {
        GoalTreasury goalTreasury;
        GoalRevnetSplitHook splitHook;
        CustomFlow goalFlow;
        ISuperToken goalSuperToken;
        StakeVault stakeVault;
        BudgetStakeLedger budgetStakeLedger;
        RewardEscrow rewardEscrow;
    }

    function initializeCoreStack(
        CoreStackRequest memory request
    ) external returns (CoreStackResult memory out) {
        out.goalTreasury = request.goalTreasury;
        out.splitHook = request.splitHook;
        out.goalFlow = request.goalFlow;

        out.goalSuperToken = _createGoalSuperToken(
            request.superfluidHost, request.goalToken, request.revnetName, request.revnetTicker
        );

        IERC20 goalToken = IERC20(request.goalToken);
        IERC20 cobuildToken = IERC20(request.cobuildToken);

        out.stakeVault = new StakeVault(
            address(out.goalTreasury),
            goalToken,
            cobuildToken,
            request.rulesets,
            request.goalRevnetId,
            request.cobuildDecimals,
            request.rentRecipient == address(0) ? request.burnAddress : request.rentRecipient,
            request.rentWadPerSecond
        );

        out.budgetStakeLedger = new BudgetStakeLedger(address(out.goalTreasury));
        GoalFlowAllocationLedgerPipeline allocationPipeline =
            new GoalFlowAllocationLedgerPipeline(address(out.budgetStakeLedger));
        IAllocationStrategy[] memory allocationStrategies = new IAllocationStrategy[](1);
        allocationStrategies[0] = IAllocationStrategy(address(out.stakeVault));

        out.rewardEscrow = new RewardEscrow(
            address(out.goalTreasury),
            goalToken,
            out.stakeVault,
            out.goalSuperToken,
            out.budgetStakeLedger
        );

        IFlow.FlowParams memory flowParams = IFlow.FlowParams({
            managerRewardPoolFlowRatePpm: request.managerRewardPoolFlowRatePpm
        });
        FlowTypes.RecipientMetadata memory metadata = FlowTypes.RecipientMetadata({
            title: request.flowTitle,
            description: request.flowDescription,
            image: request.flowImage,
            tagline: request.flowTagline,
            url: request.flowUrl
        });

        out.goalFlow.initialize(
            address(out.goalSuperToken),
            request.flowImpl,
            request.predictedBudgetTcr,
            address(out.goalTreasury),
            address(out.goalTreasury),
            address(out.rewardEscrow),
            address(allocationPipeline),
            address(0),
            flowParams,
            metadata,
            allocationStrategies
        );

        IGoalTreasury.GoalConfig memory goalCfg = IGoalTreasury.GoalConfig({
            flow: address(out.goalFlow),
            stakeVault: address(out.stakeVault),
            rewardEscrow: address(out.rewardEscrow),
            hook: address(out.splitHook),
            goalRulesets: address(request.rulesets),
            goalRevnetId: request.goalRevnetId,
            minRaiseDeadline: request.minRaiseDeadline,
            minRaise: request.minRaise,
            successSettlementRewardEscrowPpm: request.successSettlementRewardEscrowPpm,
            successResolver: request.successResolver,
            successAssertionLiveness: request.successAssertionLiveness,
            successAssertionBond: request.successAssertionBond,
            successOracleSpecHash: request.successOracleSpecHash,
            successAssertionPolicyHash: request.successAssertionPolicyHash
        });

        out.goalTreasury.initialize(request.budgetTcrFactory, goalCfg);
        out.splitHook.initialize(request.directory, out.goalTreasury, out.goalFlow, request.goalRevnetId);
    }

    function _createGoalSuperToken(
        ISuperfluid superfluidHost,
        address goalToken,
        string memory name,
        string memory ticker
    ) private returns (ISuperToken superToken) {
        ISuperTokenFactory factory = superfluidHost.getSuperTokenFactory();
        IERC20Metadata goalTokenMetadata = IERC20Metadata(goalToken);
        superToken = factory.createERC20Wrapper(
            goalTokenMetadata,
            goalTokenMetadata.decimals(),
            ISuperTokenFactory.Upgradability.SEMI_UPGRADABLE,
            string.concat(name, " SuperToken"),
            string.concat(ticker, "x")
        );
    }
}
