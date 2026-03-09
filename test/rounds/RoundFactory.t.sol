// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { RoundFactory } from "src/rounds/RoundFactory.sol";
import { RoundPrizeVault } from "src/rounds/RoundPrizeVault.sol";
import { RoundSubmissionTCR } from "src/tcr/RoundSubmissionTCR.sol";
import { PrizePoolSubmissionDepositStrategy } from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import { ERC20VotesArbitrator } from "src/tcr/ERC20VotesArbitrator.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { IAllocationMechanismFactory } from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { ISubmissionDepositStrategy } from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import {
    RoundTestSuperToken,
    RoundTestManagedFlow,
    RoundTestBudgetTreasury,
    RoundTestGoalTreasury,
    RoundTestStakeVault,
    RoundTestBudgetStakeLedger,
    RoundTestJurorSlasher
} from "test/rounds/helpers/RoundTestMocks.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract RoundTestZeroUnderlyingSuperToken {
    function getUnderlyingToken() external pure returns (address) {
        return address(0);
    }
}

contract RoundFactoryTest is Test {
    struct LegacyArbitratorConfig {
        uint256 votingPeriod;
        uint256 votingDelay;
        uint256 revealPeriod;
        uint256 arbitrationCost;
        uint256 wrongOrMissedSlashBps;
        uint256 slashCallerBountyBps;
    }

    struct LegacyAllocationMechanismConfig {
        RoundFactory.RoundTiming timing;
        address roundOperator;
        IGeneralizedTCRConfig.RegistryPolicy tcrPolicy;
        LegacyArbitratorConfig arbConfig;
    }

    MockVotesToken internal underlying;
    RoundTestSuperToken internal superToken;

    RoundTestBudgetStakeLedger internal ledger;
    RoundTestJurorSlasher internal jurorSlasher;

    RoundTestManagedFlow internal goalFlow;
    RoundTestManagedFlow internal budgetFlow;

    RoundTestGoalTreasury internal goalTreasury;
    RoundTestStakeVault internal stakeVault;
    RoundTestBudgetTreasury internal budgetTreasury;

    RoundFactory internal factory;

    address internal roundOperator = address(0x0F00);
    address internal alice = address(0xA11CE);
    address internal challenger = address(0xC0FFEE);
    address internal juror = address(0xD00D);

    uint256 internal constant ARBITRATION_COST = 1e14;
    bytes32 internal constant DEFAULT_POST_ID = bytes32("post");

    function setUp() public {
        underlying = new MockVotesToken("Goal", "GOAL");
        superToken = new RoundTestSuperToken("SuperGoal", "sGOAL", underlying);

        ledger = new RoundTestBudgetStakeLedger();
        jurorSlasher = new RoundTestJurorSlasher();

        goalFlow = new RoundTestManagedFlow(address(0xDEAD), address(0), address(0), address(0));

        stakeVault = new RoundTestStakeVault(underlying, address(0), address(jurorSlasher));
        goalTreasury = new RoundTestGoalTreasury(address(goalFlow), address(ledger), address(stakeVault));
        stakeVault.setGoalTreasury(address(goalTreasury));
        goalFlow.setFlowOperator(address(goalTreasury));

        budgetFlow = new RoundTestManagedFlow(address(0), address(0xB0), address(goalFlow), address(superToken));
        budgetTreasury = new RoundTestBudgetTreasury(address(budgetFlow));

        factory = new RoundFactory(
            address(new RoundSubmissionTCR()),
            address(new RoundPrizeVault()),
            address(new PrizePoolSubmissionDepositStrategy()),
            address(new ERC20VotesArbitrator())
        );
    }

    function test_constructor_revertsOnInvalidImplementationAddresses() public {
        address submissionImpl = address(new RoundSubmissionTCR());
        address vaultImpl = address(new RoundPrizeVault());
        address depositStrategyImpl = address(new PrizePoolSubmissionDepositStrategy());
        address arbitratorImpl = address(new ERC20VotesArbitrator());

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(address(0), vaultImpl, depositStrategyImpl, arbitratorImpl);

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(submissionImpl, address(0), depositStrategyImpl, arbitratorImpl);

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(submissionImpl, vaultImpl, address(0), arbitratorImpl);

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(submissionImpl, vaultImpl, depositStrategyImpl, address(0));

        address undeployed = makeAddr("undeployed-implementation");

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(undeployed, vaultImpl, depositStrategyImpl, arbitratorImpl);

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(submissionImpl, undeployed, depositStrategyImpl, arbitratorImpl);

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(submissionImpl, vaultImpl, undeployed, arbitratorImpl);

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        new RoundFactory(submissionImpl, vaultImpl, depositStrategyImpl, undeployed);
    }

    function _deployRound(bytes32 roundId) internal returns (RoundFactory.DeployedRound memory deployed) {
        deployed = factory.createRoundForBudget(
            roundId,
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: uint64(block.timestamp - 1), endAt: uint64(block.timestamp + 30 days) }),
            roundOperator,
            IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                submissionBaseDeposit: 1e18,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 1 days
            }),
            RoundFactory.ArbitratorConfig({
                votingPeriod: 1,
                votingDelay: 1,
                revealPeriod: 1,
                arbitrationCost: ARBITRATION_COST
            })
        );
    }

    function test_createRoundForBudget_revertsOnZeroInputs() public {
        vm.expectRevert(RoundFactory.ADDRESS_ZERO.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(0),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );

        vm.expectRevert(RoundFactory.ADDRESS_ZERO.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            address(0),
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_revertsOnInvalidBudgetContext() public {
        RoundTestManagedFlow badBudgetFlow = new RoundTestManagedFlow(address(0), address(0xB0), address(0x1234), address(0));
        RoundTestBudgetTreasury badBudgetTreasury = new RoundTestBudgetTreasury(address(badBudgetFlow));

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(badBudgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_revertsOnSuperTokenUnderlyingMismatch() public {
        MockVotesToken otherUnderlying = new MockVotesToken("Other Goal", "OGOAL");
        RoundTestSuperToken mismatchedSuperToken = new RoundTestSuperToken("Other SuperGoal", "osGOAL", otherUnderlying);
        budgetFlow.setSuperToken(address(mismatchedSuperToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                RoundFactory.SUPER_TOKEN_UNDERLYING_MISMATCH.selector,
                address(underlying),
                address(otherUnderlying)
            )
        );
        factory.createRoundForBudget(
            bytes32("r"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_revertsWhenSuperTokenUnderlyingLookupFails() public {
        budgetFlow.setSuperToken(address(goalFlow));

        vm.expectRevert(RoundFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.createRoundForBudget(
            bytes32("r"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_revertsWhenSuperTokenResolvesZeroUnderlying() public {
        RoundTestZeroUnderlyingSuperToken brokenSuperToken = new RoundTestZeroUnderlyingSuperToken();
        budgetFlow.setSuperToken(address(brokenSuperToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                RoundFactory.SUPER_TOKEN_UNDERLYING_MISMATCH.selector, address(underlying), address(0)
            )
        );
        factory.createRoundForBudget(
            bytes32("r"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: 0, endAt: 0 }),
            roundOperator,
            _dummyTcrConfig(),
            _dummyArbConfig()
        );
    }

    function test_createRoundForBudget_deploysAndWiresStack() public {
        bytes32 roundId = keccak256("round-1");
        RoundFactory.DeployedRound memory deployed = _deployRound(roundId);

        assertTrue(deployed.submissionTCR.code.length > 0);
        assertTrue(deployed.prizeVault.code.length > 0);
        assertTrue(deployed.depositStrategy.code.length > 0);
        assertTrue(deployed.arbitrator.code.length > 0);

        assertEq(deployed.underlyingToken, address(underlying));
        assertEq(deployed.superToken, address(superToken));
        assertEq(deployed.stakeVault, address(stakeVault));
        assertEq(deployed.goalTreasury, address(goalTreasury));
        assertEq(deployed.goalFlow, address(goalFlow));
        assertEq(deployed.budgetFlow, address(budgetFlow));

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.submissionTCR);
        assertEq(tcr.roundId(), roundId);
        assertEq(tcr.prizeVault(), deployed.prizeVault);
        assertEq(address(tcr.erc20()), address(underlying));

        RoundPrizeVault vault = RoundPrizeVault(deployed.prizeVault);
        assertEq(address(vault.underlyingToken()), address(underlying));
        assertEq(address(vault.submissionsTCR()), deployed.submissionTCR);
        assertEq(vault.operator(), roundOperator);
        assertEq(address(vault.superToken()), address(superToken));

        PrizePoolSubmissionDepositStrategy strategy = PrizePoolSubmissionDepositStrategy(deployed.depositStrategy);
        assertEq(address(strategy.token()), address(underlying));
        assertEq(strategy.prizePool(), deployed.prizeVault);

        ERC20VotesArbitrator arb = ERC20VotesArbitrator(deployed.arbitrator);
        assertEq(address(arb.votingToken()), address(underlying));
        assertEq(address(arb.arbitrable()), deployed.submissionTCR);
        assertEq(arb.invalidRoundRewardsSink(), deployed.prizeVault);
        assertEq(arb.wrongOrMissedSlashBps(), 0);
        assertEq(arb.slashCallerBountyBps(), 0);
        assertEq(arb.fixedBudgetTreasury(), address(budgetTreasury));
        assertEq(arb.stakeVault(), address(stakeVault));
    }

    function test_deployForBudget_decodesReducedConfigAndKeepsArbitratorNonSlashing() public {
        bytes32 roundId = keccak256("round-generic-factory");
        uint64 startAt = uint64(block.timestamp + 5);
        uint64 endAt = uint64(block.timestamp + 45 days);
        RoundFactory.AllocationMechanismConfig memory cfg = RoundFactory.AllocationMechanismConfig({
            timing: RoundFactory.RoundTiming({ startAt: startAt, endAt: endAt }),
            roundOperator: roundOperator,
            tcrPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: hex"baddcafe",
                registrationMetaEvidence: "round-reg",
                clearingMetaEvidence: "round-clr",
                submissionBaseDeposit: 3e18,
                removalBaseDeposit: 4e18,
                submissionChallengeBaseDeposit: 5e18,
                removalChallengeBaseDeposit: 6e18,
                challengePeriodDuration: 2 days
            }),
            arbConfig: RoundFactory.ArbitratorConfig({
                votingPeriod: 1,
                votingDelay: 1,
                revealPeriod: 1,
                arbitrationCost: ARBITRATION_COST
            })
        });

        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(roundId, address(budgetTreasury), abi.encode(cfg));

        assertTrue(deployed.mechanism.code.length > 0);
        assertTrue(deployed.payoutRecipient.code.length > 0);
        assertTrue(deployed.arbitrator.code.length > 0);
        assertTrue(deployed.auxiliary.code.length > 0);

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.mechanism);
        assertEq(tcr.roundId(), roundId);
        assertEq(tcr.startAt(), startAt);
        assertEq(tcr.endAt(), endAt);
        assertEq(tcr.prizeVault(), deployed.payoutRecipient);
        assertEq(address(tcr.submissionDepositStrategy()), deployed.auxiliary);

        PrizePoolSubmissionDepositStrategy strategy = PrizePoolSubmissionDepositStrategy(deployed.auxiliary);
        assertEq(address(strategy.token()), address(underlying));
        assertEq(strategy.prizePool(), deployed.payoutRecipient);

        RoundPrizeVault vault = RoundPrizeVault(deployed.payoutRecipient);
        assertEq(address(vault.submissionsTCR()), deployed.mechanism);
        assertEq(vault.operator(), roundOperator);

        ERC20VotesArbitrator arb = ERC20VotesArbitrator(deployed.arbitrator);
        assertEq(address(arb.arbitrable()), deployed.mechanism);
        assertEq(arb.invalidRoundRewardsSink(), deployed.payoutRecipient);
        assertEq(arb.fixedBudgetTreasury(), address(budgetTreasury));
        assertEq(arb.stakeVault(), address(stakeVault));
        assertEq(arb.wrongOrMissedSlashBps(), 0);
        assertEq(arb.slashCallerBountyBps(), 0);
    }

    function test_deployForBudget_legacyConfigPayloadStillKeepsArbitratorNonSlashing() public {
        bytes32 roundId = keccak256("round-generic-factory-legacy-config");
        uint64 startAt = uint64(block.timestamp + 7);
        uint64 endAt = uint64(block.timestamp + 21 days);
        LegacyAllocationMechanismConfig memory legacyCfg = LegacyAllocationMechanismConfig({
            timing: RoundFactory.RoundTiming({ startAt: startAt, endAt: endAt }),
            roundOperator: roundOperator,
            tcrPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: hex"feedface",
                registrationMetaEvidence: "legacy-round-reg",
                clearingMetaEvidence: "legacy-round-clr",
                submissionBaseDeposit: 7e18,
                removalBaseDeposit: 8e18,
                submissionChallengeBaseDeposit: 9e18,
                removalChallengeBaseDeposit: 10e18,
                challengePeriodDuration: 4 days
            }),
            arbConfig: LegacyArbitratorConfig({
                votingPeriod: 3,
                votingDelay: 4,
                revealPeriod: 5,
                arbitrationCost: ARBITRATION_COST + 1,
                wrongOrMissedSlashBps: 1234,
                slashCallerBountyBps: 321
            })
        });

        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(roundId, address(budgetTreasury), abi.encode(legacyCfg));

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.mechanism);
        assertEq(tcr.roundId(), roundId);
        assertEq(tcr.startAt(), startAt);
        assertEq(tcr.endAt(), endAt);

        ERC20VotesArbitrator arb = ERC20VotesArbitrator(deployed.arbitrator);
        assertEq(arb.wrongOrMissedSlashBps(), 0);
        assertEq(arb.slashCallerBountyBps(), 0);
    }

    function test_createRoundForBudget_initializesClonesAndGuardsReinitialize() public {
        RoundFactory.DeployedRound memory deployed = _deployRound(keccak256("round-reinitialize-guard"));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RoundPrizeVault(deployed.prizeVault).initialize(
            underlying, ISuperToken(address(superToken)), RoundSubmissionTCR(deployed.submissionTCR), roundOperator
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        PrizePoolSubmissionDepositStrategy(deployed.depositStrategy).initialize(underlying, deployed.prizeVault);

        RoundSubmissionTCR.RoundConfig memory roundCfg = RoundSubmissionTCR.RoundConfig({
            roundId: bytes32("reinit"),
            startAt: uint64(block.timestamp),
            endAt: uint64(block.timestamp + 1 days),
            prizeVault: deployed.prizeVault
        });
        IGeneralizedTCRConfig.RegistryConfig memory regCfg = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: IArbitrator(deployed.arbitrator),
            votingToken: IVotes(address(underlying)),
            submissionDepositStrategy: ISubmissionDepositStrategy(deployed.depositStrategy),
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                submissionBaseDeposit: 1e18,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: 1 days
            })
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RoundSubmissionTCR(deployed.submissionTCR).initialize(roundCfg, regCfg);
    }

    function test_createRoundForBudget_createsIsolatedDepositStrategyClonePerRound() public {
        RoundFactory.DeployedRound memory first = _deployRound(keccak256("round-one"));
        RoundFactory.DeployedRound memory second = _deployRound(keccak256("round-two"));

        assertTrue(first.depositStrategy != second.depositStrategy);
        assertTrue(first.prizeVault != second.prizeVault);

        PrizePoolSubmissionDepositStrategy firstStrategy = PrizePoolSubmissionDepositStrategy(first.depositStrategy);
        PrizePoolSubmissionDepositStrategy secondStrategy = PrizePoolSubmissionDepositStrategy(second.depositStrategy);

        assertEq(address(firstStrategy.token()), address(underlying));
        assertEq(address(secondStrategy.token()), address(underlying));
        assertEq(firstStrategy.prizePool(), first.prizeVault);
        assertEq(secondStrategy.prizePool(), second.prizeVault);
        assertTrue(firstStrategy.prizePool() != secondStrategy.prizePool());
        assertEq(address(RoundSubmissionTCR(first.submissionTCR).submissionDepositStrategy()), first.depositStrategy);
        assertEq(address(RoundSubmissionTCR(second.submissionTCR).submissionDepositStrategy()), second.depositStrategy);
    }

    function test_createRoundForBudget_wiresSubmissionConfig_and_governor_surface_is_absent() public {
        bytes memory arbitratorExtraData = hex"1234beef";
        IGeneralizedTCRConfig.RegistryPolicy memory tcrConfig = IGeneralizedTCRConfig.RegistryPolicy({
            arbitratorExtraData: arbitratorExtraData,
            registrationMetaEvidence: "ipfs://custom-reg",
            clearingMetaEvidence: "ipfs://custom-clear",
            submissionBaseDeposit: 11e18,
            removalBaseDeposit: 22e18,
            submissionChallengeBaseDeposit: 33e18,
            removalChallengeBaseDeposit: 44e18,
            challengePeriodDuration: 3 days
        });

        RoundFactory.DeployedRound memory deployed = factory.createRoundForBudget(
            keccak256("round-custom"),
            address(budgetTreasury),
            RoundFactory.RoundTiming({ startAt: uint64(block.timestamp + 10), endAt: uint64(block.timestamp + 90 days) }),
            roundOperator,
            tcrConfig,
            _dummyArbConfig()
        );

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.submissionTCR);
        assertEq(tcr.arbitratorExtraData(), arbitratorExtraData);
        assertEq(tcr.registrationMetaEvidence(), tcrConfig.registrationMetaEvidence);
        assertEq(tcr.clearingMetaEvidence(), tcrConfig.clearingMetaEvidence);
        assertEq(tcr.submissionBaseDeposit(), tcrConfig.submissionBaseDeposit);
        assertEq(tcr.removalBaseDeposit(), tcrConfig.removalBaseDeposit);
        assertEq(tcr.submissionChallengeBaseDeposit(), tcrConfig.submissionChallengeBaseDeposit);
        assertEq(tcr.removalChallengeBaseDeposit(), tcrConfig.removalChallengeBaseDeposit);
        assertEq(tcr.challengePeriodDuration(), tcrConfig.challengePeriodDuration);
        assertEq(address(tcr.submissionDepositStrategy()), deployed.depositStrategy);

        (bool success, bytes memory revertData) = deployed.submissionTCR.call(abi.encodeWithSignature("governor()"));
        assertFalse(success);
        assertEq(revertData.length, 0);
    }

    function test_budgetScopedVotingPower_isProportionalToAllocatedStake() public {
        RoundFactory.DeployedRound memory deployed = _deployRound(keccak256("round-2"));

        RoundSubmissionTCR tcr = RoundSubmissionTCR(deployed.submissionTCR);
        ERC20VotesArbitrator arb = ERC20VotesArbitrator(deployed.arbitrator);

        vm.roll(10);
        stakeVault.setPastJurorWeight(juror, 100);
        ledger.setUserAllocationWeight(juror, 200);
        ledger.setUserAllocatedStakeOnBudget(juror, address(budgetTreasury), 50);

        vm.roll(11);
        underlying.mint(alice, 1000e18);
        underlying.mint(challenger, 1000e18);

        vm.prank(alice);
        underlying.approve(address(tcr), type(uint256).max);
        vm.prank(challenger);
        underlying.approve(address(tcr), type(uint256).max);

        bytes memory item = abi.encode(uint8(0), DEFAULT_POST_ID, alice);
        vm.prank(alice);
        bytes32 itemId = tcr.addItem(item);

        vm.prank(challenger);
        tcr.challengeRequest(itemId, "");

        (bool exists, uint256 requestIndex) = tcr.getLatestRequestIndex(itemId);
        assertTrue(exists);

        (, uint256 disputeId,,,,,,,,) = tcr.getRequestInfo(itemId, requestIndex);
        assertGt(disputeId, 0);

        (uint256 power, bool canVote) = arb.votingPowerInRound(disputeId, 0, juror);
        assertTrue(canVote);
        assertEq(power, 25);
    }

    function _dummyTcrConfig() internal pure returns (IGeneralizedTCRConfig.RegistryPolicy memory cfg) {
        cfg = IGeneralizedTCRConfig.RegistryPolicy({
            arbitratorExtraData: "",
            registrationMetaEvidence: "reg",
            clearingMetaEvidence: "clr",
            submissionBaseDeposit: 0,
            removalBaseDeposit: 0,
            submissionChallengeBaseDeposit: 0,
            removalChallengeBaseDeposit: 0,
            challengePeriodDuration: 1
        });
    }

    function _dummyArbConfig() internal view returns (RoundFactory.ArbitratorConfig memory cfg) {
        cfg = RoundFactory.ArbitratorConfig({
            votingPeriod: 1,
            votingDelay: 1,
            revealPeriod: 1,
            arbitrationCost: ARBITRATION_COST
        });
    }
}
