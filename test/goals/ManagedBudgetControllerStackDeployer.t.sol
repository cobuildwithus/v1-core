// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {BudgetSingleAllocatorStrategy} from "src/allocation-strategies/BudgetSingleAllocatorStrategy.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {ManagedBudgetControllerStackDeployer} from "src/goals/ManagedBudgetControllerStackDeployer.sol";
import {NullPremiumEscrow} from "src/goals/NullPremiumEscrow.sol";
import {IManagedBudgetController} from "src/interfaces/IManagedBudgetController.sol";
import {IManagedBudgetControllerStackDeployer} from "src/interfaces/IManagedBudgetControllerStackDeployer.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

contract ManagedBudgetControllerStackDeployerSpendPolicyMock is ISpendPolicy {
    function targetFlowRate(SpendContext calldata) external pure returns (int96 flowRate) {
        return flowRate;
    }

    function syncMode() external pure returns (SyncMode mode) {
        return SyncMode.Capped;
    }
}

contract ManagedBudgetControllerStackDeployerParentFlowMock {
    function getMemberFlowRate(address) external pure returns (int96 flowRate) {
        return flowRate;
    }
}

contract ManagedBudgetControllerStackDeployerChildFlowMock {
    address public immutable superToken;
    address public immutable parent;
    address public flowOperator;
    address public sweeper;
    int96 public targetOutflowRate;

    constructor(address superToken_, address parent_) {
        superToken = superToken_;
        parent = parent_;
    }

    function setFlowOperator(address flowOperator_) external {
        flowOperator = flowOperator_;
    }

    function setSweeper(address sweeper_) external {
        sweeper = sweeper_;
    }
}

