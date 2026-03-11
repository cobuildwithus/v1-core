// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {BudgetTCRStackDeploymentLib} from "src/tcr/library/BudgetTCRStackDeploymentLib.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IBudgetTCRStackDeployer} from "src/tcr/interfaces/IBudgetTCRStackDeployer.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IBudgetFlowRouterStrategy} from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MockUnderwriterSlasherRouter} from "test/mocks/MockUnderwriterSlasherRouter.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";

contract BudgetTCRStackDeploymentLibHarness {
    function deployTreasuryClone(address treasuryImplementation) external returns (address treasury) {
        treasury = Clones.clone(treasuryImplementation);
    }

    function deployBudgetTreasury(
        address budgetTCR,
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address budgetStakeLedger,
        address goalFlow,
        address underwriterSlasherRouter,
        uint32 budgetSlashPpm,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        address spendPolicy,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            budgetTCR,
            budgetTreasury,
            premiumEscrow,
            childFlow,
            budgetStakeLedger,
            goalFlow,
            underwriterSlasherRouter,
            budgetSlashPpm,
            listing,
            successResolver,
            spendPolicy,
            successAssertionLiveness,
            successAssertionBond
        );
    }
}

contract BudgetTCRStackDeploymentLibMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract BudgetTCRStackDeploymentLibMockParentFlow {
    function getMemberFlowRate(address) external pure returns (int96) {
        return 0;
    }
}

