// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {SingleAllocatorStrategy} from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {ManagedBudgetController} from "src/goals/ManagedBudgetController.sol";
import {ManagedBudgetControllerStackDeployer} from "src/goals/ManagedBudgetControllerStackDeployer.sol";
import {NullPremiumEscrow} from "src/goals/NullPremiumEscrow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IBudgetController} from "src/interfaces/IBudgetController.sol";
import {IBudgetStackTopologyReader} from "src/interfaces/IBudgetStackTopologyReader.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IManagedBudgetController} from "src/interfaces/IManagedBudgetController.sol";
import {IManagedBudgetControllerStackDeployer} from "src/interfaces/IManagedBudgetControllerStackDeployer.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {BudgetTCRStakeLedgerHarness} from "test/helpers/BudgetTCRSystemHarnesses.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";
import {TestableCustomFlow} from "test/harness/TestableCustomFlow.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";
import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";

contract ManagedBudgetControllerTest is FlowTestBase {
    uint32 internal constant BUDGET_PREMIUM_PPM = 50_000;
    uint32 internal constant BUDGET_SLASH_PPM = 40_000;
    uint64 internal constant FUNDING_WINDOW = 7 days;
    uint64 internal constant EXECUTION_DURATION = 30 days;

    address internal safe = makeAddr("safe");
    address internal newSafe = makeAddr("new-safe");
    address internal budgetSuccessResolver = makeAddr("budget-success-resolver");
    address internal underwriterSlasherRouter;

    ManagedBudgetController internal controller;
    ManagedBudgetControllerMockGoalTreasury internal goalTreasury;
    BudgetTCRStakeLedgerHarness internal budgetAllocationLedger;
    ManagedBudgetControllerMockStackDeployer internal stackDeployer;
    ManagedBudgetControllerMockSpendPolicy internal spendPolicy;
    SingleAllocatorStrategy internal goalStrategy;
    TestableCustomFlow internal goalFlow;

    function _useHarnessFlowImplementation() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();

        underwriterSlasherRouter = address(new ManagedBudgetControllerDummyContract());

        ManagedBudgetController controllerImplementation = new ManagedBudgetController();
        controller = ManagedBudgetController(Clones.clone(address(controllerImplementation)));

        goalTreasury = new ManagedBudgetControllerMockGoalTreasury();
        budgetAllocationLedger = new BudgetTCRStakeLedgerHarness();
        stackDeployer = new ManagedBudgetControllerMockStackDeployer();
        spendPolicy = new ManagedBudgetControllerMockSpendPolicy();

        goalStrategy = new SingleAllocatorStrategy(address(goalTreasury), address(controller));
        goalFlow = TestableCustomFlow(
            address(
                _deployFlowWithConfigAndRoles(
                    owner,
                    address(controller),
                    manager,
                    manager,
                    managerRewardPool,
                    address(0),
                    address(0),
                    IAllocationStrategy(address(goalStrategy))
                )
            )
        );
        goalTreasury.setFlow(address(goalFlow));

        controller.initialize(
            IManagedBudgetController.InitConfig({
                authority: safe,
                goalTreasury: address(goalTreasury),
                goalFlow: address(goalFlow),
                budgetAllocationLedger: address(budgetAllocationLedger),
                stackDeployer: address(stackDeployer),
                budgetGatePolicy: address(0),
                budgetSuccessResolver: budgetSuccessResolver,
                budgetSpendPolicy: address(spendPolicy),
                underwriterSlasherRouter: underwriterSlasherRouter,
                successAssertionLiveness: 1 days,
                successAssertionBond: 10e18,
                budgetPremiumPpm: BUDGET_PREMIUM_PPM,
                budgetSlashPpm: BUDGET_SLASH_PPM
            })
        );
    }

    function test_managedGoalCanCreateMultipleBudgets() public {
        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));

        (address childFlowA, address treasuryA) = _createBudget(itemA, "Budget A");
        (address childFlowB, address treasuryB) = _createBudget(itemB, "Budget B");

        assertEq(controller.activeBudgetCount(), 2);
        assertEq(controller.activeBudgetIdAt(0), itemA);
        assertEq(controller.activeBudgetIdAt(1), itemB);

        assertEq(budgetAllocationLedger.budgetForRecipient(itemA), treasuryA);
        assertEq(budgetAllocationLedger.budgetForRecipient(itemB), treasuryB);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyA, bool activeA) =
            controller.budgetStackTopology(itemA);
        assertTrue(activeA);
        assertEq(topologyA.childFlow, childFlowA);
        assertEq(topologyA.budgetTreasury, treasuryA);
        assertTrue(topologyA.premiumEscrow != address(0));
        assertTrue(topologyA.strategy != address(0));

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyB, bool activeB) =
            controller.budgetStackTopology(itemB);
        assertTrue(activeB);
        assertEq(topologyB.childFlow, childFlowB);
        assertEq(topologyB.budgetTreasury, treasuryB);

        FlowTypes.FlowRecipient memory recipientA = goalFlow.getRecipientById(itemA);
        FlowTypes.FlowRecipient memory recipientB = goalFlow.getRecipientById(itemB);
        assertEq(recipientA.recipient, childFlowA);
        assertEq(recipientB.recipient, childFlowB);
        assertFalse(recipientA.isRemoved);
        assertFalse(recipientB.isRemoved);
        assertEq(uint8(recipientA.recipientType), uint8(FlowTypes.RecipientType.FlowContract));
        assertEq(uint8(recipientB.recipientType), uint8(FlowTypes.RecipientType.FlowContract));

        assertEq(IFlow(childFlowA).recipientAdmin(), address(controller));
        assertEq(IFlow(childFlowA).flowOperator(), treasuryA);
        assertEq(IFlow(childFlowA).sweeper(), treasuryA);
        assertEq(IFlow(childFlowB).recipientAdmin(), address(controller));
        assertEq(IFlow(childFlowB).flowOperator(), treasuryB);
        assertEq(IFlow(childFlowB).sweeper(), treasuryB);
    }

    function test_controllerCanUpdateLiveBudgetWeights() public {
        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));
        _createBudget(itemA, "Budget A");
        _createBudget(itemB, "Budget B");

        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = itemA;
        itemIDs[1] = itemB;

        uint32[] memory ppm = new uint32[](2);
        ppm[0] = 400_000;
        ppm[1] = 600_000;

        vm.prank(safe);
        controller.setBudgetWeights(itemIDs, ppm);

        uint256 controllerKey = _controllerAllocationKey();
        assertEq(
            goalFlow.getAllocationCommitment(address(goalStrategy), controllerKey), _allocationCommit(itemIDs, ppm)
        );
        assertEq(
            goalFlow.getAllocWeightPlusOneForTest(address(goalStrategy), controllerKey),
            goalStrategy.VIRTUAL_WEIGHT() + 1
        );
    }

    function test_createBudget_revertsOnZeroItemId() public {
        vm.expectRevert(IManagedBudgetController.INVALID_ITEM_ID.selector);
        vm.prank(safe);
        controller.createBudget(bytes32(0), _defaultBudgetConfig("Budget Zero"));
    }

    function test_setBudgetFlowWeights_revertsWhenCallerIsNotAuthority() public {
        bytes32 itemID = bytes32(uint256(1));
        _createBudget(itemID, "Budget A");

        bytes32[] memory childItemIDs = new bytes32[](1);
        childItemIDs[0] = bytes32(uint256(11));

        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 1_000_000;

        vm.expectRevert(IManagedBudgetController.ONLY_AUTHORITY.selector);
        vm.prank(makeAddr("not-authority"));
        controller.setBudgetFlowWeights(itemID, childItemIDs, ppm);
    }

    function test_setBudgetFlowWeights_revertsWhenBudgetIsInactive() public {
        bytes32 itemID = bytes32(uint256(1));
        (address childFlow, address treasury) = _createBudget(itemID, "Budget A");
        ManagedBudgetControllerMockBudgetTreasury(treasury).setActivatedAt(uint64(block.timestamp));

        vm.prank(safe);
        controller.removeBudget(itemID);

        bytes32[] memory childItemIDs = new bytes32[](1);
        childItemIDs[0] = bytes32(uint256(11));

        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 1_000_000;

        vm.expectRevert(IManagedBudgetController.ITEM_NOT_ACTIVE.selector);
        vm.prank(safe);
        controller.setBudgetFlowWeights(itemID, childItemIDs, ppm);

        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(controller.itemIdForChildFlow(childFlow), itemID);
    }

    function test_safeRotationChangesAuthorityButNotAllocatorIdentity() public {
        bytes32 itemID = bytes32(uint256(1));
        _createBudget(itemID, "Budget A");

        vm.prank(safe);
        controller.transferAuthority(newSafe);

        vm.prank(newSafe);
        controller.acceptAuthority();

        assertEq(controller.authority(), newSafe);
        assertEq(controller.pendingAuthority(), address(0));
        assertEq(goalStrategy.allocator(), address(controller));

        uint256 controllerKey = _controllerAllocationKey();
        assertTrue(goalFlow.canAllocate(controllerKey, address(controller)));
        assertFalse(goalFlow.canAllocate(controllerKey, newSafe));

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 1_000_000;

        vm.prank(newSafe);
        controller.setBudgetWeights(itemIDs, ppm);

        assertEq(
            goalFlow.getAllocationCommitment(address(goalStrategy), controllerKey), _allocationCommit(itemIDs, ppm)
        );
    }

    function test_budgetChildRecipientLifecycle_routesThroughControllerAdmin() public {
        bytes32 budgetItemID = bytes32(uint256(1));
        (address childFlow,) = _createBudget(budgetItemID, "Budget A");
        bytes32 childRecipientId = bytes32(uint256(11));
        address childRecipient = makeAddr("budget-recipient");

        vm.prank(safe);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        TestableCustomFlow(childFlow)
            .addRecipient(childRecipientId, childRecipient, _childRecipientMetadata("Budget Recipient"));

        vm.prank(safe);
        controller.addBudgetFlowRecipient(
            budgetItemID, childRecipientId, childRecipient, _childRecipientMetadata("Budget Recipient")
        );

        FlowTypes.FlowRecipient memory recipient = TestableCustomFlow(childFlow).getRecipientById(childRecipientId);
        assertEq(recipient.recipient, childRecipient);
        assertFalse(recipient.isRemoved);
        assertTrue(IFlow(childFlow).isRecipientEnabled(childRecipientId));

        vm.prank(safe);
        controller.setBudgetFlowRecipientEnabled(budgetItemID, childRecipientId, false);
        assertFalse(IFlow(childFlow).isRecipientEnabled(childRecipientId));

        vm.prank(safe);
        controller.removeBudgetFlowRecipient(budgetItemID, childRecipientId);
        assertTrue(TestableCustomFlow(childFlow).getRecipientById(childRecipientId).isRemoved);
    }

    function test_budgetChildAdminWrappers_revertWhenBudgetInactive() public {
        bytes32 budgetItemID = bytes32(uint256(1));
        (, address treasury) = _createBudget(budgetItemID, "Budget A");
        bytes32 childRecipientId = bytes32(uint256(11));
        address childRecipient = makeAddr("budget-recipient");

        vm.prank(safe);
        controller.addBudgetFlowRecipient(
            budgetItemID, childRecipientId, childRecipient, _childRecipientMetadata("Budget Recipient")
        );

        ManagedBudgetControllerMockBudgetTreasury(treasury).setActivatedAt(uint64(block.timestamp));

        vm.prank(safe);
        controller.removeBudget(budgetItemID);

        vm.startPrank(safe);

        vm.expectRevert(IManagedBudgetController.ITEM_NOT_ACTIVE.selector);
        controller.addBudgetFlowRecipient(
            budgetItemID,
            bytes32(uint256(12)),
            makeAddr("budget-recipient-2"),
            _childRecipientMetadata("Budget Recipient 2")
        );

        vm.expectRevert(IManagedBudgetController.ITEM_NOT_ACTIVE.selector);
        controller.setBudgetFlowRecipientEnabled(budgetItemID, childRecipientId, false);

        vm.expectRevert(IManagedBudgetController.ITEM_NOT_ACTIVE.selector);
        controller.removeBudgetFlowRecipient(budgetItemID, childRecipientId);

        vm.stopPrank();
    }

    function test_removeBudget_keepsTopologyDiscoverableAndCompactsActiveSetForLiveBudget() public {
        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));
        (address childFlowA, address treasuryA) = _createBudget(itemA, "Budget A");
        (address childFlowB, address treasuryB) = _createBudget(itemB, "Budget B");

        ManagedBudgetControllerMockBudgetTreasury(treasuryA).setActivatedAt(uint64(block.timestamp));

        vm.prank(safe);
        (bool removedFromParent, bool terminallyResolved) = controller.removeBudget(itemA);

        assertTrue(removedFromParent);
        assertTrue(terminallyResolved);

        assertEq(controller.activeBudgetCount(), 1);
        assertEq(controller.activeBudgetIdAt(0), itemB);
        assertEq(budgetAllocationLedger.budgetForRecipient(itemA), address(0));
        assertEq(budgetAllocationLedger.budgetForRecipient(itemB), treasuryB);

        FlowTypes.FlowRecipient memory removedRecipient = goalFlow.getRecipientById(itemA);
        FlowTypes.FlowRecipient memory survivingRecipient = goalFlow.getRecipientById(itemB);
        assertEq(removedRecipient.recipient, childFlowA);
        assertTrue(removedRecipient.isRemoved);
        assertEq(survivingRecipient.recipient, childFlowB);
        assertFalse(survivingRecipient.isRemoved);

        ManagedBudgetControllerMockBudgetTreasury removedTreasury = ManagedBudgetControllerMockBudgetTreasury(treasuryA);
        assertEq(removedTreasury.failRemovedBudgetCallCount(), 1);
        assertEq(removedTreasury.forceFlowRateToZeroCallCount(), 0);
        assertEq(removedTreasury.disableSuccessResolutionCallCount(), 0);
        assertTrue(removedTreasury.resolved());

        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            controller.budgetStackTopology(itemA);
        assertFalse(active);
        assertEq(topology.childFlow, childFlowA);
        assertEq(topology.budgetTreasury, treasuryA);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyByTreasury, bool activeByTreasury) =
            controller.budgetStackTopologyForBudgetTreasury(treasuryA);
        assertFalse(activeByTreasury);
        assertEq(topologyByTreasury.childFlow, childFlowA);
        assertEq(topologyByTreasury.budgetTreasury, treasuryA);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyByChildFlow, bool activeByChildFlow) =
            controller.budgetStackTopologyForChildFlow(childFlowA);
        assertFalse(activeByChildFlow);
        assertEq(topologyByChildFlow.childFlow, childFlowA);
        assertEq(topologyByChildFlow.budgetTreasury, treasuryA);

        assertEq(controller.itemIdForBudgetTreasury(treasuryA), itemA);
        assertEq(controller.itemIdForChildFlow(childFlowA), itemA);
    }

    function test_terminalBudgetPruningWorksThroughGenericControllerInterface() public {
        bytes32 itemID = bytes32(uint256(1));
        (address childFlow, address treasury) = _createBudget(itemID, "Budget A");

        ManagedBudgetControllerMockBudgetTreasury(treasury).setResolved(true);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        vm.prank(makeAddr("keeper"));
        (bool removedFromParent, bool goalSynced) = IBudgetController(address(controller)).pruneTerminalBudget(treasury);

        assertTrue(removedFromParent);
        assertTrue(goalSynced);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);
        assertEq(budgetAllocationLedger.budgetForRecipient(itemID), address(0));

        FlowTypes.FlowRecipient memory recipient = goalFlow.getRecipientById(itemID);
        assertEq(recipient.recipient, childFlow);
        assertTrue(recipient.isRemoved);

        (, bool active) = controller.budgetStackTopology(itemID);
        assertFalse(active);
        assertEq(controller.itemIdForBudgetTreasury(treasury), itemID);
    }

    function test_controllerAndSingleAllocatorStrategy_roundTripThroughAllocation() public {
        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));
        _createBudget(itemA, "Budget A");
        _createBudget(itemB, "Budget B");

        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = itemA;
        itemIDs[1] = itemB;

        uint32[] memory ppm = new uint32[](2);
        ppm[0] = 500_000;
        ppm[1] = 500_000;

        uint256 controllerKey = _controllerAllocationKey();
        uint256 safeKey = goalStrategy.allocationKey(safe, bytes(""));

        vm.expectRevert(IFlow.NOT_ABLE_TO_ALLOCATE.selector);
        vm.prank(safe);
        goalFlow.allocate(itemIDs, ppm);

        vm.prank(safe);
        controller.setBudgetWeights(itemIDs, ppm);

        assertTrue(goalFlow.canAllocate(controllerKey, address(controller)));
        assertFalse(goalFlow.canAllocate(safeKey, safe));
        assertEq(
            goalFlow.getAllocationCommitment(address(goalStrategy), controllerKey), _allocationCommit(itemIDs, ppm)
        );
        assertEq(goalFlow.getAllocationCommitment(address(goalStrategy), safeKey), bytes32(0));
    }

    function test_syncBudgetTreasuries_bestEffortAcrossManagedBudgets() public {
        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));
        (, address treasuryA) = _createBudget(itemA, "Budget A");
        (, address treasuryB) = _createBudget(itemB, "Budget B");

        ManagedBudgetControllerMockBudgetTreasury(treasuryA).setShouldRevertSync(true);

        bytes32[] memory itemIDs = new bytes32[](3);
        itemIDs[0] = bytes32(uint256(99));
        itemIDs[1] = itemA;
        itemIDs[2] = itemB;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = controller.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 2);
        assertEq(succeeded, 1);
        assertEq(ManagedBudgetControllerMockBudgetTreasury(treasuryA).syncCallCount(), 0);
        assertEq(ManagedBudgetControllerMockBudgetTreasury(treasuryB).syncCallCount(), 1);
    }

    function _createBudget(bytes32 itemID, string memory title)
        internal
        returns (address childFlow, address budgetTreasury)
    {
        vm.prank(safe);
        return controller.createBudget(itemID, _defaultBudgetConfig(title));
    }

    function _controllerAllocationKey() internal view returns (uint256) {
        return goalStrategy.allocationKey(address(controller), bytes(""));
    }

    function _allocationCommit(bytes32[] memory itemIDs, uint32[] memory ppm) internal pure returns (bytes32) {
        return keccak256(abi.encode(itemIDs, ppm));
    }

    function _defaultBudgetConfig(string memory title)
        internal
        view
        returns (IManagedBudgetController.BudgetConfig memory config)
    {
        config.metadata = FlowTypes.RecipientMetadata({
            title: title,
            description: string(abi.encodePacked(title, " description")),
            image: "ipfs://managed-budget",
            tagline: "managed",
            url: "https://managed.test"
        });
        config.fundingDeadline = uint64(block.timestamp + FUNDING_WINDOW);
        config.executionDuration = EXECUTION_DURATION;
        config.activationThreshold = 100e18;
        config.runwayCap = 500e18;
        config.successOracleSpecHash = keccak256(abi.encodePacked(title, "-oracle"));
        config.successAssertionPolicyHash = keccak256(abi.encodePacked(title, "-policy"));
    }

    function _childRecipientMetadata(string memory title)
        internal
        pure
        returns (FlowTypes.RecipientMetadata memory metadata)
    {
        metadata = FlowTypes.RecipientMetadata({
            title: title,
            description: string(abi.encodePacked(title, " description")),
            image: "ipfs://managed-child",
            tagline: "managed-child",
            url: "https://managed-child.test"
        });
    }
}

