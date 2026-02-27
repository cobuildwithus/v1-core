// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { GoalFactory } from "src/goals/GoalFactory.sol";
import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { StakeVault } from "src/goals/StakeVault.sol";
import { BudgetStakeLedger } from "src/goals/BudgetStakeLedger.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { MockSubmissionDepositStrategy } from "test/mocks/MockSubmissionDepositStrategy.sol";
import { RevnetTestDirectory, RevnetTestRulesets } from "test/goals/helpers/RevnetTestHarness.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBProjects } from "@bananapus/core-v5/interfaces/IJBProjects.sol";
import { IJBRulesetApprovalHook } from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBTerminalConfig } from "@bananapus/core-v5/structs/JBTerminalConfig.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISuperfluid } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ERC1820RegistryCompiled } from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { FlowSuperfluidFrameworkDeployer } from "test/utils/FlowSuperfluidFrameworkDeployer.sol";

contract GoalFactoryAllocationDriftRegressionTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 138;
    uint32 internal constant PPM_SCALE = 1_000_000;

    FlowSuperfluidFrameworkDeployer internal sfDeployer;
    FlowSuperfluidFrameworkDeployer.Framework internal sf;

    MockVotesToken internal cobuildToken;
    MockVotesToken internal goalToken;
    GoalFactoryRevnetAdapter internal revDeployer;

    MockSubmissionDepositStrategy internal submissionDepositStrategy;
    BudgetTCRFactory internal budgetTcrFactory;
    GoalFactory internal goalFactory;

    function setUp() public {
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        sfDeployer = new FlowSuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();
        sf = sfDeployer.getFramework();

        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        goalToken = new MockVotesToken("Goal", "GOAL");

        revDeployer = new GoalFactoryRevnetAdapter(address(goalToken));
        revDeployer.configureCobuildProject(
            COBUILD_REVNET_ID,
            address(cobuildToken),
            IJBTerminal(address(new GoalFactoryMockTerminal()))
        );

        GoalTreasury goalTreasuryImpl = new GoalTreasury(
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
        CustomFlow flowImpl = new CustomFlow();
        GoalRevnetSplitHook splitHookImpl = new GoalRevnetSplitHook(
            IJBDirectory(address(0)),
            IGoalTreasury(address(0)),
            IFlow(address(0)),
            0
        );

        BudgetTCR budgetTcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbitratorImpl = new ERC20VotesArbitrator();
        BudgetTCRDeployer stackDeployerImpl = new BudgetTCRDeployer();

        submissionDepositStrategy = new MockSubmissionDepositStrategy(cobuildToken);

        uint64 currentNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), currentNonce + 1);

        budgetTcrFactory = new BudgetTCRFactory(
            address(budgetTcrImpl),
            address(arbitratorImpl),
            address(stackDeployerImpl),
            predictedFactory,
            5_000
        );

        goalFactory = new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(address(sf.host)),
            budgetTcrFactory,
            address(cobuildToken),
            COBUILD_REVNET_ID,
            address(goalTreasuryImpl),
            address(flowImpl),
            address(splitHookImpl),
            address(submissionDepositStrategy),
            makeAddr("defaultBudgetTcrGovernor"),
            makeAddr("defaultInvalidRoundRewardsSink")
        );
    }

    function test_goalFactoryActivation_guardsAgainstLateRegistrationAllocationDrift() public {
        GoalFactory.DeployParams memory params = _defaultDeployParams();
        GoalFactory.DeployedGoalStack memory deployed = goalFactory.deployGoal(params);

        address allocator = makeAddr("allocator");
        _seedStakeWeight(deployed, allocator, 2_000e18);

        BudgetTCR budgetTcr = BudgetTCR(deployed.budgetTCR);
        IBudgetTCR.BudgetListing memory listing = _defaultListing();

        (uint256 addItemCost,,,,) = budgetTcr.getTotalCosts();
        cobuildToken.mint(allocator, addItemCost);
        vm.prank(allocator);
        cobuildToken.approve(address(budgetTcr), type(uint256).max);

        vm.prank(allocator);
        bytes32 itemId = budgetTcr.addItem(abi.encode(listing));

        vm.warp(block.timestamp + params.budgetTCR.challengePeriodDuration + 1);
        budgetTcr.executeRequest(itemId);
        assertTrue(budgetTcr.isRegistrationPending(itemId));

        IBudgetStakeLedger ledger = IBudgetStakeLedger(deployed.budgetStakeLedger);
        assertEq(ledger.budgetForRecipient(itemId), address(0));

        vm.expectRevert();
        CustomFlow(payable(deployed.goalFlow)).getRecipientById(itemId);

        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = itemId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = PPM_SCALE;

        vm.expectRevert();
        vm.prank(allocator);
        ICustomFlow(deployed.goalFlow).allocate(recipientIds, scaled);

        budgetTcr.activateRegisteredBudget(itemId);

        address budget = ledger.budgetForRecipient(itemId);
        assertTrue(budget != address(0));

        FlowTypes.FlowRecipient memory postActivationRecipient =
            CustomFlow(payable(deployed.goalFlow)).getRecipientById(itemId);
        assertTrue(postActivationRecipient.recipient != address(0));

        vm.prank(allocator);
        ICustomFlow(deployed.goalFlow).allocate(recipientIds, scaled);

        uint256 allocatedAfterSet = ledger.userAllocatedStakeOnBudget(allocator, budget);
        assertGt(allocatedAfterSet, 0);

        vm.prank(allocator);
        ICustomFlow(deployed.goalFlow).allocate(recipientIds, scaled);

        assertEq(ledger.userAllocatedStakeOnBudget(allocator, budget), allocatedAfterSet);
    }

    function _seedStakeWeight(GoalFactory.DeployedGoalStack memory deployed, address user, uint256 goalAmount) internal {
        StakeVault vault = StakeVault(deployed.goalStakeVault);

        goalToken.mint(user, goalAmount);
        vm.startPrank(user);
        goalToken.approve(address(vault), type(uint256).max);
        vault.depositGoal(goalAmount);
        vm.stopPrank();

        assertGt(vault.weightOf(user), 0);
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing.metadata = FlowTypes.RecipientMetadata({
            title: "Budget",
            description: "Budget description",
            image: "ipfs://budget-image",
            tagline: "Budget tagline",
            url: "https://budget.example"
        });
        listing.fundingDeadline = uint64(block.timestamp + 10 days);
        listing.executionDuration = 5 days;
        listing.activationThreshold = 100e18;
        listing.runwayCap = 500e18;
        listing.oracleConfig = IBudgetTCR.OracleConfig({
            oracleSpecHash: keccak256("budget-oracle-spec"),
            assertionPolicyHash: keccak256("budget-assertion-policy")
        });
    }

    function _defaultDeployParams() internal pure returns (GoalFactory.DeployParams memory p) {
        p.revnet = GoalFactory.RevnetParams({
            owner: address(0xA11CE),
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 1e18,
            cashOutTaxRate: 0,
            reservedPercent: 10_000,
            durationSeconds: 30 days
        });

        p.timing = GoalFactory.GoalTimingParams({ minRaise: 1e18, minRaiseDurationSeconds: 0 });

        p.success = GoalFactory.SuccessParams({
            successResolver: address(0xBEEF),
            successAssertionLiveness: 1 days,
            successAssertionBond: 1e18,
            successOracleSpecHash: keccak256("goal-success-spec"),
            successAssertionPolicyHash: keccak256("goal-success-policy")
        });

        p.settlement = GoalFactory.SettlementParams({ successSettlementRewardEscrowPpm: 500_000 });

        p.flowMetadata = GoalFactory.FlowMetadataParams({
            title: "Goal Title",
            description: "Goal Description",
            image: "ipfs://goal-image",
            tagline: "Goal Tagline",
            url: "https://goal.example"
        });

        p.flowConfig = GoalFactory.FlowConfigParams({ managerRewardPoolFlowRatePpm: 100_000 });

        p.budgetTCR = GoalFactory.BudgetTCRParams({
            governor: address(0),
            invalidRoundRewardsSink: address(0),
            submissionDepositStrategy: address(0),
            submissionBaseDeposit: 10e18,
            removalBaseDeposit: 10e18,
            submissionChallengeBaseDeposit: 10e18,
            removalChallengeBaseDeposit: 10e18,
            registrationMetaEvidence: "ipfs://registration",
            clearingMetaEvidence: "ipfs://clearing",
            challengePeriodDuration: 2 days,
            arbitratorExtraData: bytes("arbitrator-extra-data"),
            budgetBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1 hours,
                maxFundingHorizon: 25 days,
                minExecutionDuration: 1 days,
                maxExecutionDuration: 20 days,
                minActivationThreshold: 1e18,
                maxActivationThreshold: 10_000e18,
                maxRunwayCap: 20_000e18
            }),
            oracleBounds: IBudgetTCR.OracleValidationBounds({ liveness: 2 hours, bondAmount: 1e18 }),
            budgetSuccessResolver: address(0xCAFE),
            arbitratorParams: IArbitrator.ArbitratorParams({
                votingPeriod: 10,
                votingDelay: 2,
                revealPeriod: 8,
                arbitrationCost: 1e18,
                wrongOrMissedSlashBps: 500,
                slashCallerBountyBps: 100
            })
        });

        p.rentRecipient = address(0x000000000000000000000000000000000000dEaD);
        p.rentWadPerSecond = 1;
    }
}

