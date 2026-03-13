// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {BudgetStackDeployer} from "src/goals/BudgetStackDeployer.sol";
import {BudgetTopologyRegistryLib} from "src/goals/library/BudgetTopologyRegistryLib.sol";
import {BudgetTCRStackActions} from "src/tcr/library/BudgetTCRStackActions.sol";
import {BudgetTCRStorageV1} from "src/tcr/storage/BudgetTCRStorageV1.sol";
import {GeneralizedTCRStorageV1} from "src/tcr/storage/GeneralizedTCRStorageV1.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IBudgetStackChildFlowStrategyFactory} from "src/interfaces/IBudgetStackChildFlowStrategyFactory.sol";
import {
    BudgetTCRTestSuperToken,
    BudgetTCRGoalFlowHarness,
    BudgetTCRGoalTreasuryHarness,
    BudgetTCRStakeLedgerHarness
} from "test/helpers/BudgetTCRSystemHarnesses.sol";
import {BudgetTCRConfigHelpers} from "test/helpers/BudgetTCRConfigHelpers.sol";
import {MockUnderwriterSlasherRouter} from "test/mocks/MockUnderwriterSlasherRouter.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract ManagedBudgetStackFixedStrategy is IAllocationStrategy {
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
        return "managed";
    }
}

contract ManagedBudgetStackStrategyFactoryMock is IBudgetStackChildFlowStrategyFactory {
    address public immutable strategy;

    constructor(address strategy_) {
        strategy = strategy_;
    }

    function prepareChildFlowStrategy(
        address,
        address,
        address,
        address
    ) external view returns (address preparedStrategy) {
        preparedStrategy = strategy;
    }
}

