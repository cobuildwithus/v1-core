// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {BudgetStackDeploymentLib} from "src/goals/library/BudgetStackDeploymentLib.sol";
import {BudgetStackDeployer} from "src/goals/BudgetStackDeployer.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {IBudgetStackChildFlowStrategyFactory} from "src/interfaces/IBudgetStackChildFlowStrategyFactory.sol";
import {BudgetStackTypes} from "src/interfaces/BudgetStackTypes.sol";
import {IBudgetStackRuntimeDeployer} from "src/interfaces/IBudgetStackRuntimeDeployer.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
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
import {BudgetTCRConfigHelpers} from "test/helpers/BudgetTCRConfigHelpers.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";

contract BudgetStackDeploymentLibHarness {
    function deployTreasuryClone(address treasuryImplementation) external returns (address treasury) {
        treasury = Clones.clone(treasuryImplementation);
    }

    function deployBudgetTreasury(
        address budgetTCR,
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig
    ) external returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury =
            BudgetStackDeploymentLib.deployBudgetTreasury(budgetTCR, budgetTreasury, budgetConfig);
    }

    function deployBudgetTreasuryWithRiskModule(
        address budgetTCR,
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig,
        BudgetStackTypes.RiskModuleInitConfig calldata riskModuleInitConfig
    ) external returns (address deployedBudgetTreasury) {
        deployedBudgetTreasury = BudgetStackDeploymentLib.deployBudgetTreasuryWithRiskModule(
            budgetTCR, budgetTreasury, budgetConfig, riskModuleInitConfig
        );
    }
}

contract BudgetStackDeploymentLibMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract BudgetStackDeploymentLibMockParentFlow {
    function getMemberFlowRate(address) external pure returns (int96) {
        return 0;
    }
}

