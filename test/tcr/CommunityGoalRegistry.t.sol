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
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
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

        goalTreasuryOne = _newGoalTreasury(GOAL_ID_ONE, COMMUNITY_REVNET_ID, address(token));
        goalTreasuryTwo = _newGoalTreasury(GOAL_ID_TWO, COMMUNITY_REVNET_ID, address(token));
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
                communityToken: address(token)
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
                communityToken: address(token)
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
                communityToken: noCodeToken
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
                communityToken: address(token)
            })
        );
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
        assertEq(address(registry.goalDeploymentRegistry()), address(goalDeploymentRegistry));
        assertEq(goalDeploymentRegistry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));

        uint256[] memory listedGoalIds = registry.listedGoalIds();
        assertEq(listedGoalIds.length, 1);
        assertEq(listedGoalIds[0], GOAL_ID_ONE);

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.goalId, GOAL_ID_ONE);
        assertEq(listing.itemId, itemId);
        assertEq(listing.metadataURI, "ipfs://goal-one");
        assertTrue(listing.selectable);
    }

    function test_addItem_revertsWhenGoalIsAlreadyListed() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICommunityGoalRegistry.GOAL_ALREADY_LISTED.selector, GOAL_ID_ONE));
        registry.addItem(_goalItem(GOAL_ID_ONE, "ipfs://goal-one-v2"));
    }

    function test_selectableGoalIds_omitsListedGoalsWhosePrimaryTerminalLosesCode() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");
        _registerGoal(bob, GOAL_ID_TWO, "ipfs://goal-two");

        address noCodeTerminal = makeAddr("no-code-terminal");
        directory.setPrimaryTerminal(GOAL_ID_ONE, address(token), IJBTerminal(noCodeTerminal));

        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        uint256[] memory selectableGoalIds = registry.selectableGoalIds();
        assertEq(selectableGoalIds.length, 1);
        assertEq(selectableGoalIds[0], GOAL_ID_TWO);
    }

    function test_isSelectable_falseWhenGoalTreasuryCannotAcceptHookFunding() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        goalTreasuryOne.setCanAcceptHookFunding(false);

        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        uint256[] memory selectableGoalIds = registry.selectableGoalIds();
        assertEq(selectableGoalIds.length, 0);
    }

    function test_pruneTerminalGoal_delistsSucceededGoal() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        goalTreasuryOne.setCanAcceptHookFunding(false);
        goalTreasuryOne.setGoalState(IGoalTreasury.GoalState.Succeeded);

        registry.pruneTerminalGoal(GOAL_ID_ONE);

        assertFalse(registry.isListed(GOAL_ID_ONE));
        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        uint256[] memory listedGoalIds = registry.listedGoalIds();
        assertEq(listedGoalIds.length, 0);

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.goalId, GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(0));
        assertEq(bytes(listing.metadataURI).length, 0);
        assertFalse(listing.selectable);

        (, IGeneralizedTCR.Status itemStatusAfterPrune,) = registry.getItemInfo(bytes32(GOAL_ID_ONE));
        assertEq(uint256(itemStatusAfterPrune), uint256(IGeneralizedTCR.Status.Absent));
    }

    function test_pruneTerminalGoal_delistsBrokenGoalWhenTreasuryCodeIsMissing() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        vm.etch(address(goalTreasuryOne), bytes(""));

        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        registry.pruneTerminalGoal(GOAL_ID_ONE);

        assertFalse(registry.isListed(GOAL_ID_ONE));
        assertEq(goalDeploymentRegistry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));

        uint256[] memory listedGoalIds = registry.listedGoalIds();
        assertEq(listedGoalIds.length, 0);

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.goalId, GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(0));
        assertEq(bytes(listing.metadataURI).length, 0);
        assertFalse(listing.selectable);
    }

    function test_pruneTerminalGoal_revertsWhenGoalIsStillLive() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        vm.expectRevert(abi.encodeWithSelector(ICommunityGoalRegistry.GOAL_NOT_PRUNABLE.selector, GOAL_ID_ONE));
        registry.pruneTerminalGoal(GOAL_ID_ONE);
    }

    function test_pruneTerminalGoal_syncsBeforePrune_andBlocksRelist() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        goalTreasuryOne.setCanAcceptHookFunding(false);
        goalTreasuryOne.setSyncState(IGoalTreasury.GoalState.Expired);
        uint256 syncCallsBeforePrune = goalTreasuryOne.syncCallCount();

        registry.pruneTerminalGoal(GOAL_ID_ONE);

        assertEq(goalTreasuryOne.syncCallCount(), syncCallsBeforePrune + 1);
        assertFalse(registry.isListed(GOAL_ID_ONE));
        assertFalse(registry.isSelectable(GOAL_ID_ONE));

        vm.prank(bob);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(GOAL_ID_ONE, "ipfs://goal-one-relisted"));
    }

    function test_addItem_bestEffortSyncsAndRejectsGoalThatTerminalizesDuringValidation() public {
        goalTreasuryOne.setCanAcceptHookFunding(false);
        goalTreasuryOne.setSyncState(IGoalTreasury.GoalState.Expired);

        vm.expectCall(address(goalTreasuryOne), abi.encodeCall(IGoalTreasury.sync, ()));
        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(GOAL_ID_ONE, "ipfs://terminalized-during-validation"));
    }

    function test_pruneTerminalGoal_ignoresSyncRevertWhenGoalAlreadyPrunable() public {
        _registerGoal(alice, GOAL_ID_ONE, "ipfs://goal-one");

        goalTreasuryOne.setGoalState(IGoalTreasury.GoalState.Expired);
        goalTreasuryOne.setSyncShouldRevert(true);

        vm.expectCall(address(goalTreasuryOne), abi.encodeCall(IGoalTreasury.sync, ()));
        registry.pruneTerminalGoal(GOAL_ID_ONE);

        assertFalse(registry.isListed(GOAL_ID_ONE));
        assertFalse(registry.isSelectable(GOAL_ID_ONE));
    }

    function test_addItem_bestEffortSyncIgnoresRevertForLiveGoal() public {
        goalTreasuryOne.setSyncShouldRevert(true);

        vm.expectCall(address(goalTreasuryOne), abi.encodeCall(IGoalTreasury.sync, ()));
        vm.prank(alice);
        registry.addItem(_goalItem(GOAL_ID_ONE, "ipfs://goal-one"));

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        registry.executeRequest(bytes32(GOAL_ID_ONE));

        assertTrue(registry.isListed(GOAL_ID_ONE));
        assertTrue(registry.isSelectable(GOAL_ID_ONE));
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
        assertEq(removedListing.goalId, GOAL_ID_ONE);
        assertEq(removedListing.itemId, bytes32(0));
        assertEq(bytes(removedListing.metadataURI).length, 0);
        assertFalse(removedListing.selectable);

        _registerGoal(bob, GOAL_ID_ONE, "ipfs://goal-one-v2");

        ICommunityGoalRegistry.GoalListingView memory listing = registry.listingOf(GOAL_ID_ONE);
        assertEq(listing.itemId, bytes32(GOAL_ID_ONE));
        assertEq(listing.metadataURI, "ipfs://goal-one-v2");
        assertTrue(listing.selectable);
        assertEq(goalDeploymentRegistry.goalTreasuryOf(GOAL_ID_ONE), address(goalTreasuryOne));
    }

    function test_addItem_revertsWhenGoalIsNotRegisteredInDeploymentRegistry() public {
        uint256 unregisteredGoalId = 999;
        directory.setPrimaryTerminal(unregisteredGoalId, address(token), IJBTerminal(address(terminal)));

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(unregisteredGoalId, "ipfs://bad-goal"));
    }

    function test_addItem_revertsWhenGoalHasNoPrimaryTerminal() public {
        uint256 goalIdWithoutTerminal = 303;
        CommunityGoalRegistryMockGoalTreasury goalTreasury =
            _newGoalTreasury(goalIdWithoutTerminal, COMMUNITY_REVNET_ID, address(token));
        goalDeploymentRegistry.registerGoal(goalIdWithoutTerminal, address(goalTreasury));

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(goalIdWithoutTerminal, "ipfs://missing-terminal"));
    }

    function test_addItem_revertsWhenGoalFundingRevnetDiffersFromCommunity() public {
        uint256 mismatchedGoalId = 404;
        CommunityGoalRegistryMockGoalTreasury mismatchedTreasury =
            _newGoalTreasury(mismatchedGoalId, COMMUNITY_REVNET_ID + 1, address(token));
        goalDeploymentRegistry.registerGoal(mismatchedGoalId, address(mismatchedTreasury));
        directory.setPrimaryTerminal(mismatchedGoalId, address(token), IJBTerminal(address(terminal)));

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(mismatchedGoalId, "ipfs://wrong-revnet"));
    }

    function test_addItem_revertsWhenGoalFundingTokenDiffersFromCommunity() public {
        uint256 mismatchedGoalId = 505;
        CommunityGoalRegistryMockGoalTreasury mismatchedTreasury =
            _newGoalTreasury(mismatchedGoalId, COMMUNITY_REVNET_ID, address(otherToken));
        goalDeploymentRegistry.registerGoal(mismatchedGoalId, address(mismatchedTreasury));
        directory.setPrimaryTerminal(mismatchedGoalId, address(token), IJBTerminal(address(terminal)));

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(mismatchedGoalId, "ipfs://wrong-token"));
    }

    function test_addItem_revertsWhenGoalRoutesToCommunityItself() public {
        CommunityGoalRegistryMockGoalTreasury communityTreasury =
            _newGoalTreasury(COMMUNITY_REVNET_ID, COMMUNITY_REVNET_ID, address(token));
        goalDeploymentRegistry.registerGoal(COMMUNITY_REVNET_ID, address(communityTreasury));
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, address(token), IJBTerminal(address(terminal)));

        vm.prank(alice);
        vm.expectRevert(IGeneralizedTCR.INVALID_ITEM_DATA.selector);
        registry.addItem(_goalItem(COMMUNITY_REVNET_ID, "ipfs://self"));
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

    function _newGoalTreasury(uint256 goalId, uint256 fundingRevnetId, address fundingToken)
        internal
        returns (CommunityGoalRegistryMockGoalTreasury goalTreasury)
    {
        goalTreasury = new CommunityGoalRegistryMockGoalTreasury(
            goalId, fundingRevnetId, address(new CommunityGoalRegistryMockStakeVault(fundingToken))
        );
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
    uint256 public immutable cobuildRevnetId;
    address public immutable stakeVault;
    IGoalTreasury.GoalState internal _state;
    IGoalTreasury.GoalState internal _syncState;
    bool internal _syncStateConfigured;
    bool internal _canAcceptHookFunding = true;
    bool internal _syncShouldRevert;
    uint256 internal _syncCallCount;

    constructor(uint256 goalRevnetId_, uint256 cobuildRevnetId_, address stakeVault_) {
        goalRevnetId = goalRevnetId_;
        cobuildRevnetId = cobuildRevnetId_;
        stakeVault = stakeVault_;
        _state = IGoalTreasury.GoalState.Funding;
        _syncState = _state;
    }

    function canAcceptHookFunding() external view returns (bool) {
        return _canAcceptHookFunding;
    }

    function state() external view returns (IGoalTreasury.GoalState) {
        return _state;
    }

    function setCanAcceptHookFunding(bool canAcceptHookFunding_) external {
        _canAcceptHookFunding = canAcceptHookFunding_;
    }

    function setGoalState(IGoalTreasury.GoalState state_) external {
        _state = state_;
    }

    function setSyncState(IGoalTreasury.GoalState state_) external {
        _syncState = state_;
        _syncStateConfigured = true;
    }

    function syncCallCount() external view returns (uint256) {
        return _syncCallCount;
    }

    function setSyncShouldRevert(bool syncShouldRevert_) external {
        _syncShouldRevert = syncShouldRevert_;
    }

    function sync() external {
        _syncCallCount += 1;
        if (_syncShouldRevert) revert("SYNC_REVERT");
        if (_syncStateConfigured) _state = _syncState;
    }
}

contract CommunityGoalRegistryMockStakeVault {
    IERC20 public immutable cobuildToken;

    constructor(address cobuildToken_) {
        cobuildToken = IERC20(cobuildToken_);
    }
}