contract GoalFactoryMockTerminal {}

contract GoalFactoryRevnetAdapter is IREVDeployer {
    RevnetTestDirectory private immutable _directory;
    RevnetTestRulesets private immutable _rulesets;

    IJBToken private immutable _goalToken;
    uint256 private _nextRevnetId;

    mapping(uint256 => IJBToken) private _tokenOf;
    mapping(address => uint256) private _projectIdOf;

    constructor(address goalToken_) {
        _directory = new RevnetTestDirectory(address(this));
        _rulesets = new RevnetTestRulesets(IJBDirectory(address(_directory)));
        _goalToken = IJBToken(goalToken_);
    }

    function configureCobuildProject(uint256 cobuildRevnetId, address cobuildToken, IJBTerminal terminal) external {
        _projectIdOf[cobuildToken] = cobuildRevnetId;
        _tokenOf[cobuildRevnetId] = IJBToken(cobuildToken);
        _directory.setControllerOf(cobuildRevnetId, IERC165(address(this)));
        _directory.setPrimaryTerminalOf(cobuildRevnetId, cobuildToken, terminal);
    }

    function deployFor(
        uint256,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata,
        REVBuybackHookConfig calldata,
        REVSuckerDeploymentConfig calldata
    ) external returns (uint256 revnetId) {
        revnetId = ++_nextRevnetId;

        _directory.setControllerOf(revnetId, IERC165(address(this)));

        _rulesets.queueFor(
            revnetId,
            0,
            configuration.stageConfigurations[0].initialIssuance,
            0,
            IJBRulesetApprovalHook(address(0)),
            0,
            configuration.stageConfigurations[0].startsAtOrAfter
        );
        _rulesets.queueFor(
            revnetId,
            0,
            0,
            0,
            IJBRulesetApprovalHook(address(0)),
            0,
            configuration.stageConfigurations[1].startsAtOrAfter
        );

        _tokenOf[revnetId] = _goalToken;
        _projectIdOf[address(_goalToken)] = revnetId;
    }

    function CONTROLLER() external view returns (IJBController) {
        return IJBController(address(this));
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(address(_directory));
    }

    function PROJECTS() external pure returns (IJBProjects) {
        return IJBProjects(address(0));
    }

    function TOKENS() external view returns (IJBTokens) {
        return IJBTokens(address(this));
    }

    function RULESETS() external view returns (IJBRulesets) {
        return IJBRulesets(address(_rulesets));
    }

    function tokenOf(uint256 projectId) external view returns (IJBToken) {
        return _tokenOf[projectId];
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }

    function burnTokensOf(address, uint256, uint256, string calldata) external pure {}
}
