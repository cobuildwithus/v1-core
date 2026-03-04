// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {FlowSuperfluidFrameworkDeployer} from "test/utils/FlowSuperfluidFrameworkDeployer.sol";

import {GoalFactory} from "src/goals/GoalFactory.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {JurorSlasherRouter} from "src/goals/JurorSlasherRouter.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {CobuildTerminal} from "src/juicebox/CobuildTerminal.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";

import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ISuperfluid, ISuperToken} from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBControlled} from "@bananapus/core-v5/interfaces/IJBControlled.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {JBApprovalStatus} from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/structs/JBTerminalConfig.sol";

contract GoalFactoryWithdrawalGasModelTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 138;
    uint256 internal constant GOAL_BUDGET_COUNT = 1_500;
    uint256 internal constant STAKE_AMOUNT = 3e18;
    uint256 internal constant WITHDRAW_AMOUNT = 1e18;
    uint256 internal constant GAS_CAP_15M = 15_000_000;
    uint256 internal constant GAS_CAP_30M = 30_000_000;

    event PrepareGasSample(uint256 budgetsProcessed, uint256 gasUsed);

    FlowSuperfluidFrameworkDeployer private _sf;

    GoalFactory private _factory;
    MockBudgetTcrFactory private _mockBudgetTcrFactory;
    MockDirectory private _directory;
    MockTokens private _tokens;
    MockRulesets private _rulesets;
    MockController private _controller;
    MockRevDeployer private _revDeployer;

    MockMintableToken private _cobuildToken;

    address private _goalOwner = address(0xA11CE);
    address private _successResolver;
    address private _budgetSuccessResolver;

    struct Deployed {
        StakeVault vault;
        BudgetStakeLedger ledger;
        MockMintableToken goalToken;
        address goalTreasury;
        address goalFlow;
        address budgetTcr;
    }

    function setUp() public {
        _sf = new FlowSuperfluidFrameworkDeployer();
        _sf.deployTestFramework();

        _directory = new MockDirectory();
        _tokens = new MockTokens();
        _rulesets = new MockRulesets();
        _controller = new MockController(_tokens, _rulesets);
        _revDeployer = new MockRevDeployer(_directory, _controller, _tokens, _rulesets);

        _cobuildToken = new MockMintableToken("Cobuild", "CBD", 18);
        _tokens.setTokenOf(COBUILD_REVNET_ID, address(_cobuildToken));
        _tokens.setProjectIdOf(address(_cobuildToken), COBUILD_REVNET_ID);
        _directory.setController(COBUILD_REVNET_ID, address(_controller));

        address nativeTerminal = address(new DummyMultiTerminal());
        address jbMultiTerminal = address(new DummyMultiTerminal());
        _directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(nativeTerminal));
        _directory.setPrimaryTerminal(COBUILD_REVNET_ID, address(_cobuildToken), IJBTerminal(jbMultiTerminal));

        CobuildTerminal cobuildTerminal =
            new CobuildTerminal(IJBDirectory(address(_directory)), address(_cobuildToken), COBUILD_REVNET_ID);

        _mockBudgetTcrFactory = new MockBudgetTcrFactory();
        _successResolver = address(new DummyContract());
        _budgetSuccessResolver = address(new DummyContract());

        _factory = new GoalFactory(
            IREVDeployer(address(_revDeployer)),
            ISuperfluid(address(_sf.getFramework().host)),
            BudgetTCRFactory(address(_mockBudgetTcrFactory)),
            address(_cobuildToken),
            COBUILD_REVNET_ID,
            address(cobuildTerminal),
            jbMultiTerminal,
            address(new DummyContract()),
            address(new DummyContract()),
            address(new GoalTreasury()),
            address(new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0)),
            address(new CustomFlow()),
            address(new GoalRevnetSplitHook()),
            address(new BudgetStakeLedger(address(this))),
            address(new GoalFlowAllocationLedgerPipeline(address(this))),
            address(new PremiumEscrow()),
            address(new JurorSlasherRouter(IStakeVault(address(0)), address(0))),
            address(
                new UnderwriterSlasherRouter(
                    IStakeVault(address(0)),
                    address(0),
                    IJBDirectory(address(0)),
                    0,
                    IERC20(address(0)),
                    IERC20(address(0)),
                    ISuperToken(address(0)),
                    address(0)
                )
            ),
            address(new DummyContract()),
            address(0xA0A0),
            address(0xB0B0)
        );
    }

    function test_profile_goalFactoryUnderwriterExitGas() public {
        Deployed memory d = _deployGoal();

        _seedStaker(d.vault, d.goalToken, address(0x1111)); // chunked-exit @30m user
        _seedStaker(d.vault, d.goalToken, address(0x2222)); // chunked-exit @15m user
        _seedStaker(d.vault, d.goalToken, address(0x3333)); // one-shot user

        _appendRemovedBudgets(d.ledger, d.goalFlow, d.budgetTcr, GOAL_BUDGET_COUNT);

        vm.prank(d.goalTreasury);
        d.vault.markGoalResolved();

        uint256[] memory checkpoints = new uint256[](10);
        checkpoints[0] = 1;
        checkpoints[1] = 10;
        checkpoints[2] = 25;
        checkpoints[3] = 50;
        checkpoints[4] = 100;
        checkpoints[5] = 200;
        checkpoints[6] = 400;
        checkpoints[7] = 800;
        checkpoints[8] = 1_200;
        checkpoints[9] = 1_500;

        for (uint256 i = 0; i < checkpoints.length; i++) {
            uint256 gasUsed = _measurePrepare(d.vault, _freshUser(i + 1), checkpoints[i]);
            emit PrepareGasSample(checkpoints[i], gasUsed);
        }

        uint256 oneShotPrepareGas = _measurePrepare(d.vault, address(0x3333), type(uint256).max);
        uint256 oneShotWithdrawGas = _measureWithdraw(d.vault, address(0x3333));

        uint256 maxBudgetsAt30m = _maxBudgetsUnderGasCap(d.vault, GOAL_BUDGET_COUNT, GAS_CAP_30M);
        uint256 maxBudgetsAt15m = _maxBudgetsUnderGasCap(d.vault, GOAL_BUDGET_COUNT, GAS_CAP_15M);

        (uint256 totalPrepareGas30m, uint256 prepareCalls30m, uint256 withdrawGas30m) =
            _measureChunkedExit(d.vault, address(0x1111), maxBudgetsAt30m == 0 ? 1 : maxBudgetsAt30m);
        (uint256 totalPrepareGas15m, uint256 prepareCalls15m, uint256 withdrawGas15m) =
            _measureChunkedExit(d.vault, address(0x2222), maxBudgetsAt15m == 0 ? 1 : maxBudgetsAt15m);

        emit log_named_uint("registered_budgets_total", GOAL_BUDGET_COUNT);
        emit log_named_uint("one_shot_prepare_gas_type_max", oneShotPrepareGas);
        emit log_named_uint("one_shot_withdraw_goal_gas", oneShotWithdrawGas);

        emit log_named_uint("max_budgets_per_prepare_under_30m", maxBudgetsAt30m);
        emit log_named_uint("max_budgets_per_prepare_under_15m", maxBudgetsAt15m);

        emit log_named_uint("chunked_exit_prepare_calls_30m", prepareCalls30m);
        emit log_named_uint("chunked_exit_total_prepare_gas_30m", totalPrepareGas30m);
        emit log_named_uint("chunked_exit_withdraw_gas_30m", withdrawGas30m);

        emit log_named_uint("chunked_exit_prepare_calls_15m", prepareCalls15m);
        emit log_named_uint("chunked_exit_total_prepare_gas_15m", totalPrepareGas15m);
        emit log_named_uint("chunked_exit_withdraw_gas_15m", withdrawGas15m);

        assertEq(d.ledger.trackedBudgetCount(), 0);
        assertEq(d.ledger.registeredBudgetCount(), GOAL_BUDGET_COUNT);
        assertGt(oneShotPrepareGas, 0);
        assertGt(oneShotWithdrawGas, 0);
    }

    function _deployGoal() internal returns (Deployed memory d) {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        GoalFactory.DeployedGoalStack memory stack = _factory.deployGoal(p);

        d.vault = StakeVault(stack.stakeVault);
        d.ledger = BudgetStakeLedger(stack.budgetStakeLedger);
        d.goalToken = MockMintableToken(stack.goalToken);
        d.goalTreasury = stack.goalTreasury;
        d.goalFlow = stack.goalFlow;
        d.budgetTcr = stack.budgetTCR;
    }

    function _baseDeployParams() internal view returns (GoalFactory.DeployParams memory p) {
        p.revnet = GoalFactory.RevnetParams({
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 1,
            cashOutTaxRate: 0,
            reservedPercent: 0,
            durationSeconds: 30 days
        });

        p.timing = GoalFactory.GoalTimingParams({minRaise: 0, minRaiseDurationSeconds: 1 days});

        p.success = GoalFactory.SuccessParams({
            successResolver: _successResolver,
            successAssertionLiveness: 1 days,
            successAssertionBond: 1,
            successOracleSpecHash: keccak256("goal-success-spec"),
            successAssertionPolicyHash: keccak256("goal-success-policy")
        });

        p.flowMetadata = GoalFactory.FlowMetadataParams({
            title: "Goal",
            description: "Goal description",
            image: "ipfs://image",
            tagline: "tagline",
            url: "https://example.com"
        });

        p.underwriting = GoalFactory.UnderwritingParams({coverageLambda: 0, budgetPremiumPpm: 0, budgetSlashPpm: 0});

        p.budgetTCR = GoalFactory.BudgetTCRParams({
            allocationMechanismAdmin: address(0),
            invalidRoundRewardsSink: address(0),
            submissionDepositStrategy: address(0),
            submissionBaseDeposit: 1,
            removalBaseDeposit: 1,
            submissionChallengeBaseDeposit: 1,
            removalChallengeBaseDeposit: 1,
            registrationMetaEvidence: "ipfs://registration",
            clearingMetaEvidence: "ipfs://clearing",
            challengePeriodDuration: 1 days,
            arbitratorExtraData: hex"",
            budgetBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1,
                maxFundingHorizon: 365 days,
                minExecutionDuration: 1,
                maxExecutionDuration: 365 days,
                minActivationThreshold: 1,
                maxActivationThreshold: type(uint128).max,
                maxRunwayCap: type(uint128).max
            }),
            oracleBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 1}),
            budgetSuccessResolver: _budgetSuccessResolver,
            arbitratorParams: IArbitrator.ArbitratorParams({
                votingPeriod: 1,
                votingDelay: 1,
                revealPeriod: 1,
                arbitrationCost: 1,
                wrongOrMissedSlashBps: 100,
                slashCallerBountyBps: 100
            })
        });
    }

    function _seedStaker(StakeVault vault, MockMintableToken goalToken, address staker) internal {
        goalToken.mint(staker, STAKE_AMOUNT);
        vm.prank(staker);
        goalToken.approve(address(vault), type(uint256).max);
        vm.prank(staker);
        vault.depositGoal(STAKE_AMOUNT);
    }

    function _appendRemovedBudgets(
        BudgetStakeLedger ledger,
        address goalFlow,
        address budgetTcr,
        uint256 count
    ) internal {
        MockBudgetFlow budgetFlow = new MockBudgetFlow(goalFlow);
        MockPremiumEscrow premiumEscrow = new MockPremiumEscrow();

        for (uint256 i = 0; i < count; i++) {
            MockBudgetTreasury budgetTreasury = new MockBudgetTreasury(address(budgetFlow), address(premiumEscrow));
            bytes32 recipientId = bytes32(i + 1);

            vm.prank(budgetTcr);
            ledger.registerBudget(recipientId, address(budgetTreasury));

            vm.prank(budgetTcr);
            ledger.removeBudget(recipientId);
        }
    }

    function _measurePrepare(StakeVault vault, address user, uint256 maxBudgets) internal returns (uint256 gasUsed) {
        vm.prank(user);
        uint256 gasBefore = gasleft();
        vault.prepareUnderwriterWithdrawal(maxBudgets);
        gasUsed = gasBefore - gasleft();
    }

    function _measureWithdraw(StakeVault vault, address user) internal returns (uint256 gasUsed) {
        vm.prank(user);
        uint256 gasBefore = gasleft();
        vault.withdrawGoal(WITHDRAW_AMOUNT, user);
        gasUsed = gasBefore - gasleft();
    }

    function _maxBudgetsUnderGasCap(
        StakeVault vault,
        uint256 maxCandidate,
        uint256 gasCap
    ) internal returns (uint256 maxBudgets) {
        uint256 lo = 0;
        uint256 hi = maxCandidate;
        uint256 probeNonce = 1;

        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            address probeUser = _probeUser(gasCap, mid, probeNonce);
            probeNonce++;

            bool ok = _attemptPrepareWithGasCap(vault, probeUser, mid, gasCap);
            if (ok) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        return lo;
    }

    function _attemptPrepareWithGasCap(
        StakeVault vault,
        address user,
        uint256 maxBudgets,
        uint256 gasCap
    ) internal returns (bool ok) {
        vm.prank(user);
        (ok,) = address(vault).call{gas: gasCap}(
            abi.encodeWithSelector(IStakeVault.prepareUnderwriterWithdrawal.selector, maxBudgets)
        );
    }

    function _measureChunkedExit(
        StakeVault vault,
        address user,
        uint256 chunkSize
    ) internal returns (uint256 totalPrepareGas, uint256 prepareCalls, uint256 withdrawGas) {
        while (true) {
            vm.prank(user);
            uint256 gasBefore = gasleft();
            (, , bool complete) = vault.prepareUnderwriterWithdrawal(chunkSize);
            totalPrepareGas += gasBefore - gasleft();
            prepareCalls++;
            if (complete) break;
        }

        vm.prank(user);
        uint256 gasBeforeWithdraw = gasleft();
        vault.withdrawGoal(WITHDRAW_AMOUNT, user);
        withdrawGas = gasBeforeWithdraw - gasleft();
    }

    function _freshUser(uint256 index) internal pure returns (address user) {
        user = address(uint160(0x500000 + index));
    }

    function _probeUser(uint256 gasCap, uint256 mid, uint256 nonce) internal pure returns (address user) {
        user = address(uint160(uint256(keccak256(abi.encodePacked(gasCap, mid, nonce)))));
        if (user == address(0)) {
            user = address(1);
        }
    }
}