contract BudgetStackDeploymentLibMockGoalFlow {
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

contract BudgetStackDeploymentLibMockChildFlow {
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
        parent = address(new BudgetStackDeploymentLibMockParentFlow());
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

contract BudgetStackDeploymentLibMockBudgetStakeLedger {
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

contract BudgetStackDeploymentLibPermissiveFallbackTreasury {
    fallback() external payable {
        assembly ("memory-safe") {
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

contract BudgetStackDeploymentLibResolvedTreasuryMock {
    function resolved() external pure returns (bool) {
        return true;
    }
}

contract BudgetStackDeploymentLibRevertingResolvedTreasuryMock {
    error PROBE_FAILED();

    function resolved() external pure returns (bool) {
        revert PROBE_FAILED();
    }
}

contract BudgetStackDeploymentLibNoStrategyChildFlow {
    function strategy() external pure returns (IAllocationStrategy) {
        return IAllocationStrategy(address(0));
    }
}

contract BudgetStackDeploymentLibFixedStrategyMock is IAllocationStrategy {
    function allocationKey(address, bytes calldata) external pure returns (uint256 key) {
        return key;
    }

    function currentWeight(address, uint256) external pure returns (uint256 weight) {
        return weight;
    }

    function canAllocate(address, uint256, address) external pure returns (bool allowed) {
        return true;
    }

    function strategyKey() external pure returns (string memory) {
        return "fixed";
    }
}

contract BudgetTCRChildFlowStrategyFactoryMock is IBudgetStackChildFlowStrategyFactory {
    address public immutable strategy;
    address public lastBudgetTreasury;
    address public lastBudgetStakeLedger;
    address public lastGoalFlow;
    address public lastRegistrar;

    constructor(address strategy_) {
        strategy = strategy_;
    }

    function prepareChildFlowStrategy(
        address budgetTreasury,
        address budgetStakeLedger,
        address goalFlow,
        address registrar
    ) external returns (address preparedStrategy) {
        lastBudgetTreasury = budgetTreasury;
        lastBudgetStakeLedger = budgetStakeLedger;
        lastGoalFlow = goalFlow;
        lastRegistrar = registrar;
        return strategy;
    }
}

abstract contract BudgetStackDeployerOpenPresetHelpers {
    function _openStackModuleConfig(address premiumEscrowImplementation_)
        internal
        pure
        returns (BudgetStackTypes.StackModuleConfig memory stackModuleConfig)
    {
        stackModuleConfig = BudgetTCRConfigHelpers.openStackModuleConfig(premiumEscrowImplementation_);
    }

    function _initializeOpenBudgetTcrDeployer(
        BudgetStackDeployer deployer_,
        address budgetTcr_,
        address premiumEscrowImplementation_
    ) internal {
        deployer_.initializeWithConfig(budgetTcr_, _openStackModuleConfig(premiumEscrowImplementation_));
    }
}

contract BudgetStackDeploymentLibTest is Test, SpendPolicyTestUtils, BudgetStackDeployerOpenPresetHelpers {
    BudgetStackDeploymentLibHarness internal harness;
    BudgetStackDeploymentLibMockToken internal goalToken;
    BudgetStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedger;
    BudgetFlowRouterStrategy internal sharedStrategy;
    BudgetTreasury internal budgetTreasuryImplementation;
    PremiumEscrow internal premiumEscrowImplementation;
    BudgetStackDeploymentLibMockGoalFlow internal goalFlow;
    MockUnderwriterSlasherRouter internal underwriterSlasherRouter;
    address internal budgetSpendPolicy;
    uint64 internal constant SUCCESS_ASSERTION_LIVENESS = 1 days;
    uint256 internal constant SUCCESS_ASSERTION_BOND = 10e18;
    uint32 internal constant BUDGET_SLASH_PPM = 50_000;

    address internal budgetTCR = makeAddr("budgetTCR");
    bytes32 internal recipientId = bytes32(uint256(1234));

    function setUp() public {
        harness = new BudgetStackDeploymentLibHarness();
        goalToken = new BudgetStackDeploymentLibMockToken("Goal", "GOAL");
        budgetStakeLedger = new BudgetStackDeploymentLibMockBudgetStakeLedger();
        BudgetFlowRouterStrategy strategyImplementation = new BudgetFlowRouterStrategy();
        sharedStrategy = BudgetFlowRouterStrategy(Clones.clone(address(strategyImplementation)));
        sharedStrategy.initialize(address(budgetStakeLedger), address(this));
        budgetTreasuryImplementation = new BudgetTreasury();
        premiumEscrowImplementation = new PremiumEscrow();
        goalFlow = new BudgetStackDeploymentLibMockGoalFlow(address(goalToken));
        underwriterSlasherRouter = new MockUnderwriterSlasherRouter(address(this), address(0));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));
    }

    function test_prepareAndDeploy_linksTreasuryAnchor_andSharedStrategyUsesFlowRecipientRegistration() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));
        address strategy = address(sharedStrategy);

        assertTrue(strategy != address(0));
        assertEq(strategy, address(sharedStrategy));

        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), strategy);
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
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));
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

        address resolvedTreasury = address(new BudgetStackDeploymentLibResolvedTreasuryMock());
        budgetStakeLedger.setBudget(recipientId, resolvedTreasury);
        (address terminalBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus resolvedStatus) =
            sharedStrategy.flowBudgetStatus(address(childFlow));
        assertEq(terminalBudgetTreasury, resolvedTreasury);
        assertEq(uint8(resolvedStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.BudgetResolved));
        assertEq(sharedStrategy.currentWeight(address(childFlow), uint256(uint160(address(this)))), 0);
        assertFalse(sharedStrategy.canAccountAllocate(address(childFlow), address(this)));

        address probeFailedTreasury = address(new BudgetStackDeploymentLibRevertingResolvedTreasuryMock());
        budgetStakeLedger.setBudget(recipientId, probeFailedTreasury);
        (address revertedBudgetTreasury, IBudgetFlowRouterStrategy.FlowBudgetStatus probeFailedStatus) =
            sharedStrategy.flowBudgetStatus(address(childFlow));
        assertEq(revertedBudgetTreasury, probeFailedTreasury);
        assertEq(uint8(probeFailedStatus), uint8(IBudgetFlowRouterStrategy.FlowBudgetStatus.BudgetProbeFailed));
        assertEq(sharedStrategy.accountAllocationWeight(address(childFlow), address(this)), 0);
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenCallerIsNotRegistrar() public {
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));
        address notRegistrar = makeAddr("not-registrar");

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetFlowRouterStrategy.ONLY_REGISTRAR.selector, notRegistrar, address(this))
        );
        vm.prank(notRegistrar);
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenFlowHasDifferentStrategy() public {
        address otherStrategy = makeAddr("other-strategy");
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), otherStrategy);

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
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetFlowRouterStrategy.FLOW_ALREADY_REGISTERED.selector, address(childFlow))
        );
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_deployBudgetTreasury_revertsWhenBudgetTreasuryIsNonContractAddress() public {
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        vm.expectRevert(abi.encodeWithSelector(BudgetStackDeploymentLib.INVALID_TREASURY.selector, address(0xCAFE)));
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
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        vm.expectRevert(BudgetStackDeploymentLib.ADDRESS_ZERO.selector);
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
        BudgetStackDeploymentLibPermissiveFallbackTreasury invalidTreasury =
            new BudgetStackDeploymentLibPermissiveFallbackTreasury();
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));

        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetStackDeploymentLib.INVALID_TREASURY_CONFIGURATION.selector, address(invalidTreasury)
            )
        );
        _deployBudgetTreasury(
            budgetTCR, address(invalidTreasury), premiumEscrow, address(childFlow), _defaultListing(), budgetTCR
        );
    }

    function test_deployBudgetTreasury_revertsWhenTreasuryCloneAlreadyInitialized() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));

        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken), address(sharedStrategy));
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);
        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        _deployBudgetTreasury(budgetTCR, treasuryAnchor, premiumEscrow, address(childFlow), listing, budgetTCR);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _deployBudgetTreasury(budgetTCR, treasuryAnchor, premiumEscrow, address(childFlow), listing, budgetTCR);
    }

    function test_deployBudgetTreasury_revertsOnZeroCriticalAddresses() public {
        vm.expectRevert(BudgetStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            address(0),
            makeAddr("treasury"),
            address(premiumEscrowImplementation),
            makeAddr("flow"),
            _defaultListing(),
            budgetTCR
        );

        vm.expectRevert(BudgetStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR, address(0), address(premiumEscrowImplementation), makeAddr("flow"), _defaultListing(), budgetTCR
        );

        vm.expectRevert(BudgetStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR,
            makeAddr("treasury"),
            address(premiumEscrowImplementation),
            address(0),
            _defaultListing(),
            budgetTCR
        );

        vm.expectRevert(BudgetStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(
            budgetTCR,
            makeAddr("treasury"),
            address(premiumEscrowImplementation),
            makeAddr("flow"),
            _defaultListing(),
            address(0)
        );
    }

    function test_deployBudgetTreasury_allowsZeroPremiumEscrowAndSkipsRiskModuleInitialization() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        IBudgetTCR.BudgetListing memory listing = _defaultListing();

        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(makeAddr("safe"), address(goalToken), address(sharedStrategy));
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);

        address budgetTreasury = harness.deployBudgetTreasury(
            budgetTCR, treasuryAnchor, _budgetConfig(address(childFlow), address(0), listing, budgetTCR)
        );

        assertEq(budgetTreasury, treasuryAnchor);
        assertEq(BudgetTreasury(budgetTreasury).controller(), budgetTCR);
        assertEq(BudgetTreasury(budgetTreasury).flow(), address(childFlow));
        assertEq(BudgetTreasury(budgetTreasury).premiumEscrow(), address(0));
        assertEq(BudgetTreasury(budgetTreasury).successResolver(), budgetTCR);
        assertEq(BudgetTreasury(budgetTreasury).spendPolicy(), budgetSpendPolicy);
    }

    function test_deployBudgetTreasury_keepsPremiumEscrowStakeLedgerAndRouterFailFast() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        address premiumEscrow = Clones.clone(address(premiumEscrowImplementation));
        IBudgetTCR.BudgetListing memory listing = _defaultListing();

        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(makeAddr("safe"), address(goalToken), address(sharedStrategy));
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);

        vm.expectRevert(PremiumEscrow.ADDRESS_ZERO.selector);
        harness.deployBudgetTreasuryWithRiskModule(
            budgetTCR,
            treasuryAnchor,
            _budgetConfig(address(childFlow), premiumEscrow, listing, budgetTCR),
            _riskModuleInitConfig(address(0), address(goalFlow), address(0), BUDGET_SLASH_PPM)
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
        budgetTreasury = harness.deployBudgetTreasuryWithRiskModule(
            budgetTCR_,
            budgetTreasury_,
            _budgetConfig(childFlow, premiumEscrow_, listing, successResolver),
            _riskModuleInitConfig(
                address(budgetStakeLedger), address(goalFlow), address(underwriterSlasherRouter), BUDGET_SLASH_PPM
            )
        );
    }

    function _budgetConfig(
        address childFlow,
        address premiumEscrow_,
        IBudgetTCR.BudgetListing memory listing,
        address successResolver
    ) internal view returns (IBudgetTreasury.BudgetConfig memory config) {
        config = IBudgetTreasury.BudgetConfig({
            flow: childFlow,
            premiumEscrow: premiumEscrow_,
            fundingDeadline: listing.fundingDeadline,
            executionDuration: listing.executionDuration,
            activationThreshold: listing.activationThreshold,
            runwayCap: listing.runwayCap,
            successResolver: successResolver,
            successAssertionLiveness: SUCCESS_ASSERTION_LIVENESS,
            successAssertionBond: SUCCESS_ASSERTION_BOND,
            successOracleSpecHash: listing.oracleConfig.oracleSpecHash,
            successAssertionPolicyHash: listing.oracleConfig.assertionPolicyHash,
            spendPolicy: budgetSpendPolicy
        });
    }

    function _riskModuleInitConfig(
        address budgetStakeLedger_,
        address goalFlow_,
        address underwriterSlasherRouter_,
        uint32 budgetSlashPpm_
    ) internal pure returns (BudgetStackTypes.RiskModuleInitConfig memory config) {
        config = BudgetStackTypes.RiskModuleInitConfig({
            budgetStakeLedger: budgetStakeLedger_,
            goalFlow: goalFlow_,
            underwriterSlasherRouter: underwriterSlasherRouter_,
            budgetSlashPpm: budgetSlashPpm_
        });
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

contract BudgetStackDeployerSharedStrategyTest is Test, SpendPolicyTestUtils, BudgetStackDeployerOpenPresetHelpers {
    BudgetStackDeployer internal deployer;
    BudgetStackDeploymentLibMockToken internal goalToken;
    BudgetStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedgerA;
    BudgetStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedgerB;
    PremiumEscrow internal premiumEscrowImplementation;
    BudgetStackDeploymentLibMockGoalFlow internal goalFlow;
    MockUnderwriterSlasherRouter internal underwriterSlasherRouter;

    function setUp() public {
        deployer = _deployBudgetTcrDeployer();
        premiumEscrowImplementation = new PremiumEscrow();
        underwriterSlasherRouter = new MockUnderwriterSlasherRouter(address(this), address(0));
        _initializeOpenBudgetTcrDeployer(deployer, address(this), address(premiumEscrowImplementation));

        goalToken = new BudgetStackDeploymentLibMockToken("Goal", "GOAL");
        budgetStakeLedgerA = new BudgetStackDeploymentLibMockBudgetStakeLedger();
        budgetStakeLedgerB = new BudgetStackDeploymentLibMockBudgetStakeLedger();
        goalFlow = new BudgetStackDeploymentLibMockGoalFlow(address(goalToken));
    }

    function test_registerChildFlowRecipient_revertsWhenSharedStrategyNotPrepared() public {
        vm.expectRevert(BudgetStackDeployer.SHARED_BUDGET_STRATEGY_NOT_DEPLOYED.selector);
        deployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_initialize_revertsOnSecondCall() public {
        address initialBudgetController = deployer.controller();
        address initialPremiumEscrowImplementation = deployer.stackModuleConfig().premiumEscrowImplementation;
        address nextPremiumEscrowImplementation = address(new PremiumEscrow());

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        _initializeOpenBudgetTcrDeployer(deployer, makeAddr("next-budget-tcr"), nextPremiumEscrowImplementation);

        assertEq(deployer.controller(), initialBudgetController);
        assertEq(deployer.stackModuleConfig().premiumEscrowImplementation, initialPremiumEscrowImplementation);
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
        BudgetStackDeployer implementation = new BudgetStackDeployer(
            address(new BudgetTreasury()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        implementation.initializeWithConfig(address(this), _openStackModuleConfig(premiumEscrowImplementationAddress));
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
        BudgetStackDeployer guardedDeployer = _deployBudgetTcrDeployer();
        _initializeOpenBudgetTcrDeployer(guardedDeployer, makeAddr("budget-tcr"), address(premiumEscrowImplementation));

        vm.expectRevert(IBudgetStackRuntimeDeployer.ONLY_CONTROLLER.selector);
        guardedDeployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_registerChildFlowRecipient_registersRecipientAndRejectsDuplicateFlow() public {
        BudgetStackTypes.PreparationResult memory prepared =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(address(this), address(goalToken), prepared.strategy);

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
        BudgetStackTypes.PreparationResult memory prepared =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        address otherStrategy = makeAddr("other-strategy");
        BudgetStackDeploymentLibMockChildFlow childFlow =
            new BudgetStackDeploymentLibMockChildFlow(address(this), address(goalToken), otherStrategy);

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
        BudgetStackTypes.PreparationResult memory prepared =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        BudgetStackDeploymentLibNoStrategyChildFlow childFlow = new BudgetStackDeploymentLibNoStrategyChildFlow();

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
        BudgetStackTypes.PreparationResult memory firstPreparation =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertTrue(firstPreparation.budgetTreasury != address(0));
        assertEq(firstPreparation.strategy, deployer.sharedBudgetFlowStrategy());
        assertEq(
            address(IBudgetFlowRouterStrategy(deployer.sharedBudgetFlowStrategy()).budgetStakeLedger()),
            address(budgetStakeLedgerA)
        );
        assertTrue(firstPreparation.premiumEscrow != address(0));
        assertNotEq(firstPreparation.premiumEscrow, address(premiumEscrowImplementation));
        assertTrue(firstPreparation.allocationMechanism != address(0));
        assertEq(firstPreparation.childFlowRecipientAdmin, firstPreparation.allocationMechanism);

        BudgetStackTypes.PreparationResult memory secondPreparation =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertEq(secondPreparation.strategy, firstPreparation.strategy);
        assertNotEq(secondPreparation.budgetTreasury, firstPreparation.budgetTreasury);
        assertTrue(secondPreparation.premiumEscrow != address(0));
        assertNotEq(secondPreparation.premiumEscrow, address(premiumEscrowImplementation));
        assertNotEq(secondPreparation.premiumEscrow, firstPreparation.premiumEscrow);
        assertNotEq(secondPreparation.allocationMechanism, firstPreparation.allocationMechanism);
        assertEq(secondPreparation.childFlowRecipientAdmin, secondPreparation.allocationMechanism);

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetStackDeployer.BUDGET_STAKE_LEDGER_MISMATCH.selector,
                address(budgetStakeLedgerA),
                address(budgetStakeLedgerB)
            )
        );
        deployer.prepareBudgetStack(address(budgetStakeLedgerB), address(goalFlow));
    }

    function test_prepareBudgetStack_initializesClonedStrategyAndLocksStrategyInitializer() public {
        BudgetStackTypes.PreparationResult memory prepared =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        BudgetFlowRouterStrategy strategy = BudgetFlowRouterStrategy(prepared.strategy);
        assertEq(address(strategy.budgetStakeLedger()), address(budgetStakeLedgerA));
        assertEq(strategy.registrar(), address(deployer));
        assertNotEq(prepared.strategy, deployer.budgetFlowRouterStrategyImplementation());

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        strategy.initialize(address(budgetStakeLedgerB), address(this));
    }

    function test_prepareBudgetStack_revertsWhenBudgetStakeLedgerIsZeroWithoutMutatingSharedState() public {
        vm.expectRevert(IBudgetStackRuntimeDeployer.ADDRESS_ZERO.selector);
        deployer.prepareBudgetStack(address(0), address(goalFlow));

        assertEq(deployer.sharedBudgetFlowStrategy(), address(0));
    }

    function test_prepareBudgetStack_revertsWhenGoalFlowIsZeroWithoutMutatingSharedState() public {
        vm.expectRevert(IBudgetStackRuntimeDeployer.ADDRESS_ZERO.selector);
        deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(0));

        assertEq(deployer.sharedBudgetFlowStrategy(), address(0));
    }

    function test_prepareBudgetStack_preparesWithoutUnderwriterRouterInput() public {
        BudgetStackTypes.PreparationResult memory prepared =
            deployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertTrue(prepared.strategy != address(0));
        assertTrue(prepared.budgetTreasury != address(0));
    }

    function test_initializeWithConfig_nonzeroPremiumImplementation_usesFixedStrategySafeRecipientAdminAndClonedPremiumEscrow() public {
        BudgetStackDeployer managedDeployer = _deployBudgetTcrDeployer();
        BudgetStackDeploymentLibFixedStrategyMock fixedStrategy = new BudgetStackDeploymentLibFixedStrategyMock();
        BudgetTCRChildFlowStrategyFactoryMock strategyFactory =
            new BudgetTCRChildFlowStrategyFactoryMock(address(fixedStrategy));
        PremiumEscrow configuredPremiumEscrow = new PremiumEscrow();
        address safe = makeAddr("safe");
        BudgetStackTypes.StackModuleConfig memory config = BudgetStackTypes.StackModuleConfig({
            childFlowStrategyMode: BudgetStackTypes.ChildFlowStrategyMode.Factory,
            childFlowStrategyTarget: address(strategyFactory),
            mechanismLayerMode: BudgetStackTypes.MechanismLayerMode.None,
            childFlowRecipientAdmin: safe,
            premiumEscrowImplementation: address(configuredPremiumEscrow)
        });

        managedDeployer.initializeWithConfig(address(this), config);

        BudgetStackTypes.StackModuleConfig memory storedConfig = managedDeployer.stackModuleConfig();
        assertEq(uint8(storedConfig.childFlowStrategyMode), uint8(config.childFlowStrategyMode));
        assertEq(storedConfig.childFlowStrategyTarget, address(strategyFactory));
        assertEq(uint8(storedConfig.mechanismLayerMode), uint8(config.mechanismLayerMode));
        assertEq(storedConfig.childFlowRecipientAdmin, safe);
        assertEq(storedConfig.premiumEscrowImplementation, address(configuredPremiumEscrow));
        BudgetStackTypes.PreparationResult memory prepared =
            managedDeployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertEq(prepared.strategy, address(fixedStrategy));
        assertTrue(prepared.budgetTreasury != address(0));
        assertTrue(prepared.premiumEscrow != address(0));
        assertNotEq(prepared.premiumEscrow, address(configuredPremiumEscrow));
        assertEq(prepared.childFlowRecipientAdmin, safe);
        assertEq(prepared.allocationMechanism, address(0));
        assertEq(managedDeployer.sharedBudgetFlowStrategy(), address(0));
        assertEq(managedDeployer.initialMechanismFactories().length, 0);

        managedDeployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_initializeWithConfig_zeroPremiumImplementation_returnsZeroEscrow() public {
        BudgetStackDeployer managedDeployer = _deployBudgetTcrDeployer();
        BudgetStackDeploymentLibFixedStrategyMock fixedStrategy = new BudgetStackDeploymentLibFixedStrategyMock();
        BudgetTCRChildFlowStrategyFactoryMock strategyFactory =
            new BudgetTCRChildFlowStrategyFactoryMock(address(fixedStrategy));
        address safe = makeAddr("safe");
        BudgetStackTypes.StackModuleConfig memory config =
            _fixedStrategyNoPremiumStackModuleConfig(address(strategyFactory), safe);

        managedDeployer.initializeWithConfig(address(this), config);

        BudgetStackTypes.StackModuleConfig memory storedConfig = managedDeployer.stackModuleConfig();
        assertEq(storedConfig.premiumEscrowImplementation, address(0));

        BudgetStackTypes.PreparationResult memory prepared =
            managedDeployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertEq(prepared.strategy, address(fixedStrategy));
        assertTrue(prepared.budgetTreasury != address(0));
        assertEq(prepared.premiumEscrow, address(0));
        assertEq(prepared.childFlowRecipientAdmin, safe);
        assertEq(prepared.allocationMechanism, address(0));
        assertEq(managedDeployer.sharedBudgetFlowStrategy(), address(0));
        assertEq(managedDeployer.initialMechanismFactories().length, 0);
    }

    function test_initializeWithConfig_acceptsExplicitPremiumImplementationOnNoPremiumHelperConfig() public {
        BudgetStackDeployer managedDeployer = _deployBudgetTcrDeployer();
        BudgetStackDeploymentLibFixedStrategyMock fixedStrategy = new BudgetStackDeploymentLibFixedStrategyMock();
        BudgetTCRChildFlowStrategyFactoryMock strategyFactory =
            new BudgetTCRChildFlowStrategyFactoryMock(address(fixedStrategy));
        PremiumEscrow configuredPremiumEscrow = new PremiumEscrow();
        BudgetStackTypes.StackModuleConfig memory config =
            _fixedStrategyNoPremiumStackModuleConfig(address(strategyFactory), makeAddr("safe"));
        config.premiumEscrowImplementation = address(configuredPremiumEscrow);

        managedDeployer.initializeWithConfig(address(this), config);

        assertEq(managedDeployer.stackModuleConfig().premiumEscrowImplementation, address(configuredPremiumEscrow));
    }

    function test_initializeWithConfig_zeroPremiumImplementation_disablesEscrowPreparation() public {
        BudgetStackDeployer managedDeployer = _deployBudgetTcrDeployer();
        BudgetStackDeploymentLibFixedStrategyMock fixedStrategy = new BudgetStackDeploymentLibFixedStrategyMock();
        BudgetTCRChildFlowStrategyFactoryMock strategyFactory =
            new BudgetTCRChildFlowStrategyFactoryMock(address(fixedStrategy));
        BudgetStackTypes.StackModuleConfig memory config =
            _fixedStrategyNoPremiumStackModuleConfig(address(strategyFactory), makeAddr("safe"));
        managedDeployer.initializeWithConfig(address(this), config);

        BudgetStackTypes.PreparationResult memory prepared =
            managedDeployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertEq(prepared.premiumEscrow, address(0));
    }

    function test_initializeWithConfig_strategyFactoryHook_preparesManagedChildStrategy() public {
        BudgetStackDeployer managedDeployer = _deployBudgetTcrDeployer();
        BudgetStackDeploymentLibFixedStrategyMock fixedStrategy = new BudgetStackDeploymentLibFixedStrategyMock();
        BudgetTCRChildFlowStrategyFactoryMock strategyFactory =
            new BudgetTCRChildFlowStrategyFactoryMock(address(fixedStrategy));
        address safe = makeAddr("safe");
        BudgetStackTypes.StackModuleConfig memory config =
            _fixedStrategyNoPremiumStackModuleConfig(address(strategyFactory), safe);
        config.childFlowStrategyMode = BudgetStackTypes.ChildFlowStrategyMode.Factory;

        managedDeployer.initializeWithConfig(address(this), config);

        BudgetStackTypes.PreparationResult memory prepared =
            managedDeployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));

        assertEq(prepared.strategy, address(fixedStrategy));
        assertEq(prepared.premiumEscrow, address(0));
        assertEq(prepared.childFlowRecipientAdmin, safe);
        assertEq(prepared.allocationMechanism, address(0));
        assertEq(strategyFactory.lastBudgetTreasury(), prepared.budgetTreasury);
        assertEq(strategyFactory.lastBudgetStakeLedger(), address(budgetStakeLedgerA));
        assertEq(strategyFactory.lastGoalFlow(), address(goalFlow));
        assertEq(strategyFactory.lastRegistrar(), address(managedDeployer));
    }

    function test_initialize_preservesOpenPresetStackModuleConfig() public {
        BudgetStackTypes.StackModuleConfig memory config = deployer.stackModuleConfig();

        assertEq(
            uint8(config.childFlowStrategyMode),
            uint8(BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter)
        );
        assertEq(config.childFlowStrategyTarget, address(0));
        assertEq(
            uint8(config.mechanismLayerMode), uint8(BudgetStackTypes.MechanismLayerMode.AllocationMechanismTCR)
        );
        assertEq(config.childFlowRecipientAdmin, address(0));
        assertEq(config.premiumEscrowImplementation, address(premiumEscrowImplementation));
    }

    function test_initializeWithConfig_factoryHook_revertsWhenFactoryReturnsInvalidStrategy() public {
        BudgetStackDeployer managedDeployer = _deployBudgetTcrDeployer();
        BudgetTCRChildFlowStrategyFactoryMock strategyFactory = new BudgetTCRChildFlowStrategyFactoryMock(address(0));
        BudgetStackTypes.StackModuleConfig memory config =
            _fixedStrategyNoPremiumStackModuleConfig(address(strategyFactory), makeAddr("safe"));
        config.childFlowStrategyMode = BudgetStackTypes.ChildFlowStrategyMode.Factory;

        managedDeployer.initializeWithConfig(address(this), config);

        vm.expectRevert(abi.encodeWithSelector(BudgetStackDeployer.INVALID_CHILD_FLOW_STRATEGY.selector, address(0)));
        managedDeployer.prepareBudgetStack(address(budgetStakeLedgerA), address(goalFlow));
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

        vm.expectRevert(IBudgetStackRuntimeDeployer.ADDRESS_ZERO.selector);
        new BudgetStackDeployer(
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

        vm.expectRevert(abi.encodeWithSelector(BudgetStackDeployer.IMPLEMENTATION_HAS_NO_CODE.selector, noCode));
        new BudgetStackDeployer(
            budgetTreasuryImplementation,
            roundFactory,
            roundFactory,
            allocationMechanismTcrImplementation,
            allocationMechanismArbitratorImplementation,
            noCode
        );
    }

    function _deployBudgetTcrDeployer() internal returns (BudgetStackDeployer) {
        address roundFactory = address(
            new RoundFactory(
                address(new RoundSubmissionTCR()),
                address(new RoundPrizeVault()),
                address(new PrizePoolSubmissionDepositStrategy()),
                address(new ERC20VotesArbitrator())
            )
        );
        BudgetStackDeployer implementation = new BudgetStackDeployer(
            address(new BudgetTreasury()),
            roundFactory,
            roundFactory,
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
        return BudgetStackDeployer(Clones.clone(address(implementation)));
    }

    function _fixedStrategyNoPremiumStackModuleConfig(address strategy, address recipientAdmin)
        internal
        pure
        returns (BudgetStackTypes.StackModuleConfig memory config)
    {
        config = BudgetTCRConfigHelpers.fixedNoPremiumStackModuleConfig(strategy, recipientAdmin);
    }
}
