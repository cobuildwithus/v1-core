// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import {TestUtils} from "test/utils/TestUtils.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {MockGeneralizedTCR} from "test/mocks/MockGeneralizedTCR.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IGeneralizedTCR} from "src/tcr/interfaces/IGeneralizedTCR.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";
import {EscrowSubmissionDepositStrategy} from "src/tcr/strategies/EscrowSubmissionDepositStrategy.sol";

contract TCRHandler is Test {
    MockGeneralizedTCR internal tcr;
    ERC20VotesArbitrator internal arb;
    MockVotesToken internal token;
    address[] internal actors;

    bytes32[] internal itemIDs;
    mapping(bytes32 => bool) internal knownItem;
    mapping(address => bool) internal approved;

    uint256 internal constant MAX_ITEMS = 20;

    constructor(MockGeneralizedTCR tcr_, ERC20VotesArbitrator arb_, MockVotesToken token_, address[] memory actors_) {
        tcr = tcr_;
        arb = arb_;
        token = token_;
        actors = actors_;
    }

    function addItem(uint256 seed) external {
        if (itemIDs.length >= MAX_ITEMS) return;

        address actor = actors[seed % actors.length];
        _ensureApproved(actor);

        (uint256 addCost,,,,) = tcr.getTotalCosts();
        _ensureBalance(actor, addCost);

        bytes memory item = abi.encodePacked("item-", seed);
        bytes32 itemID = keccak256(item);

        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        if (status != IGeneralizedTCR.Status.Absent) return;

        vm.prank(actor);
        try tcr.addItem(item) returns (bytes32 newItem) {
            if (!knownItem[newItem]) {
                knownItem[newItem] = true;
                itemIDs.push(newItem);
            }
        } catch {}
    }

    function removeItem(uint256 seed) external {
        if (itemIDs.length == 0) return;

        bytes32 itemID = itemIDs[seed % itemIDs.length];
        (, IGeneralizedTCR.Status status,) = tcr.getItemInfo(itemID);
        if (status != IGeneralizedTCR.Status.Registered) return;

        address actor = actors[(seed >> 8) % actors.length];
        _ensureApproved(actor);

        (, uint256 removeCost,,,) = tcr.getTotalCosts();
        _ensureBalance(actor, removeCost);

        vm.prank(actor);
        try tcr.removeItem(itemID, "") {} catch {}
    }

    function challengeRequest(uint256 seed) external {
        if (itemIDs.length == 0) return;

        bytes32 itemID = itemIDs[seed % itemIDs.length];
        (, IGeneralizedTCR.Status status, uint256 requestCount) = tcr.getItemInfo(itemID);
        if (
            status != IGeneralizedTCR.Status.RegistrationRequested &&
            status != IGeneralizedTCR.Status.ClearingRequested
        ) {
            return;
        }
        if (requestCount == 0) return;

        (
            bool disputed,
            ,
            uint256 submissionTime,
            bool resolved,
            ,
            ,
            ,
            ,
            ,
        ) = tcr.getRequestInfo(itemID, requestCount - 1);
        if (disputed || resolved) return;

        if (block.timestamp - submissionTime > tcr.challengePeriodDuration()) return;

        address actor = actors[(seed >> 16) % actors.length];
        _ensureApproved(actor);

        uint256 challengeCost;
        if (status == IGeneralizedTCR.Status.RegistrationRequested) {
            (, , challengeCost,,) = tcr.getTotalCosts();
        } else {
            (,,, challengeCost,) = tcr.getTotalCosts();
        }
        _ensureBalance(actor, challengeCost);

        vm.prank(actor);
        try tcr.challengeRequest(itemID, "") {} catch {}
    }

    function executeRequest(uint256 seed) external {
        if (itemIDs.length == 0) return;

        bytes32 itemID = itemIDs[seed % itemIDs.length];
        (, IGeneralizedTCR.Status status, uint256 requestCount) = tcr.getItemInfo(itemID);
        if (
            status != IGeneralizedTCR.Status.RegistrationRequested &&
            status != IGeneralizedTCR.Status.ClearingRequested
        ) {
            return;
        }
        if (requestCount == 0) return;

        (
            bool disputed,
            ,
            uint256 submissionTime,
            bool resolved,
            ,
            ,
            ,
            ,
            ,
        ) = tcr.getRequestInfo(itemID, requestCount - 1);
        if (disputed || resolved) return;

        if (block.timestamp - submissionTime <= tcr.challengePeriodDuration()) return;

        try tcr.executeRequest(itemID) {} catch {}
    }

    function warpTime(uint256 seed) external {
        uint256 jump = _bound(seed, 1 hours, 3 days);
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);
    }

    function _ensureApproved(address actor) internal {
        if (approved[actor]) return;
        vm.prank(actor);
        token.approve(address(tcr), type(uint256).max);
        approved[actor] = true;
    }

    function _ensureBalance(address actor, uint256 minBalance) internal {
        if (token.balanceOf(actor) >= minBalance) return;
        token.mint(actor, minBalance * 4);
    }
}

