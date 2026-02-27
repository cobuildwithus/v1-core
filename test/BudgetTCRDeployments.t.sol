// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import { BudgetTCRStackDeploymentLib } from "src/tcr/library/BudgetTCRStackDeploymentLib.sol";
import { BudgetTCRDeployer } from "src/tcr/BudgetTCRDeployer.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { IBudgetTCRStackDeployer } from "src/tcr/interfaces/IBudgetTCRStackDeployer.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { StakeVault } from "src/goals/StakeVault.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IBudgetFlowRouterStrategy } from "src/interfaces/IBudgetFlowRouterStrategy.sol";
import { IBudgetStakeLedger } from "src/interfaces/IBudgetStakeLedger.sol";
import { BudgetFlowRouterStrategy } from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

contract BudgetTCRStackDeploymentLibHarness {
    function deployTreasuryClone(address treasuryImplementation) external returns (address treasury) {
        treasury = Clones.clone(treasuryImplementation);
    }

    function prepareBudgetStack(
        address treasuryAnchor,
        IERC20 goalToken,
        IERC20 cobuildToken,
        IJBRulesets goalRulesets,
        uint256 goalRevnetId,
        uint8 paymentTokenDecimals,
        address strategy
    ) external returns (BudgetTCRStackDeploymentLib.PreparationResult memory result) {
        result = BudgetTCRStackDeploymentLib.prepareBudgetStack(
            treasuryAnchor,
            goalToken,
            cobuildToken,
            goalRulesets,
            goalRevnetId,
            paymentTokenDecimals,
            strategy
        );
    }

    function deployBudgetTreasury(
        address budgetTCR,
        address stakeVault,
        address childFlow,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external returns (address budgetTreasury) {
        budgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            budgetTCR,
            stakeVault,
            childFlow,
            listing,
            successResolver,
            successAssertionLiveness,
            successAssertionBond
        );
    }
}

contract BudgetTCRStackDeploymentLibMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }
}

