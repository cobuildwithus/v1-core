// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { JurorSlasherRouter } from "src/goals/JurorSlasherRouter.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

contract _MockImplementation {}

contract _MockGoalTreasuryForFactory {
    address internal _stakeVault;
    address internal immutable _rewardEscrow;
    address internal _authority;
    address public configuredSlasher;
    address public configuredUnderwriterSlasher;

    constructor(address rewardEscrow_) {
        _rewardEscrow = rewardEscrow_;
    }

    function setStakeVault(address stakeVault_) external {
        _stakeVault = stakeVault_;
    }

    function stakeVault() external view returns (address) {
        return _stakeVault;
    }

    function rewardEscrow() external view returns (address) {
        return _rewardEscrow;
    }

    function setAuthority(address authority_) external {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
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

contract BudgetTCRFactoryTest is Test {
    uint256 internal constant DEFAULT_ESCROW_BOND_BPS = 5;

    function test_budgetTCRDeployer_constructor_sets_budget_treasury_implementation() public {
        BudgetTCRDeployer deployer = new BudgetTCRDeployer();
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
        (address budgetImpl, , address deployerImpl) = _validImplementations();

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRFactory.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new BudgetTCRFactory(budgetImpl, noCode, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_constructor_reverts_when_stack_deployer_implementation_has_no_code() public {
        address noCode = makeAddr("no-code-deployer");
        (address budgetImpl, address arbImpl, ) = _validImplementations();

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

        BudgetTCRFactory factory = new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);

        assertEq(factory.budgetTCRImplementation(), budgetImpl);
        assertEq(factory.arbitratorImplementation(), arbImpl);
        assertEq(factory.stackDeployerImplementation(), deployerImpl);
        assertEq(factory.authorizedCaller(), address(this));
        assertEq(factory.escrowBondBps(), DEFAULT_ESCROW_BOND_BPS);
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
        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRFactory.UNAUTHORIZED_CALLER.selector, unauthorizedCaller)
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_is_zero() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );
        deploymentConfig.underwriterSlasherRouter = address(0);

        vm.expectRevert(BudgetTCRFactory.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_when_underwriter_router_has_no_code() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );
        deploymentConfig.underwriterSlasherRouter = makeAddr("no-code-underwriter-router");

        vm.expectRevert(BudgetTCRFactory.UNDERWRITER_SLASHER_NOT_CONFIGURED.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_allowsConfiguredAuthorizedCaller_andDeploysAtPredictedAddress() public {
        address authorizedCaller = makeAddr("authorized-caller");
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(authorizedCaller, DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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
        assertEq(BudgetTCR(deployed.budgetTCR).premiumEscrowImplementation(), deploymentConfig.premiumEscrowImplementation);
        assertEq(BudgetTCR(deployed.budgetTCR).budgetPremiumPpm(), deploymentConfig.budgetPremiumPpm);

        IBudgetTCR.RegistryConfig memory fullRegistryConfig = IBudgetTCR.RegistryConfig({
            governor: registryConfig.governor,
            arbitrator: IArbitrator(deployed.arbitrator),
            arbitratorExtraData: registryConfig.arbitratorExtraData,
            registrationMetaEvidence: registryConfig.registrationMetaEvidence,
            clearingMetaEvidence: registryConfig.clearingMetaEvidence,
            votingToken: registryConfig.votingToken,
            submissionBaseDeposit: registryConfig.submissionBaseDeposit,
            removalBaseDeposit: registryConfig.removalBaseDeposit,
            submissionChallengeBaseDeposit: registryConfig.submissionChallengeBaseDeposit,
            removalChallengeBaseDeposit: registryConfig.removalChallengeBaseDeposit,
            challengePeriodDuration: registryConfig.challengePeriodDuration,
            submissionDepositStrategy: registryConfig.submissionDepositStrategy
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IBudgetTCR(deployed.budgetTCR).initialize(fullRegistryConfig, deploymentConfig);
    }

    function test_deployBudgetTCRStackForGoal_reusesExistingAuthorizedRouter() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        JurorSlasherRouter existingRouter = new JurorSlasherRouter(IStakeVault(address(stakeVault)), address(factory));
        goalTreasury.configureJurorSlasher(address(existingRouter));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        address unsupportedSlasher = address(new _MockImplementation());
        goalTreasury.configureJurorSlasher(unsupportedSlasher);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRFactory.UNSUPPORTED_JUROR_SLASHER.selector, unsupportedSlasher)
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_reverts_whenExistingRouterAuthorityMismatch() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        address unexpectedAuthority = makeAddr("unexpected-authority");
        JurorSlasherRouter wrongAuthorityRouter =
            new JurorSlasherRouter(IStakeVault(address(stakeVault)), unexpectedAuthority);
        goalTreasury.configureJurorSlasher(address(wrongAuthorityRouter));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);
        goalTreasury.setAuthority(address(factory));

        _MockGoalTreasuryForFactory otherGoalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory otherStakeVault = new _MockStakeVaultForFactory(address(otherGoalTreasury));
        JurorSlasherRouter mismatchedRouter =
            new JurorSlasherRouter(IStakeVault(address(otherStakeVault)), address(factory));
        goalTreasury.configureJurorSlasher(address(mismatchedRouter));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRFactory.INVALID_SLASHER_STAKE_VAULT.selector, address(stakeVault), address(otherStakeVault)
            )
        );
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_skipsSlasherConfigureWhenFactoryNotAuthority() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());

        assertTrue(deployed.budgetTCR != address(0));
        assertTrue(deployed.arbitrator != address(0));
        assertEq(goalTreasury.configuredSlasher(), address(0));
        assertEq(stakeVault.jurorSlasher(), address(0));
        assertEq(goalTreasury.configuredUnderwriterSlasher(), address(0));
        assertEq(stakeVault.underwriterSlasher(), address(0));
    }

    function test_deployBudgetTCRStackForGoal_wiresCloneFirstStackDeployer_withoutNonceGetter() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 100e18,
            removalBaseDeposit: 50e18,
            submissionChallengeBaseDeposit: 120e18,
            removalChallengeBaseDeposit: 70e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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

    function test_deployBudgetTCRStackForGoal_wiresDeploymentAndRegistryConfigIntoClone() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        MockVotesToken goalToken = new MockVotesToken("Goal", "GOAL");
        MockVotesToken cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        ISubmissionDepositStrategy submissionDepositStrategy = ISubmissionDepositStrategy(
            address(new PrizePoolSubmissionDepositStrategy(IERC20(address(votingToken)), makeAddr("prize-pool")))
        );
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes("arbitrator-extra"),
            registrationMetaEvidence: "ipfs://registration",
            clearingMetaEvidence: "ipfs://clearing",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 101e18,
            removalBaseDeposit: 202e18,
            submissionChallengeBaseDeposit: 303e18,
            removalChallengeBaseDeposit: 404e18,
            challengePeriodDuration: 5 days,
            submissionDepositStrategy: submissionDepositStrategy
        });

        IBudgetTCR.DeploymentConfig memory deploymentConfig =
            _defaultDeploymentConfig(IGoalTreasury(address(goalTreasury)), IERC20(address(goalToken)), IERC20(address(cobuildToken)));
        deploymentConfig.goalFlow = IFlow(address(new _MockImplementation()));
        deploymentConfig.goalRulesets = IJBRulesets(address(new _MockImplementation()));
        deploymentConfig.goalRevnetId = 42;
        deploymentConfig.paymentTokenDecimals = 18;
        deploymentConfig.managerRewardPool = makeAddr("manager-reward-pool");
        deploymentConfig.budgetValidationBounds = IBudgetTCR.BudgetValidationBounds({
            minFundingLeadTime: 2 days,
            maxFundingHorizon: 90 days,
            minExecutionDuration: 2 days,
            maxExecutionDuration: 45 days,
            minActivationThreshold: 2e18,
            maxActivationThreshold: 3_000_000e18,
            maxRunwayCap: 4_000_000e18
        });
        deploymentConfig.oracleValidationBounds = IBudgetTCR.OracleValidationBounds({
            liveness: 2 hours,
            bondAmount: 2e18
        });

        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);
        BudgetTCR deployedBudgetTCR = BudgetTCR(deployed.budgetTCR);

        assertEq(address(deployedBudgetTCR.arbitrator()), deployed.arbitrator);
        assertEq(deployedBudgetTCR.governor(), registryConfig.governor);
        assertEq(deployedBudgetTCR.arbitratorExtraData(), registryConfig.arbitratorExtraData);
        assertEq(deployedBudgetTCR.registrationMetaEvidence(), registryConfig.registrationMetaEvidence);
        assertEq(deployedBudgetTCR.clearingMetaEvidence(), registryConfig.clearingMetaEvidence);
        assertEq(address(deployedBudgetTCR.erc20()), address(votingToken));
        assertEq(deployedBudgetTCR.submissionBaseDeposit(), registryConfig.submissionBaseDeposit);
        assertEq(deployedBudgetTCR.removalBaseDeposit(), registryConfig.removalBaseDeposit);
        assertEq(deployedBudgetTCR.submissionChallengeBaseDeposit(), registryConfig.submissionChallengeBaseDeposit);
        assertEq(deployedBudgetTCR.removalChallengeBaseDeposit(), registryConfig.removalChallengeBaseDeposit);
        assertEq(deployedBudgetTCR.challengePeriodDuration(), registryConfig.challengePeriodDuration);
        assertEq(address(deployedBudgetTCR.submissionDepositStrategy()), address(submissionDepositStrategy));

        assertEq(address(deployedBudgetTCR.goalFlow()), address(deploymentConfig.goalFlow));
        assertEq(address(deployedBudgetTCR.goalTreasury()), address(deploymentConfig.goalTreasury));
        assertEq(address(deployedBudgetTCR.goalToken()), address(goalToken));
        assertEq(address(deployedBudgetTCR.cobuildToken()), address(cobuildToken));
        assertEq(address(deployedBudgetTCR.goalRulesets()), address(deploymentConfig.goalRulesets));
        assertEq(deployedBudgetTCR.goalRevnetId(), deploymentConfig.goalRevnetId);
        assertEq(deployedBudgetTCR.paymentTokenDecimals(), deploymentConfig.paymentTokenDecimals);
        assertEq(deployedBudgetTCR.managerRewardPool(), deploymentConfig.managerRewardPool);
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
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 1e18,
            removalBaseDeposit: 2e18,
            submissionChallengeBaseDeposit: 3e18,
            removalChallengeBaseDeposit: 4e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        uint256 expectedSizing = (deploymentConfig.budgetValidationBounds.maxRunwayCap * DEFAULT_ESCROW_BOND_BPS) / 10_000;
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
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), customEscrowBondBps);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 1e18,
            removalBaseDeposit: 2e18,
            submissionChallengeBaseDeposit: 3e18,
            removalChallengeBaseDeposit: 4e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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

    function test_deployBudgetTCRStackForGoal_derivesEscrowDeposits_fromActivationThreshold_whenRunwayCapUnset() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        ISubmissionDepositStrategy submissionDepositStrategy =
            ISubmissionDepositStrategy(address(new EscrowSubmissionDepositStrategy(IERC20(address(votingToken)))));
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 10e18,
            removalBaseDeposit: 20e18,
            submissionChallengeBaseDeposit: 30e18,
            removalChallengeBaseDeposit: 40e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
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
        ISubmissionDepositStrategy submissionDepositStrategy = ISubmissionDepositStrategy(
            address(new PrizePoolSubmissionDepositStrategy(IERC20(address(votingToken)), makeAddr("prize-pool")))
        );
        address rewardEscrow = address(new _MockImplementation());
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(rewardEscrow);
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _newRealFactory(address(this), DEFAULT_ESCROW_BOND_BPS);

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://reg",
            clearingMetaEvidence: "ipfs://clear",
            votingToken: IVotes(address(votingToken)),
            submissionBaseDeposit: 101e18,
            removalBaseDeposit: 202e18,
            submissionChallengeBaseDeposit: 303e18,
            removalChallengeBaseDeposit: 404e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: submissionDepositStrategy
        });
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            IGoalTreasury(address(goalTreasury)), IERC20(address(votingToken)), IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.DeployedBudgetTCRStack memory deployed =
            factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, arbitratorParams);

        assertEq(BudgetTCR(deployed.budgetTCR).submissionBaseDeposit(), registryConfig.submissionBaseDeposit);
        assertEq(BudgetTCR(deployed.budgetTCR).removalBaseDeposit(), registryConfig.removalBaseDeposit);
        assertEq(
            BudgetTCR(deployed.budgetTCR).submissionChallengeBaseDeposit(),
            registryConfig.submissionChallengeBaseDeposit
        );
        assertEq(
            BudgetTCR(deployed.budgetTCR).removalChallengeBaseDeposit(),
            registryConfig.removalChallengeBaseDeposit
        );
    }

    function _validImplementations() internal returns (address a, address b, address c) {
        a = address(new _MockImplementation());
        b = address(new _MockImplementation());
        c = address(new _MockImplementation());
    }

    function _newRealFactory(address authorizedCaller, uint256 escrowBondBps)
        internal
        returns (BudgetTCRFactory factory)
    {
        BudgetTCR budgetImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();
        BudgetTCRDeployer deployerImpl = new BudgetTCRDeployer();
        factory =
            new BudgetTCRFactory(address(budgetImpl), address(arbImpl), address(deployerImpl), authorizedCaller, escrowBondBps);
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
        IGoalTreasury goalTreasury,
        IERC20 goalToken,
        IERC20 cobuildToken
    ) internal returns (IBudgetTCR.DeploymentConfig memory deploymentConfig) {
        deploymentConfig = IBudgetTCR.DeploymentConfig({
            stackDeployer: makeAddr("placeholder-stack-deployer"),
            budgetSuccessResolver: makeAddr("budget-success-resolver"),
            goalFlow: IFlow(address(new _MockImplementation())),
            goalTreasury: goalTreasury,
            goalToken: goalToken,
            cobuildToken: cobuildToken,
            goalRulesets: IJBRulesets(address(new _MockImplementation())),
            goalRevnetId: 1,
            paymentTokenDecimals: 18,
            premiumEscrowImplementation: address(new _MockImplementation()),
            underwriterSlasherRouter: address(new _MockImplementation()),
            budgetPremiumPpm: 100_000,
            budgetSlashPpm: 50_000,
            managerRewardPool: address(0),
            budgetValidationBounds: IBudgetTCR.BudgetValidationBounds({
                minFundingLeadTime: 1 days,
                maxFundingHorizon: 60 days,
                minExecutionDuration: 1 days,
                maxExecutionDuration: 30 days,
                minActivationThreshold: 1e18,
                maxActivationThreshold: 1_000_000e18,
                maxRunwayCap: 2_000_000e18
            }),
            oracleValidationBounds: IBudgetTCR.OracleValidationBounds({
                liveness: 1 days,
                bondAmount: 10e18
            })
        });
    }
}
