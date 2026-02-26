// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTestBase } from "test/flows/helpers/FlowTestBase.t.sol";
import { MockAllocationStrategy } from "test/mocks/MockAllocationStrategy.sol";

import { CustomFlow } from "src/flows/CustomFlow.sol";
import { GoalFlowAllocationLedgerPipeline } from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { GoalFlowLedgerMode } from "src/library/GoalFlowLedgerMode.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CustomFlowRewardEscrowCheckpointTest is FlowTestBase {
    function setUp() public override {
        super.setUp();
    }

    function test_initialize_revertsWhenMultipleStrategiesConfigured() public {
        MockAllocationStrategy strategyA = new MockAllocationStrategy();
        strategyA.setUseAuxAsKey(true);
        MockAllocationStrategy strategyB = new MockAllocationStrategy();
        strategyB.setUseAuxAsKey(true);

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](2);
        strategies[0] = IAllocationStrategy(address(strategyA));
        strategies[1] = IAllocationStrategy(address(strategyB));

        address proxy = address(new ERC1967Proxy(address(flowImplementation), ""));

        vm.expectRevert(abi.encodeWithSelector(IFlow.FLOW_REQUIRES_SINGLE_STRATEGY.selector, 2));
        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
    }

    function test_initialize_revertsWhenPipelineHasNoCode() public {
        address invalidPipeline = address(0xF00D);
        _expectInitializeRevertWithPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            invalidPipeline,
            abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_PIPELINE.selector, invalidPipeline)
        );
    }

    function test_initialize_revertsWhenLedgerHasNoCode() public {
        address invalidLedger = address(0xBADC0DE);
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(invalidLedger);

        _expectInitializeRevertWithPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            address(pipeline),
            abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER.selector, invalidLedger)
        );
    }

    function test_initialize_revertsWhenLedgerTreasuryFlowDoesNotMatch() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        MockGoalTreasuryForCheckpoint treasury = new MockGoalTreasuryForCheckpoint(address(0xBEEF), address(stakeVault));
        MockBudgetStakeLedgerForCheckpoint ledger = new MockBudgetStakeLedgerForCheckpoint(address(treasury));
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        _expectInitializeRevertWithPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            address(pipeline),
            IFlow.INVALID_ALLOCATION_LEDGER_FLOW.selector
        );
    }

    function test_initialize_revertsWhenLedgerTreasuryStakeVaultMissing() public {
        address predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        MockGoalTreasuryForCheckpoint treasury = new MockGoalTreasuryForCheckpoint(predictedFlow, address(0));
        MockBudgetStakeLedgerForCheckpoint ledger = new MockBudgetStakeLedgerForCheckpoint(address(treasury));
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        _expectInitializeRevertWithPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            address(pipeline),
            IFlow.INVALID_ALLOCATION_LEDGER_STAKE_VAULT.selector
        );
    }

    function test_initialize_allowsLedgerTreasuryBootstrapWhenFlowAndStakeVaultUnset() public {
        MockGoalTreasuryForCheckpoint treasury = new MockGoalTreasuryForCheckpoint(address(0), address(0));
        MockBudgetStakeLedgerForCheckpoint ledger = new MockBudgetStakeLedgerForCheckpoint(address(treasury));
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        CustomFlow deployed =
            _deployFlowWithStrategiesAndPipeline(_singleStrategyArray(IAllocationStrategy(address(strategy))), address(pipeline));
        assertEq(deployed.allocationPipeline(), address(pipeline));
    }

    function test_initialize_revertsWhenLedgerTreasuryHasZeroFlowButConfiguredStakeVault() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        MockGoalTreasuryForCheckpoint treasury = new MockGoalTreasuryForCheckpoint(address(0), address(stakeVault));
        MockBudgetStakeLedgerForCheckpoint ledger = new MockBudgetStakeLedgerForCheckpoint(address(treasury));
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        _expectInitializeRevertWithPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            address(pipeline),
            IFlow.INVALID_ALLOCATION_LEDGER_FLOW.selector
        );
    }

    function test_initialize_revertsWhenStrategyStakeVaultDoesNotMatch() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();

        _expectInitializeRevertWithDefaultStrategyAndPredictedLedgerPipeline(
            address(stakeVault), GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector
        );
    }

    function test_initialize_succeedsWhenStrategyStakeVaultMatches() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        strategy.setStakeVault(address(stakeVault));

        (CustomFlow deployed,) = _deployDefaultFlowWithLedgerPipeline(address(stakeVault));
        assertTrue(deployed.allocationPipeline() != address(0));
    }

    function test_initialize_revertsWhenConfiguredLedgerTreasuryIsNotDeployed() public {
        address undeployedTreasury = address(0x12345);
        MockBudgetStakeLedgerForCheckpoint ledger = new MockBudgetStakeLedgerForCheckpoint(undeployedTreasury);
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));

        _expectInitializeRevertWithPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            address(pipeline),
            IFlow.INVALID_ALLOCATION_LEDGER_GOAL_TREASURY.selector
        );
    }

    function test_initialize_revertsWhenStrategyAccountResolverMissing() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        MockResolverMissingStrategy missingResolverStrategy = new MockResolverMissingStrategy(address(stakeVault));
        IAllocationStrategy[] memory strategies = _singleStrategyArray(IAllocationStrategy(address(missingResolverStrategy)));

        _expectInitializeRevertWithPredictedLedgerPipeline(
            strategies,
            address(stakeVault),
            GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER.selector
        );
    }

    function test_initialize_revertsWhenStrategyAccountResolverReturnsZero() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        MockResolverZeroStrategy zeroResolverStrategy = new MockResolverZeroStrategy(address(stakeVault));
        IAllocationStrategy[] memory strategies = _singleStrategyArray(IAllocationStrategy(address(zeroResolverStrategy)));

        _expectInitializeRevertWithPredictedLedgerPipeline(
            strategies,
            address(stakeVault),
            GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER.selector
        );
    }

    function test_initialize_revertsWhenStrategyAllocationKeyRequiresAux() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        MockAuxRequiredStrategy auxRequiredStrategy = new MockAuxRequiredStrategy(address(stakeVault));
        IAllocationStrategy[] memory strategies = _singleStrategyArray(IAllocationStrategy(address(auxRequiredStrategy)));

        _expectInitializeRevertWithPredictedLedgerPipeline(
            strategies,
            address(stakeVault),
            GoalFlowLedgerMode.INVALID_ALLOCATION_LEDGER_STRATEGY.selector
        );
    }

    function test_allocate_succeedsWhenPipelineConfiguredWithoutLedger() public {
        uint256 allocatorKey = _allocatorKey();
        strategy.setWeight(allocatorKey, 1e18);
        strategy.setCanAllocate(allocatorKey, allocator, true);

        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(0));
        CustomFlow targetFlow =
            _deployFlowWithStrategiesAndPipeline(_singleStrategyArray(IAllocationStrategy(address(strategy))), address(pipeline));

        bytes32 recipientId = bytes32(uint256(1));
        vm.prank(manager);
        targetFlow.addRecipient(recipientId, address(0xBEEF), recipientMetadata);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(allocatorKey);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(targetFlow), recipientIds, scaled);

        assertEq(targetFlow.allocationPipeline(), address(pipeline));
        assertTrue(targetFlow.getAllocationCommitment(address(strategy), allocatorKey) != bytes32(0));
    }

    function test_allocate_revertsWhenLedgerTreasuryRemainsBootstrapUninitialized() public {
        MockGoalTreasuryForCheckpoint treasury = new MockGoalTreasuryForCheckpoint(address(0), address(0));
        MockBudgetStakeLedgerForCheckpoint ledger = new MockBudgetStakeLedgerForCheckpoint(address(treasury));
        GoalFlowAllocationLedgerPipeline pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));
        CustomFlow targetFlow =
            _deployFlowWithStrategiesAndPipeline(_singleStrategyArray(IAllocationStrategy(address(strategy))), address(pipeline));

        uint256 allocatorKey = _allocatorKey();
        strategy.setWeight(allocatorKey, 1e18);
        strategy.setCanAllocate(allocatorKey, allocator, true);

        bytes32 recipientId = bytes32(uint256(1));
        vm.prank(manager);
        targetFlow.addRecipient(recipientId, address(0xBEEF), recipientMetadata);

        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        bytes[][] memory allocationData = _defaultAllocationDataForKey(allocatorKey);

        _allocateWithPrevStateForStrategyExpectRevert(
            allocator,
            allocationData,
            address(strategy),
            address(targetFlow),
            recipientIds,
            scaled,
            abi.encodeWithSelector(IFlow.INVALID_ALLOCATION_LEDGER_FLOW.selector, address(targetFlow), address(0))
        );
    }

    function test_allocate_revertsWhenStakeVaultMissingGoalResolved() public {
        MockStakeVaultMissingGoalResolvedForCheckpoint stakeVault = new MockStakeVaultMissingGoalResolvedForCheckpoint();

        strategy.setStakeVault(address(stakeVault));
        uint256 allocatorKey = _allocatorKey();
        strategy.setWeight(allocatorKey, 1e18);
        strategy.setCanAllocate(allocatorKey, allocator, true);

        (CustomFlow targetFlow,) = _deployDefaultFlowWithLedgerPipeline(address(stakeVault));

        bytes32 recipientId = bytes32(uint256(1));
        vm.prank(manager);
        targetFlow.addRecipient(recipientId, address(0xBEEF), recipientMetadata);

        bytes[][] memory allocationData = _defaultAllocationDataForKey(allocatorKey);
        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;

        vm.expectRevert();
        vm.prank(allocator);
        targetFlow.allocate(recipientIds, scaled);
    }

    function test_allocate_checkpointsResolverDerivedAccountWhenLedgerEnabled() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        strategy.setStakeVault(address(stakeVault));

        (CustomFlow targetFlow, MockBudgetStakeLedgerForCheckpoint ledger) = _deployDefaultFlowWithLedgerPipeline(
            address(stakeVault)
        );

        address principal = allocator;
        uint256 key = _allocatorKey();
        uint256 committedWeight = 1e18;
        uint256 stakeVaultWeight = 77e18;

        strategy.setWeight(key, committedWeight);
        strategy.setCanAllocate(key, allocator, true);
        stakeVault.setWeight(principal, stakeVaultWeight);

        bytes32 recipientId = bytes32(uint256(1));
        vm.prank(manager);
        targetFlow.addRecipient(recipientId, address(0xBEEF), recipientMetadata);

        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);

        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(targetFlow), recipientIds, scaled);

        assertEq(ledger.lastCheckpointAccount(), principal);
        assertEq(ledger.lastCheckpointNewWeight(), committedWeight);
    }

    function test_allocate_checkpointsCachedPreviousWeightWithCanonicalPrevState() public {
        MockStakeVaultForCheckpoint stakeVault = new MockStakeVaultForCheckpoint();
        strategy.setStakeVault(address(stakeVault));

        (CustomFlow targetFlow, MockBudgetStakeLedgerForCheckpoint ledger) = _deployDefaultFlowWithLedgerPipeline(
            address(stakeVault)
        );

        address principal = allocator;
        uint256 key = _allocatorKey();
        uint256 weightA = 77e18;
        uint256 weightB = 33e18;

        strategy.setWeight(key, weightA);
        strategy.setCanAllocate(key, allocator, true);
        stakeVault.setWeight(principal, weightA);

        bytes32 recipientId = bytes32(uint256(1));
        vm.prank(manager);
        targetFlow.addRecipient(recipientId, address(0xBEEF), recipientMetadata);

        bytes32[] memory recipientIds = new bytes32[](1);
        recipientIds[0] = recipientId;
        uint32[] memory scaled = new uint32[](1);
        scaled[0] = 1_000_000;
        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);

        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(targetFlow), recipientIds, scaled);

        strategy.setWeight(key, weightB);
        stakeVault.setWeight(principal, weightB);

        _allocateWithPrevStateForStrategy(allocator, allocationData, address(strategy), address(targetFlow), recipientIds, scaled);

        assertEq(ledger.lastCheckpointAccount(), principal);
        assertEq(ledger.lastCheckpointPrevWeight(), weightA);
        assertEq(ledger.lastCheckpointNewWeight(), weightB);
    }

    function test_setAllocationPipelineSelector_notExposed() public {
        vm.prank(owner);
        _assertCallFails(address(flow), abi.encodeWithSignature("setAllocationPipeline(address)", address(0x111)));
    }

    function _singleStrategyArray(IAllocationStrategy strategyAddress)
        internal
        pure
        returns (IAllocationStrategy[] memory strategies)
    {
        strategies = new IAllocationStrategy[](1);
        strategies[0] = strategyAddress;
    }

    function _expectInitializeRevertWithPipeline(
        IAllocationStrategy[] memory strategies,
        address allocationPipeline,
        bytes memory revertData
    ) internal {
        address proxy = address(new ERC1967Proxy(address(flowImplementation), ""));
        vm.expectRevert(revertData);
        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            allocationPipeline,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
    }

    function _expectInitializeRevertWithPipeline(
        IAllocationStrategy[] memory strategies,
        address allocationPipeline,
        bytes4
    ) internal {
        address proxy = address(new ERC1967Proxy(address(flowImplementation), ""));
        vm.expectRevert();
        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            allocationPipeline,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
    }

    function _expectInitializeRevertWithPredictedLedgerPipeline(
        IAllocationStrategy[] memory strategies,
        address stakeVault,
        bytes4 revertSelector
    ) internal {
        (, GoalFlowAllocationLedgerPipeline pipeline,) = _prepareLedgerPipelineForPredictedFlow(stakeVault);
        _expectInitializeRevertWithPipeline(strategies, address(pipeline), revertSelector);
    }

    function _expectInitializeRevertWithDefaultStrategyAndPredictedLedgerPipeline(
        address stakeVault,
        bytes4 revertSelector
    ) internal {
        _expectInitializeRevertWithPredictedLedgerPipeline(
            _singleStrategyArray(IAllocationStrategy(address(strategy))),
            stakeVault,
            revertSelector
        );
    }

    function _deployFlowWithStrategiesAndPipeline(
        IAllocationStrategy[] memory strategies,
        address allocationPipeline
    ) internal returns (CustomFlow deployed) {
        address proxy = address(new ERC1967Proxy(address(flowImplementation), ""));

        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            allocationPipeline,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        deployed = CustomFlow(proxy);

        vm.prank(owner);
        superToken.transfer(address(deployed), 500_000e18);
    }

    function _prepareLedgerPipelineForPredictedFlow(
        address stakeVault
    )
        internal
        returns (
            address predictedFlow,
            GoalFlowAllocationLedgerPipeline pipeline,
            MockBudgetStakeLedgerForCheckpoint ledger
        )
    {
        predictedFlow = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        MockGoalTreasuryForCheckpoint treasury = new MockGoalTreasuryForCheckpoint(predictedFlow, stakeVault);
        ledger = new MockBudgetStakeLedgerForCheckpoint(address(treasury));
        pipeline = new GoalFlowAllocationLedgerPipeline(address(ledger));
    }

    function _deployDefaultFlowWithLedgerPipeline(
        address stakeVault
    ) internal returns (CustomFlow deployed, MockBudgetStakeLedgerForCheckpoint ledger) {
        (address predictedFlow, GoalFlowAllocationLedgerPipeline pipeline, MockBudgetStakeLedgerForCheckpoint preparedLedger)
        = _prepareLedgerPipelineForPredictedFlow(stakeVault);

        deployed =
            _deployFlowWithStrategiesAndPipeline(_singleStrategyArray(IAllocationStrategy(address(strategy))), address(pipeline));
        assertEq(address(deployed), predictedFlow);
        ledger = preparedLedger;
    }
}
contract MockBudgetStakeLedgerForCheckpoint {
    address public goalTreasury;
    address public lastCheckpointAccount;
    uint256 public lastCheckpointPrevWeight;
    uint256 public lastCheckpointNewWeight;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }

    function checkpointAllocation(
        address account,
        uint256 prevWeight,
        bytes32[] calldata,
        uint32[] calldata,
        uint256 newWeight,
        bytes32[] calldata,
        uint32[] calldata
    ) external {
        lastCheckpointAccount = account;
        lastCheckpointPrevWeight = prevWeight;
        lastCheckpointNewWeight = newWeight;
    }

    function budgetForRecipient(
        bytes32
    ) external pure returns (address) {
        return address(0);
    }
}

