// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TestUtils} from "test/utils/TestUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {MockArbitrable} from "test/mocks/MockArbitrable.sol";

/// @dev Harness to expose internal pure helpers for coverage.
contract ArbitratorHarness is ERC20VotesArbitrator {
    function exposed_convertChoiceToParty(uint256 choice) external pure returns (IArbitrable.Party) {
        return _convertChoiceToParty(choice);
    }

    function exposed_bps2Uint(uint256 bps, uint256 number) external pure returns (uint256) {
        return bps2Uint(bps, number);
    }

    function exposed_roundTimes(
        uint256 disputeId,
        uint256 round
    )
        external
        view
        returns (uint256 votingStart, uint256 votingEnd, uint256 revealStart, uint256 revealEnd)
    {
        VotingRound storage votingRound = disputes[disputeId].rounds[round];
        return (
            votingRound.votingStartTime,
            votingRound.votingEndTime,
            votingRound.revealPeriodStartTime,
            votingRound.revealPeriodEndTime
        );
    }

    function exposed_setReceiptRevealed(
        uint256 disputeId,
        uint256 round,
        address voter,
        bool revealed
    ) external {
        disputes[disputeId].rounds[round].receipts[voter].hasRevealed = revealed;
    }

    function exposed_setRoundVotes(uint256 disputeId, uint256 round, uint256 votes) external {
        disputes[disputeId].rounds[round].votes = votes;
    }

    function exposed_setCreationBlock(uint256 disputeId, uint256 round, uint256 creationBlock) external {
        disputes[disputeId].rounds[round].creationBlock = creationBlock;
    }

    function exposed_validDisputeID(uint256 disputeId) external view validDisputeID(disputeId) returns (bool) {
        return true;
    }
}

/// @dev Upgrade mock used for upgrade authorization test.
contract ERC20VotesArbitratorUpgradeMock is ERC20VotesArbitrator {
    function version() external pure returns (uint256) {
        return 2;
    }
}

abstract contract ERC20VotesArbitratorTestBase is TestUtils {
    MockVotesToken internal token;
    MockArbitrable internal arbitrable;
    ERC20VotesArbitrator internal arb;

    address internal owner = makeAddr("owner");
    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");
    address internal relayer = makeAddr("relayer");
    address internal noVotes = makeAddr("noVotes");

    uint256 internal votingPeriod = 100;
    uint256 internal votingDelay = 10;
    uint256 internal revealPeriod = 25;
    uint256 internal arbitrationCost = 50e18;

    function setUp() public virtual {
        token = new MockVotesToken("MockVotes", "MV");
        arbitrable = new MockArbitrable(IERC20(address(token)));

        // Deploy arbitrator behind ERC1967Proxy (constructor uses initializer pattern).
        ArbitratorHarness impl = new ArbitratorHarness();
        bytes memory initData = abi.encodeCall(
            ERC20VotesArbitrator.initialize,
            (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );
        arb = ERC20VotesArbitrator(_deployProxy(address(impl), initData));

        arbitrable.setArbitrator(arb);

        // Fund arbitrable for arbitration costs.
        token.mint(address(arbitrable), 1_000_000e18);
        arbitrable.approveArbitrator(arbitrationCost * 10);

        // Fund voters + delegate so getPastVotes works.
        token.mint(voter1, 100e18);
        token.mint(voter2, 200e18);

        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);

        // Ensure checkpoints exist in a past block.
        vm.roll(block.number + 1);
    }

    function _createDispute(bytes memory extraData)
        internal
        returns (
            uint256 disputeId,
            uint256 startTime,
            uint256 endTime,
            uint256 revealEndTime,
            uint256 creationBlock
        )
    {
        startTime = block.timestamp + votingDelay;
        endTime = startTime + votingPeriod;
        revealEndTime = endTime + revealPeriod;
        creationBlock = block.number - 1;

        disputeId = arbitrable.createDispute(2, extraData);
        assertEq(disputeId, 1);
    }
}
