// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTestBase } from "test/flows/helpers/FlowTestBase.t.sol";
import { IRevnetHarness, RevnetHarnessDeployer } from "test/goals/helpers/RevnetHarnessDeployer.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { StakeVault } from "src/goals/StakeVault.sol";
import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { RewardEscrow } from "src/goals/RewardEscrow.sol";
import { GoalFlowAllocationLedgerPipeline } from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";

abstract contract GoalRevnetFixtureBase is FlowTestBase {
    uint256 internal constant GOAL_RENT_RATE_WAD_PER_SECOND = 1e10;
    bytes32 internal constant ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");

    struct GoalIntegrationConfig {
        uint40 mintCloseOffset;
        uint64 minRaiseDeadlineOffset;
        uint112 revnetWeight;
        uint256 minRaise;
        bool withRewardEscrow;
        uint32 successSettlementRewardEscrowPpm;
    }

    IRevnetHarness internal revnets;
    uint256 internal goalRevnetId;
    uint40 internal goalMintCloseTimestamp;

    StakeVault internal vault;
    GoalTreasury internal treasury;
    GoalRevnetSplitHook internal hook;
    BudgetStakeLedger internal budgetStakeLedger;
    RewardEscrow internal rewardEscrow;
    TreasuryMockOptimisticOracleV3 internal goalAssertionOracle;
    TreasuryMockUmaResolverConfig internal goalSuccessResolverConfig;
    address internal goalSuccessResolver;

    TestToken internal goalToken;
    MockVotesToken internal cobuildToken;

    function _goalConfigPresetNoEscrow() internal pure returns (GoalIntegrationConfig memory) {
        return GoalIntegrationConfig({
            mintCloseOffset: uint40(2 days),
            minRaiseDeadlineOffset: uint64(1 days),
            revnetWeight: 2e18,
            minRaise: 50e18,
            withRewardEscrow: false,
            successSettlementRewardEscrowPpm: 0
        });
    }

    function _goalConfigPresetWithEscrow() internal pure returns (GoalIntegrationConfig memory) {
        return GoalIntegrationConfig({
            mintCloseOffset: uint40(14 days),
            minRaiseDeadlineOffset: uint64(3 days),
            revnetWeight: 2e18,
            minRaise: 50e18,
            withRewardEscrow: true,
            successSettlementRewardEscrowPpm: 250_000
        });
    }

    function _setUpGoalIntegration(GoalIntegrationConfig memory config) internal {
        revnets = RevnetHarnessDeployer.deploy(vm);
        goalMintCloseTimestamp = uint40(block.timestamp + config.mintCloseOffset);
        goalRevnetId = revnets.createRevnetWithMintClose(config.revnetWeight, goalMintCloseTimestamp);
        uint256 cobuildRevnetId = revnets.createRevnet(config.revnetWeight);

        goalToken = underlyingToken;
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        revnets.setTokenProjectId(address(goalToken), goalRevnetId);
        revnets.setTokenProjectId(address(cobuildToken), cobuildRevnetId);
        goalAssertionOracle = new TreasuryMockOptimisticOracleV3();
        goalSuccessResolverConfig = new TreasuryMockUmaResolverConfig(
            OptimisticOracleV3Interface(address(goalAssertionOracle)),
            IERC20(address(underlyingToken)),
            address(0),
            keccak256("goal-revnet-test-domain")
        );
        goalSuccessResolver = address(goalSuccessResolverConfig);

        GoalTreasury treasuryImplementation = new GoalTreasury(
            address(0),
            IGoalTreasury.GoalConfig({
                flow: address(0),
                stakeVault: address(0),
                rewardEscrow: address(0),
                hook: address(0),
                goalRulesets: address(0),
                goalRevnetId: 0,
                minRaiseDeadline: 0,
                minRaise: 0,
                successSettlementRewardEscrowPpm: 0,
                successResolver: address(0),
                successAssertionLiveness: 0,
                successAssertionBond: 0,
                successOracleSpecHash: bytes32(0),
                successAssertionPolicyHash: bytes32(0)
            })
        );
        GoalRevnetSplitHook hookImplementation = new GoalRevnetSplitHook(
            IJBDirectory(address(0)),
            IGoalTreasury(address(0)),
            IFlow(address(0)),
            0
        );
        treasury = GoalTreasury(payable(Clones.clone(address(treasuryImplementation))));
        hook = GoalRevnetSplitHook(payable(Clones.clone(address(hookImplementation))));

        address predictedEscrow = address(0);
        if (config.withRewardEscrow) {
            uint64 nonce = vm.getNonce(address(this));
            uint64 escrowNonceOffset = 2;
            predictedEscrow = vm.computeCreateAddress(address(this), nonce + escrowNonceOffset);
        }

        vault = new StakeVault(
            address(treasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(revnets.rulesets())),
            goalRevnetId,
            18,
            predictedEscrow,
            config.withRewardEscrow ? GOAL_RENT_RATE_WAD_PER_SECOND : 0
        );
        strategy.setStakeVault(address(vault));

        if (config.withRewardEscrow) {
            budgetStakeLedger = new BudgetStakeLedger(address(treasury));
            rewardEscrow = new RewardEscrow(
                address(treasury),
                IERC20(address(goalToken)),
                vault,
                ISuperToken(address(superToken)),
                budgetStakeLedger
            );
        } else {
            budgetStakeLedger = BudgetStakeLedger(address(0));
            rewardEscrow = RewardEscrow(address(0));
        }

        address allocationPipeline = address(0);
        if (config.withRewardEscrow) {
            allocationPipeline = address(new GoalFlowAllocationLedgerPipeline(address(budgetStakeLedger)));
        }

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        address configuredManagerRewardPool = config.withRewardEscrow ? address(rewardEscrow) : managerRewardPool;
        flow = _deployFlowWithConfigAndRoles(
            owner,
            address(treasury),
            address(treasury),
            address(treasury),
            configuredManagerRewardPool,
            allocationPipeline,
            address(0),
            strategies
        );

        vm.prank(owner);
        superToken.transfer(address(flow), 2_000_000e18);

        treasury.initialize(
            owner,
            IGoalTreasury.GoalConfig({
                flow: address(flow),
                stakeVault: address(vault),
                rewardEscrow: address(rewardEscrow),
                hook: address(hook),
                goalRulesets: address(revnets.rulesets()),
                goalRevnetId: goalRevnetId,
                minRaiseDeadline: uint64(block.timestamp + config.minRaiseDeadlineOffset),
                minRaise: config.minRaise,
                successSettlementRewardEscrowPpm: config.successSettlementRewardEscrowPpm,
                successResolver: goalSuccessResolver,
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
        assertEq(treasury.cobuildRevnetId(), cobuildRevnetId);

        hook.initialize(
            IJBDirectory(address(revnets.directory())),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            goalRevnetId
        );
    }

    function _mintAndApproveStakeTokens(address user, uint256 goalAmount, uint256 cobuildAmount) internal {
        goalToken.mint(user, goalAmount);
        cobuildToken.mint(user, cobuildAmount);

        vm.startPrank(user);
        goalToken.approve(address(vault), type(uint256).max);
        cobuildToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _stakeGoal(address user, uint256 amount) internal {
        vm.prank(user);
        vault.depositGoal(amount);
    }

    function _stakeCobuild(address user, uint256 amount) internal {
        vm.prank(user);
        vault.depositCobuild(amount);
    }

    function _fundViaHookUnderlying(uint256 amount) internal {
        underlyingToken.mint(address(hook), amount);
        _processAsController(_splitContext(address(underlyingToken), amount, goalRevnetId, 1));
    }

    function _registerGoalSuccessAssertion() internal {
        bytes32 assertionId = keccak256(abi.encodePacked(address(treasury), block.timestamp));
        vm.prank(goalSuccessResolver);
        treasury.registerSuccessAssertion(assertionId);

        uint64 assertedAt = treasury.pendingSuccessAssertionAt();
        goalAssertionOracle.setAssertion(
            assertionId,
            OptimisticOracleV3Interface.Assertion({
                escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                    arbitrateViaEscalationManager: false,
                    discardOracle: false,
                    validateDisputers: false,
                    assertingCaller: goalSuccessResolver,
                    escalationManager: goalSuccessResolverConfig.escalationManager()
                }),
                asserter: goalSuccessResolver,
                assertionTime: assertedAt,
                settled: true,
                currency: IERC20(address(underlyingToken)),
                expirationTime: assertedAt + treasury.successAssertionLiveness(),
                settlementResolution: true,
                domainId: goalSuccessResolverConfig.domainId(),
                identifier: ASSERT_TRUTH_IDENTIFIER,
                bond: treasury.successAssertionBond(),
                callbackRecipient: goalSuccessResolver,
                disputer: address(0)
            })
        );
    }

    function _resolveGoalSuccessViaAssertion() internal {
        _registerGoalSuccessAssertion();
        vm.prank(goalSuccessResolver);
        treasury.resolveSuccess();
    }

    function _activateWithIncomingFlowAndHookFunding(uint256 amount, address flowSender, int96 incomingFlowRate) internal {
        _fundViaHookUnderlying(amount);
        _makeIncomingFlow(flowSender, incomingFlowRate);
        treasury.sync();
        assertGt(flow.targetOutflowRate(), 0);
    }

    function _splitContext(address token, uint256 amount, uint256 projectId, uint256 groupId)
        internal
        pure
        returns (JBSplitHookContext memory)
    {
        return JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: groupId,
            split: JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            })
        });
    }

    function _processAsController(JBSplitHookContext memory context) internal {
        vm.prank(address(revnets));
        hook.processSplitWith(context);
    }
}
