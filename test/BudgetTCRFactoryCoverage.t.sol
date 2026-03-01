// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";
import { BudgetTCR } from "src/tcr/BudgetTCR.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IArbitrable } from "src/tcr/interfaces/IArbitrable.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";

import {
    _MockImplementation,
    _MockGoalTreasuryForFactory,
    _MockStakeVaultForFactory,
    _MockUnderwriterSlasherRouterForFactory
} from "test/BudgetTCRFactory.t.sol";
import { MockVotesToken } from "test/mocks/MockVotesToken.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

contract BudgetTCRFactoryCoverageTest is Test {
    uint256 internal constant DEFAULT_ESCROW_BOND_BPS = 5;

    function test_constructor_revertsWhenImplementationAddressIsZero() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validMockImplementations();

        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        new BudgetTCRFactory(address(0), arbImpl, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);

        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        new BudgetTCRFactory(budgetImpl, address(0), deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);

        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        new BudgetTCRFactory(budgetImpl, arbImpl, address(0), address(this), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_constructor_revertsWhenAuthorizedCallerIsZero() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validMockImplementations();

        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(0), DEFAULT_ESCROW_BOND_BPS);
    }

    function test_deployBudgetTCRStackForGoal_revertsWhenCallerUnauthorized() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validMockImplementations();
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

    function test_deployBudgetTCRStackForGoal_revertsOnZeroRegistryInputs() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validMockImplementations();
        BudgetTCRFactory factory = new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);

        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(address(new _MockImplementation()));
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        IArbitrator.ArbitratorParams memory arbitratorParams = _defaultArbitratorParams();

        BudgetTCRFactory.RegistryConfigInput memory zeroVotingToken = _defaultRegistryConfig(
            IVotes(address(votingToken)), ISubmissionDepositStrategy(address(new _MockImplementation()))
        );
        zeroVotingToken.votingToken = IVotes(address(0));
        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        factory.deployBudgetTCRStackForGoal(zeroVotingToken, deploymentConfig, arbitratorParams);

        BudgetTCRFactory.RegistryConfigInput memory zeroInvalidRoundSink = _defaultRegistryConfig(
            IVotes(address(votingToken)), ISubmissionDepositStrategy(address(new _MockImplementation()))
        );
        zeroInvalidRoundSink.invalidRoundRewardsSink = address(0);
        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        factory.deployBudgetTCRStackForGoal(zeroInvalidRoundSink, deploymentConfig, arbitratorParams);

        BudgetTCRFactory.RegistryConfigInput memory zeroStrategy = _defaultRegistryConfig(
            IVotes(address(votingToken)), ISubmissionDepositStrategy(address(new _MockImplementation()))
        );
        zeroStrategy.submissionDepositStrategy = ISubmissionDepositStrategy(address(0));
        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        factory.deployBudgetTCRStackForGoal(zeroStrategy, deploymentConfig, arbitratorParams);
    }

    function test_deployBudgetTCRStackForGoal_revertsWhenGoalTreasuryStakeVaultIsZero() public {
        (address budgetImpl, address arbImpl, address deployerImpl) = _validMockImplementations();
        BudgetTCRFactory factory = new BudgetTCRFactory(budgetImpl, arbImpl, deployerImpl, address(this), DEFAULT_ESCROW_BOND_BPS);

        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(address(new _MockImplementation()));

        BudgetTCRFactory.RegistryConfigInput memory registryConfig = _defaultRegistryConfig(
            IVotes(address(votingToken)), ISubmissionDepositStrategy(address(new _MockImplementation()))
        );
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );

        vm.expectRevert(BudgetTCRFactory.ADDRESS_ZERO.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_revertsWhenOracleLivenessIsZero() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(address(new _MockImplementation()));
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _realFactory();
        BudgetTCRFactory.RegistryConfigInput memory registryConfig = _defaultRegistryConfig(
            IVotes(address(votingToken)), ISubmissionDepositStrategy(address(new _MockImplementation()))
        );
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deploymentConfig.oracleValidationBounds.liveness = 0;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_revertsWhenOracleBondAmountIsZero() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(address(new _MockImplementation()));
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _realFactory();
        BudgetTCRFactory.RegistryConfigInput memory registryConfig = _defaultRegistryConfig(
            IVotes(address(votingToken)), ISubmissionDepositStrategy(address(new _MockImplementation()))
        );
        IBudgetTCR.DeploymentConfig memory deploymentConfig = _defaultDeploymentConfig(
            factory,
            address(this),
            IVotes(address(votingToken)),
            IGoalTreasury(address(goalTreasury)),
            IERC20(address(votingToken)),
            IERC20(address(votingToken))
        );
        deploymentConfig.oracleValidationBounds.bondAmount = 0;

        vm.expectRevert(IBudgetTCR.INVALID_BOUNDS.selector);
        factory.deployBudgetTCRStackForGoal(registryConfig, deploymentConfig, _defaultArbitratorParams());
    }

    function test_deployBudgetTCRStackForGoal_preservesManualDeposits_whenEscrowDetectionRecipientMismatches() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        WrongRecipientEscrowDetectionStrategy strategy = new WrongRecipientEscrowDetectionStrategy(
            IERC20(address(votingToken)), makeAddr("wrong-escrow-detection-recipient")
        );
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(address(new _MockImplementation()));
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _realFactory();
        BudgetTCRFactory.RegistryConfigInput memory registryConfig =
            _defaultRegistryConfig(IVotes(address(votingToken)), ISubmissionDepositStrategy(address(strategy)));
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

    function test_deployBudgetTCRStackForGoal_preservesManualDeposits_whenStrategyActionReadReverts() public {
        MockVotesToken votingToken = new MockVotesToken("Voting", "VOTE");
        RevertingDepositStrategy strategy = new RevertingDepositStrategy(IERC20(address(votingToken)));
        _MockGoalTreasuryForFactory goalTreasury = new _MockGoalTreasuryForFactory(address(new _MockImplementation()));
        _MockStakeVaultForFactory stakeVault = new _MockStakeVaultForFactory(address(goalTreasury));
        goalTreasury.setStakeVault(address(stakeVault));

        BudgetTCRFactory factory = _realFactory();
        BudgetTCRFactory.RegistryConfigInput memory registryConfig =
            _defaultRegistryConfig(IVotes(address(votingToken)), ISubmissionDepositStrategy(address(strategy)));
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

    function _realFactory() internal returns (BudgetTCRFactory) {
        BudgetTCR budgetImpl = new BudgetTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();
        BudgetTCRDeployer deployerImpl = new BudgetTCRDeployer();
        return new BudgetTCRFactory(
            address(budgetImpl), address(arbImpl), address(deployerImpl), address(this), DEFAULT_ESCROW_BOND_BPS
        );
    }

    function _validMockImplementations() internal returns (address a, address b, address c) {
        a = address(new _MockImplementation());
        b = address(new _MockImplementation());
        c = address(new _MockImplementation());
    }

    function _defaultRegistryConfig(
        IVotes votingToken,
        ISubmissionDepositStrategy strategy
    )
        internal
        returns (BudgetTCRFactory.RegistryConfigInput memory registryConfig)
    {
        registryConfig = BudgetTCRFactory.RegistryConfigInput({
            governor: makeAddr("governor"),
            invalidRoundRewardsSink: makeAddr("invalid-round-reward-sink"),
            arbitratorExtraData: bytes(""),
            registrationMetaEvidence: "ipfs://registration",
            clearingMetaEvidence: "ipfs://clearing",
            votingToken: votingToken,
            submissionBaseDeposit: 111e18,
            removalBaseDeposit: 222e18,
            submissionChallengeBaseDeposit: 333e18,
            removalChallengeBaseDeposit: 444e18,
            challengePeriodDuration: 3 days,
            submissionDepositStrategy: strategy
        });
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
    )
        internal
        returns (IBudgetTCR.DeploymentConfig memory deploymentConfig)
    {
        IStakeVault stakeVault = IStakeVault(goalTreasury.stakeVault());

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
            underwriterSlasherRouter: address(0),
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

        address expectedBudgetTCR = factory.predictBudgetTCRAddress(
            sender,
            address(deploymentConfig.goalFlow),
            address(deploymentConfig.goalTreasury),
            deploymentConfig.goalRevnetId,
            address(votingToken)
        );
        deploymentConfig.underwriterSlasherRouter = address(
            new _MockUnderwriterSlasherRouterForFactory(stakeVault, expectedBudgetTCR)
        );
    }
}