contract MockGoalTreasuryForCheckpoint {
    address public flow;
    address public stakeVault;

    constructor(address flow_, address stakeVault_) {
        flow = flow_;
        stakeVault = stakeVault_;
    }
}

contract MockStakeVaultForCheckpoint {
    mapping(address => uint256) internal _weightOf;
    bool internal _goalResolved;

    function setWeight(address account, uint256 weight) external {
        _weightOf[account] = weight;
    }

    function setGoalResolved(bool resolved_) external {
        _goalResolved = resolved_;
    }

    function goalResolved() external view returns (bool) {
        return _goalResolved;
    }

    function weightOf(
        address account
    ) external view returns (uint256) {
        return _weightOf[account];
    }
}

contract MockStakeVaultMissingGoalResolvedForCheckpoint {
    function weightOf(
        address
    ) external pure returns (uint256) {
        return 0;
    }
}

contract MockResolverMissingStrategy is IAllocationStrategy {
    address public stakeVault;

    constructor(address stakeVault_) {
        stakeVault = stakeVault_;
    }

    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function currentWeight(
        uint256
    ) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(uint256, address) external pure returns (bool) {
        return true;
    }

    function canAccountAllocate(
        address
    ) external pure returns (bool) {
        return true;
    }

    function accountAllocationWeight(
        address
    ) external pure returns (uint256) {
        return 1;
    }

    function strategyKey() external pure returns (string memory) {
        return "missing-resolver";
    }
}

