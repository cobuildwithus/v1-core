// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {JurorSlasherRouter} from "src/goals/JurorSlasherRouter.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {IBudgetStackDeployer} from "src/interfaces/IBudgetStackDeployer.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";
import {StakeCoverageGatePolicy} from "src/goals/policies/StakeCoverageGatePolicy.sol";

contract _MockImplementation {}

contract _MockGoalTreasuryForFactory {
    address internal _stakeVault;
    address internal immutable _budgetStakeLedger;
    address public configuredSlasher;
    address public configuredUnderwriterSlasher;

    constructor(address budgetStakeLedger_) {
        _budgetStakeLedger = budgetStakeLedger_;
    }

    function setStakeVault(address stakeVault_) external {
        _stakeVault = stakeVault_;
    }

    function stakeVault() external view returns (address) {
        return _stakeVault;
    }

    function budgetStakeLedger() external view returns (address) {
        return _budgetStakeLedger;
    }

    function configureJurorSlasher(address slasher) external {
        configuredSlasher = slasher;
        _MockStakeVaultForFactory(_stakeVault).setJurorSlasher(slasher);
    }

    function configureUnderwriterSlasher(address slasher) external {
        configuredUnderwriterSlasher = slasher;
        _MockStakeVaultForFactory(_stakeVault).setUnderwriterSlasher(slasher);
    }
}

contract _MockStakeVaultForFactory {
    address internal immutable _goalTreasury;
    address public jurorSlasher;
    address public underwriterSlasher;

    constructor(address goalTreasury_) {
        _goalTreasury = goalTreasury_;
    }

    function goalTreasury() external view returns (address) {
        return _goalTreasury;
    }

    function setJurorSlasher(address slasher) external {
        if (msg.sender != _goalTreasury) revert();
        jurorSlasher = slasher;
    }

    function setUnderwriterSlasher(address slasher) external {
        if (msg.sender != _goalTreasury) revert();
        underwriterSlasher = slasher;
    }
}

contract _MockUnderwriterSlasherRouterForFactory {
    IStakeVault private immutable _stakeVault;
    address private immutable _authority;

    constructor(IStakeVault stakeVault_, address authority_) {
        _stakeVault = stakeVault_;
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }

    function stakeVault() external view returns (IStakeVault) {
        return _stakeVault;
    }

    function isAuthorizedPremiumEscrow(address) external pure returns (bool) {
        return true;
    }

    function setAuthorizedPremiumEscrow(address, bool) external {}

    function slashUnderwriter(address, uint256) external {}
}

contract _MockUnderwriterSlasherRouterWithoutStakeVaultForFactory {
    address private immutable _authority;

    constructor(address authority_) {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }

    function isAuthorizedPremiumEscrow(address) external pure returns (bool) {
        return true;
    }

    function setAuthorizedPremiumEscrow(address, bool) external {}

    function slashUnderwriter(address, uint256) external {}
}

contract _MockSubmissionDepositStrategyWithoutCapabilities is ISubmissionDepositStrategy {
    IERC20 private immutable _token;

    constructor(IERC20 token_) {
        _token = token_;
    }

    function token() external view override returns (IERC20) {
        return _token;
    }

    function getSubmissionDepositAction(
        bytes32,
        IGeneralizedTCR.Status,
        IArbitrable.Party,
        address,
        address,
        address,
        uint256
    ) external pure override returns (DepositAction action, address recipient) {
        return (DepositAction.Hold, address(0));
    }
}