contract BudgetTCRStackDeploymentLibMockGoalFlow {
    address private immutable _superToken;

    constructor(address superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (address) {
        return _superToken;
    }

    function getTotalReceivedByMember(address) external pure returns (uint256 totalReceived) {
        return totalReceived;
    }
}

contract BudgetTCRStackDeploymentLibMockChildFlow {
    error NOT_RECIPIENT_ADMIN();

    address public recipientAdmin;
    address public flowOperator;
    address public sweeper;
    address public parent;
    address private immutable _superToken;
    address private immutable _strategy;

    constructor(address recipientAdmin_, address superToken_, address strategy_) {
        recipientAdmin = recipientAdmin_;
        flowOperator = recipientAdmin_;
        sweeper = recipientAdmin_;
        parent = address(new BudgetTCRStackDeploymentLibMockParentFlow());
        _superToken = superToken_;
        _strategy = strategy_;
    }

    function setRecipientAdmin(address newRecipientAdmin) external {
        if (msg.sender != recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        recipientAdmin = newRecipientAdmin;
    }

    function superToken() external view returns (address) {
        return _superToken;
    }

    function setFlowOperator(address newFlowOperator) external {
        flowOperator = newFlowOperator;
    }

    function setSweeper(address newSweeper) external {
        sweeper = newSweeper;
    }

    function strategy() external view returns (IAllocationStrategy) {
        return IAllocationStrategy(_strategy);
    }
}

contract BudgetTCRStackDeploymentLibMockBudgetStakeLedger {
    mapping(bytes32 => address) internal _budgetByRecipient;
    mapping(address => mapping(address => uint256)) internal _allocatedStake;

    function setBudget(bytes32 recipientId, address budgetTreasury) external {
        _budgetByRecipient[recipientId] = budgetTreasury;
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetByRecipient[recipientId];
    }

    function setAllocatedStake(address account, address budgetTreasury, uint256 amount) external {
        _allocatedStake[account][budgetTreasury] = amount;
    }

    function userAllocatedStakeOnBudget(address account, address budgetTreasury) external view returns (uint256) {
        return _allocatedStake[account][budgetTreasury];
    }
}

contract BudgetTCRStackDeploymentLibPermissiveFallbackTreasury {
    fallback() external payable {
        assembly ("memory-safe") {
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

contract BudgetTCRStackDeploymentLibResolvedTreasuryMock {
    function resolved() external pure returns (bool) {
        return true;
    }
}

contract BudgetTCRStackDeploymentLibRevertingResolvedTreasuryMock {
    error PROBE_FAILED();

    function resolved() external pure returns (bool) {
        revert PROBE_FAILED();
    }
}

contract BudgetTCRStackDeploymentLibNoStrategyChildFlow {
    function strategy() external pure returns (IAllocationStrategy) {
        return IAllocationStrategy(address(0));
    }
}

contract BudgetTCRDiscoveryEmitterMock {
    bytes32 public lastStackItemId;
    address public lastStackChildFlow;
    address public lastStackBudgetTreasury;
    address public lastStackPremiumEscrow;
    address public lastStackStrategy;

    bytes32 public lastMechanismItemId;
    address public lastMechanism;
    address public lastMechanismArbitrator;
    address public lastRoundFactory;

    function onBudgetStackDeployed(
        bytes32 itemID,
        address childFlow,
        address budgetTreasury,
        address premiumEscrow,
        address strategy
    ) external {
        lastStackItemId = itemID;
        lastStackChildFlow = childFlow;
        lastStackBudgetTreasury = budgetTreasury;
        lastStackPremiumEscrow = premiumEscrow;
        lastStackStrategy = strategy;
    }

    function onBudgetAllocationMechanismDeployed(
        bytes32 itemID,
        address allocationMechanism,
        address allocationMechanismArbitrator,
        address roundFactory
    ) external {
        lastMechanismItemId = itemID;
        lastMechanism = allocationMechanism;
        lastMechanismArbitrator = allocationMechanismArbitrator;
        lastRoundFactory = roundFactory;
    }
}

contract BudgetTCRStackDeploymentLibTest is Test, SpendPolicyTestUtils {
    BudgetTCRStackDeploymentLibHarness internal harness;
    BudgetTCRStackDeploymentLibMockToken internal goalToken;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedger;
    BudgetFlowRouterStrategy internal sharedStrategy;
    BudgetTreasury internal budgetTreasuryImplementation;
    PremiumEscrow internal premiumEscrowImplementation;
    BudgetTCRStackDeploymentLibMockGoalFlow internal goalFlow;
    MockUnderwriterSlasherRouter internal underwriterSlasherRouter;
    address internal budgetSpendPolicy;
    uint64 internal constant SUCCESS_ASSERTION_LIVENESS = 1 days;
    uint256 internal constant SUCCESS_ASSERTION_BOND = 10e18;
    uint32 internal constant BUDGET_SLASH_PPM = 50_000;

    address internal budgetTCR = makeAddr("budgetTCR");
    bytes32 internal recipientId = bytes32(uint256(1234));

    function setUp() public {
        harness = new BudgetTCRStackDeploymentLibHarness();
        goalToken = new BudgetTCRStackDeploymentLibMockToken("Goal", "GOAL");
        budgetStakeLedger = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
        BudgetFlowRouterStrategy strategyImplementation = new BudgetFlowRouterStrategy();
        sharedStrategy = BudgetFlowRouterStrategy(Clones.clone(address(strategyImplementation)));
        sharedStrategy.initialize(address(budgetStakeLedger), address(this));
        budgetTreasuryImplementation = new BudgetTreasury();
        premiumEscrowImplementation = new PremiumEscrow();
        goalFlow = new BudgetTCRStackDeploymentLibMockGoalFlow(address(goalToken));
        underwriterSlasherRouter = new MockUnderwriterSlasherRouter(address(this), address(0));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));
    }

    function test_prepareAndDeploy_linksTreasuryAnchor_andSharedStrategyUsesFlowRecipientRegistration() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));
        address strategy = address(sharedStrategy);

        assertTrue(strategy != address(0));
        assertEq(strategy, address(sharedStrategy));

        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), strategy);
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        address budgetTreasury =
            _deployBudgetTreasury(budgetTCR, treasuryAnchor, premiumEscrow, address(childFlow), listing, budgetTCR);

        assertEq(budgetTreasury, treasuryAnchor);
        assertEq(childFlow.recipientAdmin(), budgetTCR);
        assertEq(BudgetTreasury(budgetTreasury).successAssertionLiveness(), SUCCESS_ASSERTION_LIVENESS);
        assertEq(BudgetTreasury(budgetTreasury).successAssertionBond(), SUCCESS_ASSERTION_BOND);
        assertEq(BudgetTreasury(budgetTreasury).premiumEscrow(), premiumEscrow);
        assertEq(PremiumEscrow(premiumEscrow).budgetTreasury(), budgetTreasury);
        assertEq(PremiumEscrow(premiumEscrow).budgetStakeLedger(), address(budgetStakeLedger));
        assertEq(PremiumEscrow(premiumEscrow).goalFlow(), address(goalFlow));
        assertEq(PremiumEscrow(premiumEscrow).underwriterSlasherRouter(), address(underwriterSlasherRouter));
        assertEq(PremiumEscrow(premiumEscrow).budgetSlashPpm(), BUDGET_SLASH_PPM);

        BudgetFlowRouterStrategy budgetStrategy = BudgetFlowRouterStrategy(strategy);
        address allocator = makeAddr("allocator");
        uint256 allocatorKey = uint256(uint160(allocator));

        // No registered child flow for strategy context yet.
        (address unresolvedBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus unresolvedStatus) =
            budgetStrategy.flowBudgetStatus(address(childFlow));
        assertEq(unresolvedBudgetTreasury, address(0));
        assertEq(uint8(unresolvedStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.FlowNotRegistered));
        assertEq(budgetStrategy.currentWeight(address(childFlow), allocatorKey), 0);
        assertEq(budgetStrategy.accountAllocationWeight(address(childFlow), allocator), 0);
        assertFalse(budgetStrategy.canAllocate(address(childFlow), allocatorKey, allocator));
        assertFalse(budgetStrategy.canAccountAllocate(address(childFlow), allocator));

        budgetStrategy.registerFlowRecipient(address(childFlow), recipientId);
        budgetStakeLedger.setBudget(recipientId, budgetTreasury);
        budgetStakeLedger.setAllocatedStake(allocator, budgetTreasury, 42e18);

        (address resolvedBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus resolvedStatus) =
            budgetStrategy.flowBudgetStatus(address(childFlow));
        assertEq(resolvedBudgetTreasury, budgetTreasury);
        assertEq(uint8(resolvedStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.Active));
        assertEq(budgetStrategy.currentWeight(address(childFlow), allocatorKey), 42e18);
        assertEq(budgetStrategy.accountAllocationWeight(address(childFlow), allocator), 42e18);
        assertTrue(budgetStrategy.canAllocate(address(childFlow), allocatorKey, allocator));
        assertTrue(budgetStrategy.canAccountAllocate(address(childFlow), allocator));
    }

    function test_sharedStrategy_flowBudgetStatus_distinguishesInactiveFailureModes() public {
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);

        (address missingBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus missingStatus) =
            sharedStrategy.flowBudgetStatus(address(childFlow));
        assertEq(missingBudgetTreasury, address(0));
        assertEq(uint8(missingStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.MissingBudgetTreasury));

        address invalidTreasury = makeAddr("invalidTreasury");
        budgetStakeLedger.setBudget(recipientId, invalidTreasury);
        (address nonCodeBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus invalidStatus) =
            sharedStrategy.flowBudgetStatus(address(childFlow));
        assertEq(nonCodeBudgetTreasury, invalidTreasury);
        assertEq(uint8(invalidStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.InvalidBudgetTreasury));

        address resolvedTreasury = address(new BudgetTCRStackDeploymentLibResolvedTreasuryMock());
        budgetStakeLedger.setBudget(recipientId, resolvedTreasury);
        (address terminalBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus resolvedStatus) =
            sharedStrategy.flowBudgetStatus(address(childFlow));
        assertEq(terminalBudgetTreasury, resolvedTreasury);
        assertEq(uint8(resolvedStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.BudgetResolved));
        assertEq(sharedStrategy.currentWeight(address(childFlow), uint256(uint160(address(this)))), 0);
        assertFalse(sharedStrategy.canAccountAllocate(address(childFlow), address(this)));

        address probeFailedTreasury = address(new BudgetTCRStackDeploymentLibRevertingResolvedTreasuryMock());
        budgetStakeLedger.setBudget(recipientId, probeFailedTreasury);
        (address revertedBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus probeFailedStatus) =
            sharedStrategy.flowBudgetStatus(address(childFlow));
        assertEq(revertedBudgetTreasury, probeFailedTreasury);
        assertEq(uint8(probeFailedStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.BudgetProbeFailed));
        assertEq(sharedStrategy.accountAllocationWeight(address(childFlow), address(this)), 0);
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenCallerIsNotRegistrar() public {
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));
        address notRegistrar = makeAddr("not-registrar");

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetFlowRouterStrategy.ONLY_REGISTRAR.selector, notRegistrar, address(this))
        );
        vm.prank(notRegistrar);
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenFlowHasDifferentStrategy() public {
        address otherStrategy = makeAddr("other-strategy");
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), otherStrategy);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetFlowRouterStrategy.INVALID_FLOW_STRATEGY.selector,
                address(childFlow),
                address(sharedStrategy),
                otherStrategy
            )
        );
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenAlreadyRegistered() public {
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetFlowRouterStrategy.FLOW_ALREADY_REGISTERED.selector, address(childFlow))
        );
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_deployBudgetTreasury_revertsWhenBudgetTreasuryIsNonContractAddress() public {
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRStackDeploymentLib.INVALID_TREASURY.selector, address(0xCAFE)));
        _deployBudgetTreasury(
            budgetTCR,
            address(0xCAFE),
            address(premiumEscrowImplementation),
            address(childFlow),
            _defaultListing(),
            budgetTCR
        );
    }

    function test_deployBudgetTreasury_revertsWhenBudgetTreasuryIsZeroAddress() public {
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR,
            address(0),
            address(premiumEscrowImplementation),
            address(childFlow),
            _defaultListing(),
            budgetTCR
        );
    }

    function test_deployBudgetTreasury_revertsWhenBudgetTreasuryHasInvalidConfiguration() public {
        BudgetTCRStackDeploymentLibPermissiveFallbackTreasury invalidTreasury =
            new BudgetTCRStackDeploymentLibPermissiveFallbackTreasury();
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));

        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRStackDeploymentLib.INVALID_TREASURY_CONFIGURATION.selector, address(invalidTreasury)
            )
        );
        _deployBudgetTreasury(
            budgetTCR, address(invalidTreasury), premiumEscrow, address(childFlow), _defaultListing(), budgetTCR
        );
    }

    function test_deployBudgetTreasury_revertsWhenTreasuryCloneAlreadyInitialized() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));

        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);
        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        _deployBudgetTreasury(budgetTCR, treasuryAnchor, premiumEscrow, address(childFlow), listing, budgetTCR);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _deployBudgetTreasury(budgetTCR, treasuryAnchor, premiumEscrow, address(childFlow), listing, budgetTCR);
    }

    function test_deployBudgetTreasury_revertsOnZeroCriticalAddresses() public {
        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            address(0),
            makeAddr("treasury"),
            address(premiumEscrowImplementation),
            makeAddr("flow"),
            _defaultListing(),
            budgetTCR
        );

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR, address(0), address(premiumEscrowImplementation), makeAddr("flow"), _defaultListing(), budgetTCR
        );

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR,
            makeAddr("treasury"),
            address(premiumEscrowImplementation),
            address(0),
            _defaultListing(),
            budgetTCR
        );

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR,
            makeAddr("treasury"),
            address(premiumEscrowImplementation),
            makeAddr("flow"),
            _defaultListing(),
            address(0)
        );
    }

    function _deployBudgetTreasury(
        address budgetTCR_,
        address budgetTreasury_,
        address premiumEscrow_,
        address childFlow,
        IBudgetTCR.BudgetListing memory listing,
        address successResolver
    ) internal returns (address budgetTreasury) {
        budgetTreasury = harness.deployBudgetTreasury(
            budgetTCR_,
            budgetTreasury_,
            premiumEscrow_,
            childFlow,
            address(budgetStakeLedger),
            address(goalFlow),
            address(underwriterSlasherRouter),
            BUDGET_SLASH_PPM,
            listing,
            successResolver,
            budgetSpendPolicy,
            SUCCESS_ASSERTION_LIVENESS,
            SUCCESS_ASSERTION_BOND
        );
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing.metadata = FlowTypes.RecipientMetadata({
            title: "Budget",
            description: "Budget description",
            image: "ipfs://image",
            tagline: "tagline",
            url: "https://example.com"
        });
        listing.fundingDeadline = uint64(block.timestamp + 7 days);
        listing.executionDuration = uint64(14 days);
        listing.activationThreshold = 100e18;
        listing.runwayCap = 1_000e18;
        listing.oracleConfig = IBudgetTCR.OracleConfig({
            oracleSpecHash: keccak256("oracle-spec"), assertionPolicyHash: keccak256("oracle-policy")
        });
    }
}