contract GeneralizedTCRInvariantTest is StdInvariant, TestUtils {
    MockVotesToken internal token;
    ERC20VotesArbitrator internal arb;
    MockGeneralizedTCR internal tcr;
    TCRHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");

    uint256 internal votingPeriod = 20;
    uint256 internal votingDelay = 2;
    uint256 internal revealPeriod = 15;
    uint256 internal arbitrationCost = 10e18;

    uint256 internal submissionBaseDeposit = 100e18;
    uint256 internal removalBaseDeposit = 50e18;
    uint256 internal submissionChallengeBaseDeposit = 120e18;
    uint256 internal removalChallengeBaseDeposit = 70e18;
    uint256 internal challengePeriodDuration = 3 days;
    ISubmissionDepositStrategy internal defaultSubmissionDepositStrategy;

    function setUp() public {
        token = new MockVotesToken("MockVotes", "MV");
        defaultSubmissionDepositStrategy = ISubmissionDepositStrategy(
            address(new EscrowSubmissionDepositStrategy(token))
        );

        MockGeneralizedTCR tcrImpl = new MockGeneralizedTCR();
        ERC20VotesArbitrator arbImpl = new ERC20VotesArbitrator();

        uint256 nonce = vm.getNonce(address(this));
        address arbProxyAddr = vm.computeCreateAddress(address(this), nonce);
        address tcrProxyAddr = vm.computeCreateAddress(address(this), nonce + 1);

        bytes memory arbInit = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), tcrProxyAddr, votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(arbImpl), arbInit));
        assertEq(address(arb), arbProxyAddr);

        bytes memory tcrInit = abi.encodeCall(
            MockGeneralizedTCR.initialize,
            (
                owner,
                arb,
                bytes(""),
                "ipfs://regMeta",
                "ipfs://clearMeta",
                governor,
                token,
                submissionBaseDeposit,
                removalBaseDeposit,
                submissionChallengeBaseDeposit,
                removalChallengeBaseDeposit,
                challengePeriodDuration,
                defaultSubmissionDepositStrategy
            )
        );
        tcr = MockGeneralizedTCR(_deployProxy(address(tcrImpl), tcrInit));
        assertEq(address(tcr), tcrProxyAddr);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("actor1");
        actors[1] = makeAddr("actor2");
        actors[2] = makeAddr("actor3");
        actors[3] = makeAddr("actor4");

        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            token.approve(address(tcr), type(uint256).max);
        }

        handler = new TCRHandler(tcr, arb, token, actors);
        targetContract(address(handler));
    }

    function invariant_itemIndexMappingConsistent() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            assertEq(tcr.itemIDtoIndex(itemID), i);
        }
    }

    function invariant_statusMatchesRequestResolution() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            (, IGeneralizedTCR.Status status, uint256 requestCount) = tcr.getItemInfo(itemID);

            if (requestCount == 0) {
                assertEq(uint256(status), uint256(IGeneralizedTCR.Status.Absent));
                continue;
            }

            (, , , bool resolved, , , , , ,) = tcr.getRequestInfo(itemID, requestCount - 1);

            if (
                status == IGeneralizedTCR.Status.RegistrationRequested ||
                status == IGeneralizedTCR.Status.ClearingRequested
            ) {
                assertFalse(resolved);
            } else {
                assertTrue(resolved);
            }
        }
    }

    function invariant_feeRewardsNeverExceedPaid() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            (, , uint256 requestCount) = tcr.getItemInfo(itemID);

            for (uint256 r = 0; r < requestCount; r++) {
                (, , , , , uint256 rounds, , , ,) = tcr.getRequestInfo(itemID, r);
                for (uint256 round = 0; round < rounds; round++) {
                    (
                        uint256[3] memory amountPaid,
                        ,
                        uint256 feeRewards
                    ) = tcr.getRoundInfo(itemID, r, round);
                    uint256 paid = amountPaid[uint256(IArbitrable.Party.Requester)] +
                        amountPaid[uint256(IArbitrable.Party.Challenger)];
                    assertTrue(feeRewards <= paid);
                }
            }
        }
    }

    function invariant_disputedRequestsHaveMapping() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            (, , uint256 requestCount) = tcr.getItemInfo(itemID);

            for (uint256 r = 0; r < requestCount; r++) {
                (bool disputed, uint256 disputeID,,,,,, IArbitrator requestArbitrator,,) = tcr.getRequestInfo(itemID, r);

                if (disputed) {
                    assertGt(disputeID, 0);
                    bytes32 mapped = tcr.arbitratorDisputeIDToItem(address(requestArbitrator), disputeID);
                    assertEq(mapped, itemID);
                }
            }
        }
    }

    function invariant_submissionDepositStrategyAlwaysConfigured() public view {
        assertTrue(address(tcr.submissionDepositStrategy()) != address(0));
    }

    function invariant_undisputedRequestsHaveZeroDisputeId() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            (, , uint256 requestCount) = tcr.getItemInfo(itemID);

            for (uint256 r = 0; r < requestCount; r++) {
                (
                    bool disputed,
                    uint256 disputeID,
                    ,
                    ,
                    ,
                    ,
                    ,
                    ,
                    bytes memory _arbitratorExtraData,
                    uint256 _metaEvidenceID
                ) = tcr.getRequestInfo(itemID, r);
                if (!disputed) {
                    assertEq(disputeID, 0);
                }
            }
        }
    }

    function invariant_unresolvedRequestsHaveNoRuling() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            (, , uint256 requestCount) = tcr.getItemInfo(itemID);

            for (uint256 r = 0; r < requestCount; r++) {
                (
                    bool disputed,
                    uint256 disputeID,
                    ,
                    bool resolved,
                    ,
                    ,
                    IArbitrable.Party ruling,
                    IArbitrator requestArbitrator,
                    bytes memory _arbitratorExtraData,
                    uint256 _metaEvidenceID
                ) = tcr.getRequestInfo(itemID, r);

                if (!resolved) {
                    assertEq(uint256(ruling), uint256(IArbitrable.Party.None));
                }

                if (resolved && disputed) {
                    bytes32 mapped = tcr.arbitratorDisputeIDToItem(address(requestArbitrator), disputeID);
                    assertEq(mapped, bytes32(0));
                }
            }
        }
    }

    function invariant_itemManagersAreSet() public view {
        uint256 count = tcr.itemCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 itemID = tcr.itemList(i);
            (, address manager,) = tcr.items(itemID);
            assertTrue(manager != address(0));
        }
    }
}
