// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { GoalFactory } from "src/goals/GoalFactory.sol";
import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { ISuperfluid } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract GoalFactoryTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 138;
    uint8 internal constant COBUILD_DECIMALS = 6;
    uint32 internal constant SCALE_1E6 = 1_000_000;
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant GOAL_OWNER = address(0xA11CE);
    address internal constant SUCCESS_RESOLVER = address(0xA11CF);
    address internal constant BUDGET_SUCCESS_RESOLVER = address(0xA11D0);
    address internal constant RENT_RECIPIENT = address(0xA11D1);

    GoalFactoryTestToken internal cobuildToken;
    address internal revDeployer;
    address internal superfluidHost;
    address internal budgetTcrFactory;
    address internal goalTreasuryImpl;
    address internal flowImpl;
    address internal splitHookImpl;
    address internal defaultSubmissionDepositStrategy;
    address internal defaultBudgetTcrGovernor;
    address internal defaultInvalidRoundRewardsSink;

    function setUp() public {
        cobuildToken = new GoalFactoryTestToken(COBUILD_DECIMALS);
        revDeployer = address(new GoalFactoryMockContract());
        superfluidHost = address(new GoalFactoryMockContract());
        budgetTcrFactory = address(new GoalFactoryMockContract());
        goalTreasuryImpl = address(new GoalFactoryMockContract());
        flowImpl = address(new GoalFactoryMockContract());
        splitHookImpl = address(new GoalFactoryMockContract());
        defaultSubmissionDepositStrategy = address(new GoalFactoryMockContract());
        defaultBudgetTcrGovernor = makeAddr("defaultBudgetTcrGovernor");
        defaultInvalidRoundRewardsSink = makeAddr("defaultInvalidRoundRewardsSink");
    }

    function test_constructor_storesImmutables() public {
        GoalFactoryHarness factory = _deployFactory();

        assertEq(address(factory.REV_DEPLOYER()), revDeployer);
        assertEq(address(factory.SUPERFLUID_HOST()), superfluidHost);
        assertEq(address(factory.BUDGET_TCR_FACTORY()), budgetTcrFactory);
        assertEq(factory.COBUILD_TOKEN(), address(cobuildToken));
        assertEq(factory.COBUILD_DECIMALS(), COBUILD_DECIMALS);
        assertEq(factory.COBUILD_REVNET_ID(), COBUILD_REVNET_ID);
        assertEq(factory.GOAL_TREASURY_IMPL(), goalTreasuryImpl);
        assertEq(factory.FLOW_IMPL(), flowImpl);
        assertEq(factory.SPLIT_HOOK_IMPL(), splitHookImpl);
        assertEq(factory.DEFAULT_SUBMISSION_DEPOSIT_STRATEGY(), defaultSubmissionDepositStrategy);
        assertEq(factory.DEFAULT_BUDGET_TCR_GOVERNOR(), defaultBudgetTcrGovernor);
        assertEq(factory.DEFAULT_INVALID_ROUND_REWARDS_SINK(), defaultInvalidRoundRewardsSink);
    }

    function test_constructor_revertsWhenRevDeployerZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            address(0),
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenSuperfluidHostZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            address(0),
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenBudgetTcrFactoryZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            address(0),
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenCobuildTokenZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(0),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenGoalTreasuryImplZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            address(0),
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenFlowImplZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            address(0),
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenSplitHookImplZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            address(0),
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenSubmissionDepositStrategyZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            address(0),
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenGovernorZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            address(0),
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenInvalidRoundRewardsSinkZero() public {
        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            address(0)
        );
    }

    function test_constructor_revertsWhenGoalTreasuryImplHasNoCode() public {
        address noCode = makeAddr("noCodeGoalTreasury");
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCode));
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            noCode,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenFlowImplHasNoCode() public {
        address noCode = makeAddr("noCodeFlow");
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCode));
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            noCode,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenSplitHookImplHasNoCode() public {
        address noCode = makeAddr("noCodeSplitHook");
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCode));
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            noCode,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_constructor_revertsWhenSubmissionDepositStrategyHasNoCode() public {
        address noCode = makeAddr("noCodeDepositStrategy");
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.NOT_A_CONTRACT.selector, noCode));
        _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            noCode,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function test_deployGoal_revertsWhenRevnetOwnerZero() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.revnet.owner = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenDurationZero() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.revnet.durationSeconds = 0;

        vm.expectRevert(GoalFactory.INVALID_DURATION.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenReservedPercentExceedsBpsDenominator() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.revnet.reservedPercent = BPS_DENOMINATOR + 1;

        vm.expectRevert(GoalFactory.INVALID_RESERVED_PERCENT.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenTaxRateExceedsBpsDenominator() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.revnet.cashOutTaxRate = BPS_DENOMINATOR + 1;

        vm.expectRevert(GoalFactory.INVALID_TAX_RATE.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSuccessResolverZero() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.success.successResolver = address(0);

        vm.expectRevert(GoalFactory.ADDRESS_ZERO.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSuccessAssertionLivenessZero() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.success.successAssertionLiveness = 0;

        vm.expectRevert(GoalFactory.INVALID_ASSERTION_CONFIG.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSuccessOracleSpecHashZero() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.success.successOracleSpecHash = bytes32(0);

        vm.expectRevert(GoalFactory.INVALID_ASSERTION_CONFIG.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSuccessAssertionPolicyHashZero() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.success.successAssertionPolicyHash = bytes32(0);

        vm.expectRevert(GoalFactory.INVALID_ASSERTION_CONFIG.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSettlementEscrowScaleExceedsOneE6() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.settlement.settlementRewardEscrowScaled = SCALE_1E6 + 1;

        vm.expectRevert(GoalFactory.INVALID_SCALE.selector);
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenTreasurySettlementEscrowScaleExceedsOneE6() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.DeployParams memory p = _defaultDeployParams();
        p.settlement.treasurySettlementRewardEscrowScaled = SCALE_1E6 + 1;

        vm.expectRevert(GoalFactory.INVALID_SCALE.selector);
        factory.deployGoal(p);
    }

    function test_resolveRegistryConfig_usesDefaultAddressesWhenUnset() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.BudgetTCRParams memory p = _defaultBudgetTCRParams();
        p.governor = address(0);
        p.invalidRoundRewardsSink = address(0);
        p.submissionDepositStrategy = address(0);

        BudgetTCRFactory.RegistryConfigInput memory out = factory.exposedResolveRegistryConfig(p);

        assertEq(out.governor, defaultBudgetTcrGovernor);
        assertEq(out.invalidRoundRewardsSink, defaultInvalidRoundRewardsSink);
        assertEq(address(out.submissionDepositStrategy), defaultSubmissionDepositStrategy);
        assertEq(address(out.votingToken), address(cobuildToken));
        assertEq(out.challengePeriodDuration, p.challengePeriodDuration);
    }

    function test_resolveRegistryConfig_preservesExplicitOverrides() public {
        GoalFactoryHarness factory = _deployFactory();
        GoalFactory.BudgetTCRParams memory p = _defaultBudgetTCRParams();
        address overrideGovernor = makeAddr("overrideGovernor");
        address overrideInvalidSink = makeAddr("overrideInvalidSink");
        address overrideSubmissionStrategy = address(new GoalFactoryMockContract());
        p.governor = overrideGovernor;
        p.invalidRoundRewardsSink = overrideInvalidSink;
        p.submissionDepositStrategy = overrideSubmissionStrategy;

        BudgetTCRFactory.RegistryConfigInput memory out = factory.exposedResolveRegistryConfig(p);

        assertEq(out.governor, overrideGovernor);
        assertEq(out.invalidRoundRewardsSink, overrideInvalidSink);
        assertEq(address(out.submissionDepositStrategy), overrideSubmissionStrategy);
        assertEq(out.submissionBaseDeposit, p.submissionBaseDeposit);
        assertEq(out.removalBaseDeposit, p.removalBaseDeposit);
        assertEq(out.submissionChallengeBaseDeposit, p.submissionChallengeBaseDeposit);
        assertEq(out.removalChallengeBaseDeposit, p.removalChallengeBaseDeposit);
        assertEq(out.registrationMetaEvidence, p.registrationMetaEvidence);
        assertEq(out.clearingMetaEvidence, p.clearingMetaEvidence);
    }

    function test_resolveMinRaiseWindow_usesHalfDurationWhenUnset() public {
        GoalFactoryHarness factory = _deployFactory();
        uint32 resolved = factory.exposedResolveMinRaiseWindow(10 days, 0);
        assertEq(resolved, 5 days);
    }

    function test_resolveMinRaiseWindow_usesFullDurationWhenHalfRoundsToZero() public {
        GoalFactoryHarness factory = _deployFactory();
        uint32 resolved = factory.exposedResolveMinRaiseWindow(1, 0);
        assertEq(resolved, 1);
    }

    function test_resolveMinRaiseWindow_revertsWhenResolvedWindowExceedsDuration() public {
        GoalFactoryHarness factory = _deployFactory();
        vm.expectRevert(abi.encodeWithSelector(GoalFactory.INVALID_MIN_RAISE_WINDOW.selector, uint32(11), uint32(10)));
        factory.exposedResolveMinRaiseWindow(10, 11);
    }

    function _deployFactory() internal returns (GoalFactoryHarness) {
        return _deployFactoryWithOverrides(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            address(cobuildToken),
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        );
    }

    function _deployFactoryWithOverrides(
        address revDeployer_,
        address superfluidHost_,
        address budgetTcrFactory_,
        address cobuildToken_,
        address goalTreasuryImpl_,
        address flowImpl_,
        address splitHookImpl_,
        address defaultSubmissionDepositStrategy_,
        address defaultBudgetTcrGovernor_,
        address defaultInvalidRoundRewardsSink_
    )
        internal
        returns (GoalFactoryHarness)
    {
        return new GoalFactoryHarness(
            IREVDeployer(revDeployer_),
            ISuperfluid(superfluidHost_),
            BudgetTCRFactory(budgetTcrFactory_),
            cobuildToken_,
            COBUILD_REVNET_ID,
            goalTreasuryImpl_,
            flowImpl_,
            splitHookImpl_,
            defaultSubmissionDepositStrategy_,
            defaultBudgetTcrGovernor_,
            defaultInvalidRoundRewardsSink_
        );
    }

    function _defaultBudgetTCRParams() internal pure returns (GoalFactory.BudgetTCRParams memory p) {
        p.governor = address(0);
        p.invalidRoundRewardsSink = address(0);
        p.submissionDepositStrategy = address(0);
        p.submissionBaseDeposit = 1e18;
        p.removalBaseDeposit = 2e18;
        p.submissionChallengeBaseDeposit = 3e18;
        p.removalChallengeBaseDeposit = 4e18;
        p.registrationMetaEvidence = "ipfs://registration";
        p.clearingMetaEvidence = "ipfs://clearing";
        p.challengePeriodDuration = 1 days;
        p.arbitratorExtraData = bytes("extra-data");
        p.budgetBounds = IBudgetTCR.BudgetValidationBounds({
            minFundingLeadTime: 1,
            maxFundingHorizon: 2,
            minExecutionDuration: 3,
            maxExecutionDuration: 4,
            minActivationThreshold: 5,
            maxActivationThreshold: 6,
            maxRunwayCap: 7
        });
        p.oracleBounds = IBudgetTCR.OracleValidationBounds({ maxOracleType: 1, liveness: 2, bondAmount: 3 });
        p.budgetSuccessResolver = BUDGET_SUCCESS_RESOLVER;
        p.arbitratorParams = IArbitrator.ArbitratorParams({
            votingPeriod: 1,
            votingDelay: 2,
            revealPeriod: 3,
            arbitrationCost: 4,
            wrongOrMissedSlashBps: 5,
            slashCallerBountyBps: 6
        });
    }

    function _defaultDeployParams() internal pure returns (GoalFactory.DeployParams memory p) {
        p.revnet = GoalFactory.RevnetParams({
            owner: GOAL_OWNER,
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 1e18,
            cashOutTaxRate: 0,
            reservedPercent: BPS_DENOMINATOR,
            durationSeconds: 1 days
        });
        p.timing = GoalFactory.GoalTimingParams({ minRaise: 1e18, minRaiseDurationSeconds: 0 });
        p.success = GoalFactory.SuccessParams({
            successResolver: SUCCESS_RESOLVER,
            successAssertionLiveness: 1 days,
            successAssertionBond: 1e18,
            successOracleSpecHash: keccak256("oracle-spec"),
            successAssertionPolicyHash: keccak256("assertion-policy")
        });
        p.settlement = GoalFactory.SettlementParams({
            settlementRewardEscrowScaled: SCALE_1E6,
            treasurySettlementRewardEscrowScaled: SCALE_1E6
        });
        p.flowMetadata = GoalFactory.FlowMetadataParams({
            title: "Goal title",
            description: "Goal description",
            image: "ipfs://image"
        });
        p.budgetTCR = _defaultBudgetTCRParams();
        p.rentRecipient = RENT_RECIPIENT;
        p.rentWadPerSecond = 1;
    }
}

contract GoalFactoryHarness is GoalFactory {
    constructor(
        IREVDeployer revDeployer,
        ISuperfluid superfluidHost,
        BudgetTCRFactory budgetTcrFactory,
        address cobuildToken,
        uint256 cobuildRevnetId,
        address goalTreasuryImpl,
        address flowImpl,
        address splitHookImpl,
        address defaultSubmissionDepositStrategy,
        address defaultBudgetTcrGovernor,
        address defaultInvalidRoundRewardsSink
    )
        GoalFactory(
            revDeployer,
            superfluidHost,
            budgetTcrFactory,
            cobuildToken,
            cobuildRevnetId,
            goalTreasuryImpl,
            flowImpl,
            splitHookImpl,
            defaultSubmissionDepositStrategy,
            defaultBudgetTcrGovernor,
            defaultInvalidRoundRewardsSink
        )
    { }

    function exposedResolveRegistryConfig(
        BudgetTCRParams calldata p
    )
        external
        view
        returns (BudgetTCRFactory.RegistryConfigInput memory)
    {
        return _resolveRegistryConfig(p);
    }

    function exposedResolveMinRaiseWindow(uint32 durationSeconds, uint32 minRaiseDurationSeconds)
        external
        pure
        returns (uint32)
    {
        return _resolveMinRaiseWindow(durationSeconds, minRaiseDurationSeconds);
    }
}

contract GoalFactoryMockContract { }

contract GoalFactoryTestToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(uint8 tokenDecimals) ERC20("Cobuild Token", "CBD") {
        _tokenDecimals = tokenDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}
