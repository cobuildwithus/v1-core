// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {BudgetSingleAllocatorStrategyFactory} from "src/allocation-strategies/BudgetSingleAllocatorStrategyFactory.sol";
import {SingleAllocatorStrategy} from "src/allocation-strategies/SingleAllocatorStrategy.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {ManagedBudgetController} from "src/goals/ManagedBudgetController.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {BudgetStackTypes} from "src/interfaces/BudgetStackTypes.sol";
import {IBudgetStackDeployer} from "src/interfaces/IBudgetStackDeployer.sol";
import {IBudgetController} from "src/interfaces/IBudgetController.sol";
import {IBudgetGatePolicy} from "src/interfaces/IBudgetGatePolicy.sol";
import {IBudgetStackTopologyReader} from "src/interfaces/IBudgetStackTopologyReader.sol";
import {IBudgetTreasury} from "src/interfaces/IBudgetTreasury.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IManagedBudgetController} from "src/interfaces/IManagedBudgetController.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {IAllocationMechanismFactory} from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import {BudgetStackDeployer} from "src/goals/BudgetStackDeployer.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {TeamFlow} from "src/teamflow/TeamFlow.sol";
import {TeamFlowFactory} from "src/teamflow/TeamFlowFactory.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {AlwaysEnabledZeroCoverageBudgetGatePolicy} from "test/helpers/ZeroCoverageBudgetGatePolicies.sol";
import {SpendPolicyTestUtils} from "test/helpers/SpendPolicyTestUtils.sol";
import {
    TreasuryMockOptimisticOracleV3,
    TreasuryMockUmaResolverConfig,
    TreasuryUmaResolverMockFactory
} from "test/goals/helpers/TreasuryUmaResolverMocks.sol";
import {TestableCustomFlow} from "test/harness/TestableCustomFlow.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";
import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";

