// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    ISuperfluid,
    ISuperToken,
    ISuperTokenFactory,
    ISuperfluidPool
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {JBApprovalStatus} from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/structs/JBTerminalConfig.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";

import {GoalFactory} from "src/goals/GoalFactory.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {LinearSpendPolicy} from "src/goals/policies/LinearSpendPolicy.sol";
import {UnitsCapSpendPolicy} from "src/goals/policies/UnitsCapSpendPolicy.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";

contract GoalFactorySpendPolicyDeployTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 1;
    uint256 internal constant GOAL_REVNET_ID = 2;
    address internal constant PREDICTED_BUDGET_TCR = address(0xBEEF);
    address internal constant DEFAULT_ALLOCATION_MECHANISM_ADMIN = address(0xA11CE);
    address internal constant DEFAULT_INVALID_ROUND_REWARDS_SINK = address(0xCAFE);

    GoalFactory internal factory;
    FactoryDeployMockToken internal cobuildToken;
    FactoryDeployMockToken internal goalToken;
    FactoryDeployMockTokens internal tokens;
    FactoryDeployMockRulesets internal rulesets;
    FactoryDeployMockDirectory internal directory;
    FactoryDeployMockController internal controller;
    FactoryDeployMockRevDeployer internal revDeployer;
    FactoryDeployMockCobuildTerminal internal cobuildTerminal;
    FactoryDeployMockSuperTokenFactory internal superTokenFactory;
    FactoryDeployMockSuperfluidHost internal superfluidHost;
    FactoryDeployMockBudgetTcrFactory internal budgetTcrFactory;
    FactoryDeployDummyContract internal successResolver;

    function setUp() public {
        cobuildToken = new FactoryDeployMockToken("Cobuild", "CBD");
        goalToken = new FactoryDeployMockToken("Goal", "GOAL");
        tokens = new FactoryDeployMockTokens();
        rulesets = new FactoryDeployMockRulesets();
        directory = new FactoryDeployMockDirectory();
        controller = new FactoryDeployMockController(address(tokens), address(rulesets));
        revDeployer = new FactoryDeployMockRevDeployer(address(directory), address(controller), GOAL_REVNET_ID);
        cobuildTerminal = new FactoryDeployMockCobuildTerminal(
            IJBDirectory(address(directory)), address(cobuildToken), COBUILD_REVNET_ID
        );
        superTokenFactory = new FactoryDeployMockSuperTokenFactory();
        superfluidHost = new FactoryDeployMockSuperfluidHost(address(superTokenFactory));
        budgetTcrFactory = new FactoryDeployMockBudgetTcrFactory(PREDICTED_BUDGET_TCR);
        successResolver = new FactoryDeployDummyContract();

        rulesets.setDirectory(IJBDirectory(address(directory)));
        rulesets.configureTwoRulesetSchedule(GOAL_REVNET_ID, uint48(block.timestamp + 7 days), 1e18);

        tokens.setTokenOf(COBUILD_REVNET_ID, address(cobuildToken));
        tokens.setProjectIdOf(address(cobuildToken), COBUILD_REVNET_ID);
        tokens.setTokenOf(GOAL_REVNET_ID, address(goalToken));
        tokens.setProjectIdOf(address(goalToken), GOAL_REVNET_ID);

        directory.setController(COBUILD_REVNET_ID, address(controller));
        directory.setController(GOAL_REVNET_ID, address(controller));
        directory.setPrimaryTerminal(
            COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(new FactoryDeployDummyContract()))
        );

        factory = new GoalFactory(
            IREVDeployer(address(revDeployer)),
            ISuperfluid(address(superfluidHost)),
            BudgetTCRFactory(address(budgetTcrFactory)),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            address(cobuildTerminal),
            address(new FactoryDeployDummyContract()),
            address(new FactoryDeployDummyContract()),
            address(new FactoryDeployDummyContract()),
            address(new GoalTreasury()),
            address(new FactoryDeployMockStakeVault()),
            address(new FactoryDeployMockFlow()),
            address(new FactoryDeployMockSplitHook()),
            address(new FactoryDeployMockBudgetStakeLedger()),
            address(new FactoryDeployMockAllocationPipeline()),
            address(new FactoryDeployDummyContract()),
            address(new FactoryDeployMockJurorSlasherRouter()),
            address(new FactoryDeployMockUnderwriterSlasherRouter()),
            address(new FactoryDeployDummyContract()),
            DEFAULT_ALLOCATION_MECHANISM_ADMIN,
            DEFAULT_INVALID_ROUND_REWARDS_SINK
        );
    }

    function test_deployGoal_setsConfiguredSpendPolicyOnDeployedGoalTreasury() public {
        LinearSpendPolicy spendPolicy = _deployLinearSpendPolicy();

        GoalFactory.DeployedGoalStack memory deployed = factory.deployGoal(_baseDeployParams(address(spendPolicy)));

        assertEq(deployed.goalRevnetId, GOAL_REVNET_ID);
        assertEq(IGoalTreasury(deployed.goalTreasury).spendPolicy(), address(spendPolicy));
    }

    function test_deployGoal_bubblesInvalidSpendPolicyFromGoalTreasuryInitialization() public {
        FactoryDeployDummyContract invalidPolicy = new FactoryDeployDummyContract();

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(_baseDeployParams(address(invalidPolicy)));
    }

    function test_deployGoal_revertsForUninitializedLinearSpendPolicyImplementation() public {
        LinearSpendPolicy invalidPolicy = new LinearSpendPolicy();

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(_baseDeployParams(address(invalidPolicy)));
    }

    function test_deployGoal_revertsForUninitializedUnitsCapSpendPolicyClone() public {
        UnitsCapSpendPolicy implementation = new UnitsCapSpendPolicy();
        UnitsCapSpendPolicy invalidPolicy = UnitsCapSpendPolicy(Clones.clone(address(implementation)));

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(_baseDeployParams(address(invalidPolicy)));
    }

    function test_deployGoal_revertsForPolicyThatFailsActiveContextValidation() public {
        ZeroContextOnlySpendPolicy invalidPolicy = new ZeroContextOnlySpendPolicy();

        vm.expectRevert(abi.encodeWithSelector(IGoalTreasury.INVALID_SPEND_POLICY.selector, address(invalidPolicy)));
        factory.deployGoal(_baseDeployParams(address(invalidPolicy)));
    }

    function _deployLinearSpendPolicy() internal returns (LinearSpendPolicy policy) {
        LinearSpendPolicy implementation = new LinearSpendPolicy();
        policy = LinearSpendPolicy(Clones.clone(address(implementation)));
        policy.initialize(false, ISpendPolicy.SyncMode.LinearSpendDownFallback);
    }

    function _baseDeployParams(address goalSpendPolicy) internal view returns (GoalFactory.DeployParams memory p) {
        p.revnet = GoalFactory.RevnetParams({
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 1,
            cashOutTaxRate: 0,
            reservedPercent: 0,
            durationSeconds: 7 days
        });
        p.timing = GoalFactory.GoalTimingParams({minRaise: 0, minRaiseDurationSeconds: 0});
        p.success = GoalFactory.SuccessParams({
            successResolver: address(successResolver),
            successAssertionLiveness: 1 days,
            successAssertionBond: 0,
            successOracleSpecHash: keccak256("spec"),
            successAssertionPolicyHash: keccak256("policy")
        });
        p.flowMetadata = GoalFactory.FlowMetadataParams({
            title: "title",
            description: "description",
            image: "ipfs://image",
            tagline: "tagline",
            url: "https://example.com"
        });
        p.underwriting = GoalFactory.UnderwritingParams({budgetPremiumPpm: 0, budgetSlashPpm: 0});
        p.budgetTCR = GoalFactory.BudgetTCRParams({
            allocationMechanismAdmin: address(0),
            invalidRoundRewardsSink: address(0),
            submissionDepositStrategy: address(0),
            submissionBaseDeposit: 0,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            challengePeriodDuration: 0,
            arbitratorExtraData: bytes(""),
            budgetBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 0,
                maxFundingHorizon: 0,
                minExecutionDuration: 0,
                maxExecutionDuration: 0,
                minActivationThreshold: 0,
                maxActivationThreshold: 0,
                maxRunwayCap: 0
            }),
            oracleBounds: IBudgetTCR.OracleValidationBounds({liveness: 0, bondAmount: 0}),
            budgetSuccessResolver: address(successResolver),
            arbitratorParams: IArbitrator.ArbitratorParams({
                votingPeriod: 0,
                votingDelay: 0,
                revealPeriod: 0,
                arbitrationCost: 0,
                wrongOrMissedSlashBps: 0,
                slashCallerBountyBps: 0
            })
        });
        p.goalSpendPolicy = goalSpendPolicy;
    }
}

