// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {CommunityGoalRegistry} from "src/tcr/CommunityGoalRegistry.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {IGeneralizedTCRConfig} from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {RoundTestArbitrator} from "test/rounds/helpers/RoundTestMocks.sol";

contract CommunityGoalRegistryTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 77;
    uint256 internal constant GOAL_ID_ONE = 101;
    uint256 internal constant GOAL_ID_TWO = 202;
    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant CHALLENGE_PERIOD = 7 days;
    uint256 internal constant SUBMISSION_DEPOSIT = 1e18;
    uint32 internal constant SYSTEM_FLOOR_ONE = 120_000;
    uint32 internal constant SYSTEM_FLOOR_TWO = 30_000;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockVotesToken internal token;
    MockVotesToken internal otherToken;
    EscrowSubmissionDepositStrategy internal depositStrategy;
    RoundTestArbitrator internal arbitrator;
    CommunityGoalRegistryMockDirectory internal directory;
    CommunityGoalRegistryMockTerminal internal terminal;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CommunityGoalRegistry internal registry;

    CommunityGoalRegistryMockGoalTreasury internal goalTreasuryOne;
    CommunityGoalRegistryMockGoalTreasury internal goalTreasuryTwo;

    function setUp() public {
        token = new MockVotesToken("Goal Registry Votes", "GRV");
        otherToken = new MockVotesToken("Other Goal Registry Votes", "OGRV");
        depositStrategy = new EscrowSubmissionDepositStrategy(IERC20(address(token)));
        directory = new CommunityGoalRegistryMockDirectory();
        terminal = new CommunityGoalRegistryMockTerminal();
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));

        goalTreasuryOne = new CommunityGoalRegistryMockGoalTreasury(GOAL_ID_ONE);
        goalTreasuryTwo = new CommunityGoalRegistryMockGoalTreasury(GOAL_ID_TWO);
        goalDeploymentRegistry.registerGoal(GOAL_ID_ONE, address(goalTreasuryOne));
        goalDeploymentRegistry.registerGoal(GOAL_ID_TWO, address(goalTreasuryTwo));

        directory.setPrimaryTerminal(GOAL_ID_ONE, address(token), IJBTerminal(address(terminal)));
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(token), IJBTerminal(address(terminal)));

        CommunityGoalRegistry implementation = new CommunityGoalRegistry();
        registry = CommunityGoalRegistry(Clones.clone(address(implementation)));

        arbitrator = new RoundTestArbitrator(IVotes(address(token)), address(registry), 1, 1, 1, ARBITRATION_COST);

        registry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(arbitrator, SUBMISSION_DEPOSIT),
                directory: IJBDirectory(address(directory)),
                goalDeploymentRegistry: goalDeploymentRegistry,
                communityRevnetId: COMMUNITY_REVNET_ID,
                communityToken: address(token),
                owner: owner
            })
        );

        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);

        vm.prank(alice);
        token.approve(address(registry), type(uint256).max);
        vm.prank(bob);
        token.approve(address(registry), type(uint256).max);
    }

    function test_initialize_revertsWhenVotingTokenDiffersFromCommunityToken() public {
        CommunityGoalRegistry implementation = new CommunityGoalRegistry();
        CommunityGoalRegistry mismatchedRegistry = CommunityGoalRegistry(Clones.clone(address(implementation)));
        RoundTestArbitrator mismatchedArbitrator = new RoundTestArbitrator(
            IVotes(address(otherToken)), address(mismatchedRegistry), 1, 1, 1, ARBITRATION_COST
        );
        EscrowSubmissionDepositStrategy otherDepositStrategy =
            new EscrowSubmissionDepositStrategy(IERC20(address(otherToken)));

        vm.expectRevert(
            abi.encodeWithSelector(
                CommunityGoalRegistry.VOTING_TOKEN_MISMATCH.selector, address(token), address(otherToken)
            )
        );
        mismatchedRegistry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(
                    mismatchedArbitrator, SUBMISSION_DEPOSIT, IVotes(address(otherToken)), otherDepositStrategy
                ),
                directory: IJBDirectory(address(directory)),
                goalDeploymentRegistry: goalDeploymentRegistry,
                communityRevnetId: COMMUNITY_REVNET_ID,
                communityToken: address(token),
                owner: owner
            })
        );
    }

    function test_initialize_revertsWhenCommunityTokenHasNoCode_beforeVotingTokenMismatchCheck() public {
        address noCodeToken = makeAddr("no-code-token");
        CommunityGoalRegistry implementation = new CommunityGoalRegistry();
        CommunityGoalRegistry freshRegistry = CommunityGoalRegistry(Clones.clone(address(implementation)));
        RoundTestArbitrator freshArbitrator =
            new RoundTestArbitrator(IVotes(address(token)), address(freshRegistry), 1, 1, 1, ARBITRATION_COST);

        vm.expectRevert(abi.encodeWithSelector(CommunityGoalRegistry.NOT_A_CONTRACT.selector, noCodeToken));
        freshRegistry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(freshArbitrator, SUBMISSION_DEPOSIT),
                directory: IJBDirectory(address(directory)),
                goalDeploymentRegistry: goalDeploymentRegistry,
                communityRevnetId: COMMUNITY_REVNET_ID,
                communityToken: noCodeToken,
                owner: owner
            })
        );
    }

    function test_initialize_revertsWhenArbitratorTokenDiffersEvenIfVotingTokenMatchesCommunityToken() public {
        CommunityGoalRegistry implementation = new CommunityGoalRegistry();
        CommunityGoalRegistry freshRegistry = CommunityGoalRegistry(Clones.clone(address(implementation)));
        RoundTestArbitrator mismatchedArbitrator =
            new RoundTestArbitrator(IVotes(address(otherToken)), address(freshRegistry), 1, 1, 1, ARBITRATION_COST);

        vm.expectRevert(IGeneralizedTCR.ARBITRATOR_TOKEN_MISMATCH.selector);
        freshRegistry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(mismatchedArbitrator, SUBMISSION_DEPOSIT),
                directory: IJBDirectory(address(directory)),
                goalDeploymentRegistry: goalDeploymentRegistry,
                communityRevnetId: COMMUNITY_REVNET_ID,
                communityToken: address(token),
                owner: owner
            })
        );
    }

    function test_pinSystemGoal_marksGoalSelectable() public {
        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);

        assertTrue(registry.isListed(GOAL_ID_ONE));
        assertTrue(registry.isSelectable(GOAL_ID_ONE));
        assertEq(address(registry.goalDeploymentRegistry()), address(goalDeploymentRegistry));
        assertEq(registry.totalSystemFloorPpm(), SYSTEM_FLOOR_ONE);

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(GOAL_ID_ONE));
        assertEq(listing.metadataURI, "ipfs://system-goal");
        assertTrue(listing.isSystem);
        assertEq(listing.floorPpm, SYSTEM_FLOOR_ONE);
        assertFalse(listing.paused);
        assertTrue(listing.selectable);

        (uint256[] memory goalIds, uint32[] memory floorPpms) = registry.systemRoute();
        assertEq(goalIds.length, 1);
        assertEq(goalIds[0], GOAL_ID_ONE);
        assertEq(floorPpms.length, 1);
        assertEq(floorPpms[0], SYSTEM_FLOOR_ONE);
    }

    function test_setGoalPaused_togglesSystemGoalSelectability() public {
        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);

        vm.prank(owner);
        registry.setGoalPaused(GOAL_ID_ONE, true);
        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        vm.prank(owner);
        registry.setGoalPaused(GOAL_ID_ONE, false);
        assertTrue(registry.isSelectable(GOAL_ID_ONE));
    }

    function test_isSelectable_returnsFalseWhenPrimaryTerminalHasNoCode() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        address noCodeTerminal = makeAddr("no-code-terminal");
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(token), IJBTerminal(noCodeTerminal));

        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        uint256[] memory selectableGoalIds = registry.selectableGoalIds();
        assertEq(selectableGoalIds.length, 0);
    }

    function test_pinSystemGoal_revertsWhenPrimaryTerminalHasNoCode() public {
        address noCodeTerminal = makeAddr("no-code-terminal");
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(token), IJBTerminal(noCodeTerminal));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICommunityGoalRegistry.GOAL_TERMINAL_NOT_CONFIGURED.selector, GOAL_ID_ONE)
        );
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);
    }

    function test_pinSystemGoal_revertsWhenGoalAlreadyHasPendingTcrRequest() public {
        bytes memory item = _goalItem(GOAL_ID_ONE, "ipfs://goal-one");

        vm.prank(alice);
        registry.addItem(item);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommunityGoalRegistry.GOAL_ALREADY_LISTED.selector, GOAL_ID_ONE));
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);
    }

    function test_pinSystemGoal_revertsWhenFloorIsZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommunityGoalRegistry.INVALID_SYSTEM_FLOOR_PPM.selector, uint32(0)));
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", 0);
    }

    function test_pinSystemGoal_revertsWhenTotalSystemFloorPpmExceedsScale() public {
        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", 900_000);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICommunityGoalRegistry.TOTAL_SYSTEM_FLOOR_PPM_EXCEEDS_MAX.selector, uint256(1_100_000)
            )
        );
        registry.pinSystemGoal(GOAL_ID_TWO, "ipfs://system-goal-two", 200_000);
    }

    function test_pinSystemGoal_updatesTotalSystemFloorPpmWhenRepinned() public {
        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);

        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal-v2", SYSTEM_FLOOR_TWO);

        assertEq(registry.totalSystemFloorPpm(), SYSTEM_FLOOR_TWO);
        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.metadataURI, "ipfs://system-goal-v2");
        assertEq(listing.floorPpm, SYSTEM_FLOOR_TWO);
    }

    function test_pinSystemGoal_repinnedSystemGoalPreservesPausedState() public {
        vm.startPrank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);
        registry.setGoalPaused(GOAL_ID_ONE, true);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal-v2", SYSTEM_FLOOR_TWO);
        vm.stopPrank();

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.metadataURI, "ipfs://system-goal-v2");
        assertEq(listing.floorPpm, SYSTEM_FLOOR_TWO);
        assertTrue(listing.paused);
        assertFalse(listing.selectable);
        assertFalse(registry.isSelectable(GOAL_ID_ONE));
        assertEq(registry.totalSystemFloorPpm(), SYSTEM_FLOOR_TWO);
    }

    function test_unpinSystemGoal_removesFloorFromTotalsAndSystemRoute() public {
        vm.startPrank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, "ipfs://system-goal", SYSTEM_FLOOR_ONE);
        registry.pinSystemGoal(GOAL_ID_TWO, "ipfs://system-goal-two", SYSTEM_FLOOR_TWO);
        registry.unpinSystemGoal(GOAL_ID_ONE);
        vm.stopPrank();

        assertEq(registry.totalSystemFloorPpm(), SYSTEM_FLOOR_TWO);
        assertFalse(registry.isListed(GOAL_ID_ONE));

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.floorPpm, 0);
        assertFalse(listing.isSystem);

        (uint256[] memory goalIds, uint32[] memory floorPpms) = registry.systemRoute();
        assertEq(goalIds.length, 1);
        assertEq(goalIds[0], GOAL_ID_TWO);
        assertEq(floorPpms.length, 1);
        assertEq(floorPpms[0], SYSTEM_FLOOR_TWO);
    }

    function test_addItem_registersGoalWithCanonicalItemId() public {
        bytes memory item = _goalItem(GOAL_ID_ONE, "ipfs://goal-one");

        vm.prank(alice);
        bytes32 itemId = registry.addItem(item);
        assertEq(itemId, bytes32(GOAL_ID_ONE));

        (bytes memory storedData, IGeneralizedTCR.Status statusBefore,) = registry.getItemInfo(itemId);
        assertEq(storedData, item);
        assertEq(uint256(statusBefore), uint256(IGeneralizedTCR.Status.RegistrationRequested));
        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(itemId);

        assertTrue(registry.isListed(GOAL_ID_ONE));
        assertTrue(registry.isSelectable(GOAL_ID_ONE));
        assertEq(goalDeploymentRegistry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, itemId);
        assertEq(listing.metadataURI, "ipfs://goal-one");
        assertFalse(listing.isSystem);
        assertEq(listing.floorPpm, 0);
    }

    function test_removeAndRelistGoal_updatesOnlyMetadata_notCanonicalTreasury() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        vm.prank(alice);
        registry.removeItem(bytes32(GOAL_ID_ONE), "");

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(bytes32(GOAL_ID_ONE));

        assertFalse(registry.isListed(GOAL_ID_ONE));
        assertFalse(registry.isSelectable(GOAL_ID_ONE));
        assertEq(goalDeploymentRegistry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));
        ICommunityGoalRegistry.GoalListingView memory removedListing = registry.listingOf(GOAL_ID_ONE);
        assertEq(removedListing.itemId, bytes32(0));
        assertEq(bytes(removedListing.metadataURI).length, 0);
        assertFalse(removedListing.isSystem);
        assertEq(removedListing.floorPpm, 0);
        assertFalse(removedListing.paused);
        assertFalse(removedListing.selectable);

        _registerGoal(bob, GOAL_ID_ONE, "ipfs://goal-one-v2");

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(GOAL_ID_ONE));
        assertEq(listing.metadataURI, "ipfs://goal-one-v2");
        assertTrue(listing.selectable);
        assertEq(listing.floorPpm, 0);
        assertEq(goalDeploymentRegistry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));
    }

    function test_addItem_revertsWhenGoalIsNotRegisteredInDeploymentRegistry() public {
        uint256 unregisteredGoalId = 999;
        directory.setPrimaryTerminal(unregisteredGoalId, address(token), IJBTerminal(address(terminal)));
        bytes memory badItem = _goalItem(unregisteredGoalId, "ipfs://bad-goal");

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(badItem);
    }

    function test_addItem_revertsWhenGoalHasNoPrimaryTerminal() public {
        uint256 goalIdWithoutTerminal = 303;
        CommunityGoalRegistryMockGoalTreasury goalTreasury =
            new CommunityGoalRegistryMockGoalTreasury(goalIdWithoutTerminal);
        goalDeploymentRegistry.registerGoal(goalIdWithoutTerminal, address(goalTreasury));
        bytes memory missingTerminalItem = _goalItem(goalIdWithoutTerminal, "ipfs://missing-terminal");

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(missingTerminalItem);
    }

    function _registerGoal(address submitter, uint256 goalId, string memory metadataUri) internal {
        vm.prank(submitter);
        registry.addItem(_goalItem(goalId, metadataUri));

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(bytes32(goalId));
    }

    function _goalItem(uint256 goalId, string memory metadataUri) internal pure returns (bytes memory item) {
        item = abi.encode(ICommunityGoalRegistry.GoalItemData({goalId: goalId, metadataURI: metadataUri}));
    }

    function _registryConfig(
        RoundTestArbitrator arbitrator_,
        uint256 submissionBaseDeposit,
        IVotes votingToken_,
        EscrowSubmissionDepositStrategy submissionDepositStrategy_
    ) internal view returns (IGeneralizedTCRConfig.RegistryConfig memory cfg) {
        cfg = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: arbitrator_,
            votingToken: votingToken_,
            submissionDepositStrategy: submissionDepositStrategy_,
            registryPolicy: IGeneralizedTCRConfig.RegistryPolicy({
                arbitratorExtraData: "",
                registrationMetaEvidence: "reg",
                clearingMetaEvidence: "clr",
                submissionBaseDeposit: submissionBaseDeposit,
                removalBaseDeposit: 0,
                submissionChallengeBaseDeposit: 0,
                removalChallengeBaseDeposit: 0,
                challengePeriodDuration: CHALLENGE_PERIOD
            })
        });
    }

    function _registryConfig(RoundTestArbitrator arbitrator_, uint256 submissionBaseDeposit)
        internal
        view
        returns (IGeneralizedTCRConfig.RegistryConfig memory cfg)
    {
        return _registryConfig(arbitrator_, submissionBaseDeposit, IVotes(address(token)), depositStrategy);
    }
}

contract CommunityGoalRegistryMockDirectory {
    mapping(uint256 projectId => mapping(address token => IJBTerminal terminal)) internal _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract CommunityGoalRegistryMockTerminal {}

contract CommunityGoalRegistryMockGoalTreasury {
    uint256 public immutable goalRevnetId;

    constructor(uint256 goalRevnetId_) {
        goalRevnetId = goalRevnetId_;
    }
}
