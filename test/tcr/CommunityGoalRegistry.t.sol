// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { CommunityGoalRegistry } from "src/tcr/CommunityGoalRegistry.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import { IGeneralizedTCR } from "src/tcr/interfaces/IGeneralizedTCR.sol";
import { IGeneralizedTCRConfig } from "src/tcr/interfaces/IGeneralizedTCRConfig.sol";
import { EscrowSubmissionDepositStrategy } from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";

import { MockVotesToken } from "test/mocks/MockVotesToken.sol";
import { RoundTestArbitrator } from "test/rounds/helpers/RoundTestMocks.sol";

contract CommunityGoalRegistryTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 77;
    uint256 internal constant GOAL_ID_ONE = 101;
    uint256 internal constant GOAL_ID_TWO = 202;
    uint256 internal constant ARBITRATION_COST = 1e14;
    uint256 internal constant CHALLENGE_PERIOD = 7 days;
    uint256 internal constant SUBMISSION_DEPOSIT = 1e18;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockVotesToken internal token;
    EscrowSubmissionDepositStrategy internal depositStrategy;
    RoundTestArbitrator internal arbitrator;
    CommunityGoalRegistryMockDirectory internal directory;
    CommunityGoalRegistryMockTerminal internal terminal;
    CommunityGoalRegistry internal registry;

    CommunityGoalRegistryMockGoalTreasury internal goalTreasuryOne;
    CommunityGoalRegistryMockGoalTreasury internal goalTreasuryOneV2;
    CommunityGoalRegistryMockGoalTreasury internal goalTreasuryTwo;

    function setUp() public {
        token = new MockVotesToken("Goal Registry Votes", "GRV");
        depositStrategy = new EscrowSubmissionDepositStrategy(IERC20(address(token)));
        directory = new CommunityGoalRegistryMockDirectory();
        terminal = new CommunityGoalRegistryMockTerminal();

        goalTreasuryOne = new CommunityGoalRegistryMockGoalTreasury(GOAL_ID_ONE);
        goalTreasuryOneV2 = new CommunityGoalRegistryMockGoalTreasury(GOAL_ID_ONE);
        goalTreasuryTwo = new CommunityGoalRegistryMockGoalTreasury(GOAL_ID_TWO);

        directory.setPrimaryTerminal(GOAL_ID_ONE, address(token), IJBTerminal(address(terminal)));
        directory.setPrimaryTerminal(GOAL_ID_TWO, address(token), IJBTerminal(address(terminal)));

        CommunityGoalRegistry implementation = new CommunityGoalRegistry();
        registry = CommunityGoalRegistry(Clones.clone(address(implementation)));

        arbitrator = new RoundTestArbitrator(IVotes(address(token)), address(registry), 1, 1, 1, ARBITRATION_COST);

        registry.initialize(
            CommunityGoalRegistry.InitConfig({
                tcrConfig: _registryConfig(arbitrator, SUBMISSION_DEPOSIT),
                directory: IJBDirectory(address(directory)),
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

    function test_pinSystemGoal_marksGoalSelectable_andStoresTreasury() public {
        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, address(goalTreasuryOne), "ipfs://system-goal");

        assertTrue(registry.isListed(GOAL_ID_ONE));
        assertTrue(registry.isSelectable(GOAL_ID_ONE));
        assertEq(registry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(GOAL_ID_ONE));
        assertEq(listing.goalTreasury, address(goalTreasuryOne));
        assertEq(listing.metadataURI, "ipfs://system-goal");
        assertTrue(listing.isSystem);
        assertFalse(listing.paused);
        assertTrue(listing.selectable);
    }

    function test_setGoalPaused_togglesSystemGoalSelectability() public {
        vm.prank(owner);
        registry.pinSystemGoal(GOAL_ID_ONE, address(goalTreasuryOne), "ipfs://system-goal");

        vm.prank(owner);
        registry.setGoalPaused(GOAL_ID_ONE, true);
        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        vm.prank(owner);
        registry.setGoalPaused(GOAL_ID_ONE, false);
        assertTrue(registry.isSelectable(GOAL_ID_ONE));
    }

    function test_pinSystemGoal_revertsWhenGoalAlreadyHasPendingTcrRequest() public {
        bytes memory item = _goalItem(GOAL_ID_ONE, address(goalTreasuryOne), "ipfs://goal-one");

        vm.prank(alice);
        registry.addItem(item);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommunityGoalRegistry.GOAL_ALREADY_LISTED.selector, GOAL_ID_ONE));
        registry.pinSystemGoal(GOAL_ID_ONE, address(goalTreasuryOneV2), "ipfs://system-goal");
    }

    function test_addItem_registersGoalWithCanonicalItemId() public {
        bytes memory item = _goalItem(GOAL_ID_ONE, address(goalTreasuryOne), "ipfs://goal-one");

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
        assertEq(registry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, itemId);
        assertEq(listing.goalTreasury, address(goalTreasuryOne));
        assertEq(listing.metadataURI, "ipfs://goal-one");
        assertFalse(listing.isSystem);
    }

    function test_removeAndRelistGoal_updatesListingPayload() public {
        _registerGoal(alice, GOAL_ID_ONE, address(goalTreasuryOne), "ipfs://goal-one");

        vm.prank(alice);
        registry.removeItem(bytes32(GOAL_ID_ONE), "");

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(bytes32(GOAL_ID_ONE));

        assertFalse(registry.isListed(GOAL_ID_ONE));
        assertFalse(registry.isSelectable(GOAL_ID_ONE));
        assertEq(registry.goalTreasuryOf(GOAL_ID_ONE), address(0));

        _registerGoal(bob, GOAL_ID_ONE, address(goalTreasuryOneV2), "ipfs://goal-one-v2");

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(GOAL_ID_ONE));
        assertEq(listing.goalTreasury, address(goalTreasuryOneV2));
        assertEq(listing.metadataURI, "ipfs://goal-one-v2");
        assertTrue(listing.selectable);
    }

    function test_addItem_revertsWhenGoalTreasuryGoalIdMismatch() public {
        bytes memory badItem = _goalItem(GOAL_ID_ONE, address(goalTreasuryTwo), "ipfs://bad-goal");

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(badItem);
    }

    function test_addItem_revertsWhenGoalHasNoPrimaryTerminal() public {
        bytes memory missingTerminalItem = _goalItem(999, address(goalTreasuryOne), "ipfs://missing-terminal");

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(missingTerminalItem);
    }

    function _registerGoal(address submitter, uint256 goalId, address goalTreasury, string memory metadataUri) internal {
        vm.prank(submitter);
        registry.addItem(_goalItem(goalId, goalTreasury, metadataUri));

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(bytes32(goalId));
    }

    function _goalItem(
        uint256 goalId,
        address goalTreasury,
        string memory metadataUri
    ) internal pure returns (bytes memory item) {
        item = abi.encode(
            ICommunityGoalRegistry.GoalItemData({
                goalId: goalId,
                goalTreasury: goalTreasury,
                metadataURI: metadataUri
            })
        );
    }

    function _registryConfig(
        RoundTestArbitrator arbitrator_,
        uint256 submissionBaseDeposit
    ) internal view returns (IGeneralizedTCRConfig.RegistryConfig memory cfg) {
        cfg = IGeneralizedTCRConfig.RegistryConfig({
            arbitrator: arbitrator_,
            votingToken: IVotes(address(token)),
            submissionDepositStrategy: depositStrategy,
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

contract CommunityGoalRegistryMockTerminal { }

contract CommunityGoalRegistryMockGoalTreasury {
    uint256 public immutable goalRevnetId;

    constructor(uint256 goalRevnetId_) {
        goalRevnetId = goalRevnetId_;
    }
}