contract FactoryDeployMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract ZeroContextOnlySpendPolicy is ISpendPolicy {
    error ACTIVE_CONTEXT_REJECTED();

    function targetFlowRate(SpendContext calldata ctx) external pure returns (int96) {
        if (ctx.timeRemaining == 0 && ctx.totalRecipientUnits == 0) return 0;
        revert ACTIVE_CONTEXT_REJECTED();
    }

    function syncMode() external pure returns (SyncMode) {
        return SyncMode.Capped;
    }
}

contract FactoryDeployDummyContract {}

contract FactoryDeployMockBudgetTcrFactory {
    address internal immutable _predictedBudgetTcr;

    constructor(address predictedBudgetTcr_) {
        _predictedBudgetTcr = predictedBudgetTcr_;
    }

    function predictBudgetTCRAddress(address, address, address, uint256, address) external view returns (address) {
        return _predictedBudgetTcr;
    }

    function deployBudgetTCRStackForGoal(
        BudgetTCRFactory.RegistryConfigInput calldata,
        IBudgetTCR.DeploymentConfig calldata,
        IArbitrator.ArbitratorParams calldata
    ) external view returns (BudgetTCRFactory.DeployedBudgetTCRStack memory deployed) {
        deployed.budgetTCR = _predictedBudgetTcr;
        deployed.arbitrator = address(0xA11CE);
        deployed.token = address(0xCAFE);
    }
}