contract DummyContract {}

contract DummyMultiTerminal {
    function STORE() external pure returns (address) {
        return address(0xB0A1);
    }
}

contract MockMintableToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract MockBudgetTcrFactory {
    function predictBudgetTCRAddress(
        address sender,
        address goalFlow,
        address goalTreasury,
        uint256 goalRevnetId,
        address votingToken
    ) external pure returns (address predicted) {
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked("mock-budget-tcr", sender, goalFlow, goalTreasury, goalRevnetId, votingToken))))
        );
    }

    function deployBudgetTCRStackForGoal(
        BudgetTCRFactory.RegistryConfigInput calldata,
        IBudgetTCR.DeploymentConfig calldata deploymentConfig,
        IArbitrator.ArbitratorParams calldata
    ) external returns (BudgetTCRFactory.DeployedBudgetTCRStack memory deployed) {
        address budgetTcr = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            "mock-budget-tcr",
                            msg.sender,
                            address(deploymentConfig.goalFlow),
                            address(deploymentConfig.goalTreasury),
                            deploymentConfig.goalRevnetId,
                            address(deploymentConfig.cobuildToken)
                        )
                    )
                )
            )
        );

        deployed = BudgetTCRFactory.DeployedBudgetTCRStack({
            budgetTCR: budgetTcr,
            arbitrator: address(0xA11B),
            token: address(deploymentConfig.cobuildToken)
        });
    }
}