contract ManagedBudgetControllerInitializeValidationTest is Test {
    ManagedBudgetController internal controller;
    address internal authority = makeAddr("safe");
    address internal goalTreasury = address(new ManagedBudgetControllerDummyContract());
    address internal goalFlow = address(new ManagedBudgetControllerDummyContract());
    address internal budgetAllocationLedger = address(new ManagedBudgetControllerDummyContract());
    address internal stackDeployer = address(new ManagedBudgetControllerDummyContract());
    address internal budgetSuccessResolver = makeAddr("budget-success-resolver");
    address internal budgetSpendPolicy = address(new ManagedBudgetControllerDummyContract());
    address internal underwriterSlasherRouter = address(new ManagedBudgetControllerDummyContract());

    function setUp() public {
        ManagedBudgetController implementation = new ManagedBudgetController();
        controller = ManagedBudgetController(Clones.clone(address(implementation)));
    }

    function test_initialize_revertsOnZeroBudgetAllocationLedger() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetAllocationLedger = address(0);

        vm.expectRevert(IManagedBudgetController.ADDRESS_ZERO.selector);
        controller.initialize(config);
    }

    function test_initialize_revertsOnNonContractBudgetAllocationLedger() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetAllocationLedger = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(IManagedBudgetController.NOT_A_CONTRACT.selector, address(0xBEEF)));
        controller.initialize(config);
    }

    function test_initialize_revertsOnZeroUnderwriterSlasherRouter() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.underwriterSlasherRouter = address(0);

        vm.expectRevert(IManagedBudgetController.ADDRESS_ZERO.selector);
        controller.initialize(config);
    }

    function test_initialize_revertsOnNonContractUnderwriterSlasherRouter() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.underwriterSlasherRouter = address(0xCAFE);

        vm.expectRevert(abi.encodeWithSelector(IManagedBudgetController.NOT_A_CONTRACT.selector, address(0xCAFE)));
        controller.initialize(config);
    }

    function _baseInitConfig() internal view returns (IManagedBudgetController.InitConfig memory config) {
        config = IManagedBudgetController.InitConfig({
            authority: authority,
            goalTreasury: goalTreasury,
            goalFlow: goalFlow,
            budgetAllocationLedger: budgetAllocationLedger,
            stackDeployer: stackDeployer,
            budgetGatePolicy: address(0),
            budgetSuccessResolver: budgetSuccessResolver,
            budgetSpendPolicy: budgetSpendPolicy,
            underwriterSlasherRouter: underwriterSlasherRouter,
            successAssertionLiveness: 1 days,
            successAssertionBond: 10e18,
            budgetPremiumPpm: 0,
            budgetSlashPpm: 0
        });
    }
}