contract ManagedBudgetControllerTest is FlowTestBase {
    uint64 internal constant FUNDING_WINDOW = 7 days;
    uint64 internal constant EXECUTION_DURATION = 30 days;

    address internal safe = makeAddr("safe");
    address internal newSafe = makeAddr("new-safe");
    address internal budgetSuccessResolver;
    address internal budgetChildStrategyFactory = address(new ManagedBudgetControllerDummyContract());

    ManagedBudgetController internal controller;
    ManagedBudgetControllerMockGoalTreasury internal goalTreasury;
    ManagedBudgetControllerMockStackDeployer internal stackDeployer;
    ManagedBudgetControllerMockSpendPolicy internal spendPolicy;
    SingleAllocatorStrategy internal goalStrategy;
    TestableCustomFlow internal goalFlow;

    function _useHarnessFlowImplementation() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();

        ManagedBudgetController controllerImplementation = new ManagedBudgetController();
        controller = ManagedBudgetController(Clones.clone(address(controllerImplementation)));

        goalTreasury = new ManagedBudgetControllerMockGoalTreasury();
        stackDeployer = new ManagedBudgetControllerMockStackDeployer();
        stackDeployer.setController(address(controller));
        stackDeployer.setChildFlowStrategyTarget(budgetChildStrategyFactory);
        stackDeployer.setChildFlowRecipientAdmin(address(controller));
        spendPolicy = new ManagedBudgetControllerMockSpendPolicy();
        budgetSuccessResolver = address(
            TreasuryUmaResolverMockFactory.deployResolver(IERC20(address(new ManagedBudgetControllerDummyContract())))
        );

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
                stackDeployer: address(stackDeployer),
                budgetChildStrategyFactory: budgetChildStrategyFactory,
                budgetGatePolicy: address(0),
                budgetSuccessResolver: budgetSuccessResolver,
                budgetSpendPolicy: address(spendPolicy),
                successAssertionLiveness: 1 days,
                successAssertionBond: 10e18
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

        (IBudgetStackTopologyReader.BudgetStackTopology memory topologyA, bool activeA) =
            controller.budgetStackTopology(itemA);
        assertTrue(activeA);
        assertEq(topologyA.childFlow, childFlowA);
        assertEq(topologyA.budgetTreasury, treasuryA);
        assertEq(topologyA.premiumEscrow, address(0));
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

    function test_createBudget_revertsWhenPreparedChildFlowRecipientAdminIsNotController() public {
        address childAdmin = address(new ManagedBudgetControllerDummyContract());
        stackDeployer.setChildFlowRecipientAdmin(childAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(IManagedBudgetController.INVALID_CHILD_FLOW_RECIPIENT_ADMIN.selector, childAdmin)
        );
        _createBudget(bytes32(uint256(1)), "Budget A");
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

    function test_createBudget_revertsWhenStackDeployerReturnsPremiumEscrow() public {
        address premiumEscrow = makeAddr("managed-premium-escrow");
        stackDeployer.setPreparedPremiumEscrow(premiumEscrow);

        vm.expectRevert(abi.encodeWithSelector(IManagedBudgetController.INVALID_PREMIUM_ESCROW.selector, premiumEscrow));
        vm.prank(safe);
        controller.createBudget(bytes32(uint256(1)), _defaultBudgetConfig("Budget A"));

        assertEq(controller.activeBudgetCount(), 0);
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

    function test_setBudgetWeights_revertsWhenBudgetIsInactiveButStillDiscoverable() public {
        bytes32 itemA = bytes32(uint256(1));
        bytes32 itemB = bytes32(uint256(2));
        (address childFlowA, address treasuryA) = _createBudget(itemA, "Budget A");
        _createBudget(itemB, "Budget B");

        vm.prank(safe);
        controller.removeBudget(itemA);

        bytes32[] memory itemIDs = new bytes32[](2);
        itemIDs[0] = itemA;
        itemIDs[1] = itemB;

        uint32[] memory ppm = new uint32[](2);
        ppm[0] = 500_000;
        ppm[1] = 500_000;

        vm.expectRevert(IManagedBudgetController.ITEM_NOT_ACTIVE.selector);
        vm.prank(safe);
        controller.setBudgetWeights(itemIDs, ppm);

        (IBudgetStackTopologyReader.BudgetStackTopology memory topology, bool active) =
            controller.budgetStackTopologyForBudgetTreasury(treasuryA);
        assertFalse(active);
        assertEq(topology.childFlow, childFlowA);
        assertEq(topology.budgetTreasury, treasuryA);
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
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        vm.prank(safe);
        (bool removedFromParent, bool terminallyResolved) = controller.removeBudget(itemA);

        assertTrue(removedFromParent);
        assertTrue(terminallyResolved);

        assertEq(controller.activeBudgetCount(), 1);
        assertEq(controller.activeBudgetIdAt(0), itemB);

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
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);

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

    function test_removeBudget_preActivation_usesRemovalFinalizer_andSyncsGoal() public {
        bytes32 itemID = bytes32(uint256(1));
        (address childFlow, address treasury) = _createBudget(itemID, "Budget A");
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        vm.prank(safe);
        (bool removedFromParent, bool terminallyResolved) = controller.removeBudget(itemID);

        assertTrue(removedFromParent);
        assertTrue(terminallyResolved);
        assertEq(controller.activeBudgetCount(), 0);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(controller.itemIdForChildFlow(childFlow), itemID);

        ManagedBudgetControllerMockBudgetTreasury removedTreasury = ManagedBudgetControllerMockBudgetTreasury(treasury);
        assertEq(removedTreasury.failRemovedBudgetCallCount(), 1);
        assertEq(removedTreasury.forceFlowRateToZeroCallCount(), 0);
        assertEq(removedTreasury.disableSuccessResolutionCallCount(), 0);
        assertEq(removedTreasury.resolveFailureCallCount(), 0);
        assertTrue(removedTreasury.resolved());
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);
    }

    function test_removeBudget_goalSyncFailure_isBestEffort() public {
        bytes32 itemID = bytes32(uint256(1));
        (, address treasury) = _createBudget(itemID, "Budget A");

        goalTreasury.setShouldRevertSync(true);

        vm.prank(safe);
        (bool removedFromParent, bool terminallyResolved) = controller.removeBudget(itemID);

        assertTrue(removedFromParent);
        assertTrue(terminallyResolved);
        assertEq(controller.activeBudgetCount(), 0);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertTrue(ManagedBudgetControllerMockBudgetTreasury(treasury).resolved());
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

    function test_syncBudgetTreasuries_budgetGatePolicy_allowsZeroCoverageCompatiblePolicy() public {
        (ManagedBudgetController gatedController, TestableCustomFlow gatedGoalFlow) =
            _deployControllerWithGatePolicy(address(new AlwaysEnabledZeroCoverageBudgetGatePolicy()));
        bytes32 itemID = bytes32(uint256(1));

        vm.prank(safe);
        gatedController.createBudget(itemID, _defaultBudgetConfig("Budget A"));

        assertTrue(gatedGoalFlow.isRecipientEnabled(itemID));

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = gatedController.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertTrue(gatedGoalFlow.isRecipientEnabled(itemID));
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

    function _deployControllerWithGatePolicy(address gatePolicy)
        internal
        returns (ManagedBudgetController deployedController, TestableCustomFlow deployedGoalFlow)
    {
        ManagedBudgetController controllerImplementation = new ManagedBudgetController();
        deployedController = ManagedBudgetController(Clones.clone(address(controllerImplementation)));

        ManagedBudgetControllerMockGoalTreasury deployedGoalTreasury = new ManagedBudgetControllerMockGoalTreasury();
        ManagedBudgetControllerMockStackDeployer deployedStackDeployer = new ManagedBudgetControllerMockStackDeployer();
        address deployedChildStrategyFactory = address(new ManagedBudgetControllerDummyContract());
        deployedStackDeployer.setController(address(deployedController));
        deployedStackDeployer.setChildFlowStrategyTarget(deployedChildStrategyFactory);
        deployedStackDeployer.setChildFlowRecipientAdmin(address(deployedController));
        ManagedBudgetControllerMockSpendPolicy deployedSpendPolicy = new ManagedBudgetControllerMockSpendPolicy();

        SingleAllocatorStrategy deployedGoalStrategy =
            new SingleAllocatorStrategy(address(deployedGoalTreasury), address(deployedController));
        deployedGoalFlow = TestableCustomFlow(
            address(
                _deployFlowWithConfigAndRoles(
                    owner,
                    address(deployedController),
                    manager,
                    manager,
                    managerRewardPool,
                    address(0),
                    address(0),
                    IAllocationStrategy(address(deployedGoalStrategy))
                )
            )
        );
        deployedGoalTreasury.setFlow(address(deployedGoalFlow));
        deployedGoalTreasury.setBudgetStakeLedger(address(new ManagedBudgetControllerMockBudgetStakeLedger()));

        deployedController.initialize(
            IManagedBudgetController.InitConfig({
                authority: safe,
                goalTreasury: address(deployedGoalTreasury),
                goalFlow: address(deployedGoalFlow),
                stackDeployer: address(deployedStackDeployer),
                budgetChildStrategyFactory: deployedChildStrategyFactory,
                budgetGatePolicy: gatePolicy,
                budgetSuccessResolver: budgetSuccessResolver,
                budgetSpendPolicy: address(deployedSpendPolicy),
                successAssertionLiveness: 1 days,
                successAssertionBond: 10e18
            })
        );
    }
}

contract ManagedBudgetControllerInitializeValidationTest is Test {
    ManagedBudgetController internal controller;
    address internal authority = makeAddr("safe");
    address internal goalTreasury = address(new ManagedBudgetControllerDummyContract());
    address internal goalFlow = address(new ManagedBudgetControllerDummyContract());
    address internal stackDeployer;
    address internal budgetChildStrategyFactory = address(new ManagedBudgetControllerDummyContract());
    address internal budgetSuccessResolver;
    address internal budgetSpendPolicy;

    function setUp() public {
        ManagedBudgetController implementation = new ManagedBudgetController();
        controller = ManagedBudgetController(Clones.clone(address(implementation)));
        ManagedBudgetControllerMockStackDeployer stackDeployerMock = new ManagedBudgetControllerMockStackDeployer();
        stackDeployerMock.setController(address(controller));
        stackDeployerMock.setChildFlowStrategyTarget(budgetChildStrategyFactory);
        stackDeployerMock.setChildFlowRecipientAdmin(address(controller));
        stackDeployer = address(stackDeployerMock);
        budgetSuccessResolver = address(
            TreasuryUmaResolverMockFactory.deployResolver(IERC20(address(new ManagedBudgetControllerDummyContract())))
        );
        budgetSpendPolicy = address(new ManagedBudgetControllerMockSpendPolicy());
    }

    function test_initialize_setsManagedCoreReferences() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();

        controller.initialize(config);
        assertEq(controller.authority(), authority);
        assertEq(controller.goalTreasury(), goalTreasury);
        assertEq(controller.goalFlow(), goalFlow);
        assertEq(controller.stackDeployer(), stackDeployer);
        assertEq(controller.budgetSuccessResolver(), budgetSuccessResolver);
        assertEq(controller.budgetSpendPolicy(), budgetSpendPolicy);
    }

    function test_initialize_revertsOnNonContractBudgetGatePolicy() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetGatePolicy = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(IManagedBudgetController.NOT_A_CONTRACT.selector, address(0xBEEF)));
        controller.initialize(config);
    }

    function test_initialize_revertsOnZeroCoverageIncompatibleBudgetGatePolicy() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetGatePolicy = address(new ManagedBudgetControllerZeroCoverageGatePolicy());

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedBudgetController.INVALID_BUDGET_GATE_POLICY.selector, config.budgetGatePolicy
            )
        );
        controller.initialize(config);
    }

    function test_initialize_revertsOnProbeOnlyBudgetGatePolicyWithoutExplicitZeroCoverageSupport() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetGatePolicy = address(new ManagedBudgetControllerProbeAwareGatePolicy());

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedBudgetController.INVALID_BUDGET_GATE_POLICY.selector, config.budgetGatePolicy
            )
        );
        controller.initialize(config);
    }

    function test_initialize_revertsOnInvalidSuccessResolverProbe() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetSuccessResolver = address(new ManagedBudgetControllerDummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedBudgetController.INVALID_SUCCESS_RESOLVER.selector, config.budgetSuccessResolver
            )
        );
        controller.initialize(config);
    }

    function test_initialize_revertsOnInvalidBudgetSpendPolicyProbe() public {
        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.budgetSpendPolicy = address(new ManagedBudgetControllerDummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedBudgetController.INVALID_BUDGET_SPEND_POLICY.selector, config.budgetSpendPolicy
            )
        );
        controller.initialize(config);
    }

    function test_initialize_trimmedControllerDoesNotExposeRemovedCoverageOrSlashGetters() public {
        controller.initialize(_baseInitConfig());

        (bool hasBudgetAllocationLedgerGetter,) =
            address(controller).staticcall(abi.encodeWithSignature("budgetAllocationLedger()"));
        (bool hasUnderwriterSlasherRouterGetter,) =
            address(controller).staticcall(abi.encodeWithSignature("underwriterSlasherRouter()"));
        (bool hasBudgetPremiumPpmGetter,) =
            address(controller).staticcall(abi.encodeWithSignature("budgetPremiumPpm()"));
        (bool hasBudgetSlashPpmGetter,) = address(controller).staticcall(abi.encodeWithSignature("budgetSlashPpm()"));

        assertFalse(hasBudgetAllocationLedgerGetter);
        assertFalse(hasUnderwriterSlasherRouterGetter);
        assertFalse(hasBudgetPremiumPpmGetter);
        assertFalse(hasBudgetSlashPpmGetter);
    }

    function test_initialize_revertsWhenStackDeployerControllerDoesNotMatch() public {
        ManagedBudgetControllerMockStackDeployer mismatchedStackDeployer =
            new ManagedBudgetControllerMockStackDeployer();
        mismatchedStackDeployer.setController(address(new ManagedBudgetControllerDummyContract()));
        mismatchedStackDeployer.setChildFlowStrategyTarget(budgetChildStrategyFactory);
        mismatchedStackDeployer.setChildFlowRecipientAdmin(address(controller));

        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.stackDeployer = address(mismatchedStackDeployer);

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedBudgetController.INVALID_STACK_DEPLOYER.selector, address(mismatchedStackDeployer)
            )
        );
        controller.initialize(config);
    }

    function test_initialize_revertsWhenStackDeployerTupleDoesNotMatchManagedPreset() public {
        ManagedBudgetControllerMockStackDeployer mismatchedStackDeployer =
            new ManagedBudgetControllerMockStackDeployer();
        mismatchedStackDeployer.setController(address(controller));
        mismatchedStackDeployer.setChildFlowStrategyMode(BudgetStackTypes.ChildFlowStrategyMode.SharedBudgetFlowRouter);
        mismatchedStackDeployer.setChildFlowRecipientAdmin(address(controller));

        IManagedBudgetController.InitConfig memory config = _baseInitConfig();
        config.stackDeployer = address(mismatchedStackDeployer);

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedBudgetController.INVALID_STACK_DEPLOYER.selector, address(mismatchedStackDeployer)
            )
        );
        controller.initialize(config);
    }

    function _baseInitConfig() internal view returns (IManagedBudgetController.InitConfig memory config) {
        config = IManagedBudgetController.InitConfig({
            authority: authority,
            goalTreasury: goalTreasury,
            goalFlow: goalFlow,
            stackDeployer: stackDeployer,
            budgetChildStrategyFactory: budgetChildStrategyFactory,
            budgetGatePolicy: address(0),
            budgetSuccessResolver: budgetSuccessResolver,
            budgetSpendPolicy: budgetSpendPolicy,
            successAssertionLiveness: 1 days,
            successAssertionBond: 10e18
        });
    }
}