contract FactoryDeployMockRevDeployer {
    address internal immutable _directory;
    address internal immutable _controller;
    uint256 internal immutable _goalRevnetId;

    constructor(address directory_, address controller_, uint256 goalRevnetId_) {
        _directory = directory_;
        _controller = controller_;
        _goalRevnetId = goalRevnetId_;
    }

    function deployFor(
        uint256,
        IREVDeployer.REVConfig calldata,
        JBTerminalConfig[] calldata,
        IREVDeployer.REVBuybackHookConfig calldata,
        IREVDeployer.REVSuckerDeploymentConfig calldata
    ) external view returns (uint256 revnetId) {
        revnetId = _goalRevnetId;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(_directory);
    }

    function CONTROLLER() external view returns (FactoryDeployMockController) {
        return FactoryDeployMockController(_controller);
    }
}

contract FactoryDeployMockController {
    address internal immutable _tokens;
    address internal immutable _rulesets;

    constructor(address tokens_, address rulesets_) {
        _tokens = tokens_;
        _rulesets = rulesets_;
    }

    function TOKENS() external view returns (IJBTokens) {
        return IJBTokens(_tokens);
    }

    function RULESETS() external view returns (IJBRulesets) {
        return IJBRulesets(_rulesets);
    }
}

contract FactoryDeployMockTokens {
    mapping(uint256 => address) internal _tokenOf;
    mapping(address => uint256) internal _projectIdOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function setProjectIdOf(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}

contract FactoryDeployMockRulesets {
    struct RulesetPair {
        JBRuleset base;
        JBRuleset terminal;
    }

    IJBDirectory internal _directory;
    mapping(uint256 => RulesetPair) internal _pairOf;

    function setDirectory(IJBDirectory directory_) external {
        _directory = directory_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function configureTwoRulesetSchedule(uint256 projectId, uint48 terminalStart, uint112 openWeight) external {
        uint48 nowTs = uint48(block.timestamp);
        _pairOf[projectId] = RulesetPair({
            base: JBRuleset({
                cycleNumber: 1,
                id: 1,
                basedOnId: 0,
                start: nowTs,
                duration: 0,
                weight: openWeight,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            }),
            terminal: JBRuleset({
                cycleNumber: 2,
                id: 2,
                basedOnId: 1,
                start: terminalStart,
                duration: 0,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            })
        });
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory) {
        return _pairOf[projectId].base;
    }

    function latestQueuedOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBApprovalStatus approvalStatus)
    {
        return (_pairOf[projectId].terminal, JBApprovalStatus.Approved);
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory) {
        if (rulesetId == _pairOf[projectId].base.id) return _pairOf[projectId].base;
        if (rulesetId == _pairOf[projectId].terminal.id) return _pairOf[projectId].terminal;
        return JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
    }
}

contract FactoryDeployMockDirectory {
    mapping(uint256 => address) internal _controllerOf;
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract FactoryDeployMockCobuildTerminal {
    IJBDirectory private immutable _directory;
    address private immutable _cobuildToken;
    uint256 private immutable _cobuildRevnetId;

    constructor(IJBDirectory directory_, address cobuildToken_, uint256 cobuildRevnetId_) {
        _directory = directory_;
        _cobuildToken = cobuildToken_;
        _cobuildRevnetId = cobuildRevnetId_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function COBUILD_TOKEN() external view returns (address) {
        return _cobuildToken;
    }

    function COBUILD_REVNET_ID() external view returns (uint256) {
        return _cobuildRevnetId;
    }
}

contract FactoryDeployMockSuperfluidHost {
    address private immutable _superTokenFactory;

    constructor(address superTokenFactory_) {
        _superTokenFactory = superTokenFactory_;
    }

    function getSuperTokenFactory() external view returns (ISuperTokenFactory) {
        return ISuperTokenFactory(_superTokenFactory);
    }
}

contract FactoryDeployMockSuperTokenFactory {
    function createERC20Wrapper(
        IERC20Metadata token,
        uint8,
        ISuperTokenFactory.Upgradability,
        string calldata,
        string calldata
    ) external returns (ISuperToken) {
        return ISuperToken(address(new FactoryDeployMockSuperToken(address(token))));
    }
}

contract FactoryDeployMockSuperToken {
    address private immutable _underlyingToken;

    constructor(address underlyingToken_) {
        _underlyingToken = underlyingToken_;
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlyingToken;
    }
}

contract FactoryDeployMockSplitHook {
    function initialize(IJBDirectory, IGoalTreasury, IFlow, uint256) external {}
}

contract FactoryDeployMockFlow {
    ISuperToken public superToken;
    address public recipientAdmin;
    address public flowOperator;
    address public sweeper;
    ISuperfluidPool public distributionPool;
    int96 public targetOutflowRate;

    function initialize(
        address superToken_,
        address,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address,
        address,
        address,
        IFlow.FlowParams memory,
        FlowTypes.RecipientMetadata memory,
        IAllocationStrategy[] calldata
    ) external {
        superToken = ISuperToken(superToken_);
        recipientAdmin = recipientAdmin_;
        flowOperator = flowOperator_;
        sweeper = sweeper_;
        distributionPool = ISuperfluidPool(address(new FactoryDeployMockDistributionPool()));
    }

    function setTargetOutflowRate(int96 targetOutflowRate_) external {
        targetOutflowRate = targetOutflowRate_;
    }
}

contract FactoryDeployMockDistributionPool {
    function getTotalUnits() external pure returns (uint128) {
        return 0;
    }
}

contract FactoryDeployMockStakeVault {
    address public goalTreasury;
    IERC20 public goalToken;
    IERC20 public cobuildToken;
    address public jurorSlasher;
    address public underwriterSlasher;

    function initialize(address goalTreasury_, IERC20 goalToken_, IERC20 cobuildToken_, IJBRulesets, uint256, uint8)
        external
    {
        goalTreasury = goalTreasury_;
        goalToken = goalToken_;
        cobuildToken = cobuildToken_;
    }

    function setJurorSlasher(address slasher) external {
        jurorSlasher = slasher;
    }

    function setUnderwriterSlasher(address slasher) external {
        underwriterSlasher = slasher;
    }
}

contract FactoryDeployMockBudgetStakeLedger {
    address public goalTreasury;

    function initialize(address goalTreasury_) external {
        goalTreasury = goalTreasury_;
    }
}

contract FactoryDeployMockAllocationPipeline {
    address public allocationLedger;

    function initialize(address allocationLedger_) external {
        allocationLedger = allocationLedger_;
    }
}

contract FactoryDeployMockJurorSlasherRouter {
    IStakeVault public stakeVault;
    address public authority;

    function initialize(IStakeVault stakeVault_, address authority_) external {
        stakeVault = stakeVault_;
        authority = authority_;
    }
}

contract FactoryDeployMockUnderwriterSlasherRouter {
    IStakeVault public stakeVault;
    address public goalFundingTarget;

    function initialize(
        IStakeVault stakeVault_,
        address,
        IJBDirectory,
        uint256,
        IERC20Metadata,
        IERC20Metadata,
        ISuperToken,
        address goalFundingTarget_
    ) external {
        stakeVault = stakeVault_;
        goalFundingTarget = goalFundingTarget_;
    }
}