contract BudgetTCRStackDeploymentLibMockParentFlow {
    function getMemberFlowRate(address) external pure returns (int96) {
        return 0;
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

    function strategies() external view returns (IAllocationStrategy[] memory s) {
        s = new IAllocationStrategy[](1);
        s[0] = IAllocationStrategy(_strategy);
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

contract BudgetTCRStackDeploymentLibMockStakeVault {
    address internal immutable _goalTreasury;

    constructor(address goalTreasury_) {
        _goalTreasury = goalTreasury_;
    }

    function goalTreasury() external view returns (address) {
        return _goalTreasury;
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

contract BudgetTCRStackDeploymentLibNoStrategyChildFlow {
    function strategies() external pure returns (IAllocationStrategy[] memory s) {
        s = new IAllocationStrategy[](0);
    }
}

contract BudgetTCRStackDeploymentLibTest is Test {
    BudgetTCRStackDeploymentLibHarness internal harness;
    BudgetTCRStackDeploymentLibMockToken internal goalToken;
    BudgetTCRStackDeploymentLibMockToken internal cobuildToken;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedger;
    BudgetFlowRouterStrategy internal sharedStrategy;
    BudgetTreasury internal budgetTreasuryImplementation;
    uint64 internal constant SUCCESS_ASSERTION_LIVENESS = 1 days;
    uint256 internal constant SUCCESS_ASSERTION_BOND = 10e18;

    address internal budgetTCR = makeAddr("budgetTCR");
    bytes32 internal recipientId = bytes32(uint256(1234));

    function setUp() public {
        harness = new BudgetTCRStackDeploymentLibHarness();
        goalToken = new BudgetTCRStackDeploymentLibMockToken("Goal", "GOAL");
        cobuildToken = new BudgetTCRStackDeploymentLibMockToken("Cobuild", "COB");
        budgetStakeLedger = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
        sharedStrategy = new BudgetFlowRouterStrategy(IBudgetStakeLedger(address(budgetStakeLedger)), address(this));
        budgetTreasuryImplementation = new BudgetTreasury();
    }

    function test_prepareAndDeploy_linksTreasuryAnchor_andSharedStrategyUsesFlowRecipientRegistration() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            treasuryAnchor,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(sharedStrategy)
        );

        assertTrue(prepared.stakeVault != address(0));
        assertTrue(prepared.strategy != address(0));
        assertEq(StakeVault(prepared.stakeVault).goalTreasury(), treasuryAnchor);
        assertEq(prepared.strategy, address(sharedStrategy));

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            prepared.strategy
        );
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        address budgetTreasury = _deployBudgetTreasury(
            budgetTCR, prepared.stakeVault, address(childFlow), listing, budgetTCR
        );

        assertEq(budgetTreasury, treasuryAnchor);
        assertEq(childFlow.recipientAdmin(), budgetTCR);
        assertEq(BudgetTreasury(budgetTreasury).successAssertionLiveness(), SUCCESS_ASSERTION_LIVENESS);
        assertEq(BudgetTreasury(budgetTreasury).successAssertionBond(), SUCCESS_ASSERTION_BOND);

        BudgetFlowRouterStrategy strategy = BudgetFlowRouterStrategy(prepared.strategy);
        address allocator = makeAddr("allocator");
        uint256 allocatorKey = uint256(uint160(allocator));

        // No registered child flow for strategy context yet.
        assertEq(strategy.currentWeight(allocatorKey), 0);
        assertEq(strategy.accountAllocationWeight(allocator), 0);
        assertFalse(strategy.canAllocate(allocatorKey, allocator));
        assertFalse(strategy.canAccountAllocate(allocator));

        strategy.registerFlowRecipient(address(childFlow), recipientId);
        budgetStakeLedger.setBudget(recipientId, budgetTreasury);
        budgetStakeLedger.setAllocatedStake(allocator, budgetTreasury, 42e18);

        assertEq(strategy.currentWeightForFlow(address(childFlow), allocatorKey), 42e18);
        assertEq(strategy.accountAllocationWeightForFlow(address(childFlow), allocator), 42e18);
        assertTrue(strategy.canAllocateForFlow(address(childFlow), allocatorKey, allocator));
        assertTrue(strategy.canAccountAllocateForFlow(address(childFlow), allocator));
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenCallerIsNotRegistrar() public {
        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            address(sharedStrategy)
        );
        address notRegistrar = makeAddr("not-registrar");

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetFlowRouterStrategy.ONLY_REGISTRAR.selector, notRegistrar, address(this)
            )
        );
        vm.prank(notRegistrar);
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_sharedStrategy_registerFlowRecipient_revertsWhenFlowHasDifferentStrategy() public {
        address otherStrategy = makeAddr("other-strategy");
        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            otherStrategy
        );

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
        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            address(sharedStrategy)
        );

        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);

        vm.expectRevert(
            abi.encodeWithSelector(IBudgetFlowRouterStrategy.FLOW_ALREADY_REGISTERED.selector, address(childFlow))
        );
        sharedStrategy.registerFlowRecipient(address(childFlow), recipientId);
    }

    function test_deployBudgetTreasury_revertsWhenStakeVaultAnchorsNonContractAddress() public {
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            address(0xCAFE),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(sharedStrategy)
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            prepared.strategy
        );

        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRStackDeploymentLib.INVALID_TREASURY_ANCHOR.selector, address(0xCAFE))
        );
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), _defaultListing(), budgetTCR);
    }

    function test_deployBudgetTreasury_revertsWhenStakeVaultAnchorsZeroAddress() public {
        BudgetTCRStackDeploymentLibMockStakeVault stakeVault = new BudgetTCRStackDeploymentLibMockStakeVault(address(0));
        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            address(sharedStrategy)
        );

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRStackDeploymentLib.INVALID_TREASURY_ANCHOR.selector, address(0)));
        _deployBudgetTreasury(budgetTCR, address(stakeVault), address(childFlow), _defaultListing(), budgetTCR);
    }

    function test_deployBudgetTreasury_revertsWhenStakeVaultAnchorsNonTreasuryContract() public {
        BudgetTCRStackDeploymentLibPermissiveFallbackTreasury invalidTreasury =
            new BudgetTCRStackDeploymentLibPermissiveFallbackTreasury();

        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            address(invalidTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(sharedStrategy)
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            prepared.strategy
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRStackDeploymentLib.INVALID_TREASURY_CONFIGURATION.selector, address(invalidTreasury)
            )
        );
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), _defaultListing(), budgetTCR);
    }

    function test_deployBudgetTreasury_revertsWhenTreasuryCloneAlreadyInitialized() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            treasuryAnchor,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(sharedStrategy)
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            budgetTCR,
            address(goalToken),
            prepared.strategy
        );
        childFlow.setFlowOperator(treasuryAnchor);
        childFlow.setSweeper(treasuryAnchor);
        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), listing, budgetTCR);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), listing, budgetTCR);
    }

    function test_deployBudgetTreasury_revertsOnZeroCriticalAddresses() public {
        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(address(0), makeAddr("vault"), makeAddr("flow"), _defaultListing(), budgetTCR);

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(budgetTCR, address(0), makeAddr("flow"), _defaultListing(), budgetTCR);

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(budgetTCR, makeAddr("vault"), address(0), _defaultListing(), budgetTCR);

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(budgetTCR, makeAddr("vault"), makeAddr("flow"), _defaultListing(), address(0));
    }

    function test_prepareBudgetStack_revertsOnZeroCriticalAddresses() public {
        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        harness.prepareBudgetStack(
            address(0),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(sharedStrategy)
        );

        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRStackDeploymentLib.INVALID_STRATEGY.selector, address(0))
        );
        harness.prepareBudgetStack(
            makeAddr("predicted"),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(0)
        );
    }

    function _deployBudgetTreasury(
        address budgetTCR_,
        address stakeVault,
        address childFlow,
        IBudgetTCR.BudgetListing memory listing,
        address successResolver
    ) internal returns (address budgetTreasury) {
        budgetTreasury = harness.deployBudgetTreasury(
            budgetTCR_,
            stakeVault,
            childFlow,
            listing,
            successResolver,
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
            oracleSpecHash: keccak256("oracle-spec"),
            assertionPolicyHash: keccak256("oracle-policy")
        });
    }
}

