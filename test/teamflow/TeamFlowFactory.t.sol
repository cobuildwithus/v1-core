// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {FlowSuperfluidFrameworkDeployer} from "test/utils/FlowSuperfluidFrameworkDeployer.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";

import {TeamFlow} from "src/teamflow/TeamFlow.sol";
import {TeamFlowFactory} from "src/teamflow/TeamFlowFactory.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {IAllocationMechanismFactory} from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {ERC1820RegistryCompiled} from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import {TestToken} from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import {SuperToken} from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";

contract TeamFlowBudgetTreasuryMock {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract TeamFlowFactoryTest is Test {
    bytes32 internal constant MECHANISM_ID = keccak256("teamflow-mechanism");
    uint256 internal constant INITIAL_CHILD_BALANCE = 1_000_000e18;

    FlowSuperfluidFrameworkDeployer internal sfDeployer;
    TestToken internal underlyingToken;
    SuperToken internal superToken;

    CustomFlow internal customFlowImplementation;
    MockAllocationStrategy internal budgetFlowStrategy;
    CustomFlow internal budgetFlow;
    TeamFlowFactory internal factory;
    TeamFlowBudgetTreasuryMock internal budgetTreasury;

    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        sfDeployer = new FlowSuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();

        (TestToken underlyingToken_, SuperToken superToken_) =
            sfDeployer.deployWrapperSuperToken("MockUSD", "mUSD", 18, type(uint256).max, address(this));
        underlyingToken = underlyingToken_;
        superToken = superToken_;

        customFlowImplementation = new CustomFlow();
        budgetFlowStrategy = new MockAllocationStrategy();
        budgetFlow = _deployBudgetFlow();

        factory = new TeamFlowFactory(address(new TeamFlow()), address(customFlowImplementation));
        budgetTreasury = new TeamFlowBudgetTreasuryMock(address(budgetFlow));

        _mintAndUpgrade(address(this), 5_000_000e18);
    }

    function test_deployForBudget_initializesTeamFlowAndChildFlowAuthorities() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(100, 150)));

        TeamFlow teamFlow = TeamFlow(deployed.mechanism);
        CustomFlow childFlow = CustomFlow(deployed.payoutRecipient);
        IAllocationStrategy[] memory strategies = childFlow.strategies();

        assertEq(deployed.auxiliary, deployed.payoutRecipient);
        assertEq(deployed.arbitrator, address(0));
        assertEq(teamFlow.manager(), manager);
        assertEq(address(teamFlow.childFlow()), address(childFlow));
        assertEq(teamFlow.perSeatRate(), 100);
        assertEq(teamFlow.maxTotalRate(), 150);
        assertEq(address(childFlow.superToken()), address(superToken));
        assertEq(childFlow.recipientAdmin(), address(teamFlow));
        assertEq(childFlow.flowOperator(), address(teamFlow));
        assertEq(childFlow.sweeper(), address(teamFlow));
        assertEq(childFlow.parent(), address(0));
        assertEq(childFlow.managerRewardPool(), address(0));
        assertEq(childFlow.allocationPipeline(), address(0));
        assertEq(strategies.length, 1);
        assertEq(address(strategies[0]), address(teamFlow));
    }

    function test_deployForBudget_revertsWhenBudgetTreasuryHasNoCode() public {
        vm.expectRevert(TeamFlowFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.deployForBudget(MECHANISM_ID, makeAddr("no-code-budget"), abi.encode(_defaultConfig(100, 150)));
    }

    function test_deployForBudget_revertsWhenManagerIsZero() public {
        TeamFlowFactory.AllocationMechanismConfig memory cfg = _defaultConfig(100, 150);
        cfg.manager = address(0);

        vm.expectRevert(TeamFlowFactory.ADDRESS_ZERO.selector);
        factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(cfg));
    }

    function test_teamFlow_syncsEqualSplit_capsRate_andHardRemovesMembers() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(100, 150)));

        TeamFlow teamFlow = TeamFlow(deployed.mechanism);
        CustomFlow childFlow = CustomFlow(deployed.payoutRecipient);
        uint256 strategyKey = uint256(uint160(address(teamFlow)));

        vm.prank(manager);
        bytes32 aliceRecipientId = teamFlow.addMember(alice, _recipientMetadata("Alice"));

        assertEq(teamFlow.activeMemberCount(), 1);
        assertEq(childFlow.targetOutflowRate(), 0);
        assertGt(childFlow.distributionPool().getUnits(alice), 0);

        superToken.transfer(address(childFlow), INITIAL_CHILD_BALANCE);

        vm.prank(outsider);
        int96 appliedRate = teamFlow.sync();
        assertEq(appliedRate, int96(100));
        assertEq(childFlow.targetOutflowRate(), int96(100));
        assertTrue(childFlow.getAllocationCommitment(address(teamFlow), strategyKey) != bytes32(0));

        vm.prank(manager);
        bytes32 bobRecipientId = teamFlow.addMember(bob, _recipientMetadata("Bob"));

        assertEq(teamFlow.activeMemberCount(), 2);
        assertEq(childFlow.targetOutflowRate(), int96(150));
        assertEq(childFlow.distributionPool().getUnits(alice), childFlow.distributionPool().getUnits(bob));
        assertTrue(bobRecipientId != bytes32(0));

        vm.prank(manager);
        bytes32 removedAliceRecipientId = teamFlow.removeMember(alice);

        FlowTypes.FlowRecipient memory removedAlice = childFlow.getRecipientById(aliceRecipientId);
        assertEq(removedAliceRecipientId, aliceRecipientId);
        assertTrue(removedAlice.isRemoved);
        assertEq(childFlow.distributionPool().getUnits(alice), 0);
        assertEq(teamFlow.activeMemberCount(), 1);
        assertEq(childFlow.targetOutflowRate(), int96(100));

        vm.prank(manager);
        bytes32 readdedAliceRecipientId = teamFlow.addMember(alice, _recipientMetadata("Alice Again"));

        assertTrue(readdedAliceRecipientId != aliceRecipientId);
        assertEq(teamFlow.memberRecipientId(alice), readdedAliceRecipientId);
        assertEq(childFlow.recipientCount(), 3);
        assertEq(childFlow.targetOutflowRate(), int96(150));

        vm.prank(manager);
        teamFlow.removeMember(bob);
        assertEq(childFlow.targetOutflowRate(), int96(100));

        vm.prank(manager);
        teamFlow.removeMember(alice);

        FlowTypes.FlowRecipient memory removedBob = childFlow.getRecipientById(bobRecipientId);
        FlowTypes.FlowRecipient memory removedReaddedAlice = childFlow.getRecipientById(readdedAliceRecipientId);

        assertTrue(removedBob.isRemoved);
        assertTrue(removedReaddedAlice.isRemoved);
        assertEq(teamFlow.activeMemberCount(), 0);
        assertEq(childFlow.targetOutflowRate(), 0);
        assertEq(childFlow.distributionPool().getUnits(alice), 0);
        assertEq(childFlow.distributionPool().getUnits(bob), 0);
        assertEq(teamFlow.accountAllocationWeight(address(teamFlow)), 0);
    }

    function test_teamFlow_setRateConfig_recomputesChildFlowTargetRate() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(50, 200)));

        TeamFlow teamFlow = TeamFlow(deployed.mechanism);
        CustomFlow childFlow = CustomFlow(deployed.payoutRecipient);

        superToken.transfer(address(childFlow), INITIAL_CHILD_BALANCE);

        vm.startPrank(manager);
        teamFlow.addMember(alice, _recipientMetadata("Alice"));
        teamFlow.addMember(bob, _recipientMetadata("Bob"));
        assertEq(childFlow.targetOutflowRate(), int96(100));

        teamFlow.setRateConfig(80, 150);
        assertEq(teamFlow.perSeatRate(), 80);
        assertEq(teamFlow.maxTotalRate(), 150);
        assertEq(childFlow.targetOutflowRate(), int96(150));

        teamFlow.setRateConfig(20, 0);
        vm.stopPrank();

        assertEq(teamFlow.perSeatRate(), 20);
        assertEq(teamFlow.maxTotalRate(), 0);
        assertEq(childFlow.targetOutflowRate(), int96(40));
    }

    function _deployBudgetFlow() internal returns (CustomFlow flow) {
        address clone = Clones.clone(address(customFlowImplementation));
        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(budgetFlowStrategy));

        ICustomFlow(clone).initialize(
            address(superToken),
            address(customFlowImplementation),
            address(this),
            address(this),
            address(this),
            address(0),
            address(0),
            address(0),
            IFlow.FlowParams({managerRewardPoolFlowRatePpm: 0}),
            _recipientMetadata("Budget Flow"),
            strategies
        );

        flow = CustomFlow(clone);
    }

    function _mintAndUpgrade(address to, uint256 amount) internal {
        vm.startPrank(to);
        underlyingToken.mint(to, amount);
        underlyingToken.approve(address(superToken), amount);
        ISuperToken(address(superToken)).upgrade(amount);
        vm.stopPrank();
    }

    function _defaultConfig(
        uint256 perSeatRate,
        uint256 maxTotalRate
    ) internal view returns (TeamFlowFactory.AllocationMechanismConfig memory cfg) {
        cfg = TeamFlowFactory.AllocationMechanismConfig({
            manager: manager,
            perSeatRate: perSeatRate,
            maxTotalRate: maxTotalRate,
            flowMetadata: _recipientMetadata("Team Flow")
        });
    }

    function _recipientMetadata(string memory title) internal pure returns (FlowTypes.RecipientMetadata memory metadata) {
        metadata = FlowTypes.RecipientMetadata({
            title: title,
            description: "TeamFlow test metadata",
            image: "ipfs://teamflow",
            tagline: "teamflow",
            url: "https://teamflow.test"
        });
    }
}
