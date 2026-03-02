// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";

abstract contract TestUtils is Test {
    function _defaultArbitratorInitConfig(
        address invalidRoundRewardsSink,
        address votingToken,
        address arbitrable,
        uint256 votingPeriod,
        uint256 votingDelay,
        uint256 revealPeriod,
        uint256 arbitrationCost
    ) internal pure returns (IERC20VotesArbitrator.InitConfig memory cfg) {
        cfg = IERC20VotesArbitrator.InitConfig({
            invalidRoundRewardsSink: invalidRoundRewardsSink,
            votingToken: votingToken,
            arbitrable: arbitrable,
            votingPeriod: votingPeriod,
            votingDelay: votingDelay,
            revealPeriod: revealPeriod,
            arbitrationCost: arbitrationCost,
            stakeVault: address(0),
            fixedBudgetTreasury: address(0),
            wrongOrMissedSlashBps: 50,
            slashCallerBountyBps: 100
        });
    }

    function _arbitratorInitData(
        IERC20VotesArbitrator.InitConfig memory config
    ) internal pure returns (bytes memory initData) {
        initData = abi.encodeCall(ERC20VotesArbitrator.initializeWithConfig, (config));
    }

    function _defaultArbitratorInitData(
        address invalidRoundRewardsSink,
        address votingToken,
        address arbitrable,
        uint256 votingPeriod,
        uint256 votingDelay,
        uint256 revealPeriod,
        uint256 arbitrationCost
    ) internal pure returns (bytes memory initData) {
        initData = _arbitratorInitData(
            _defaultArbitratorInitConfig(
                invalidRoundRewardsSink,
                votingToken,
                arbitrable,
                votingPeriod,
                votingDelay,
                revealPeriod,
                arbitrationCost
            )
        );
    }

    function _voteHash(
        ERC20VotesArbitrator arb,
        uint256 disputeId,
        uint256 round,
        address voter,
        uint256 choice,
        string memory reason,
        bytes32 salt
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(arb), disputeId, round, voter, choice, reason, salt));
    }

    function _warpRoll(uint256 newTimestamp) internal {
        vm.warp(newTimestamp);
        vm.roll(block.number + 1);
    }

    function _deployProxy(address impl, bytes memory initData) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(impl, initData));
    }

    function _scheduleVoting(
        ERC20VotesArbitrator arb,
        uint256 disputeCreationTs
    ) internal view returns (uint256 start, uint256 end, uint256 revealEnd) {
        start = disputeCreationTs + arb._votingDelay();
        end = start + arb._votingPeriod();
        revealEnd = end + arb._revealPeriod();
    }

    function _commitRevealTwoVotes(
        ERC20VotesArbitrator arb,
        uint256 disputeId,
        uint256 start,
        uint256 end,
        address voter1,
        uint256 choice1,
        bytes32 salt1,
        string memory reason1,
        address voter2,
        uint256 choice2,
        bytes32 salt2,
        string memory reason2
    ) internal {
        _warpRoll(start + 1);

        vm.prank(voter1);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter1, choice1, reason1, salt1));
        vm.prank(voter2);
        arb.commitVote(disputeId, _voteHash(arb, disputeId, 0, voter2, choice2, reason2, salt2));

        _warpRoll(end + 1);

        vm.prank(voter1);
        arb.revealVote(disputeId, voter1, choice1, reason1, salt1);
        vm.prank(voter2);
        arb.revealVote(disputeId, voter2, choice2, reason2, salt2);
    }
}