contract WrongRecipientEscrowDetectionStrategy is ISubmissionDepositStrategy {
    IERC20 internal immutable _token;
    address internal immutable _wrongRecipient;

    constructor(IERC20 token_, address wrongRecipient_) {
        _token = token_;
        _wrongRecipient = wrongRecipient_;
    }

    function token() external view returns (IERC20) {
        return _token;
    }

    function getSubmissionDepositAction(
        bytes32,
        IGeneralizedTCR.Status requestType,
        IArbitrable.Party ruling,
        address,
        address,
        address,
        uint256
    )
        external
        view
        returns (DepositAction action, address recipient)
    {
        if (requestType == IGeneralizedTCR.Status.RegistrationRequested && ruling == IArbitrable.Party.Requester) {
            return (DepositAction.Hold, address(0));
        }
        if (requestType == IGeneralizedTCR.Status.ClearingRequested && ruling == IArbitrable.Party.Requester) {
            return (DepositAction.Transfer, _wrongRecipient);
        }
        if (requestType == IGeneralizedTCR.Status.ClearingRequested && ruling == IArbitrable.Party.Challenger) {
            return (DepositAction.Hold, address(0));
        }
        return (DepositAction.Hold, address(0));
    }
}

contract RevertingDepositStrategy is ISubmissionDepositStrategy {
    IERC20 internal immutable _token;

    constructor(IERC20 token_) {
        _token = token_;
    }

    function token() external view returns (IERC20) {
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
    )
        external
        pure
        returns (DepositAction, address)
    {
        revert("STRATEGY_READ_REVERT");
    }
}
