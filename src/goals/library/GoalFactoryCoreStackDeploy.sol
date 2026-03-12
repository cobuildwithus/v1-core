// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ISuperfluid, ISuperToken, ISuperTokenFactory } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalFlowAllocationLedgerPipeline } from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { JurorSlasherRouter } from "src/goals/JurorSlasherRouter.sol";
import { StakeVault } from "src/goals/StakeVault.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { UnderwriterSlasherRouter } from "src/goals/UnderwriterSlasherRouter.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

library GoalFactoryCoreStackDeploy {
    struct CoreBaseRequest {
        GoalTreasury goalTreasury;
        GoalRevnetSplitHook splitHook;
        CustomFlow goalFlow;
        address stakeVaultImpl;
        ISuperfluid superfluidHost;
        address budgetStakeLedgerImpl;
        address goalFlowAllocationLedgerPipelineImpl;
        address cobuildToken;
        uint8 cobuildDecimals;
        uint256 goalRevnetId;
        address goalToken;
        IJBRulesets rulesets;
        string revnetName;
        string revnetTicker;
    }

    struct CoreFinalizeRequest {
        address goalAllocatorStrategy;
        address budgetController;
        address jurorSlasherAuthority;
        address jurorSlasherRouterImpl;
        address underwriterSlasherRouterImpl;
        address flowImpl;
        address goalToken;
        address cobuildToken;
        uint256 goalRevnetId;
        IJBRulesets rulesets;
        IJBDirectory directory;
        string flowTitle;
        string flowDescription;
        string flowImage;
        string flowTagline;
        string flowUrl;
        uint64 minRaiseDeadline;
        uint256 minRaise;
        uint32 budgetPremiumPpm;
        uint32 budgetSlashPpm;
        address successResolver;
        uint64 successAssertionLiveness;
        uint256 successAssertionBond;
        bytes32 successOracleSpecHash;
        bytes32 successAssertionPolicyHash;
        address goalSpendPolicy;
        uint64 terminalRolloverCooldown;
    }

    struct CoreStackResult {
        GoalTreasury goalTreasury;
        GoalRevnetSplitHook splitHook;
        CustomFlow goalFlow;
        ISuperToken goalSuperToken;
        StakeVault stakeVault;
        BudgetStakeLedger budgetStakeLedger;
        address goalFlowAllocationLedgerPipeline;
        address jurorSlasherRouter;
        address underwriterSlasherRouter;
    }

    function deployCoreBase(CoreBaseRequest memory request) external returns (CoreStackResult memory out) {
        out.goalTreasury = request.goalTreasury;
        out.splitHook = request.splitHook;
        out.goalFlow = request.goalFlow;

        out.goalSuperToken = _createGoalSuperToken(
            request.superfluidHost,
            request.goalToken,
            request.revnetName,
            request.revnetTicker
        );

        IERC20 goalToken = IERC20(request.goalToken);
        IERC20 cobuildToken = IERC20(request.cobuildToken);

        out.stakeVault = StakeVault(Clones.clone(request.stakeVaultImpl));
        out.stakeVault.initialize(
            address(out.goalTreasury),
            goalToken,
            cobuildToken,
            request.rulesets,
            request.goalRevnetId,
            request.cobuildDecimals
        );

        out.budgetStakeLedger = BudgetStakeLedger(Clones.clone(request.budgetStakeLedgerImpl));
        out.budgetStakeLedger.initialize(address(out.goalTreasury));

        GoalFlowAllocationLedgerPipeline allocationPipeline = GoalFlowAllocationLedgerPipeline(
            Clones.clone(request.goalFlowAllocationLedgerPipelineImpl)
        );
        out.goalFlowAllocationLedgerPipeline = address(allocationPipeline);
        allocationPipeline.initialize(address(out.budgetStakeLedger));
    }

    function finalizeCoreStack(
        CoreStackResult memory out,
        CoreFinalizeRequest memory request
    ) external returns (CoreStackResult memory) {
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
            request.budgetController,
            address(out.goalTreasury),
            address(out.goalTreasury),
            address(0),
            out.goalFlowAllocationLedgerPipeline,
            address(0),
            IFlow.FlowParams({ managerRewardPoolFlowRatePpm: 0 }),
            metadata,
            IAllocationStrategy(request.goalAllocatorStrategy)
        );

        JurorSlasherRouter jurorSlasherRouter = JurorSlasherRouter(Clones.clone(request.jurorSlasherRouterImpl));
        IStakeVault stakeVaultRef = IStakeVault(address(out.stakeVault));
        jurorSlasherRouter.initialize(stakeVaultRef, request.jurorSlasherAuthority);
        out.jurorSlasherRouter = address(jurorSlasherRouter);
        UnderwriterSlasherRouter underwriterSlasherRouter = UnderwriterSlasherRouter(
            Clones.clone(request.underwriterSlasherRouterImpl)
        );
        underwriterSlasherRouter.initialize(
            stakeVaultRef,
            request.budgetController,
            request.directory,
            request.goalRevnetId,
            IERC20Metadata(request.goalToken),
            IERC20Metadata(request.cobuildToken),
            out.goalSuperToken,
            address(out.goalFlow)
        );
        out.underwriterSlasherRouter = address(underwriterSlasherRouter);

        IGoalTreasury.GoalConfig memory goalCfg = IGoalTreasury.GoalConfig({
            flow: address(out.goalFlow),
            stakeVault: address(out.stakeVault),
            jurorSlasher: address(jurorSlasherRouter),
            underwriterSlasher: out.underwriterSlasherRouter,
            budgetStakeLedger: address(out.budgetStakeLedger),
            hook: address(out.splitHook),
            goalRulesets: address(request.rulesets),
            goalRevnetId: request.goalRevnetId,
            minRaiseDeadline: request.minRaiseDeadline,
            minRaise: request.minRaise,
            budgetPremiumPpm: request.budgetPremiumPpm,
            budgetSlashPpm: request.budgetSlashPpm,
            successResolver: request.successResolver,
            successAssertionLiveness: request.successAssertionLiveness,
            successAssertionBond: request.successAssertionBond,
            successOracleSpecHash: request.successOracleSpecHash,
            successAssertionPolicyHash: request.successAssertionPolicyHash,
            spendPolicy: request.goalSpendPolicy,
            terminalRolloverCooldown: request.terminalRolloverCooldown
        });

        out.goalTreasury.initialize(goalCfg);
        out.splitHook.initialize(request.directory, out.goalTreasury, request.goalRevnetId);
        return out;
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
