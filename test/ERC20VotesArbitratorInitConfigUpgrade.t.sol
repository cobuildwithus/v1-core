// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness, ERC20VotesArbitratorUpgradeMock} from "test/ERC20VotesArbitrator.t.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import {
    MockNonERC20Votes,
    MockVotesToken6Decimals
} from "test/mocks/MockIncompatibleVotesToken.sol";

contract ERC20VotesArbitratorInitConfigUpgradeTest is ERC20VotesArbitratorTestBase {
    function test_initialize_reverts_on_invalid_params() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        uint256 minVotingPeriod = arb.MIN_VOTING_PERIOD();
        uint256 minVotingDelay = arb.MIN_VOTING_DELAY();
        uint256 minRevealPeriod = arb.MIN_REVEAL_PERIOD();
        uint256 minArbitrationCost = arb.MIN_ARBITRATION_COST();

        // INVALID_INVALID_ROUND_REWARD_SINK
        vm.expectRevert(IERC20VotesArbitrator.INVALID_INVALID_ROUND_REWARD_SINK.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (address(0), address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
            )
        );

        // INVALID_ARBITRABLE_ADDRESS
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRABLE_ADDRESS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(0), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
            )
        );

        // INVALID_VOTING_TOKEN_ADDRESS
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_TOKEN_ADDRESS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(0), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
            )
        );

        // INVALID_VOTING_PERIOD
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_PERIOD.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), minVotingPeriod - 1, votingDelay, revealPeriod, arbitrationCost)
            )
        );

        // INVALID_VOTING_DELAY
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), votingPeriod, minVotingDelay - 1, revealPeriod, arbitrationCost)
            )
        );

        // INVALID_REVEAL_PERIOD
        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), votingPeriod, votingDelay, minRevealPeriod - 1, arbitrationCost)
            )
        );

        // INVALID_ARBITRATION_COST
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, minArbitrationCost - 1)
            )
        );
    }

    function test_initialize_reverts_on_invalid_params_high_bounds() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        uint256 maxVotingPeriod = arb.MAX_VOTING_PERIOD();
        uint256 maxVotingDelay = arb.MAX_VOTING_DELAY();
        uint256 maxRevealPeriod = arb.MAX_REVEAL_PERIOD();
        uint256 maxArbitrationCost = arb.MAX_ARBITRATION_COST();

        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_PERIOD.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), maxVotingPeriod + 1, votingDelay, revealPeriod, arbitrationCost)
            )
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), votingPeriod, maxVotingDelay + 1, revealPeriod, arbitrationCost)
            )
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), votingPeriod, votingDelay, maxRevealPeriod + 1, arbitrationCost)
            )
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, maxArbitrationCost + 1)
            )
        );
    }

    function test_initialize_reverts_on_incompatible_voting_tokens() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();

        MockNonERC20Votes nonErc20Votes = new MockNonERC20Votes();
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_TOKEN_COMPATIBILITY.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (
                    owner,
                    address(nonErc20Votes),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost
                )
            )
        );

        MockVotesToken6Decimals token6 = new MockVotesToken6Decimals("Six Decimals Votes", "SIX");
        vm.expectRevert(abi.encodeWithSelector(IERC20VotesArbitrator.INVALID_VOTING_TOKEN_DECIMALS.selector, 6));
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initialize,
                (
                    owner,
                    address(token6),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost
                )
            )
        );
    }

    function test_arbitrationCost_bounds_are_defined_in_votingToken_units() public view {
        uint256 tokenUnit = 10 ** uint256(token.decimals());
        assertEq(arb.MIN_ARBITRATION_COST(), tokenUnit / 10_000);
        assertEq(arb.MAX_ARBITRATION_COST(), tokenUnit * 1_000_000);
    }

    function test_votingPower_helpers_and_factory_params() public {
        (uint256 disputeId,,,,) = _createDispute("");
        vm.roll(block.number + 1);

        (uint256 p1, bool can1) = arb.votingPowerInRound(disputeId, 0, voter1);
        assertGt(p1, 0);
        assertTrue(can1);

        (uint256 p0, bool can0) = arb.votingPowerInRound(disputeId, 0, noVotes);
        assertEq(p0, 0);
        assertFalse(can0);

        (uint256 p2, bool can2) = arb.votingPowerInCurrentRound(disputeId, voter2);
        assertGt(p2, 0);
        assertTrue(can2);

        IArbitrator.ArbitratorParams memory params = arb.getArbitratorParamsForFactory();
        assertEq(params.votingPeriod, votingPeriod);
        assertEq(params.votingDelay, votingDelay);
        assertEq(params.revealPeriod, revealPeriod);
        assertEq(params.arbitrationCost, arbitrationCost);
        assertEq(params.wrongOrMissedSlashBps, arb.wrongOrMissedSlashBps());
        assertEq(params.slashCallerBountyBps, arb.slashCallerBountyBps());
    }

    function test_initialize_sets_default_slash_config() public view {
        assertEq(arb.wrongOrMissedSlashBps(), arb.DEFAULT_WRONG_OR_MISSED_SLASH_BPS());
        assertEq(arb.slashCallerBountyBps(), arb.DEFAULT_SLASH_CALLER_BOUNTY_BPS());
    }

    function test_initialize_accepts_explicit_slash_config_and_reverts_on_caps() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();

        ERC20VotesArbitrator configured = ERC20VotesArbitrator(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    ERC20VotesArbitrator.initializeWithSlashConfig,
                    (owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost, 321, 123)
                )
            )
        );
        assertEq(configured.wrongOrMissedSlashBps(), 321);
        assertEq(configured.slashCallerBountyBps(), 123);

        vm.expectRevert(IERC20VotesArbitrator.INVALID_WRONG_OR_MISSED_SLASH_BPS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithSlashConfig,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    10_001,
                    0
                )
            )
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_SLASH_CALLER_BOUNTY_BPS.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                ERC20VotesArbitrator.initializeWithSlashConfig,
                (
                    owner,
                    address(token),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost,
                    10_000,
                    501
                )
            )
        );
    }

    function test_setters_onlyArbitrable_and_ranges() public {
        uint256 minVotingPeriod = arb.MIN_VOTING_PERIOD();
        uint256 minVotingDelay = arb.MIN_VOTING_DELAY();
        uint256 minRevealPeriod = arb.MIN_REVEAL_PERIOD();
        uint256 minArbitrationCost = arb.MIN_ARBITRATION_COST();
        uint256 maxArbitrationCost = arb.MAX_ARBITRATION_COST();
        uint256 maxVotingDelay = arb.MAX_VOTING_DELAY();
        uint256 maxRevealPeriod = arb.MAX_REVEAL_PERIOD();

        // setVotingPeriod range check
        vm.expectRevert(IERC20VotesArbitrator.ONLY_ARBITRABLE.selector);
        arb.setVotingPeriod(minVotingPeriod); // non-arbitrable

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_PERIOD.selector);
        arb.setVotingPeriod(minVotingPeriod - 1);

        vm.prank(address(arbitrable));
        arb.setVotingPeriod(minVotingPeriod);

        // setVotingDelay range check
        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        arb.setVotingDelay(maxVotingDelay + 1);

        vm.prank(address(arbitrable));
        arb.setVotingDelay(minVotingDelay);

        // setRevealPeriod range check
        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        arb.setRevealPeriod(maxRevealPeriod + 1);

        vm.prank(address(arbitrable));
        arb.setRevealPeriod(minRevealPeriod);

        // setArbitrationCost range + access control
        vm.expectRevert(IERC20VotesArbitrator.ONLY_ARBITRABLE.selector);
        arb.setArbitrationCost(minArbitrationCost);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        arb.setArbitrationCost(minArbitrationCost - 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        arb.setArbitrationCost(maxArbitrationCost + 1);

        vm.prank(address(arbitrable));
        arb.setArbitrationCost(minArbitrationCost);
        assertEq(arb.arbitrationCost(""), minArbitrationCost);
    }

    function test_setters_range_checks_both_sides() public {
        uint256 minDelay = arb.MIN_VOTING_DELAY();
        uint256 maxDelay = arb.MAX_VOTING_DELAY();
        uint256 minReveal = arb.MIN_REVEAL_PERIOD();
        uint256 maxReveal = arb.MAX_REVEAL_PERIOD();
        uint256 minPeriod = arb.MIN_VOTING_PERIOD();
        uint256 maxPeriod = arb.MAX_VOTING_PERIOD();
        uint256 minCost = arb.MIN_ARBITRATION_COST();
        uint256 maxCost = arb.MAX_ARBITRATION_COST();

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        arb.setVotingDelay(minDelay - 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        arb.setVotingDelay(maxDelay + 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        arb.setRevealPeriod(minReveal - 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        arb.setRevealPeriod(maxReveal + 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_PERIOD.selector);
        arb.setVotingPeriod(minPeriod - 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_PERIOD.selector);
        arb.setVotingPeriod(maxPeriod + 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        arb.setArbitrationCost(minCost - 1);

        vm.prank(address(arbitrable));
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        arb.setArbitrationCost(maxCost + 1);
    }

    function test_internal_helpers_via_harness() public {
        ArbitratorHarness h = new ArbitratorHarness();

        assertEq(uint256(h.exposed_convertChoiceToParty(0)), uint256(IArbitrable.Party.None));
        assertEq(uint256(h.exposed_convertChoiceToParty(1)), uint256(IArbitrable.Party.Requester));
        assertEq(uint256(h.exposed_convertChoiceToParty(2)), uint256(IArbitrable.Party.Challenger));
        assertEq(uint256(h.exposed_convertChoiceToParty(999)), uint256(IArbitrable.Party.None));

        assertEq(h.exposed_bps2Uint(10_000, 1000), 1000);
        assertEq(h.exposed_bps2Uint(5_000, 1000), 500);
    }

    function test_upgrade_reverts_when_nonupgradeable() public {
        // deploy new impl
        ERC20VotesArbitratorUpgradeMock newImpl = new ERC20VotesArbitratorUpgradeMock();

        vm.expectRevert(ERC20VotesArbitrator.NON_UPGRADEABLE.selector);
        arb.upgradeToAndCall(address(newImpl), bytes(""));

        vm.prank(address(arbitrable));
        vm.expectRevert(ERC20VotesArbitrator.NON_UPGRADEABLE.selector);
        arb.upgradeToAndCall(address(newImpl), bytes(""));
    }
}