contract BudgetTCRFactoryTest is Test, SpendPolicyTestUtils {
    using stdStorage for StdStorage;

    uint256 internal constant DEFAULT_ESCROW_BOND_BPS = 5;

    event BudgetStackDeployed(
        address indexed budgetTCR,
        bytes32 indexed itemID,
        address indexed childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    );
    event BudgetAllocationMechanismDeployed(
        address indexed budgetTCR,
        bytes32 indexed itemID,
        address indexed allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory
    );

    function test_budgetTCRDeployer_constructor_sets_budget_treasury_implementation() public {
        BudgetTCRDeployer deployer = _deployBudgetTcrDeployer();
        address implementation = deployer.budgetTreasuryImplementation();

        assertTrue(implementation != address(0));
        assertGt(implementation.code.length, 0);
    }

    function test_constructor_reverts_when_budget_tcr_implementation_has_no_code() public {
        address noCode = makeAddr("no-code-budget-tcr");
        (, address arbImpl, address deployerImpl) = _validImplementations();

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new BudgetTCRFactory(noCode, arbImpl, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_constructor_reverts_when_arbitrator_implementation_has_no_code() public {
        address noCode = makeAddr("no-code-arbitrator");
        (address budgetImpl,, address deployerImpl) = _validImplementations();

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new BudgetTCRFactory(budgetImpl, noCode, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_constructor_reverts_when_stack_deployer_implementation_has_no_code() public {
        address noCode = makeAddr("no-code-deployer");
        (address budgetImpl, address arbImpl,) = _validImplementations();

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new BudgetTCRFactory(budgetImpl, arbImpl, noCode, address(this), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_constructor_reverts_when_authorized_caller_is_zero() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();

        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(0), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_constructor_reverts_when_escrow_bond_bps_is_zero() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.INVALID_ESCROW_BOND_BPS.selector, 0));
        new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), 0);
    }

    function test_constructor_reverts_when_escrow_bond_bps_exceeds_denominator() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();
        uint256 invalidBps = 10_001;

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.INVALID_ESCROW_BOND_BPS.selector, invalidBps));
        new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), invalidBps);
    }

    function test_constructor_accepts_escrow_bond_bps_at_lower_bound() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();
        uint256 minBps = 1;

        BudgetTCRFactory factory = new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), minBps);

        assertEq(factory.escrowBondBps(), minBps);
    }

    function test_constructor_accepts_escrow_bond_bps_at_denominator() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();
        uint256 maxBps = 10_000;

        BudgetTCRFactory factory = new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), maxBps);

        assertEq(factory.escrowBondBps(), maxBps);
    }

    function test_constructor_accepts_implementation_addresses_with_code() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();

        BudgetTCRFactory factory =
            new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);

        assertEq(factory.budgetTCRImplementation(), budgetImpl);
        assertEq(factory.arbitratorImplementation(), arbImpl);
        assertEq(factory.stackDeployerImplementation(), deployerImpl);
        assertEq(factory.authorizedCaller(), address(this));
        assertEq(factory.escrowBondBps(), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_setAuthorizedCaller_selector_is_not_supported_and_authorized_caller_remains_immutable() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();
        address immutableCaller = makeAddr("immutable-caller");
        BudgetTCRFactory factory =
            new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, immutableCaller, DEFAULT_ESCROW_BOND_BPS);

        (bool success,) = address(factory)
            .call(
                abi.encodeWithSelector(bytes4(keccak256("setAuthorizedCaller(address)")), makeAddr("attempted-caller"))
            );

        assertFalse(success);
        assertEq(factory.authorizedCaller(), immutableCaller);
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_caller_not_authorized() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validImplementations();
        address authorizedCaller = makeAddr("authorized-caller");
        address unauthorizedCaller = makeAddr("unauthorized-caller");
        BudgetTCRFactory factory =
            new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, authorizedCaller, DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig;
        IBudgetTCR.DeploymentConfig memory deploymentConfig;
        IArbitrator.ArbitratorParams memory arbitratorParams;

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.UNAUTHORIZED_CALLER.selector, unauthorizedCaller));
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_is_zero() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deploymentConfig.underwriterSlasherRouter = address(0);

        vm.expectRevert(BudgetTCRFactory.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_has_no_code() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deploymentConfig.underwriterSlasherRouter = makeAddr("no-code-underwriter-router");

        vm.expectRevert(BudgetTCRFactory.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_is_not_supported() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        address unsupportedRouter = address(new _MockImplementation());
        deploymentConfig.underwriterSlasherRouter = unsupportedRouter;

        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRFactory.UNSUPPORTED_UNDERWRITER_SLASHER.selector, unsupportedRouter)
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_authority_mismatch() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            address(this),
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );
        address unexpectedAuthority = makeAddr("unexpected-underwriter-authority");
        deploymentConfig.underwriterSlasherRouter =
            address(new _MockUnderwriterSlasherRouterForFactory(IStakeVault(address(stakeVault)), unexpectedAuthority));

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.INVALID_UNDERWRITER_SLASHER_AUTHORITY.selector, expectedBudgetTCR, unexpectedAuthority
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_missing_stake_vault() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            address(this),
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );
        address routerWithoutStakeVault =
            address(new _MockUnderwriterSlasherRouterWithoutStakeVaultForFactory(expectedBudgetTCR));
        deploymentConfig.underwriterSlasherRouter = routerWithoutStakeVault;

        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRFactory.UNSUPPORTED_UNDERWRITER_SLASHER.selector, routerWithoutStakeVault)
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_stake_vault_mismatch() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            address(this),
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );
        _MockGoalTreasuryForFactory otherGoalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory otherStakeVault = new _MockStakeVaultForFactory(address(otherGoalTreasury));
        deploymentConfig.underwriterSlasherRouter = address(
            new _MockUnderwriterSlasherRouterForFactory(IStakeVault(address(otherStakeVault)), expectedBudgetTCR)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.INVALID_UNDERWRITER_SLASHER_STAKE_VAULT.selector,
                address(stakeVault),
                address(otherStakeVault)
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_mismatches_stake_vault_configuration()
        public
    {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            address(this),
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );
        address mismatchedRouter =
            address(new _MockUnderwriterSlasherRouterForFactory(IStakeVault(address(stakeVault)), expectedBudgetTCR));
        deploymentConfig.underwriterSlasherRouter = mismatchedRouter;

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.UNDERWRITER_SLASHER_MISMATCH.selector,
                mismatchedRouter,
                stakeVault.underwriterSlasher()
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_stake_vault_underwriter_slasher_not_preconfigured() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        goalTreasury.configureUnderwriterSlasher(address(0));

        vm.expectRevert(BudgetTCRFactory.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_allowsConfiguredAuthorizedCaller_andDeploysAtPredictedAddress() public {
        address authorizedCaller = makeAddr("authorized-caller");
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(authorizedCaller, DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            authorizedCaller,
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        address predictedBudgetTCR = factory.predictBudgetTCRAddress(
            authorizedCaller,
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );

        vm.prank(authorizedCaller);
        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        assertEq(deployed.budgetTCR, predictedBudgetTCR);
    }

    function test_deployBudgetTCRStackForGoal_deploysBudgetTCRAtPredictedDeterministicAddress() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        address predictedBudgetTCR = factory.predictBudgetTCRAddress(
            address(this),
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);
        assertEq(deployed.budgetTCR, predictedBudgetTCR);

        vm.expectRevert();
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);
    }

    function test_deployBudgetTCRStackForGoal_initializes_clone_once_and_rejects_reinitialize() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();
        arbitratorParams.wrongOrMissedSlashBps = 777;
        arbitratorParams.slashCallerBountyBps = 321;

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        assertTrue(deployed.budgetTCR != address(0));
        assertTrue(deployed.arbitrator != address(0));
        assertEq(deployed.token, address(votingToken));
        address configuredSlasher = goalTreasury.configuredSlasher();
        assertEq(stakeVault.jurorSlasher(), configuredSlasher);
        assertTrue(configuredSlasher != deployed.arbitrator);
        assertEq(factory.jurorSlasherRouterByBudgetTCR(deployed.budgetTCR), configuredSlasher);
        JurorSlasherRouter router = JurorSlasherRouter(configuredSlasher);
        assertEq(router.authority(), address(factory));
        assertTrue(router.isAuthorizedSlasher(deployed.arbitrator));
        assertEq(goalTreasury.configuredUnderwriterSlasher(), deploymentConfig.underwriterSlasherRouter);
        assertEq(stakeVault.underwriterSlasher(), deploymentConfig.underwriterSlasherRouter);
        ERC20VotesArbitrator deployedArbitrator = ERC20VotesArbitrator(deployed.arbitrator);
        assertEq(deployedArbitrator.stakeVault(), address(stakeVault));
        assertEq(deployedArbitrator.wrongOrMissedSlashBps(), arbitratorParams.wrongOrMissedSlashBps);
        assertEq(deployedArbitrator.slashCallerBountyBps(), arbitratorParams.slashCallerBountyBps);
        assertEq(BudgetTCR(deployed.budgetTCR).underwriterSlasherRouter(), deploymentConfig.underwriterSlasherRouter);
        assertEq(
            BudgetTCR(deployed.budgetTCR).premiumEscrowImplementation(), deploymentConfig.premiumEscrowImplementation
        );
        assertEq(BudgetTCR(deployed.budgetTCR).budgetPremiumPpm(), deploymentConfig.budgetPremiumPpm);

        IBudgetTCR.InitConfig memory fullRegistryConfig = IBudgetTCR.InitConfig({
            allocationMechanismAdmin: registryConfig.allocationMechanismAdmin,
            tcrConfig: IGeneralizedTCRConfig.RegistryConfig({
                arbitrator: IArbitrator(deployed.arbitrator),
                votingToken: registryConfig.votingToken,
                submissionDepositStrategy: registryConfig.submissionDepositStrategy,
                registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                    arbitratorExtraData: registryConfig.registryPolicy.arbitratorExtraData,
                    registrationMetaEvidence: registryConfig.registryPolicy.registrationMetaEvidence,
                    clearingMetaEvidence: registryConfig.registryPolicy.clearingMetaEvidence,
                    submissionBaseDeposit: registryConfig.registryPolicy.submissionBaseDeposit,
                    removalBaseDeposit: registryConfig.registryPolicy.removalBaseDeposit,
                    submissionChallengeBaseDeposit: registryConfig.registryPolicy.submissionChallengeBaseDeposit,
                    removalChallengeBaseDeposit: registryConfig.registryPolicy.removalChallengeBaseDeposit,
                    challengePeriodDuration: registryConfig.registryPolicy.challengePeriodDuration
                })
            })
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IBudgetTCR(deployed.budgetTCR).initialize(fullRegistryConfig, deploymentConfig);
    }

    function test_deployBudgetTCRStackForGoal_reusesExistingAuthorizedRouter() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        JurorSlasherRouter existingRouter = new JurorSlasherRouter(IStakeVault(address(stakeVault)), address(factory));
        goalTreasury.configureJurorSlasher(address(existingRouter));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());

        assertEq(goalTreasury.configuredSlasher(), address(existingRouter));
        assertEq(stakeVault.jurorSlasher(), address(existingRouter));
        assertTrue(existingRouter.isAuthorizedSlasher(deployed.arbitrator));
    }

    function test_deployBudgetTCRStackForGoal_reverts_whenExistingSlasherIsNotRouter() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        address unsupportedSlasher = address(new _MockImplementation());
        goalTreasury.configureJurorSlasher(unsupportedSlasher);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.UNSUPPORTED_JUROR_SLASHER.selector, unsupportedSlasher));
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_whenExistingRouterAuthorityMismatch() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        address unexpectedAuthority = makeAddr("unexpected-authority");
        JurorSlasherRouter wrongAuthorityRouter =
            new JurorSlasherRouter(IStakeVault(address(stakeVault)), unexpectedAuthority);
        goalTreasury.configureJurorSlasher(address(wrongAuthorityRouter));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.INVALID_SLASHER_AUTHORITY.selector, address(factory), unexpectedAuthority
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_whenExistingRouterStakeVaultMismatch() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        _MockGoalTreasuryForFactory otherGoalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory otherStakeVault = new _MockStakeVaultForFactory(address(otherGoalTreasury));
        JurorSlasherRouter mismatchedRouter =
            new JurorSlasherRouter(IStakeVault(address(otherStakeVault)), address(factory));
        goalTreasury.configureJurorSlasher(address(mismatchedRouter));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.INVALID_SLASHER_STAKE_VAULT.selector, address(stakeVault), address(otherStakeVault)
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_juror_slasher_not_preconfigured() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        goalTreasury.configureJurorSlasher(address(0));

        vm.expectRevert(BudgetTCRFactory.JUROR_SLASHER_NOT_CONFIGURED.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_wiresCloneFirstStackDeployer_withoutNonceGetter() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        address stackDeployer = BudgetTCR(deployed.budgetTCR).stackDeployer();
        assertTrue(stackDeployer != address(0));
        assertEq(BudgetTCRDeployer(stackDeployer).budgetTCR(), deployed.budgetTCR);

        address treasuryImplementation = BudgetTCRDeployer(stackDeployer).budgetTreasuryImplementation();
        assertTrue(treasuryImplementation != address(0));
        assertGt(treasuryImplementation.code.length, 0);

        (bool ok,) = stackDeployer.staticcall(abi.encodeWithSignature("nextBudgetTreasuryCreateNonce()"));
        assertFalse(ok);
    }

    function test_deployBudgetTCRStackForGoal_allowsExplicitNoPremiumMode_withoutUnderwriterRouter() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deploymentConfig.premiumEscrowImplementation = address(0);
        deploymentConfig.underwriterSlasherRouter = address(0);
        deploymentConfig.budgetPremiumPpm = 0;
        deploymentConfig.budgetSlashPpm = 0;
        goalTreasury.configureUnderwriterSlasher(address(0));

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
        BudgetTCR deployedBudgetTCR = BudgetTCR(deployed.budgetTCR);
        BudgetTCRDeployer stackDeployer = BudgetTCRDeployer(deployedBudgetTCR.stackDeployer());

        assertEq(deployedBudgetTCR.premiumEscrowImplementation(), address(0));
        assertEq(deployedBudgetTCR.underwriterSlasherRouter(), address(0));
        assertEq(_MockStakeVaultForFactory(address(stakeVault)).underwriterSlasher(), address(0));
        assertEq(uint8(stackDeployer.premiumEscrowMode()), uint8(IBudgetStackDeployer.PremiumEscrowMode.None));
        assertEq(stackDeployer.premiumEscrowImplementation(), address(0));
        assertTrue(stackDeployer.requireZeroPremiumAndSlashRates());
        assertEq(stackDeployer.discoveryEmitter(), address(factory));
    }

    function test_deployBudgetTCRStackForGoal_registersStackDeployerForFactoryDiscoveryCallbacks() public {
        (BudgetTCRFactory factory, BudgetTCRFactory.DeployedBudgetTCRStack memory deployed, address stackDeployer) =
            _deployDefaultStackForDiscovery();

        assertEq(factory.budgetTCRByStackDeployer(stackDeployer), deployed.budgetTCR);
        assertEq(factory.stackDeployerByBudgetTCR(deployed.budgetTCR), stackDeployer);
    }

    function test_onBudgetStackDeployed_emitsFactoryDiscoveryEvent_forRegisteredStackDeployer() public {
        (BudgetTCRFactory factory, BudgetTCRFactory.DeployedBudgetTCRStack memory deployed, address stackDeployer) =
            _deployDefaultStackForDiscovery();
        bytes32 itemID = keccak256("budget-item");
        address childFlow = makeAddr("child-flow");
        address budgetTreasury = makeAddr("budget-treasury");
        address premiumEscrow = makeAddr("premium-escrow");
        address strategy = makeAddr("strategy");

        vm.expectEmit(true, true, true, true, address(factory));
        emit BudgetStackDeployed(deployed.budgetTCR, itemID, childFlow, budgetTreasury, premiumEscrow, strategy);

        vm.prank(stackDeployer);
        factory.onBudgetStackDeployed(itemID, childFlow, budgetTreasury, premiumEscrow, strategy);
    }

    function test_onBudgetAllocationMechanismDeployed_authorizesMechanismArbitrator_andEmitsFactoryDiscoveryEvent_forRegisteredStackDeployer()
        public
    {
        (BudgetTCRFactory factory, BudgetTCRFactory.DeployedBudgetTCRStack memory deployed, address stackDeployer) =
            _deployDefaultStackForDiscovery();
        bytes32 itemID = keccak256("budget-item");
        address mechanism = makeAddr("allocation-mechanism");
        address mechanismArbitrator = makeAddr("mechanism-arbitrator");
        address roundFactory = makeAddr("round-factory");
        JurorSlasherRouter router = JurorSlasherRouter(factory.jurorSlasherRouterByBudgetTCR(deployed.budgetTCR));

        assertFalse(router.isAuthorizedSlasher(mechanismArbitrator));

        vm.expectEmit(true, true, true, true, address(factory));
        emit BudgetAllocationMechanismDeployed(deployed.budgetTCR, itemID, mechanism, mechanismArbitrator, roundFactory);

        vm.prank(stackDeployer);
        factory.onBudgetAllocationMechanismDeployed(itemID, mechanism, mechanismArbitrator, roundFactory);

        assertTrue(router.isAuthorizedSlasher(mechanismArbitrator));
    }

    function test_onBudgetAllocationMechanismDeployed_reverts_whenCachedRouterMissing_forRegisteredStackDeployer()
        public
    {
        (BudgetTCRFactory factory, BudgetTCRFactory.DeployedBudgetTCRStack memory deployed, address stackDeployer) =
            _deployDefaultStackForDiscovery();
        bytes32 itemID = keccak256("budget-item");
        address mechanism = makeAddr("allocation-mechanism");
        address mechanismArbitrator = makeAddr("mechanism-arbitrator");
        address roundFactory = makeAddr("round-factory");
        JurorSlasherRouter router = JurorSlasherRouter(factory.jurorSlasherRouterByBudgetTCR(deployed.budgetTCR));

        assertFalse(router.isAuthorizedSlasher(mechanismArbitrator));

        stdstore.target(address(factory)).sig(factory.jurorSlasherRouterByBudgetTCR.selector)
            .with_key(deployed.budgetTCR).checked_write(address(0));

        assertEq(factory.jurorSlasherRouterByBudgetTCR(deployed.budgetTCR), address(0));

        vm.expectRevert(BudgetTCRFactory.JUROR_SLASHER_NOT_CONFIGURED.selector);
        vm.prank(stackDeployer);
        factory.onBudgetAllocationMechanismDeployed(itemID, mechanism, mechanismArbitrator, roundFactory);

        assertFalse(router.isAuthorizedSlasher(mechanismArbitrator));
    }

    function test_onBudgetAllocationMechanismDeployed_reverts_whenCallerNotRegistered() public {
        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.UNAUTHORIZED_STACK_DEPLOYER.selector, address(this)));
        factory.onBudgetAllocationMechanismDeployed(
            keccak256("budget-item"),
            makeAddr("allocation-mechanism"),
            makeAddr("mechanism-arbitrator"),
            makeAddr("round-factory")
        );
    }

    function test_onBudgetStackDeployed_reverts_whenCallerNotRegistered() public {
        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.UNAUTHORIZED_STACK_DEPLOYER.selector, address(this)));
        factory.onBudgetStackDeployed(
            keccak256("budget-item"),
            makeAddr("child-flow"),
            makeAddr("budget-treasury"),
            makeAddr("premium-escrow"),
            makeAddr("strategy")
        );
    }

    function test_deployBudgetTCRStackForGoal_wiresDeploymentAndRegistryConfigIntoClone() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        MockVotesToken goalToken = new MockVotesToken("Goal", "GOAL");
        MockVotesToken cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        ISubmissionDepositStrategy submissionDepositStrategy =
            _deployPrizePoolSubmissionDepositStrategy(IERC20(address(votingToken)), makeAddr("prize-pool"));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes("arbitrator-extra"),
                registrationMetaEvidence: "ipfs://registration",
                clearingMetaEvidence: "ipfs://clearing",
                submissionBaseDeposit: 101e18,
                removalBaseDeposit: 202e18,
                submissionChallengeBaseDeposit: 303e18,
                removalChallengeBaseDeposit: 404e18,
                challengePeriodDuration: 5 days
            })
        });

        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken))
        );
        deploymentConfig.goalFlow = IFlow(address(new _MockImplementation()));
        deploymentConfig.goalRulesets = IJBRulesets(address(new _MockImplementation()));
        deploymentConfig.goalRevnetId = 42;
        deploymentConfig.paymentTokenDecimals = 18;
        deploymentConfig.budgetValidationBounds = IBudgetTCR.BudgetValidationBounds({
            minFundingLeadTime: 2 days,
            maxFundingHorizon: 90 days,
            minExecutionDuration: 2 days,
            maxExecutionDuration: 45 days,
            minActivationThreshold: 2e18,
            maxActivationThreshold: 3_000_000e18,
            maxRunwayCap: 4_000_000e18
        });
        deploymentConfig.oracleValidationBounds =
            IBudgetTCR.OracleValidationBounds({liveness: 2 hours, bondAmount: 2e18});
        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            address(this),
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(registryConfig.votingToken)
        );
        deploymentConfig.underwriterSlasherRouter =
            address(new _MockUnderwriterSlasherRouterForFactory(IStakeVault(address(stakeVault)), expectedBudgetTCR));
        goalTreasury.configureUnderwriterSlasher(deploymentConfig.underwriterSlasherRouter);

        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);
        BudgetTCR deployedBudgetTCR = BudgetTCR(deployed.budgetTCR);

        assertEq(address(deployedBudgetTCR.arbitrator()), deployed.arbitrator);
        assertEq(deployedBudgetTCR.allocationMechanismAdmin(), registryConfig.allocationMechanismAdmin);
        assertEq(deployedBudgetTCR.arbitratorExtraData(), registryConfig.registryPolicy.arbitratorExtraData);
        assertEq(deployedBudgetTCR.registrationMetaEvidence(), registryConfig.registryPolicy.registrationMetaEvidence);
        assertEq(deployedBudgetTCR.clearingMetaEvidence(), registryConfig.registryPolicy.clearingMetaEvidence);
        assertEq(address(deployedBudgetTCR.erc20()), address(votingToken));
        assertEq(deployedBudgetTCR.submissionBaseDeposit(), registryConfig.registryPolicy.submissionBaseDeposit);
        assertEq(deployedBudgetTCR.removalBaseDeposit(), registryConfig.registryPolicy.removalBaseDeposit);
        assertEq(
            deployedBudgetTCR.submissionChallengeBaseDeposit(),
            registryConfig.registryPolicy.submissionChallengeBaseDeposit
        );
        assertEq(
            deployedBudgetTCR.removalChallengeBaseDeposit(), registryConfig.registryPolicy.removalChallengeBaseDeposit
        );
        assertEq(deployedBudgetTCR.challengePeriodDuration(), registryConfig.registryPolicy.challengePeriodDuration);
        assertEq(address(deployedBudgetTCR.submissionDepositStrategy()), address(submissionDepositStrategy));

        assertEq(address(deployedBudgetTCR.goalFlow()), address(deploymentConfig.goalFlow));
        assertEq(address(deployedBudgetTCR.goalTreasury()), address(deploymentConfig.goalTreasury));
        assertEq(address(deployedBudgetTCR.goalToken()), address(goalToken));
        assertEq(address(deployedBudgetTCR.cobuildToken()), address(cobuildToken));
        assertEq(address(deployedBudgetTCR.goalRulesets()), address(deploymentConfig.goalRulesets));
        assertEq(deployedBudgetTCR.goalRevnetId(), deploymentConfig.goalRevnetId);
        assertEq(deployedBudgetTCR.paymentTokenDecimals(), deploymentConfig.paymentTokenDecimals);
        assertEq(deployedBudgetTCR.budgetSuccessResolver(), deploymentConfig.budgetSuccessResolver);
        assertEq(deployedBudgetTCR.premiumEscrowImplementation(), deploymentConfig.premiumEscrowImplementation);
        assertEq(deployedBudgetTCR.underwriterSlasherRouter(), deploymentConfig.underwriterSlasherRouter);
        assertEq(deployedBudgetTCR.budgetPremiumPpm(), deploymentConfig.budgetPremiumPpm);
        assertEq(deployedBudgetTCR.budgetSlashPpm(), deploymentConfig.budgetSlashPpm);

        address stackDeployer = deployedBudgetTCR.stackDeployer();
        assertTrue(stackDeployer != address(0));
        assertGt(stackDeployer.code.length, 0);
        assertNotEq(stackDeployer, deploymentConfig.stackDeployer);

        (
            uint64 minFundingLeadTime,
            uint64 maxFundingHorizon,
            uint64 minExecutionDuration,
            uint64 maxExecutionDuration,
            uint256 minActivationThreshold,
            uint256 maxActivationThreshold,
            uint256 maxRunwayCap
        ) = deployedBudgetTCR.budgetValidationBounds();
        assertEq(minFundingLeadTime, deploymentConfig.budgetValidationBounds.minFundingLeadTime);
        assertEq(maxFundingHorizon, deploymentConfig.budgetValidationBounds.maxFundingHorizon);
        assertEq(minExecutionDuration, deploymentConfig.budgetValidationBounds.minExecutionDuration);
        assertEq(maxExecutionDuration, deploymentConfig.budgetValidationBounds.maxExecutionDuration);
        assertEq(minActivationThreshold, deploymentConfig.budgetValidationBounds.minActivationThreshold);
        assertEq(maxActivationThreshold, deploymentConfig.budgetValidationBounds.maxActivationThreshold);
        assertEq(maxRunwayCap, deploymentConfig.budgetValidationBounds.maxRunwayCap);

        (uint64 liveness, uint256 bondAmount) = deployedBudgetTCR.oracleValidationBounds();
        assertEq(liveness, deploymentConfig.oracleValidationBounds.liveness);
        assertEq(bondAmount, deploymentConfig.oracleValidationBounds.bondAmount);
    }

    function test_deployBudgetTCRStackForGoal_derivesEscrowDeposits_fromRunwayCap() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 1e18,
                removalBaseDeposit: 2e18,
                submissionChallengeBaseDeposit: 3e18,
                removalChallengeBaseDeposit: 4e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        uint256 expectedSizing =
            (deploymentConfig.budgetValidationBounds.maxRunwayCap * DEFAULT_ESCROW_BOND_BPS) / 10_000;
        uint256 expectedFloor = arbitratorParams.arbitrationCost * 6;
        uint256 expectedDeposit = expectedSizing > expectedFloor ? expectedSizing : expectedFloor;

        assertEq(BudgetTCR(deployed.budgetTCR).submissionBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).submissionChallengeBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalChallengeBaseDeposit(), 0);
    }

    function test_deployBudgetTCRStackForGoal_derivesEscrowDeposits_withConfiguredBps() public {
        uint256 customEscrowBondBps = 25;
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), customEscrowBondBps);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 1e18,
                removalBaseDeposit: 2e18,
                submissionChallengeBaseDeposit: 3e18,
                removalChallengeBaseDeposit: 4e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        uint256 expectedSizing = (deploymentConfig.budgetValidationBounds.maxRunwayCap * customEscrowBondBps) / 10_000;
        uint256 expectedFloor = arbitratorParams.arbitrationCost * 6;
        uint256 expectedDeposit = expectedSizing > expectedFloor ? expectedSizing : expectedFloor;

        assertEq(BudgetTCR(deployed.budgetTCR).submissionBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).submissionChallengeBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalChallengeBaseDeposit(), 0);
    }

    function test_deployBudgetTCRStackForGoal_derivesEscrowDeposits_fromActivationThreshold_whenRunwayCapUnset()
        public
    {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 10e18,
                removalBaseDeposit: 20e18,
                submissionChallengeBaseDeposit: 30e18,
                removalChallengeBaseDeposit: 40e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deploymentConfig.budgetValidationBounds.maxRunwayCap = 0;
        deploymentConfig.budgetValidationBounds.maxActivationThreshold = 100e18;
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        uint256 expectedSizing =
            (deploymentConfig.budgetValidationBounds.maxActivationThreshold * DEFAULT_ESCROW_BOND_BPS) / 10_000;
        uint256 expectedFloor = arbitratorParams.arbitrationCost * 6;
        uint256 expectedDeposit = expectedSizing > expectedFloor ? expectedSizing : expectedFloor;

        assertEq(BudgetTCR(deployed.budgetTCR).submissionBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).submissionChallengeBaseDeposit(), expectedDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalChallengeBaseDeposit(), 0);
    }

    function test_deployBudgetTCRStackForGoal_preservesManualDeposits_forNonEscrowStrategy() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            _deployPrizePoolSubmissionDepositStrategy(IERC20(address(votingToken)), makeAddr("prize-pool"));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 101e18,
                removalBaseDeposit: 202e18,
                submissionChallengeBaseDeposit: 303e18,
                removalChallengeBaseDeposit: 404e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        assertEq(
            BudgetTCR(deployed.budgetTCR).submissionBaseDeposit(), registryConfig.registryPolicy.submissionBaseDeposit
        );
        assertEq(BudgetTCR(deployed.budgetTCR).removalBaseDeposit(), registryConfig.registryPolicy.removalBaseDeposit);
        assertEq(
            BudgetTCR(deployed.budgetTCR).submissionChallengeBaseDeposit(),
            registryConfig.registryPolicy.submissionChallengeBaseDeposit
        );
        assertEq(
            BudgetTCR(deployed.budgetTCR).removalChallengeBaseDeposit(),
            registryConfig.registryPolicy.removalChallengeBaseDeposit
        );
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_submission_strategy_probe_fails() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy = ISubmissionDepositStrategy(
            address(new _MockSubmissionDepositStrategyWithoutCapabilities(IERC20(address(votingToken))))
        );
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 101e18,
                removalBaseDeposit: 202e18,
                submissionChallengeBaseDeposit: 303e18,
                removalChallengeBaseDeposit: 404e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.SUBMISSION_DEPOSIT_STRATEGY_CAPABILITY_PROBE_FAILED.selector,
                address(submissionDepositStrategy)
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function _validImplementations() internal returns (address a, address b, address c) {
        a = address(new _MockImplementation());
        b = address(new _MockImplementation());
        c = address(new _MockImplementation());
    }

    function _deployPrizePoolSubmissionDepositStrategy(IERC20 token, address prizePool)
        internal
        returns (ISubmissionDepositStrategy strategy)
    {
        PrizePoolSubmissionDepositStrategy implementation = new PrizePoolSubmissionDepositStrategy();
        address clone = Clones.clone(address(implementation));
        PrizePoolSubmissionDepositStrategy(clone).initialize(token, prizePool);
        return ISubmissionDepositStrategy(clone);
    }

    function _newRealFactory(address authorizedCaller, uint256 escrowBondBps)
        internal
        returns (BudgetTCRFactory factory)
    {
        BudgetTCR budgetImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();
        BudgetTCRDeployer deployerImpl = _deployBudgetTcrDeployer();
        factory = new BudgetTCRFactory(
            address(budgetImpl), address(arbImpl), address(deployerImpl), authorizedCaller, escrowBondBps
        );
    }

    function _deployBudgetTcrDeployer() internal returns (BudgetTCRDeployer) {
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        return BudgetTCRDeployer(
            new BudgetTCRDeployer(
                address(new BudgetTreasury()),
                roundFactory,
                roundFactory,
                address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
                address(new ERC20VotesArbitrator()),
                address(new BudgetFlowRouterStrategy())
            )
        );
    }

    function _defaultArbitratorParams() internal pure returns (IArbitrator.ArbitratorParams memory params) {
        params = IArbitrator.ArbitratorParams({
            votingPeriod: 20,
            votingDelay: 2,
            revealPeriod: 15,
            arbitrationCost: 10e18,
            wrongOrMissedSlashBps: 50,
            slashCallerBountyBps: 100
        });
    }

    function _defaultDeploymentConfig(
        BudgetTCRFactory factory,
        address sender,
        IVotes votingToken,
        IGoalTreasury goalTreasury,
        IERC20 goalToken,
        IERC20 cobuildToken
    ) internal returns (IBudgetTCR.DeploymentConfig memory deploymentConfig) {
        IStakeVault stakeVault = IStakeVault(goalTreasury.stakeVault());

        deploymentConfig = IBudgetTCR.DeploymentConfig({
            stackDeployer: makeAddr("placeholder-stack-deployer"),
            budgetSuccessResolver: makeAddr("budget-success-resolver"),
            budgetSpendPolicy: address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped)),
            budgetGatePolicy: address(new StakeCoverageGatePolicy()),
            goalFlow: IFlow(address(new _MockImplementation())),
            goalTreasury: goalTreasury,
            goalToken: goalToken,
            cobuildToken: cobuildToken,
            goalRulesets: IJBRulesets(address(new _MockImplementation())),
            goalRevnetId: 1,
            paymentTokenDecimals: 18,
            premiumEscrowImplementation: address(new _MockImplementation()),
            underwriterSlasherRouter: address(0),
            budgetPremiumPpm: 100_000,
            budgetSlashPpm: 50_000,
            budgetValidationBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1 days,
                maxFundingHorizon: 60 days,
                minExecutionDuration: 1 days,
                maxExecutionDuration: 30 days,
                minActivationThreshold: 1e18,
                maxActivationThreshold: 1_000_000e18,
                maxRunwayCap: 2_000_000e18
            }),
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        });

        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            sender,
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(votingToken)
        );
        _MockGoalTreasuryForFactory mockGoalTreasury = _MockGoalTreasuryForFactory(address(goalTreasury));
        if (_MockStakeVaultForFactory(address(stakeVault)).jurorSlasher() == address(0)) {
            mockGoalTreasury.configureJurorSlasher(address(new JurorSlasherRouter(stakeVault, address(factory))));
        }
        deploymentConfig.underwriterSlasherRouter =
            address(new _MockUnderwriterSlasherRouterForFactory(stakeVault, expectedBudgetTCR));
        if (_MockStakeVaultForFactory(address(stakeVault)).underwriterSlasher() == address(0)) {
            mockGoalTreasury.configureUnderwriterSlasher(deploymentConfig.underwriterSlasherRouter);
        }
    }

    function _deployDefaultStackForDiscovery()
        internal
        returns (
            BudgetTCRFactory factory,
            BudgetTCRFactory.DeployedBudgetTCRStack memory deployed,
            address stackDeployer
        )
    {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address budgetStakeLedger = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(budgetStakeLedger);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));
        factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            allocationMechanismAdmin: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            votingToken: IVotes(address(votingToken)),
            submissionDepositStrategy: submissionDepositStrategy,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: bytes(""),
                registrationMetaEvidence: "ipfs://reg",
                clearingMetaEvidence: "ipfs://clear",
                submissionBaseDeposit: 100e18,
                removalBaseDeposit: 50e18,
                submissionChallengeBaseDeposit: 120e18,
                removalChallengeBaseDeposit: 70e18,
                challengePeriodDuration: 3 days
            })
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deployed = factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
        stackDeployer = BudgetTCR(deployed.budgetTCR).stackDeployer();
    }
}