contract MockRevDeployer {
    MockDirectory internal immutable _directory;
    MockController internal immutable _controller;
    MockTokens internal immutable _tokens;
    MockRulesets internal immutable _rulesets;

    uint256 internal _nextRevnetId = 1_000;

    constructor(MockDirectory directory_, MockController controller_, MockTokens tokens_, MockRulesets rulesets_) {
        _directory = directory_;
        _controller = controller_;
        _tokens = tokens_;
        _rulesets = rulesets_;
    }

    function deployFor(
        uint256,
        IREVDeployer.REVConfig calldata configuration,
        JBTerminalConfig[] calldata,
        IREVDeployer.REVBuybackHookConfig calldata,
        IREVDeployer.REVSuckerDeploymentConfig calldata
    ) external returns (uint256 revnetId) {
        revnetId = _nextRevnetId;
        _nextRevnetId++;

        MockMintableToken goalToken = new MockMintableToken(configuration.description.name, configuration.description.ticker, 18);
        _tokens.setTokenOf(revnetId, address(goalToken));
        _tokens.setProjectIdOf(address(goalToken), revnetId);
        _directory.setController(revnetId, address(_controller));

        uint48 terminalStart = uint48(block.timestamp + 30 days);
        if (configuration.stageConfigurations.length > 1) {
            terminalStart = configuration.stageConfigurations[1].startsAtOrAfter;
        }
        _rulesets.configureTwoRulesetSchedule(revnetId, terminalStart, 2e18);
    }

    function CONTROLLER() external view returns (IJBController) {
        return IJBController(address(_controller));
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(address(_directory));
    }

    function PROJECTS() external pure returns (address) {
        return address(0);
    }
}