contract ManagedBudgetControllerRealStackTest is FlowTestBase, SpendPolicyTestUtils {
    uint64 internal constant FUNDING_WINDOW = 7 days;
    uint64 internal constant EXECUTION_DURATION = 30 days;
    uint64 internal constant SUCCESS_ASSERTION_LIVENESS = 1 days;
    uint256 internal constant SUCCESS_ASSERTION_BOND = 10e18;

    address internal safe = address(new ManagedBudgetControllerDummyContract());
    address internal budgetSuccessResolver = address(new ManagedBudgetControllerDummyContract());
    address internal underwriterSlasherRouter = address(new ManagedBudgetControllerDummyContract());

    ManagedBudgetController internal controller;
    ManagedBudgetControllerMockGoalTreasury internal goalTreasury;
    BudgetTCRStakeLedgerHarness internal budgetAllocationLedger;
    ManagedBudgetControllerStackDeployer internal stackDeployer;
    SingleAllocatorStrategy internal goalStrategy;
    TestableCustomFlow internal goalFlow;
    address internal spendPolicy;

    function _useHarnessFlowImplementation() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();

        ManagedBudgetController controllerImplementation = new ManagedBudgetController();
        controller = ManagedBudgetController(Clones.clone(address(controllerImplementation)));

        goalTreasury = new ManagedBudgetControllerMockGoalTreasury();
        budgetAllocationLedger = new BudgetTCRStakeLedgerHarness();
        stackDeployer =
            new ManagedBudgetControllerStackDeployer(address(new BudgetTreasury()), address(new NullPremiumEscrow()));
        spendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));

        goalStrategy = new SingleAllocatorStrategy(address(goalTreasury), address(controller));
        goalFlow = TestableCustomFlow(
            address(
                _deployFlowWithConfigAndRoles(
                    owner,
                    address(controller),
                    manager,
                    manager,
                    managerRewardPool,
                    address(0),
                    address(0),
                    IAllocationStrategy(address(goalStrategy))
                )
            )
        );
        goalTreasury.setFlow(address(goalFlow));

        controller.initialize(
            IManagedBudgetController.InitConfig({
                authority: safe,
                goalTreasury: address(goalTreasury),
                goalFlow: address(goalFlow),
                budgetAllocationLedger: address(budgetAllocationLedger),
                stackDeployer: address(stackDeployer),
                budgetGatePolicy: address(0),
                budgetSuccessResolver: budgetSuccessResolver,
                budgetSpendPolicy: spendPolicy,
                underwriterSlasherRouter: underwriterSlasherRouter,
                successAssertionLiveness: SUCCESS_ASSERTION_LIVENESS,
                successAssertionBond: SUCCESS_ASSERTION_BOND,
                budgetPremiumPpm: 0,
                budgetSlashPpm: 0
            })
        );
    }

    function test_createBudget_realStackDeploysBudgetTreasuryAndScopedChildFlow() public {
        bytes32 itemID = bytes32(uint256(1));
        IManagedBudgetController.BudgetConfig memory config = _defaultBudgetConfig("Budget A");

        vm.prank(safe);
        (address childFlow, address budgetTreasury) = controller.createBudget(itemID, config);

        assertEq(controller.activeBudgetCount(), 1);
        assertEq(controller.activeBudgetIdAt(0), itemID);
        assertEq(controller.itemIdForBudgetTreasury(budgetTreasury), itemID);
        assertEq(controller.itemIdForChildFlow(childFlow), itemID);
        assertEq(budgetAllocationLedger.budgetForRecipient(itemID), budgetTreasury);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            controller.budgetStackTopology(itemID);
        assertTrue(active);
        assertEq(topology.childFlow, childFlow);
        assertEq(topology.budgetTreasury, budgetTreasury);
        assertEq(controller.itemIdForBudgetTreasury(topology.budgetTreasury), itemID);
        assertEq(controller.itemIdForChildFlow(topology.childFlow), itemID);

        FlowTypes.FlowRecipient memory recipient = goalFlow.getRecipientById(itemID);
        assertEq(recipient.recipient, childFlow);
        assertFalse(recipient.isRemoved);
        assertEq(uint8(recipient.recipientType), uint8(FlowTypes.RecipientType.FlowContract));

        ICustomFlow child = ICustomFlow(childFlow);
        assertEq(child.parent(), address(goalFlow));
        assertEq(child.recipientAdmin(), address(controller));
        assertEq(child.flowOperator(), budgetTreasury);
        assertEq(child.sweeper(), budgetTreasury);
        assertEq(address(child.strategy()), topology.strategy);

        BudgetSingleAllocatorStrategy childStrategy = BudgetSingleAllocatorStrategy(topology.strategy);
        uint256 safeKey = childStrategy.allocationKey(safe, bytes(""));
        uint256 controllerKey = childStrategy.allocationKey(address(controller), bytes(""));

        assertEq(childStrategy.owner(), address(controller));
        assertEq(childStrategy.budgetTreasury(), budgetTreasury);
        assertEq(childStrategy.allocator(), address(controller));
        assertEq(childStrategy.currentWeight(childFlow, controllerKey), childStrategy.VIRTUAL_WEIGHT());
        assertEq(childStrategy.currentWeight(childFlow, safeKey), 0);
        assertEq(childStrategy.currentWeight(address(goalFlow), controllerKey), 0);
        assertTrue(child.canAllocate(controllerKey, address(controller)));
        assertFalse(child.canAllocate(controllerKey, safe));
        assertFalse(child.canAllocate(safeKey, safe));

        BudgetTreasury treasury = BudgetTreasury(budgetTreasury);
        assertEq(treasury.controller(), address(controller));
        assertEq(treasury.flow(), childFlow);
        assertEq(treasury.premiumEscrow(), topology.premiumEscrow);
        assertEq(treasury.fundingDeadline(), config.fundingDeadline);
        assertEq(treasury.executionDuration(), config.executionDuration);
        assertEq(treasury.activationThreshold(), config.activationThreshold);
        assertEq(treasury.runwayCap(), config.runwayCap);
        assertEq(treasury.successResolver(), budgetSuccessResolver);
        assertEq(treasury.successAssertionLiveness(), SUCCESS_ASSERTION_LIVENESS);
        assertEq(treasury.successAssertionBond(), SUCCESS_ASSERTION_BOND);
        assertEq(treasury.successOracleSpecHash(), config.successOracleSpecHash);
        assertEq(treasury.successAssertionPolicyHash(), config.successAssertionPolicyHash);
        assertEq(treasury.spendPolicy(), spendPolicy);

        NullPremiumEscrow premiumEscrow = NullPremiumEscrow(topology.premiumEscrow);
        assertEq(premiumEscrow.budgetTreasury(), budgetTreasury);
        assertEq(premiumEscrow.budgetStakeLedger(), address(budgetAllocationLedger));
        assertEq(premiumEscrow.goalFlow(), address(goalFlow));
        assertEq(premiumEscrow.underwriterSlasherRouter(), underwriterSlasherRouter);
        assertEq(premiumEscrow.budgetSlashPpm(), 0);
    }

    function test_removeBudget_realStackFailClosesActivatedBudgetAndKeepsSyncTerminal() public {
        bytes32 itemID = bytes32(uint256(1));

        vm.prank(safe);
        (address childFlow, address budgetTreasury) = controller.createBudget(itemID, _defaultBudgetConfig("Budget A"));

        BudgetTreasury treasury = BudgetTreasury(budgetTreasury);
        _mintAndUpgrade(owner, treasury.activationThreshold());
        vm.prank(owner);
        superToken.transfer(childFlow, treasury.activationThreshold());
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.activatedAt(), 0);
        assertGt(IFlow(childFlow).targetOutflowRate(), 0);

        vm.prank(safe);
        (bool removedFromParent, bool terminallyResolved) = controller.removeBudget(itemID);

        assertTrue(removedFromParent);
        assertTrue(terminallyResolved);
        assertEq(controller.activeBudgetCount(), 0);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertTrue(treasury.successResolutionDisabled());
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);

        _mintAndUpgrade(owner, 50e18);
        vm.prank(owner);
        superToken.transfer(childFlow, 50e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_authorityRotation_keepsBudgetChildAllocatorIdentityOnControllerAndAllowsChildFlowAllocation() public {
        bytes32 budgetItemID = bytes32(uint256(1));
        vm.prank(safe);
        (address childFlow,) = controller.createBudget(budgetItemID, _defaultBudgetConfig("Budget A"));

        bytes32 childRecipientId = bytes32(uint256(11));
        vm.prank(safe);
        vm.expectRevert(IFlow.NOT_RECIPIENT_ADMIN.selector);
        TestableCustomFlow(childFlow)
            .addRecipient(childRecipientId, makeAddr("budget-recipient"), _childRecipientMetadata("Budget Recipient"));

        vm.prank(safe);
        controller.addBudgetFlowRecipient(
            budgetItemID, childRecipientId, makeAddr("budget-recipient"), _childRecipientMetadata("Budget Recipient")
        );

        BudgetSingleAllocatorStrategy childStrategy =
            BudgetSingleAllocatorStrategy(address(ICustomFlow(childFlow).strategy()));
        uint256 controllerKey = childStrategy.allocationKey(address(controller), bytes(""));
        uint256 safeKey = childStrategy.allocationKey(safe, bytes(""));
        address rotatedSafe = makeAddr("rotated-safe");
        uint256 newSafeKey = childStrategy.allocationKey(rotatedSafe, bytes(""));

        assertEq(childStrategy.owner(), address(controller));
        assertEq(childStrategy.allocator(), address(controller));
        assertTrue(ICustomFlow(childFlow).canAllocate(controllerKey, address(controller)));
        assertFalse(ICustomFlow(childFlow).canAllocate(safeKey, safe));

        vm.prank(safe);
        controller.transferAuthority(rotatedSafe);

        vm.prank(rotatedSafe);
        controller.acceptAuthority();

        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = childRecipientId;

        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 1_000_000;

        vm.prank(rotatedSafe);
        controller.setBudgetFlowWeights(budgetItemID, recipientIds, ppm);

        assertEq(
            IFlow(childFlow).getAllocationCommitment(address(childStrategy), controllerKey),
            keccak256(abi.encode(recipientIds, ppm))
        );
        assertTrue(ICustomFlow(childFlow).canAllocate(controllerKey, address(controller)));
        assertFalse(ICustomFlow(childFlow).canAllocate(safeKey, safe));
        assertFalse(ICustomFlow(childFlow).canAllocate(newSafeKey, rotatedSafe));
    }

    function _defaultBudgetConfig(string memory title)
        internal
        view
        returns (IManagedBudgetController.BudgetConfig memory config)
    {
        config.metadata = FlowTypes.RecipientMetadata({
            title: title,
            description: string(abi.encodePacked(title, " description")),
            image: "ipfs://managed-budget",
            tagline: "managed",
            url: "https://managed.test"
        });
        config.fundingDeadline = uint64(block.timestamp + FUNDING_WINDOW);
        config.executionDuration = EXECUTION_DURATION;
        config.activationThreshold = 100e18;
        config.runwayCap = 500e18;
        config.successOracleSpecHash = keccak256(abi.encodePacked(title, "-oracle"));
        config.successAssertionPolicyHash = keccak256(abi.encodePacked(title, "-policy"));
    }

    function _childRecipientMetadata(string memory title)
        internal
        pure
        returns (FlowTypes.RecipientMetadata memory metadata)
    {
        metadata = FlowTypes.RecipientMetadata({
            title: title,
            description: string(abi.encodePacked(title, " description")),
            image: "ipfs://managed-child",
            tagline: "managed-child",
            url: "https://managed-child.test"
        });
    }
}