contract MockResolverZeroStrategy is IAllocationStrategy {
    address public stakeVault;

    constructor(address stakeVault_) {
        stakeVault = stakeVault_;
    }

    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(
        uint256
    ) external pure returns (address) {
        return address(0);
    }

    function currentWeight(
        uint256
    ) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(uint256, address) external pure returns (bool) {
        return true;
    }

    function canAccountAllocate(
        address
    ) external pure returns (bool) {
        return true;
    }

    function accountAllocationWeight(
        address
    ) external pure returns (uint256) {
        return 1;
    }

    function strategyKey() external pure returns (string memory) {
        return "zero-resolver";
    }
}

contract MockAuxRequiredStrategy is IAllocationStrategy {
    address public stakeVault;

    constructor(address stakeVault_) {
        stakeVault = stakeVault_;
    }

    function allocationKey(address caller, bytes calldata aux) external pure returns (uint256) {
        if (aux.length == 0) revert("AUX_REQUIRED");
        return uint256(uint160(caller));
    }

    function accountForAllocationKey(
        uint256 key
    ) external pure returns (address) {
        return address(uint160(key));
    }

    function currentWeight(
        uint256
    ) external pure returns (uint256) {
        return 1;
    }

    function canAllocate(uint256, address) external pure returns (bool) {
        return true;
    }

    function canAccountAllocate(
        address
    ) external pure returns (bool) {
        return true;
    }

    function accountAllocationWeight(
        address
    ) external pure returns (uint256) {
        return 1;
    }

    function strategyKey() external pure returns (string memory) {
        return "aux-required";
    }
}