contract ManagedBudgetControllerStackDeployerTest is Test {
    BudgetTreasury internal budgetTreasuryImplementation;
    NullPremiumEscrow internal premiumEscrowImplementation;
    ManagedBudgetControllerStackDeployer internal deployer;

    address internal budgetAllocationLedger = address(new ManagedBudgetControllerStackDeployerDummyContract());
    address internal goalFlow = address(new ManagedBudgetControllerStackDeployerDummyContract());
    address internal childFlow = address(new ManagedBudgetControllerStackDeployerDummyContract());
    address internal successResolver = address(new ManagedBudgetControllerStackDeployerDummyContract());
    address internal spendPolicy = address(new ManagedBudgetControllerStackDeployerSpendPolicyMock());

    function setUp() public {
        budgetTreasuryImplementation = new BudgetTreasury();
        premiumEscrowImplementation = new NullPremiumEscrow();
        deployer = new ManagedBudgetControllerStackDeployer(
            address(budgetTreasuryImplementation), address(premiumEscrowImplementation)
        );
    }

    function test_constructor_revertsOnZeroBudgetTreasuryImplementation() public {
        vm.expectRevert(IManagedBudgetControllerStackDeployer.ADDRESS_ZERO.selector);
        new ManagedBudgetControllerStackDeployer(address(0), address(premiumEscrowImplementation));
    }

    function test_constructor_revertsOnNonContractBudgetTreasuryImplementation() public {
        vm.expectRevert(
            abi.encodeWithSelector(ManagedBudgetControllerStackDeployer.NOT_A_CONTRACT.selector, address(0xBEEF))
        );
        new ManagedBudgetControllerStackDeployer(address(0xBEEF), address(premiumEscrowImplementation));
    }

    function test_constructor_revertsOnZeroPremiumEscrowImplementation() public {
        vm.expectRevert(IManagedBudgetControllerStackDeployer.ADDRESS_ZERO.selector);
        new ManagedBudgetControllerStackDeployer(address(budgetTreasuryImplementation), address(0));
    }

    function test_constructor_revertsOnNonContractPremiumEscrowImplementation() public {
        vm.expectRevert(
            abi.encodeWithSelector(ManagedBudgetControllerStackDeployer.NOT_A_CONTRACT.selector, address(0xBEEF))
        );
        new ManagedBudgetControllerStackDeployer(address(budgetTreasuryImplementation), address(0xBEEF));
    }

    function test_prepareBudgetStack_deploysScopedStrategyAndClonesImplementations() public {
        IManagedBudgetControllerStackDeployer.PreparationResult memory result =
            deployer.prepareBudgetStack(address(this));

        assertTrue(result.strategy != address(0));
        assertTrue(result.budgetTreasury != address(0));
        assertTrue(result.premiumEscrow != address(0));
        assertTrue(result.budgetTreasury != address(budgetTreasuryImplementation));
        assertTrue(result.premiumEscrow != address(premiumEscrowImplementation));

        BudgetSingleAllocatorStrategy strategy = BudgetSingleAllocatorStrategy(result.strategy);
        assertEq(strategy.budgetTreasury(), result.budgetTreasury);
        assertEq(strategy.allocator(), address(this));
    }

    function test_prepareBudgetStack_revertsWhenCallerIsNotController() public {
        address controller = address(new ManagedBudgetControllerStackDeployerDummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagedBudgetControllerStackDeployer.ONLY_CONTROLLER.selector, controller, address(this)
            )
        );
        deployer.prepareBudgetStack(controller);
    }

    function test_prepareBudgetStack_revertsOnZeroController() public {
        vm.expectRevert(IManagedBudgetControllerStackDeployer.ADDRESS_ZERO.selector);
        deployer.prepareBudgetStack(address(0));
    }

    function test_prepareBudgetStack_revertsOnNonContractController() public {
        address controller = makeAddr("controller");
        vm.expectRevert(
            abi.encodeWithSelector(ManagedBudgetControllerStackDeployer.NOT_A_CONTRACT.selector, controller)
        );
        vm.prank(controller);
        deployer.prepareBudgetStack(controller);
    }

    function test_deployBudgetTreasury_allowsZeroManagedLedgerAndRouterForNullEscrow() public {
        IManagedBudgetControllerStackDeployer.PreparationResult memory prepared =
            deployer.prepareBudgetStack(address(this));
        ManagedBudgetControllerStackDeployerParentFlowMock parentFlow =
            new ManagedBudgetControllerStackDeployerParentFlowMock();
        ManagedBudgetControllerStackDeployerChildFlowMock budgetFlow =
            new ManagedBudgetControllerStackDeployerChildFlowMock(
                address(new ManagedBudgetControllerStackDeployerDummyContract()), address(parentFlow)
            );
        budgetFlow.setFlowOperator(prepared.budgetTreasury);
        budgetFlow.setSweeper(prepared.budgetTreasury);

        address deployedBudgetTreasury = deployer.deployBudgetTreasury(
            address(this),
            prepared.budgetTreasury,
            prepared.premiumEscrow,
            address(budgetFlow),
            address(0),
            goalFlow,
            address(0),
            0,
            _defaultBudgetConfig(),
            successResolver,
            spendPolicy,
            1 days,
            1 ether
        );

        assertEq(deployedBudgetTreasury, prepared.budgetTreasury);
        assertEq(NullPremiumEscrow(prepared.premiumEscrow).budgetTreasury(), prepared.budgetTreasury);
        assertEq(NullPremiumEscrow(prepared.premiumEscrow).budgetStakeLedger(), address(0));
        assertEq(NullPremiumEscrow(prepared.premiumEscrow).goalFlow(), goalFlow);
        assertEq(NullPremiumEscrow(prepared.premiumEscrow).underwriterSlasherRouter(), address(0));
        assertEq(NullPremiumEscrow(prepared.premiumEscrow).budgetSlashPpm(), 0);
    }

    function test_deployBudgetTreasury_revertsWhenCallerIsNotController() public {
        address controller = address(new ManagedBudgetControllerStackDeployerDummyContract());

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagedBudgetControllerStackDeployer.ONLY_CONTROLLER.selector, controller, address(this)
            )
        );
        deployer.deployBudgetTreasury(
            controller,
            address(1),
            address(2),
            address(3),
            address(4),
            address(5),
            address(6),
            0,
            _defaultBudgetConfig(),
            address(7),
            address(8),
            1 days,
            1 ether
        );
    }

    function _defaultBudgetConfig() internal pure returns (IManagedBudgetController.BudgetConfig memory config) {
        config.metadata = FlowTypes.RecipientMetadata({
            title: "Budget",
            description: "Budget description",
            image: "ipfs://budget",
            tagline: "managed",
            url: "https://managed.test"
        });
        config.fundingDeadline = 1;
        config.executionDuration = 1;
        config.activationThreshold = 1;
        config.runwayCap = 1;
        config.successOracleSpecHash = bytes32(uint256(1));
        config.successAssertionPolicyHash = bytes32(uint256(2));
    }
}

contract ManagedBudgetControllerStackDeployerDummyContract {}