contract BudgetTCRDeployerSharedStrategyTest is Test, SpendPolicyTestUtils {
    BudgetTCRDeployer internal deployer;
    BudgetTCRStackDeploymentLibMockToken internal goalToken;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedgerA;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedgerB;
    PremiumEscrow internal premiumEscrowImplementation;
    BudgetTCRStackDeploymentLibMockGoalFlow internal goalFlow;
    MockUnderwriterSlasherRouter internal underwriterSlasherRouter;

    function setUp() public {
        deployer = _deployBudgetTcrDeployer();
        premiumEscrowImplementation = new PremiumEscrow();
        underwriterSlasherRouter = new MockUnderwriterSlasherRouter(address(this), address(0));
        deployer.initialize(address(this), address(premiumEscrowImplementation), address(0));

        goalToken = new BudgetTCRStackDeploymentLibMockToken("Goal", "GOAL");
        budgetStakeLedgerA = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
        budgetStakeLedgerB = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
        goalFlow = new BudgetTCRStackDeploymentLibMockGoalFlow(address(goalToken));
    }

    function test_registerChildFlowRecipient_revertsWhenSharedStrategyNotPrepared() public {
        vm.expectRevert(BudgetTCRDeployer.SHARED_BUDGET_STRATEGY_NOT_DEPLOYED.selector);
        deployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_initialize_revertsOnSecondCall() public {
        address initialBudgetTcr = deployer.budgetTCR();
        address initialPremiumEscrowImplementation = deployer.premiumEscrowImplementation();
        address nextPremiumEscrowImplementation = address(new PremiumEscrow());

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        deployer.initialize(makeAddr("next-budget-tcr"), nextPremiumEscrowImplementation, address(0));

        assertEq(deployer.budgetTCR(), initialBudgetTcr);
        assertEq(deployer.premiumEscrowImplementation(), initialPremiumEscrowImplementation);
    }

    function test_initialize_revertsWhenCalledOnImplementation() public {
        address premiumEscrowImplementationAddress = address(new PremiumEscrow());
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        BudgetTCRDeployer implementation = new BudgetTCRDeployer(
            address(new BudgetTreasury()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        implementation.initialize(address(this), premiumEscrowImplementationAddress, address(0));
    }

    function test_initialize_withDiscoveryEmitter_setsDiscoveryEmitter() public {
        BudgetTCRDeployer deployerWithEmitter = _deployBudgetTcrDeployer();
        BudgetTCRDiscoveryEmitterMock discoveryEmitter = new BudgetTCRDiscoveryEmitterMock();
        address budgetTcr = makeAddr("budget-tcr");
        PremiumEscrow premiumEscrow = new PremiumEscrow();

        deployerWithEmitter.initialize(budgetTcr, address(premiumEscrow), address(discoveryEmitter));

        assertEq(deployerWithEmitter.budgetTCR(), budgetTcr);
        assertEq(deployerWithEmitter.premiumEscrowImplementation(), address(premiumEscrow));
        assertEq(deployerWithEmitter.discoveryEmitter(), address(discoveryEmitter));
    }

    function test_initialize_withDiscoveryEmitter_revertsWhenEmitterHasNoCode() public {
        BudgetTCRDeployer deployerWithEmitter = _deployBudgetTcrDeployer();
        address noCodeEmitter = vm.addr(123456789);
        assertEq(noCodeEmitter.code.length, 0);
        address premiumEscrow = address(new PremiumEscrow());

        vm.expectRevert(IBudgetTCRStackDeployer.ADDRESS_ZERO.selector);
        deployerWithEmitter.initialize(makeAddr("budget-tcr"), premiumEscrow, noCodeEmitter);
    }

    function test_strategyImplementation_revertsWhenInitializedDirectly() public {
        BudgetFlowRouterStrategy implementation = new BudgetFlowRouterStrategy();

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        implementation.initialize(address(budgetStakeLedgerA), address(this));
    }

    function test_strategyCloneInitialize_revertsWhenLedgerIsZero() public {
        BudgetFlowRouterStrategy implementation = new BudgetFlowRouterStrategy();
        BudgetFlowRouterStrategy clone = BudgetFlowRouterStrategy(Clones.clone(address(implementation)));

        vm.expectRevert(abi.encodeWithSelector(IAllocationStrategy.ADDRESS_ZERO.selector));
        clone.initialize(address(0), address(this));
    }

    function test_strategyCloneInitialize_revertsWhenRegistrarIsZero() public {
        BudgetFlowRouterStrategy implementation = new BudgetFlowRouterStrategy();
        BudgetFlowRouterStrategy clone = BudgetFlowRouterStrategy(Clones.clone(address(implementation)));

        vm.expectRevert(abi.encodeWithSelector(IAllocationStrategy.ADDRESS_ZERO.selector));
        clone.initialize(address(budgetStakeLedgerA), address(0));
    }

    function test_registerChildFlowRecipient_revertsWhenCallerIsNotBudgetTCR() public {
        BudgetTCRDeployer guardedDeployer = _deployBudgetTcrDeployer();
        guardedDeployer.initialize(makeAddr("budget-tcr"), address(premiumEscrowImplementation), address(0));

        vm.expectRevert(IBudgetTCRStackDeployer.ONLY_BUDGET_TCR.selector);
        guardedDeployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_emitBudgetStackDeployed_forwardsToDiscoveryEmitter() public {
        BudgetTCRDeployer deployerWithEmitter = _deployBudgetTcrDeployer();
        BudgetTCRDiscoveryEmitterMock discoveryEmitter = new BudgetTCRDiscoveryEmitterMock();
        address budgetTcr = makeAddr("budget-tcr");
        deployerWithEmitter.initialize(budgetTcr, address(premiumEscrowImplementation), address(discoveryEmitter));

        bytes32 itemID = keccak256("item-id");
        address childFlow = makeAddr("child-flow");
        address budgetTreasury = makeAddr("budget-treasury");
        address premiumEscrow = makeAddr("premium-escrow");
        address strategy = makeAddr("strategy");

        vm.prank(budgetTcr);
        deployerWithEmitter.emitBudgetStackDeployed(itemID, childFlow, budgetTreasury, premiumEscrow, strategy);

        assertEq(discoveryEmitter.lastStackItemId(), itemID);
        assertEq(discoveryEmitter.lastStackChildFlow(), childFlow);
        assertEq(discoveryEmitter.lastStackBudgetTreasury(), budgetTreasury);
        assertEq(discoveryEmitter.lastStackPremiumEscrow(), premiumEscrow);
        assertEq(discoveryEmitter.lastStackStrategy(), strategy);
    }

    function test_emitBudgetAllocationMechanismDeployed_forwardsToDiscoveryEmitter() public {
        BudgetTCRDeployer deployerWithEmitter = _deployBudgetTcrDeployer();
        BudgetTCRDiscoveryEmitterMock discoveryEmitter = new BudgetTCRDiscoveryEmitterMock();
        address budgetTcr = makeAddr("budget-tcr");
        deployerWithEmitter.initialize(budgetTcr, address(premiumEscrowImplementation), address(discoveryEmitter));

        bytes32 itemID = keccak256("item-id");
        address mechanism = makeAddr("mechanism");
        address mechanismArbitrator = makeAddr("mechanism-arbitrator");
        address roundFactory = makeAddr("round-factory");

        vm.prank(budgetTcr);
        deployerWithEmitter.emitBudgetAllocationMechanismDeployed(itemID, mechanism, mechanismArbitrator, roundFactory);

        assertEq(discoveryEmitter.lastMechanismItemId(), itemID);
        assertEq(discoveryEmitter.lastMechanism(), mechanism);
        assertEq(discoveryEmitter.lastMechanismArbitrator(), mechanismArbitrator);
        assertEq(discoveryEmitter.lastRoundFactory(), roundFactory);
    }

    function test_emitBudgetStackDeployed_revertsWhenCallerIsNotBudgetTCR() public {
        BudgetTCRDeployer guardedDeployer = _deployBudgetTcrDeployer();
        guardedDeployer.initialize(makeAddr("budget-tcr"), address(premiumEscrowImplementation), address(0));

        vm.expectRevert(IBudgetTCRStackDeployer.ONLY_BUDGET_TCR.selector);
        guardedDeployer.emitBudgetStackDeployed(
            keccak256("item-id"),
            makeAddr("child-flow"),
            makeAddr("budget-treasury"),
            makeAddr("premium-escrow"),
            makeAddr("strategy")
        );
    }

    function test_registerChildFlowRecipient_registersRecipientAndRejectsDuplicateFlow() public {
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            address(budgetStakeLedgerA), address(goalFlow), address(underwriterSlasherRouter)
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(address(this), address(goalToken), prepared.strategy);

        bytes32 recipientId = bytes32(uint256(77));
        deployer.registerChildFlowRecipient(recipientId, address(childFlow));

        (bytes32 registeredRecipientId, bool registered) =
            IBudgetFlowRouterStrategy(prepared.strategy).recipientIdForFlow(address(childFlow));
        assertTrue(registered);
        assertEq(registeredRecipientId, recipientId);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetFlowRouterStrategy.FLOW_ALREADY_REGISTERED.selector, address(childFlow))
        );
        deployer.registerChildFlowRecipient(bytes32(uint256(88)), address(childFlow));
    }

    function test_registerChildFlowRecipient_revertsWhenChildFlowUsesDifferentStrategy() public {
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            address(budgetStakeLedgerA), address(goalFlow), address(underwriterSlasherRouter)
        );

        address otherStrategy = makeAddr("other-strategy");
        BudgetTCRStackDeploymentLibMockChildFlow childFlow =
            new BudgetTCRStackDeploymentLibMockChildFlow(address(this), address(goalToken), otherStrategy);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetFlowRouterStrategy.INVALID_FLOW_STRATEGY.selector,
                address(childFlow),
                prepared.strategy,
                otherStrategy
            )
        );
        deployer.registerChildFlowRecipient(bytes32(uint256(99)), address(childFlow));
    }

    function test_registerChildFlowRecipient_revertsWhenChildFlowHasZeroStrategies() public {
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            address(budgetStakeLedgerA), address(goalFlow), address(underwriterSlasherRouter)
        );

        BudgetTCRStackDeploymentLibNoStrategyChildFlow childFlow = new BudgetTCRStackDeploymentLibNoStrategyChildFlow();

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetFlowRouterStrategy.INVALID_FLOW_STRATEGY.selector,
                address(childFlow),
                prepared.strategy,
                address(0)
            )
        );
        deployer.registerChildFlowRecipient(bytes32(uint256(100)), address(childFlow));
    }

    function test_prepareBudgetStack_reusesSharedStrategyAndRejectsLedgerMismatch() public {
        IBudgetTCRStackDeployer.PreparationResult memory firstPreparation = deployer.prepareBudgetStack(
            address(budgetStakeLedgerA), address(goalFlow), address(underwriterSlasherRouter)
        );

        assertTrue(firstPreparation.budgetTreasury != address(0));
        assertEq(firstPreparation.strategy, deployer.sharedBudgetFlowStrategy());
        assertEq(deployer.sharedBudgetFlowStrategyLedger(), address(budgetStakeLedgerA));

        IBudgetTCRStackDeployer.PreparationResult memory secondPreparation = deployer.prepareBudgetStack(
            address(budgetStakeLedgerA), address(goalFlow), address(underwriterSlasherRouter)
        );

        assertEq(secondPreparation.strategy, firstPreparation.strategy);
        assertNotEq(secondPreparation.budgetTreasury, firstPreparation.budgetTreasury);

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRDeployer.BUDGET_STAKE_LEDGER_MISMATCH.selector,
                address(budgetStakeLedgerA),
                address(budgetStakeLedgerB)
            )
        );
        deployer.prepareBudgetStack(address(budgetStakeLedgerB), address(goalFlow), address(underwriterSlasherRouter));
    }

    function test_prepareBudgetStack_initializesClonedStrategyAndLocksStrategyInitializer() public {
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            address(budgetStakeLedgerA), address(goalFlow), address(underwriterSlasherRouter)
        );

        BudgetFlowRouterStrategy strategy = BudgetFlowRouterStrategy(prepared.strategy);
        assertEq(address(strategy.budgetStakeLedger()), address(budgetStakeLedgerA));
        assertEq(strategy.registrar(), address(deployer));
        assertNotEq(prepared.strategy, deployer.budgetFlowRouterStrategyImplementation());

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        strategy.initialize(address(budgetStakeLedgerB), address(this));
    }

    function test_prepareBudgetStack_revertsWhenBudgetStakeLedgerIsZeroWithoutMutatingSharedState() public {
        vm.expectRevert(IBudgetTCRStackDeployer.ADDRESS_ZERO.selector);
        deployer.prepareBudgetStack(address(0), address(goalFlow), address(underwriterSlasherRouter));

        assertEq(deployer.sharedBudgetFlowStrategy(), address(0));
        assertEq(deployer.sharedBudgetFlowStrategyLedger(), address(0));
    }

    function test_prepareBudgetStack_revertsWhenGoalFlowIsZeroWithoutMutatingSharedState() public {
        vm.expectRevert(IBudgetTCRStackDeployer.ADDRESS_ZERO.selector);
        deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(0), address(underwriterSlasherRouter));

        assertEq(deployer.sharedBudgetFlowStrategy(), address(0));
        assertEq(deployer.sharedBudgetFlowStrategyLedger(), address(0));
    }

    function test_prepareBudgetStack_revertsWhenUnderwriterSlasherRouterIsZeroWithoutMutatingSharedState() public {
        vm.expectRevert(IBudgetTCRStackDeployer.ADDRESS_ZERO.selector);
        deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow), address(0));

        assertEq(deployer.sharedBudgetFlowStrategy(), address(0));
        assertEq(deployer.sharedBudgetFlowStrategyLedger(), address(0));
    }

    function test_constructor_revertsWhenBudgetFlowRouterStrategyImplementationIsZero() public {
        address budgetTreasuryImplementation = address(new BudgetTreasury());
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        address allocationMechanismTcrImplementation =
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow())));
        address allocationMechanismArbitratorImplementation = address(new ERC20VotesArbitrator());

        vm.expectRevert(IBudgetTCRStackDeployer.ADDRESS_ZERO.selector);
        new BudgetTCRDeployer(
            budgetTreasuryImplementation,
            roundFactory,
            roundFactory,
            allocationMechanismTcrImplementation,
            allocationMechanismArbitratorImplementation,
            address(0)
        );
    }

    function test_constructor_revertsWhenBudgetFlowRouterStrategyImplementationHasNoCode() public {
        address budgetTreasuryImplementation = address(new BudgetTreasury());
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        address allocationMechanismTcrImplementation =
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow())));
        address allocationMechanismArbitratorImplementation = address(new ERC20VotesArbitrator());
        address noCode = makeAddr("no-code");

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRDeployer.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new BudgetTCRDeployer(
            budgetTreasuryImplementation,
            roundFactory,
            roundFactory,
            allocationMechanismTcrImplementation,
            allocationMechanismArbitratorImplementation,
            noCode
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
        BudgetTCRDeployer implementation = new BudgetTCRDeployer(
            address(new BudgetTreasury()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
        return BudgetTCRDeployer(Clones.clone(address(implementation)));
    }
}