contract BudgetTCRDeployerSharedStrategyTest is Test {
    BudgetTCRDeployer internal deployer;
    BudgetTCRStackDeploymentLibMockToken internal goalToken;
    BudgetTCRStackDeploymentLibMockToken internal cobuildToken;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedgerA;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedgerB;

    function setUp() public {
        deployer = new BudgetTCRDeployer();
        deployer.initialize(address(this));

        goalToken = new BudgetTCRStackDeploymentLibMockToken("Goal", "GOAL");
        cobuildToken = new BudgetTCRStackDeploymentLibMockToken("Cobuild", "COB");
        budgetStakeLedgerA = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
        budgetStakeLedgerB = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
    }

    function test_registerChildFlowRecipient_revertsWhenSharedStrategyNotPrepared() public {
        vm.expectRevert(BudgetTCRDeployer.SHARED_BUDGET_STRATEGY_NOT_DEPLOYED.selector);
        deployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_registerChildFlowRecipient_revertsWhenCallerIsNotBudgetTCR() public {
        BudgetTCRDeployer guardedDeployer = new BudgetTCRDeployer();
        guardedDeployer.initialize(makeAddr("budget-tcr"));

        vm.expectRevert(IBudgetTCRStackDeployer.ONLY_BUDGET_TCR.selector);
        guardedDeployer.registerChildFlowRecipient(bytes32(uint256(1)), makeAddr("child-flow"));
    }

    function test_registerChildFlowRecipient_registersRecipientAndRejectsDuplicateFlow() public {
        IBudgetTCRStackDeployer.PreparationResult memory prepared = deployer.prepareBudgetStack(
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(budgetStakeLedgerA),
            bytes32(uint256(1))
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            address(this),
            address(goalToken),
            prepared.strategy
        );

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
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(budgetStakeLedgerA),
            bytes32(uint256(1))
        );

        address otherStrategy = makeAddr("other-strategy");
        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(
            address(this),
            address(goalToken),
            otherStrategy
        );

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
        deployer.prepareBudgetStack(
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(budgetStakeLedgerA),
            bytes32(uint256(1))
        );

        BudgetTCRStackDeploymentLibNoStrategyChildFlow childFlow = new BudgetTCRStackDeploymentLibNoStrategyChildFlow();

        vm.expectRevert(
            abi.encodeWithSelector(
                IBudgetFlowRouterStrategy.INVALID_FLOW_STRATEGY_COUNT.selector, address(childFlow), 0
            )
        );
        deployer.registerChildFlowRecipient(bytes32(uint256(100)), address(childFlow));
    }

    function test_prepareBudgetStack_reusesSharedStrategyAndRejectsLedgerMismatch() public {
        IBudgetTCRStackDeployer.PreparationResult memory firstPreparation = deployer.prepareBudgetStack(
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(budgetStakeLedgerA),
            bytes32(uint256(1))
        );

        assertTrue(firstPreparation.stakeVault != address(0));
        assertTrue(firstPreparation.budgetTreasury != address(0));
        assertEq(firstPreparation.strategy, deployer.sharedBudgetFlowStrategy());
        assertEq(deployer.sharedBudgetFlowStrategyLedger(), address(budgetStakeLedgerA));

        IBudgetTCRStackDeployer.PreparationResult memory secondPreparation = deployer.prepareBudgetStack(
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(budgetStakeLedgerA),
            bytes32(uint256(2))
        );

        assertEq(secondPreparation.strategy, firstPreparation.strategy);
        assertNotEq(secondPreparation.stakeVault, firstPreparation.stakeVault);
        assertNotEq(secondPreparation.budgetTreasury, firstPreparation.budgetTreasury);

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRDeployer.BUDGET_STAKE_LEDGER_MISMATCH.selector,
                address(budgetStakeLedgerA),
                address(budgetStakeLedgerB)
            )
        );
        deployer.prepareBudgetStack(
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(budgetStakeLedgerB),
            bytes32(uint256(3))
        );
    }
}