contract ManagedBudgetControllerMockGoalTreasury {
    address public flow;
    bool public resolved;
    bool public shouldRevertSync;
    uint256 public syncCallCount;

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }

    function setShouldRevertSync(bool shouldRevertSync_) external {
        shouldRevertSync = shouldRevertSync_;
    }

    function sync() external {
        if (shouldRevertSync) revert("GOAL_SYNC_FAILED");
        syncCallCount += 1;
    }
}

contract ManagedBudgetControllerMockSpendPolicy {}

contract ManagedBudgetControllerMockPremiumEscrow {}

contract ManagedBudgetControllerMockBudgetTreasury {
    address public controller;
    address public flow;
    address public premiumEscrow;
    uint64 public activatedAt;
    bool public resolved;
    bool public shouldRevertSync;
    uint256 public syncCallCount;
    uint256 public forceFlowRateToZeroCallCount;
    uint256 public failRemovedBudgetCallCount;
    uint256 public disableSuccessResolutionCallCount;

    function configure(address controller_, address flow_, address premiumEscrow_) external {
        controller = controller_;
        flow = flow_;
        premiumEscrow = premiumEscrow_;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        activatedAt = activatedAt_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }

    function setShouldRevertSync(bool shouldRevertSync_) external {
        shouldRevertSync = shouldRevertSync_;
    }

    function forceFlowRateToZero() external {
        forceFlowRateToZeroCallCount += 1;
    }

    function failRemovedBudget() external {
        failRemovedBudgetCallCount += 1;
        resolved = true;
    }

    function disableSuccessResolution() external {
        disableSuccessResolutionCallCount += 1;
    }

    function sync() external {
        if (shouldRevertSync) revert("SYNC_FAILED");
        syncCallCount += 1;
    }
}

contract ManagedBudgetControllerMockStackDeployer is IManagedBudgetControllerStackDeployer {
    function prepareBudgetStack(address, address, address, address)
        external
        override
        returns (PreparationResult memory result)
    {
        result.strategy = address(new MockAllocationStrategy());
        result.budgetTreasury = address(new ManagedBudgetControllerMockBudgetTreasury());
        result.premiumEscrow = address(new ManagedBudgetControllerMockPremiumEscrow());
    }

    function deployBudgetTreasury(
        address controller,
        address budgetTreasury,
        address premiumEscrow,
        address childFlow,
        address,
        address,
        address,
        uint32,
        IManagedBudgetController.BudgetConfig calldata,
        address,
        address,
        uint64,
        uint256
    ) external override returns (address deployedBudgetTreasury) {
        ManagedBudgetControllerMockBudgetTreasury(budgetTreasury).configure(controller, childFlow, premiumEscrow);
        return budgetTreasury;
    }
}

contract ManagedBudgetControllerDummyContract {}
