// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { FlowSuperfluidFrameworkDeployer } from "test/utils/FlowSuperfluidFrameworkDeployer.sol";
import { MockAllocationStrategy } from "test/mocks/MockAllocationStrategy.sol";

import { TeamFlow } from "src/teamflow/TeamFlow.sol";
import { TeamFlowFactory } from "src/teamflow/TeamFlowFactory.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { IAllocationMechanismFactory } from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ERC1820RegistryCompiled } from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";

contract TeamFlowBudgetTreasuryMock {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract TeamFlowManagedFlowMock {
    address public superToken;

    constructor(address superToken_) {
        superToken = superToken_;
    }
}

contract TeamFlowFactoryTest is Test {
    bytes32 internal constant MECHANISM_ID = keccak256("teamflow-mechanism");
    uint128 internal constant DEFAULT_MEMBER_UNITS = 20;
    uint256 internal constant INITIAL_TEAM_BALANCE = 1_000_000e18;

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
    address internal carol = makeAddr("carol");
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

        factory = new TeamFlowFactory(address(new TeamFlow()));
        budgetTreasury = new TeamFlowBudgetTreasuryMock(address(budgetFlow));

        _mintAndUpgrade(address(this), 5_000_000e18);
    }

    function test_deployForBudget_initializesTeamFlowAsPayoutFlow() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(100, 150)));

        TeamFlow teamFlow = TeamFlow(deployed.mechanism);
        IAllocationStrategy[] memory strategies = teamFlow.strategies();

        assertEq(deployed.mechanism, deployed.payoutRecipient);
        assertEq(deployed.auxiliary, address(0));
        assertEq(deployed.arbitrator, address(0));
        assertEq(teamFlow.manager(), manager);
        assertEq(teamFlow.perSeatRate(), 100);
        assertEq(teamFlow.maxTotalRate(), 150);
        assertEq(address(teamFlow.superToken()), address(superToken));
        assertEq(teamFlow.flowImplementation(), factory.teamFlowImplementation());
        assertEq(teamFlow.recipientAdmin(), address(teamFlow));
        assertEq(teamFlow.flowOperator(), address(teamFlow));
        assertEq(teamFlow.sweeper(), address(teamFlow));
        assertEq(teamFlow.parent(), address(0));
        assertEq(teamFlow.managerRewardPool(), address(0));
        assertEq(teamFlow.allocationPipeline(), address(0));
        assertEq(strategies.length, 1);
        assertEq(address(strategies[0]), address(teamFlow));
    }

    function test_deployForBudget_revertsWhenBudgetTreasuryHasNoCode() public {
        vm.expectRevert(TeamFlowFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.deployForBudget(MECHANISM_ID, makeAddr("no-code-budget"), abi.encode(_defaultConfig(100, 150)));
    }

    function test_deployForBudget_revertsWhenBudgetTreasuryFlowHasNoCode() public {
        TeamFlowBudgetTreasuryMock invalidBudgetTreasury = new TeamFlowBudgetTreasuryMock(makeAddr("no-code-flow"));

        vm.expectRevert(TeamFlowFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.deployForBudget(MECHANISM_ID, address(invalidBudgetTreasury), abi.encode(_defaultConfig(100, 150)));
    }

    function test_deployForBudget_revertsWhenBudgetFlowSuperTokenHasNoCode() public {
        TeamFlowManagedFlowMock invalidBudgetFlow = new TeamFlowManagedFlowMock(makeAddr("no-code-super-token"));
        TeamFlowBudgetTreasuryMock invalidBudgetTreasury = new TeamFlowBudgetTreasuryMock(address(invalidBudgetFlow));

        vm.expectRevert(TeamFlowFactory.INVALID_BUDGET_CONTEXT.selector);
        factory.deployForBudget(MECHANISM_ID, address(invalidBudgetTreasury), abi.encode(_defaultConfig(100, 150)));
    }

    function test_deployForBudget_revertsWhenManagerIsZero() public {
        TeamFlowFactory.AllocationMechanismConfig memory cfg = _defaultConfig(100, 150);
        cfg.manager = address(0);

        vm.expectRevert(TeamFlowFactory.ADDRESS_ZERO.selector);
        factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(cfg));
    }

    function test_teamFlow_onlyManagerCanMutateSeatsAndRateConfig() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(100, 150)));

        TeamFlow teamFlow = TeamFlow(deployed.payoutRecipient);

        vm.expectRevert(TeamFlow.ONLY_MANAGER.selector);
        teamFlow.addMember(alice, _recipientMetadata("Alice"));

        vm.prank(manager);
        teamFlow.addMember(alice, _recipientMetadata("Alice"));

        vm.expectRevert(TeamFlow.ONLY_MANAGER.selector);
        teamFlow.removeMember(alice);

        vm.expectRevert(TeamFlow.ONLY_MANAGER.selector);
        teamFlow.setRateConfig(50, 75);

        assertEq(teamFlow.activeMemberCount(), 1);
        assertEq(teamFlow.perSeatRate(), 100);
        assertEq(teamFlow.maxTotalRate(), 150);
    }

    function test_teamFlow_revertsOnDuplicateInactiveAndNestedRecipientOperations() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(100, 150)));

        TeamFlow teamFlow = TeamFlow(deployed.payoutRecipient);

        vm.prank(manager);
        bytes32 aliceRecipientId = teamFlow.addMember(alice, _recipientMetadata("Alice"));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(TeamFlow.MEMBER_ALREADY_ACTIVE.selector, alice));
        teamFlow.addMember(alice, _recipientMetadata("Alice Again"));

        vm.prank(manager);
        bytes32 removedRecipientId = teamFlow.removeMember(alice);

        assertEq(removedRecipientId, aliceRecipientId);
        assertEq(teamFlow.memberRecipientId(alice), bytes32(0));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(TeamFlow.MEMBER_NOT_ACTIVE.selector, alice));
        teamFlow.removeMember(alice);

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(teamFlow));

        vm.prank(address(teamFlow));
        vm.expectRevert(IFlow.NESTED_FLOW_RECIPIENTS_DISABLED.selector);
        teamFlow.addFlowRecipient(
            keccak256("nested-team-seat"),
            _recipientMetadata("Nested Team Flow"),
            address(teamFlow),
            address(teamFlow),
            address(teamFlow),
            address(0),
            0,
            strategies
        );
    }

    function test_teamFlow_syncsExactSeatUnits_capsRate_andHardRemovesMembers() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(100, 150)));

        TeamFlow teamFlow = TeamFlow(deployed.payoutRecipient);

        vm.prank(manager);
        bytes32 aliceRecipientId = teamFlow.addMember(alice, _recipientMetadata("Alice"));

        assertEq(teamFlow.activeMemberCount(), 1);
        assertEq(teamFlow.targetOutflowRate(), 0);
        assertEq(teamFlow.distributionPool().getUnits(alice), DEFAULT_MEMBER_UNITS);

        superToken.transfer(address(teamFlow), INITIAL_TEAM_BALANCE);

        vm.prank(outsider);
        int96 appliedRate = teamFlow.sync();
        assertEq(appliedRate, int96(100));
        assertEq(teamFlow.targetOutflowRate(), int96(100));

        vm.startPrank(manager);
        bytes32 bobRecipientId = teamFlow.addMember(bob, _recipientMetadata("Bob"));
        bytes32 carolRecipientId = teamFlow.addMember(carol, _recipientMetadata("Carol"));
        vm.stopPrank();

        assertEq(teamFlow.activeMemberCount(), 3);
        assertEq(teamFlow.targetOutflowRate(), int96(150));
        assertEq(teamFlow.distributionPool().getUnits(alice), DEFAULT_MEMBER_UNITS);
        assertEq(teamFlow.distributionPool().getUnits(bob), DEFAULT_MEMBER_UNITS);
        assertEq(teamFlow.distributionPool().getUnits(carol), DEFAULT_MEMBER_UNITS);
        assertTrue(bobRecipientId != bytes32(0));
        assertTrue(carolRecipientId != bytes32(0));

        vm.prank(manager);
        bytes32 removedAliceRecipientId = teamFlow.removeMember(alice);

        FlowTypes.FlowRecipient memory removedAlice = teamFlow.getRecipientById(aliceRecipientId);
        assertEq(removedAliceRecipientId, aliceRecipientId);
        assertTrue(removedAlice.isRemoved);
        assertEq(teamFlow.distributionPool().getUnits(alice), 0);
        assertEq(teamFlow.activeMemberCount(), 2);
        assertEq(teamFlow.targetOutflowRate(), int96(150));

        vm.prank(manager);
        bytes32 readdedAliceRecipientId = teamFlow.addMember(alice, _recipientMetadata("Alice Again"));

        assertTrue(readdedAliceRecipientId != aliceRecipientId);
        assertEq(teamFlow.memberRecipientId(alice), readdedAliceRecipientId);
        assertEq(teamFlow.targetOutflowRate(), int96(150));
        assertEq(teamFlow.distributionPool().getUnits(alice), DEFAULT_MEMBER_UNITS);

        vm.startPrank(manager);
        teamFlow.removeMember(bob);
        teamFlow.removeMember(carol);
        teamFlow.removeMember(alice);
        vm.stopPrank();

        FlowTypes.FlowRecipient memory removedBob = teamFlow.getRecipientById(bobRecipientId);
        FlowTypes.FlowRecipient memory removedCarol = teamFlow.getRecipientById(carolRecipientId);
        FlowTypes.FlowRecipient memory removedReaddedAlice = teamFlow.getRecipientById(readdedAliceRecipientId);

        assertTrue(removedBob.isRemoved);
        assertTrue(removedCarol.isRemoved);
        assertTrue(removedReaddedAlice.isRemoved);
        assertEq(teamFlow.activeMemberCount(), 0);
        assertEq(teamFlow.targetOutflowRate(), 0);
        assertEq(teamFlow.distributionPool().getUnits(alice), 0);
        assertEq(teamFlow.distributionPool().getUnits(bob), 0);
        assertEq(teamFlow.distributionPool().getUnits(carol), 0);
        assertEq(teamFlow.accountAllocationWeight(address(teamFlow)), 0);
    }

    function test_teamFlow_setRateConfig_recomputesTargetRate() public {
        IAllocationMechanismFactory.DeployedMechanism memory deployed =
            factory.deployForBudget(MECHANISM_ID, address(budgetTreasury), abi.encode(_defaultConfig(50, 200)));

        TeamFlow teamFlow = TeamFlow(deployed.payoutRecipient);

        superToken.transfer(address(teamFlow), INITIAL_TEAM_BALANCE);

        vm.startPrank(manager);
        teamFlow.addMember(alice, _recipientMetadata("Alice"));
        teamFlow.addMember(bob, _recipientMetadata("Bob"));
        assertEq(teamFlow.targetOutflowRate(), int96(100));

        teamFlow.setRateConfig(80, 150);
        assertEq(teamFlow.perSeatRate(), 80);
        assertEq(teamFlow.maxTotalRate(), 150);
        assertEq(teamFlow.targetOutflowRate(), int96(150));

        teamFlow.setRateConfig(20, 0);
        vm.stopPrank();

        assertEq(teamFlow.perSeatRate(), 20);
        assertEq(teamFlow.maxTotalRate(), 0);
        assertEq(teamFlow.targetOutflowRate(), int96(40));
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
            IFlow.FlowParams({ managerRewardPoolFlowRatePpm: 0 }),
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