contract ManagedBudgetStackDiscoveryEmitterMock {
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

contract ManagedBudgetStackActionsHarness is BudgetTCRStorageV1, GeneralizedTCRStorageV1 {
    function configure(
        address goalFlow_,
        address goalTreasury_,
        address stackDeployer_,
        address discoveryEmitter_,
        address underwriterSlasherRouter_,
        uint32 budgetPremiumPpm_,
        uint32 budgetSlashPpm_,
        address budgetSuccessResolver_,
        address budgetSpendPolicy_,
        IBudgetTCR.OracleValidationBounds calldata oracleValidationBounds_
    ) external {
        goalFlow = IFlow(goalFlow_);
        goalTreasury = IGoalTreasury(goalTreasury_);
        stackDeployer = stackDeployer_;
        discoveryEmitter = discoveryEmitter_;
        underwriterSlasherRouter = underwriterSlasherRouter_;
        budgetPremiumPpm = budgetPremiumPpm_;
        budgetSlashPpm = budgetSlashPpm_;
        budgetSuccessResolver = budgetSuccessResolver_;
        _budgetSpendPolicy = budgetSpendPolicy_;
        oracleValidationBounds = oracleValidationBounds_;
    }

    function deploy(bytes32 itemID, bytes calldata item) external {
        BudgetTCRStackActions.deployBudgetStack(
            _budgetDeployments, _itemIdByBudgetTreasury, _itemIdByChildFlow, itemID, item
        );
    }

    function deployment(bytes32 itemID)
        external
        view
        returns (BudgetTopologyRegistryLib.BudgetDeployment memory budgetDeployment)
    {
        budgetDeployment = _budgetDeployments[itemID];
    }

    function itemIdForBudgetTreasury(address budgetTreasury_) external view returns (bytes32 itemID) {
        itemID = _itemIdByBudgetTreasury[budgetTreasury_];
    }

    function itemIdForChildFlow(address childFlow_) external view returns (bytes32 itemID) {
        itemID = _itemIdByChildFlow[childFlow_];
    }
}

contract BudgetTCRManagedStackDeploymentsTest is Test, SpendPolicyTestUtils {
    uint32 internal constant MANAGED_BUDGET_PREMIUM_PPM = 0;
    uint32 internal constant MANAGED_BUDGET_SLASH_PPM = 0;

    ManagedBudgetStackActionsHarness internal harness;
    BudgetStackDeployer internal deployer;
    ManagedBudgetStackFixedStrategy internal fixedStrategy;
    ManagedBudgetStackStrategyFactoryMock internal fixedStrategyFactory;
    BudgetTCRTestSuperToken internal superToken;
    BudgetTCRGoalFlowHarness internal goalFlow;
    BudgetTCRGoalTreasuryHarness internal goalTreasury;
    BudgetTCRStakeLedgerHarness internal budgetStakeLedger;
    ManagedBudgetStackDiscoveryEmitterMock internal defaultDiscoveryEmitter;
    MockUnderwriterSlasherRouter internal underwriterSlasherRouter;
    address internal budgetSpendPolicy;

    address internal safe = makeAddr("safe");
    address internal managerRewardPool = makeAddr("managerRewardPool");
    address internal budgetSuccessResolver = makeAddr("budget-success-resolver");

    function setUp() public {
        harness = new ManagedBudgetStackActionsHarness();
        fixedStrategy = new ManagedBudgetStackFixedStrategy();
        fixedStrategyFactory = new ManagedBudgetStackStrategyFactoryMock(address(fixedStrategy));
        superToken = new BudgetTCRTestSuperToken();
        goalFlow = new BudgetTCRGoalFlowHarness(
            address(this), address(harness), managerRewardPool, ISuperToken(address(superToken))
        );
        goalTreasury = new BudgetTCRGoalTreasuryHarness(uint64(block.timestamp + 120 days));
        budgetStakeLedger = new BudgetTCRStakeLedgerHarness();
        defaultDiscoveryEmitter = new ManagedBudgetStackDiscoveryEmitterMock();
        underwriterSlasherRouter = new MockUnderwriterSlasherRouter(address(this), address(0));
        budgetSpendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));

        goalTreasury.setBudgetStakeLedger(address(budgetStakeLedger));
        goalTreasury.setFlow(address(goalFlow));

        deployer = _deployBudgetTcrDeployer();
        deployer.initializeWithConfig(
            address(harness), BudgetTCRConfigHelpers.fixedNoPremiumStackModuleConfig(address(fixedStrategyFactory), safe)
        );

        harness.configure(
            address(goalFlow),
            address(goalTreasury),
            address(deployer),
            address(defaultDiscoveryEmitter),
            address(underwriterSlasherRouter),
            MANAGED_BUDGET_PREMIUM_PPM,
            MANAGED_BUDGET_SLASH_PPM,
            budgetSuccessResolver,
            budgetSpendPolicy,
            IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        );
    }

    function test_managedStackDeploy_revertsWhenMechanismLayerDisabled() public {
        bytes32 itemID = keccak256("managed-budget");
        vm.expectRevert(IBudgetTCR.PREPARED_ALLOCATION_MECHANISM_REQUIRED.selector);
        harness.deploy(itemID, abi.encode(_defaultListing()));
    }

    function test_managedStackDeploy_revertsWithoutDiscoveryOrTopologySideEffects_whenMechanismLayerDisabled() public {
        ManagedBudgetStackDiscoveryEmitterMock discoveryEmitter = new ManagedBudgetStackDiscoveryEmitterMock();
        BudgetStackDeployer deployerWithEmitter = _deployBudgetTcrDeployer();
        deployerWithEmitter.initializeWithConfig(
            address(harness), BudgetTCRConfigHelpers.fixedNoPremiumStackModuleConfig(address(fixedStrategyFactory), safe)
        );

        harness.configure(
            address(goalFlow),
            address(goalTreasury),
            address(deployerWithEmitter),
            address(discoveryEmitter),
            address(underwriterSlasherRouter),
            MANAGED_BUDGET_PREMIUM_PPM,
            MANAGED_BUDGET_SLASH_PPM,
            budgetSuccessResolver,
            budgetSpendPolicy,
            IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        );

        bytes32 itemID = keccak256("managed-budget-with-emitter");
        vm.expectRevert(IBudgetTCR.PREPARED_ALLOCATION_MECHANISM_REQUIRED.selector);
        harness.deploy(itemID, abi.encode(_defaultListing()));

        BudgetTopologyRegistryLib.BudgetDeployment memory deployment = harness.deployment(itemID);
        assertFalse(deployment.active);
        assertEq(deployment.strategy, address(0));
        assertEq(deployment.childFlow, address(0));
        assertEq(deployment.budgetTreasury, address(0));
        assertEq(deployment.premiumEscrow, address(0));
        assertEq(harness.itemIdForBudgetTreasury(address(0)), bytes32(0));
        assertEq(harness.itemIdForChildFlow(address(0)), bytes32(0));
        assertEq(budgetStakeLedger.budgetForRecipient(itemID), address(0));

        assertEq(discoveryEmitter.lastStackItemId(), bytes32(0));
        assertEq(discoveryEmitter.lastStackChildFlow(), address(0));
        assertEq(discoveryEmitter.lastStackBudgetTreasury(), address(0));
        assertEq(discoveryEmitter.lastStackPremiumEscrow(), address(0));
        assertEq(discoveryEmitter.lastStackStrategy(), address(0));
        assertEq(discoveryEmitter.lastMechanismItemId(), bytes32(0));
        assertEq(discoveryEmitter.lastMechanism(), address(0));
        assertEq(discoveryEmitter.lastMechanismArbitrator(), address(0));
        assertEq(discoveryEmitter.lastRoundFactory(), address(0));
    }

    function test_managedStackDeploy_revertsBeforePremiumValidation_whenMechanismLayerDisabled() public {
        harness.configure(
            address(goalFlow),
            address(goalTreasury),
            address(deployer),
            address(defaultDiscoveryEmitter),
            address(underwriterSlasherRouter),
            50_000,
            40_000,
            budgetSuccessResolver,
            budgetSpendPolicy,
            IBudgetTCR.OracleValidationBounds({liveness: 1 days, bondAmount: 10e18})
        );

        vm.expectRevert(IBudgetTCR.PREPARED_ALLOCATION_MECHANISM_REQUIRED.selector);
        harness.deploy(keccak256("managed-budget-nonzero-rates"), abi.encode(_defaultListing()));
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing.metadata = FlowTypes.RecipientMetadata({
            title: "Managed Budget",
            description: "Managed budget description",
            image: "ipfs://managed-image",
            tagline: "managed",
            url: "https://example.com/managed"
        });
        listing.fundingDeadline = uint64(block.timestamp + 7 days);
        listing.executionDuration = uint64(14 days);
        listing.activationThreshold = 100e18;
        listing.runwayCap = 500e18;
        listing.oracleConfig = IBudgetTCR.OracleConfig({
            oracleSpecHash: keccak256("managed-oracle-spec"), assertionPolicyHash: keccak256("managed-oracle-policy")
        });
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
}