contract ManagedBudgetControllerRealStackTest is FlowTestBase, SpendPolicyTestUtils {
    uint64 internal constant FUNDING_WINDOW = 7 days;
    uint64 internal constant EXECUTION_DURATION = 30 days;
    uint64 internal constant SUCCESS_ASSERTION_LIVENESS = 1 days;
    uint256 internal constant SUCCESS_ASSERTION_BOND = 10e18;

    address internal safe = address(new ManagedBudgetControllerDummyContract());
    address internal budgetSuccessResolver;

    ManagedBudgetController internal controller;
    ManagedBudgetControllerMockGoalTreasury internal goalTreasury;
    BudgetStackDeployer internal stackDeployer;
    BudgetSingleAllocatorStrategyFactory internal childStrategyFactory;
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
        childStrategyFactory = new BudgetSingleAllocatorStrategyFactory(
            address(new BudgetSingleAllocatorStrategy(address(0), address(0)))
        );
        BudgetStackDeployer deployerImplementation = new BudgetStackDeployer(
            address(new BudgetTreasury()),
            address(
                new RoundFactory(
                    address(new RoundSubmissionTCR()),
                    address(new RoundPrizeVault()),
                    address(new PrizePoolSubmissionDepositStrategy()),
                    address(new ERC20VotesArbitrator())
                )
            ),
            address(
                new RoundFactory(
                    address(new RoundSubmissionTCR()),
                    address(new RoundPrizeVault()),
                    address(new PrizePoolSubmissionDepositStrategy()),
                    address(new ERC20VotesArbitrator())
                )
            ),
            address(new AllocationMechanismTCR(address(new MechanismFundingEscrow()))),
            address(new ERC20VotesArbitrator()),
            address(new BudgetFlowRouterStrategy())
        );
        stackDeployer = BudgetStackDeployer(Clones.clone(address(deployerImplementation)));
        spendPolicy = address(_deployLinearSpendPolicy(true, 0, ISpendPolicy.SyncMode.Capped));
        budgetSuccessResolver = address(
            TreasuryUmaResolverMockFactory.deployResolver(IERC20(address(new ManagedBudgetControllerDummyContract())))
        );

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
        goalTreasury.setBudgetStakeLedger(address(new ManagedBudgetControllerMockBudgetStakeLedger()));

        stackDeployer.initializeWithConfig(
            address(controller),
            BudgetStackTypes.StackModuleConfig({
                childFlowStrategyMode: BudgetStackTypes.ChildFlowStrategyMode.Factory,
                childFlowStrategyTarget: address(childStrategyFactory),
                mechanismLayerMode: BudgetStackTypes.MechanismLayerMode.None,
                childFlowRecipientAdmin: address(controller),
                premiumEscrowImplementation: address(0)
            })
        );

        controller.initialize(
            IManagedBudgetController.InitConfig({
                authority: safe,
                goalTreasury: address(goalTreasury),
                goalFlow: address(goalFlow),
                stackDeployer: address(stackDeployer),
                budgetChildStrategyFactory: address(childStrategyFactory),
                budgetGatePolicy: address(0),
                budgetSuccessResolver: budgetSuccessResolver,
                budgetSpendPolicy: spendPolicy,
                successAssertionLiveness: SUCCESS_ASSERTION_LIVENESS,
                successAssertionBond: SUCCESS_ASSERTION_BOND
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
        assertEq(child.managerRewardPool(), address(0));
        assertEq(child.managerRewardPoolFlowRatePpm(), 0);
        assertEq(address(child.managerRewardDistributionPool()), address(0));
        assertEq(address(child.strategy()), topology.strategy);

        BudgetSingleAllocatorStrategy childStrategy = BudgetSingleAllocatorStrategy(topology.strategy);
        uint256 safeKey = childStrategy.allocationKey(safe, bytes(""));
        uint256 controllerKey = childStrategy.allocationKey(address(controller), bytes(""));

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

        assertEq(topology.premiumEscrow, address(0));
    }

    function test_removeBudget_realStackFailClosesActivatedBudgetAndKeepsSyncTerminal() public {
        bytes32 itemID = bytes32(uint256(1));

        vm.prank(safe);
        (address childFlow, address budgetTreasury) = controller.createBudget(itemID, _defaultBudgetConfig("Budget A"));

        BudgetTreasury treasury = BudgetTreasury(budgetTreasury);
        uint256 activationThreshold = treasury.activationThreshold();
        _mintAndUpgrade(owner, activationThreshold);
        vm.prank(owner);
        superToken.transfer(childFlow, activationThreshold);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Active));
        assertGt(treasury.activatedAt(), 0);
        assertGt(IFlow(childFlow).targetOutflowRate(), 0);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

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
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);

        _mintAndUpgrade(owner, 50e18);
        vm.prank(owner);
        superToken.transfer(childFlow, 50e18);
        treasury.sync();

        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_removeBudget_realStack_goalSyncFailureRepairsViaRetryTerminalSideEffects() public {
        bytes32 itemID = bytes32(uint256(1));

        vm.prank(safe);
        (address childFlow, address budgetTreasury) = controller.createBudget(itemID, _defaultBudgetConfig("Budget A"));

        BudgetTreasury treasury = BudgetTreasury(budgetTreasury);
        uint256 activationThreshold = treasury.activationThreshold();
        _mintAndUpgrade(owner, activationThreshold);
        vm.prank(owner);
        superToken.transfer(childFlow, activationThreshold);
        treasury.sync();

        goalTreasury.setShouldRevertSync(true);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        vm.prank(safe);
        (bool removedFromParent, bool terminallyResolved) = controller.removeBudget(itemID);

        assertTrue(removedFromParent);
        assertTrue(terminallyResolved);
        assertEq(controller.activeBudgetCount(), 0);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore);

        goalTreasury.setShouldRevertSync(false);

        vm.prank(makeAddr("keeper"));
        treasury.retryTerminalSideEffects();

        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);
        assertEq(uint256(treasury.state()), uint256(IBudgetTreasury.BudgetState.Failed));
        assertTrue(treasury.resolved());
        assertEq(IFlow(childFlow).targetOutflowRate(), 0);
    }

    function test_syncBudgetTreasuries_realStackLocallyPrunesBudgetWhenSyncExpiresIt() public {
        bytes32 itemID = bytes32(uint256(1));

        vm.prank(safe);
        (, address budgetTreasury) = controller.createBudget(itemID, _defaultBudgetConfig("Budget A"));

        vm.warp(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = controller.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertEq(controller.activeBudgetCount(), 0);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());
        assertEq(uint256(IBudgetTreasury(budgetTreasury).state()), uint256(IBudgetTreasury.BudgetState.Expired));

        (, bool active) = controller.budgetStackTopology(itemID);
        assertFalse(active);
    }

    function test_syncBudgetTreasuries_realStack_goalSyncFailureRepairsViaRetryTerminalSideEffects() public {
        bytes32 itemID = bytes32(uint256(1));

        vm.prank(safe);
        (, address budgetTreasury) = controller.createBudget(itemID, _defaultBudgetConfig("Budget A"));

        vm.warp(IBudgetTreasury(budgetTreasury).fundingDeadline() + 1);
        goalTreasury.setShouldRevertSync(true);
        uint256 syncCallCountBefore = goalTreasury.syncCallCount();

        bytes32[] memory itemIDs = new bytes32[](1);
        itemIDs[0] = itemID;

        vm.prank(makeAddr("keeper"));
        (uint256 attempted, uint256 succeeded) = controller.syncBudgetTreasuries(itemIDs);

        assertEq(attempted, 1);
        assertEq(succeeded, 1);
        assertEq(controller.activeBudgetCount(), 0);
        assertTrue(goalFlow.getRecipientById(itemID).isRemoved);
        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore);
        assertTrue(IBudgetTreasury(budgetTreasury).resolved());

        goalTreasury.setShouldRevertSync(false);

        vm.prank(makeAddr("keeper"));
        IBudgetTreasury(budgetTreasury).retryTerminalSideEffects();

        assertEq(goalTreasury.syncCallCount(), syncCallCountBefore + 1);
        (, bool active) = controller.budgetStackTopology(itemID);
        assertFalse(active);
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
        controller.setBudgetFlowRecipientEnabled(budgetItemID, childRecipientId, false);
        assertFalse(IFlow(childFlow).isRecipientEnabled(childRecipientId));

        vm.prank(rotatedSafe);
        controller.setBudgetFlowRecipientEnabled(budgetItemID, childRecipientId, true);
        assertTrue(IFlow(childFlow).isRecipientEnabled(childRecipientId));

        vm.prank(rotatedSafe);
        controller.setBudgetFlowWeights(budgetItemID, recipientIds, ppm);

        assertEq(
            IFlow(childFlow).getAllocationCommitment(address(childStrategy), controllerKey),
            keccak256(abi.encode(recipientIds, ppm))
        );

        vm.prank(rotatedSafe);
        controller.removeBudgetFlowRecipient(budgetItemID, childRecipientId);
        assertTrue(TestableCustomFlow(childFlow).getRecipientById(childRecipientId).isRemoved);

        assertTrue(ICustomFlow(childFlow).canAllocate(controllerKey, address(controller)));
        assertFalse(ICustomFlow(childFlow).canAllocate(safeKey, safe));
        assertFalse(ICustomFlow(childFlow).canAllocate(newSafeKey, rotatedSafe));
    }

    function test_safeManagedTeamFlow_canBeDeployedDirectlyAndAttachedThroughGenericRecipientApis() public {
        bytes32 budgetItemID = bytes32(uint256(1));
        vm.prank(safe);
        (address childFlow, address budgetTreasury) =
            controller.createBudget(budgetItemID, _defaultBudgetConfig("Budget A"));

        TeamFlowFactory teamFlowFactory = new TeamFlowFactory(address(new TeamFlow()));
        TeamFlowFactory.AllocationMechanismConfig memory cfg = TeamFlowFactory.AllocationMechanismConfig({
            manager: safe,
            perSeatRate: 100,
            maxTotalRate: 250,
            flowMetadata: _childRecipientMetadata("Managed TeamFlow")
        });

        vm.prank(safe);
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            teamFlowFactory.deployForBudget(bytes32(uint256(101)), budgetTreasury, abi.encode(cfg));

        TeamFlow teamFlow = TeamFlow(deployed.payoutRecipient);
        bytes32 teamRecipientId = bytes32(uint256(11));

        assertEq(deployed.mechanism, deployed.payoutRecipient);
        assertEq(teamFlow.manager(), safe);
        assertEq(teamFlow.pendingManager(), address(0));
        assertEq(teamFlow.mechanismId(), bytes32(uint256(101)));

        vm.prank(safe);
        controller.addBudgetFlowRecipient(
            budgetItemID, teamRecipientId, deployed.payoutRecipient, _childRecipientMetadata("Managed TeamFlow")
        );

        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = teamRecipientId;
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 1_000_000;

        vm.prank(safe);
        controller.setBudgetFlowWeights(budgetItemID, recipientIds, ppm);

        FlowTypes.FlowRecipient memory childRecipient = TestableCustomFlow(childFlow).getRecipientById(teamRecipientId);
        assertEq(childRecipient.recipient, deployed.payoutRecipient);
        assertFalse(childRecipient.isRemoved);

        vm.prank(safe);
        bytes32 memberRecipientId = teamFlow.addMember(makeAddr("team-member"), _childRecipientMetadata("Seat A"));
        assertTrue(memberRecipientId != bytes32(0));
        assertEq(teamFlow.activeMemberCount(), 1);

        address rotatedSafe = makeAddr("rotated-safe");

        vm.prank(safe);
        controller.transferAuthority(rotatedSafe);
        vm.prank(rotatedSafe);
        controller.acceptAuthority();

        vm.prank(safe);
        teamFlow.transferManager(rotatedSafe);
        vm.prank(rotatedSafe);
        teamFlow.acceptManager();

        assertEq(controller.authority(), rotatedSafe);
        assertEq(teamFlow.manager(), rotatedSafe);
        assertEq(teamFlow.pendingManager(), address(0));

        vm.prank(rotatedSafe);
        teamFlow.addMember(makeAddr("team-member-2"), _childRecipientMetadata("Seat B"));

        assertEq(teamFlow.activeMemberCount(), 2);
    }

    function test_safeManagedTeamFlow_authorityRotationDoesNotImplicitlyRotateMechanismManager() public {
        bytes32 budgetItemID = bytes32(uint256(1));
        vm.prank(safe);
        (address childFlow, address budgetTreasury) =
            controller.createBudget(budgetItemID, _defaultBudgetConfig("Budget A"));

        TeamFlowFactory teamFlowFactory = new TeamFlowFactory(address(new TeamFlow()));
        TeamFlowFactory.AllocationMechanismConfig memory cfg = TeamFlowFactory.AllocationMechanismConfig({
            manager: safe,
            perSeatRate: 100,
            maxTotalRate: 250,
            flowMetadata: _childRecipientMetadata("Managed TeamFlow")
        });

        vm.prank(safe);
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            teamFlowFactory.deployForBudget(bytes32(uint256(102)), budgetTreasury, abi.encode(cfg));

        TeamFlow teamFlow = TeamFlow(deployed.payoutRecipient);
        bytes32 teamRecipientId = bytes32(uint256(12));
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = teamRecipientId;
        uint32[] memory ppm = new uint32[](1);
        ppm[0] = 1_000_000;
        address rotatedSafe = makeAddr("rotated-safe");

        vm.prank(safe);
        controller.addBudgetFlowRecipient(
            budgetItemID, teamRecipientId, deployed.payoutRecipient, _childRecipientMetadata("Managed TeamFlow")
        );

        vm.prank(safe);
        controller.setBudgetFlowWeights(budgetItemID, recipientIds, ppm);

        FlowTypes.FlowRecipient memory attachedRecipient =
            TestableCustomFlow(childFlow).getRecipientById(teamRecipientId);
        assertEq(attachedRecipient.recipient, deployed.payoutRecipient);
        assertEq(uint8(attachedRecipient.recipientType), uint8(FlowTypes.RecipientType.ExternalAccount));
        assertEq(IFlow(childFlow).recipientAdmin(), address(controller));

        vm.prank(safe);
        controller.transferAuthority(rotatedSafe);
        vm.prank(rotatedSafe);
        controller.acceptAuthority();

        assertEq(controller.authority(), rotatedSafe);
        assertEq(teamFlow.manager(), safe);
        assertEq(teamFlow.pendingManager(), address(0));

        vm.prank(rotatedSafe);
        controller.setBudgetFlowWeights(budgetItemID, recipientIds, ppm);

        vm.expectRevert(IManagedBudgetController.ONLY_AUTHORITY.selector);
        vm.prank(safe);
        controller.setBudgetFlowWeights(budgetItemID, recipientIds, ppm);

        vm.expectRevert(TeamFlow.ONLY_MANAGER.selector);
        vm.prank(rotatedSafe);
        teamFlow.addMember(makeAddr("team-member-rotated"), _childRecipientMetadata("Seat B"));

        vm.prank(safe);
        teamFlow.transferManager(rotatedSafe);

        vm.prank(safe);
        teamFlow.addMember(makeAddr("team-member-safe"), _childRecipientMetadata("Seat A"));
        assertEq(teamFlow.activeMemberCount(), 1);
        assertEq(teamFlow.pendingManager(), rotatedSafe);

        vm.expectRevert(TeamFlow.ONLY_MANAGER.selector);
        vm.prank(rotatedSafe);
        teamFlow.addMember(makeAddr("team-member-rotated"), _childRecipientMetadata("Seat B"));

        vm.prank(rotatedSafe);
        teamFlow.acceptManager();

        vm.expectRevert(TeamFlow.ONLY_MANAGER.selector);
        vm.prank(safe);
        teamFlow.addMember(makeAddr("team-member-old-safe"), _childRecipientMetadata("Seat C"));

        vm.prank(rotatedSafe);
        teamFlow.addMember(makeAddr("team-member-rotated"), _childRecipientMetadata("Seat B"));

        assertEq(teamFlow.manager(), rotatedSafe);
        assertEq(teamFlow.pendingManager(), address(0));
        assertEq(teamFlow.activeMemberCount(), 2);
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
    address public budgetStakeLedger;
    bool public resolved;
    bool public shouldRevertSync;
    uint256 public syncCallCount;

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setBudgetStakeLedger(address budgetStakeLedger_) external {
        budgetStakeLedger = budgetStakeLedger_;
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

contract ManagedBudgetControllerZeroCoverageGatePolicy is IBudgetGatePolicy {
    function evaluateBudgetGate(SyncContext calldata context) external pure returns (SyncResult memory result) {
        result.shouldSetRecipientEnabled = true;
        result.recipientEnabled = context.coverageSource != address(0) || context.coverageToCreditPpm != 0;
    }
}

contract ManagedBudgetControllerProbeAwareGatePolicy is IBudgetGatePolicy {
    function evaluateBudgetGate(SyncContext calldata context) external pure returns (SyncResult memory result) {
        if (
            context.itemID == bytes32(0) && address(context.goalFlow) == address(0) && context.childFlow == address(0)
                && context.budgetTreasury == address(0) && context.coverageSource == address(0)
                && context.coverageToCreditPpm == 0
        ) {
            return result;
        }

        result.shouldSetRecipientEnabled = true;
        result.recipientEnabled = false;
    }
}

contract ManagedBudgetControllerMockSpendPolicy is ISpendPolicy {
    function targetFlowRate(SpendContext calldata) external pure returns (int96) {
        return 0;
    }

    function syncMode() external pure returns (SyncMode) {
        return SyncMode.Capped;
    }
}

contract ManagedBudgetControllerMockPremiumEscrow {}

contract ManagedBudgetControllerMockBudgetTreasury {
    address public controller;
    address public flow;
    address public premiumEscrow;
    bool public resolved;
    bool public shouldRevertSync;
    uint256 public syncCallCount;
    uint256 public forceFlowRateToZeroCallCount;
    uint256 public failRemovedBudgetCallCount;
    uint256 public disableSuccessResolutionCallCount;
    uint256 public resolveFailureCallCount;

    function configure(address controller_, address flow_, address premiumEscrow_) external {
        controller = controller_;
        flow = flow_;
        premiumEscrow = premiumEscrow_;
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

    function resolveFailure() external {
        resolveFailureCallCount += 1;
        resolved = true;
    }

    function sync() external {
        if (shouldRevertSync) revert("SYNC_FAILED");
        syncCallCount += 1;
    }
}

contract ManagedBudgetControllerMockStackDeployer is IBudgetStackDeployer {
    address public configuredController;
    BudgetStackTypes.ChildFlowStrategyMode public configuredChildFlowStrategyMode =
    BudgetStackTypes.ChildFlowStrategyMode.Factory;
    address public configuredChildFlowStrategyTarget;
    BudgetStackTypes.MechanismLayerMode public configuredMechanismLayerMode = BudgetStackTypes.MechanismLayerMode.None;
    address public childFlowRecipientAdmin;
    address public preparedPremiumEscrow;
    address public premiumEscrowImplementation;

    function setController(address controller_) external {
        configuredController = controller_;
    }

    function setChildFlowStrategyMode(BudgetStackTypes.ChildFlowStrategyMode childFlowStrategyMode_) external {
        configuredChildFlowStrategyMode = childFlowStrategyMode_;
    }

    function setChildFlowStrategyTarget(address childFlowStrategyTarget_) external {
        configuredChildFlowStrategyTarget = childFlowStrategyTarget_;
    }

    function setMechanismLayerMode(BudgetStackTypes.MechanismLayerMode mechanismLayerMode_) external {
        configuredMechanismLayerMode = mechanismLayerMode_;
    }

    function setChildFlowRecipientAdmin(address childFlowRecipientAdmin_) external {
        childFlowRecipientAdmin = childFlowRecipientAdmin_;
    }

    function setPremiumEscrowImplementation(address premiumEscrowImplementation_) external {
        premiumEscrowImplementation = premiumEscrowImplementation_;
    }

    function setPreparedPremiumEscrow(address preparedPremiumEscrow_) external {
        preparedPremiumEscrow = preparedPremiumEscrow_;
    }

    function controller() external view returns (address controller_) {
        controller_ = configuredController;
    }

    function initializeWithConfig(address, BudgetStackTypes.StackModuleConfig calldata) external {}

    function prepareBudgetStack(address, address)
        external
        override
        returns (BudgetStackTypes.PreparationResult memory result)
    {
        result.strategy = address(new MockAllocationStrategy());
        result.budgetTreasury = address(new ManagedBudgetControllerMockBudgetTreasury());
        result.premiumEscrow = preparedPremiumEscrow;
        result.childFlowRecipientAdmin = childFlowRecipientAdmin;
    }

    function deployBudgetTreasury(address budgetTreasury, IBudgetTreasury.BudgetConfig calldata budgetConfig)
        external
        override
        returns (address deployedBudgetTreasury)
    {
        ManagedBudgetControllerMockBudgetTreasury(budgetTreasury)
            .configure(address(this), budgetConfig.flow, budgetConfig.premiumEscrow);
        return budgetTreasury;
    }

    function deployBudgetTreasuryWithRiskModule(
        address budgetTreasury,
        IBudgetTreasury.BudgetConfig calldata budgetConfig,
        BudgetStackTypes.RiskModuleInitConfig calldata
    ) external override returns (address deployedBudgetTreasury) {
        ManagedBudgetControllerMockBudgetTreasury(budgetTreasury)
            .configure(address(this), budgetConfig.flow, budgetConfig.premiumEscrow);
        return budgetTreasury;
    }

    function registerChildFlowRecipient(bytes32, address) external {}

    function stackModuleConfig() external view returns (BudgetStackTypes.StackModuleConfig memory config) {
        config = BudgetStackTypes.StackModuleConfig({
            childFlowStrategyMode: configuredChildFlowStrategyMode,
            childFlowStrategyTarget: configuredChildFlowStrategyTarget,
            mechanismLayerMode: configuredMechanismLayerMode,
            childFlowRecipientAdmin: childFlowRecipientAdmin,
            premiumEscrowImplementation: premiumEscrowImplementation
        });
    }

    function initialMechanismFactories() external pure returns (address[] memory factories) {
        factories = new address[](0);
    }

    function roundFactory() external pure returns (address) {
        return address(0);
    }

    function allocationMechanismTcrImplementation() external pure returns (address) {
        return address(0);
    }

    function allocationMechanismArbitratorImplementation() external pure returns (address) {
        return address(0);
    }
}

contract ManagedBudgetControllerMockBudgetStakeLedger {}

contract ManagedBudgetControllerDummyContract {}