contract MockController {
    MockTokens internal immutable _tokens;
    MockRulesets internal immutable _rulesets;

    constructor(MockTokens tokens_, MockRulesets rulesets_) {
        _tokens = tokens_;
        _rulesets = rulesets_;
    }

    function TOKENS() external view returns (IJBTokens) {
        return IJBTokens(address(_tokens));
    }

    function RULESETS() external view returns (IJBRulesets) {
        return IJBRulesets(address(_rulesets));
    }

    function burnTokensOf(address, uint256, uint256, string calldata) external {}
}

contract MockDirectory {
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

contract MockTokens {
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

contract MockRulesets is IJBControlled {
    struct RulesetPair {
        JBRuleset base;
        JBRuleset terminal;
        bool configured;
    }

    mapping(uint256 => RulesetPair) internal _pairOf;
    IJBDirectory internal _directory;

    function setDirectory(IJBDirectory directory_) external {
        _directory = directory_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function configureTwoRulesetSchedule(uint256 projectId, uint48 terminalStart, uint112 openWeight) external {
        uint48 nowTs = uint48(block.timestamp);

        RulesetPair storage pair = _pairOf[projectId];
        pair.base = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: nowTs,
            duration: 0,
            weight: openWeight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        pair.terminal = JBRuleset({
            cycleNumber: 2,
            id: 2,
            basedOnId: 1,
            start: terminalStart,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        pair.configured = true;
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        RulesetPair storage pair = _pairOf[projectId];
        return pair.base;
    }

    function latestQueuedOf(uint256 projectId) external view returns (JBRuleset memory ruleset, JBApprovalStatus status) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) {
            return (ruleset, JBApprovalStatus.Empty);
        }
        return (pair.terminal, JBApprovalStatus.Approved);
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory ruleset) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return ruleset;
        if (rulesetId == pair.base.id) return pair.base;
        if (rulesetId == pair.terminal.id) return pair.terminal;
        return ruleset;
    }
}

contract MockBudgetFlow {
    address internal _parent;

    constructor(address parent_) {
        _parent = parent_;
    }

    function parent() external view returns (address) {
        return _parent;
    }
}

contract MockBudgetTreasury {
    address internal immutable _flow;
    address internal immutable _premiumEscrow;

    constructor(address flow_, address premiumEscrow_) {
        _flow = flow_;
        _premiumEscrow = premiumEscrow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }

    function premiumEscrow() external view returns (address) {
        return _premiumEscrow;
    }

    function executionDuration() external pure returns (uint64) {
        return 7 days;
    }

    function fundingDeadline() external pure returns (uint64) {
        return 1;
    }

    function activatedAt() external pure returns (uint64) {
        return 0;
    }

    function resolvedAt() external pure returns (uint64) {
        return 1;
    }

    function resolved() external pure returns (bool) {
        return true;
    }

    function state() external pure returns (IBudgetTreasury.BudgetState) {
        return IBudgetTreasury.BudgetState.Succeeded;
    }

    function retryTerminalSideEffects() external {}
}

contract MockPremiumEscrow {
    function userCov(address) external pure returns (uint256) {
        return 0;
    }

    function exposureIntegral(address) external pure returns (uint256) {
        return 0;
    }

    function creditDrawn(address) external pure returns (uint256) {
        return 0;
    }

    function slash(address) external pure returns (uint256) {
        return 0;
    }
}
