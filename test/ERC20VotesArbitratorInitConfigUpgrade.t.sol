// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20VotesArbitratorTestBase, ArbitratorHarness} from "test/ERC20VotesArbitrator.t.sol";

import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";
import {IArbitrator} from "src/tcr/interfaces/IArbitrator.sol";
import {IERC20VotesArbitrator} from "src/tcr/interfaces/IERC20VotesArbitrator.sol";
import {
    MockNonERC20Votes,
    MockVotesToken6Decimals
} from "test/mocks/MockIncompatibleVotesToken.sol";

contract InitConfigAuditCodeMock {}

contract InitConfigAuditFlowMock {
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }
}

contract InitConfigAuditBudgetTreasuryMock {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }
}

contract InitConfigAuditGoalTreasuryMock {
    address public budgetStakeLedger;
    address public flow;

    constructor(address budgetStakeLedger_, address flow_) {
        budgetStakeLedger = budgetStakeLedger_;
        flow = flow_;
    }
}

contract InitConfigAuditStakeVaultMock {
    address public goalTreasury;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }
}

contract ERC20VotesArbitratorInitConfigUpgradeTest is ERC20VotesArbitratorTestBase {
    function test_removedRuntimeConfigSetterSelectors_notExposed() public {
        IArbitrator.ArbitratorParams memory beforeParams = arb.getArbitratorParamsForFactory();
        address beforeStakeVault = arb.stakeVault();

        bytes[] memory removedSetterCalls = new bytes[](5);
        removedSetterCalls[0] = abi.encodeWithSignature("configureStakeVault(address)", address(0xBEEF));
        removedSetterCalls[1] = abi.encodeWithSignature("setVotingPeriod(uint256)", beforeParams.votingPeriod + 1);
        removedSetterCalls[2] = abi.encodeWithSignature("setVotingDelay(uint256)", beforeParams.votingDelay + 1);
        removedSetterCalls[3] = abi.encodeWithSignature("setRevealPeriod(uint256)", beforeParams.revealPeriod + 1);
        removedSetterCalls[4] = abi.encodeWithSignature("setArbitrationCost(uint256)", beforeParams.arbitrationCost + 1);

        for (uint256 i = 0; i < removedSetterCalls.length; ) {
            (bool success, bytes memory revertData) = address(arb).call(removedSetterCalls[i]);
            assertFalse(success);
            assertEq(revertData.length, 0);
            unchecked {
                ++i;
            }
        }

        IArbitrator.ArbitratorParams memory afterParams = arb.getArbitratorParamsForFactory();
        assertEq(afterParams.votingPeriod, beforeParams.votingPeriod);
        assertEq(afterParams.votingDelay, beforeParams.votingDelay);
        assertEq(afterParams.revealPeriod, beforeParams.revealPeriod);
        assertEq(afterParams.arbitrationCost, beforeParams.arbitrationCost);
        assertEq(afterParams.wrongOrMissedSlashBps, beforeParams.wrongOrMissedSlashBps);
        assertEq(afterParams.slashCallerBountyBps, beforeParams.slashCallerBountyBps);
        assertEq(arb.stakeVault(), beforeStakeVault);
    }

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
            _defaultArbitratorInitData(address(0), address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );

        // INVALID_ARBITRABLE_ADDRESS
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRABLE_ADDRESS.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(0), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );

        // INVALID_VOTING_TOKEN_ADDRESS
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_TOKEN_ADDRESS.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(0), address(arbitrable), votingPeriod, votingDelay, revealPeriod, arbitrationCost)
        );

        // INVALID_VOTING_PERIOD
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_PERIOD.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), minVotingPeriod - 1, votingDelay, revealPeriod, arbitrationCost)
        );

        // INVALID_VOTING_DELAY
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), votingPeriod, minVotingDelay - 1, revealPeriod, arbitrationCost)
        );

        // INVALID_REVEAL_PERIOD
        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), votingPeriod, votingDelay, minRevealPeriod - 1, arbitrationCost)
        );

        // INVALID_ARBITRATION_COST
        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, minArbitrationCost - 1)
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
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), maxVotingPeriod + 1, votingDelay, revealPeriod, arbitrationCost)
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_DELAY.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), votingPeriod, maxVotingDelay + 1, revealPeriod, arbitrationCost)
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_REVEAL_PERIOD.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), votingPeriod, votingDelay, maxRevealPeriod + 1, arbitrationCost)
        );

        vm.expectRevert(IERC20VotesArbitrator.INVALID_ARBITRATION_COST.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(owner, address(token), address(arbitrable), votingPeriod, votingDelay, revealPeriod, maxArbitrationCost + 1)
        );
    }

    function test_initialize_reverts_on_incompatible_voting_tokens() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();

        MockNonERC20Votes nonErc20Votes = new MockNonERC20Votes();
        vm.expectRevert(IERC20VotesArbitrator.INVALID_VOTING_TOKEN_COMPATIBILITY.selector);
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(
                    owner,
                    address(nonErc20Votes),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost
                )
        );

        MockVotesToken6Decimals token6 = new MockVotesToken6Decimals("Six Decimals Votes", "SIX");
        vm.expectRevert(abi.encodeWithSelector(IERC20VotesArbitrator.INVALID_VOTING_TOKEN_DECIMALS.selector, 6));
        _deployProxy(
            address(impl),
            _defaultArbitratorInitData(
                    owner,
                    address(token6),
                    address(arbitrable),
                    votingPeriod,
                    votingDelay,
                    revealPeriod,
                    arbitrationCost
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

    function test_removedLegacyInitializers_selectors_notExposed_onFreshProxy() public {
        bytes[] memory legacyCalls = new bytes[](6);
        legacyCalls[0] = abi.encodeWithSignature(
            "initialize(address,address,address,uint256,uint256,uint256,uint256)",
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );
        legacyCalls[1] = abi.encodeWithSignature(
            "initializeWithSlashConfig(address,address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost,
            uint256(321),
            uint256(123)
        );
        legacyCalls[2] = abi.encodeWithSignature(
            "initializeWithStakeVault(address,address,address,uint256,uint256,uint256,uint256,address)",
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost,
            address(0)
        );
        legacyCalls[3] = abi.encodeWithSignature(
            "initializeWithStakeVaultAndSlashConfig(address,address,address,uint256,uint256,uint256,uint256,address,uint256,uint256)",
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost,
            address(0),
            uint256(321),
            uint256(123)
        );
        legacyCalls[4] = abi.encodeWithSignature(
            "initializeWithStakeVaultAndBudgetScope(address,address,address,uint256,uint256,uint256,uint256,address,address)",
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost,
            address(0),
            address(0)
        );
        legacyCalls[5] = abi.encodeWithSignature(
            "initializeWithStakeVaultAndBudgetScopeAndSlashConfig(address,address,address,uint256,uint256,uint256,uint256,address,address,uint256,uint256)",
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost,
            address(0),
            address(0),
            uint256(321),
            uint256(123)
        );

        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        for (uint256 i = 0; i < legacyCalls.length; ) {
            address proxy = _deployProxy(address(impl), "");
            (bool success,) = proxy.call(legacyCalls[i]);
            assertFalse(success);
            assertEq(address(ERC20VotesArbitrator(proxy).votingToken()), address(0));
            assertEq(address(ERC20VotesArbitrator(proxy).arbitrable()), address(0));
            unchecked {
                ++i;
            }
        }
    }

    function test_initialize_config_accepts_explicit_slash_config() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        IERC20VotesArbitrator.InitConfig memory cfg = IERC20VotesArbitrator.InitConfig({
            invalidRoundRewardsSink: owner,
            votingToken: address(token),
            arbitrable: address(arbitrable),
            votingPeriod: votingPeriod,
            votingDelay: votingDelay,
            revealPeriod: revealPeriod,
            arbitrationCost: arbitrationCost,
            stakeVault: address(0),
            fixedBudgetTreasury: address(0),
            wrongOrMissedSlashBps: 321,
            slashCallerBountyBps: 123
        });

        ERC20VotesArbitrator configured =
            ERC20VotesArbitrator(
                _deployProxy(address(impl), _arbitratorInitData(cfg))
            );

        assertEq(configured.wrongOrMissedSlashBps(), 321);
        assertEq(configured.slashCallerBountyBps(), 123);
    }

    function test_initialize_config_reverts_when_fixed_budget_set_without_stake_vault() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        IERC20VotesArbitrator.InitConfig memory cfg = IERC20VotesArbitrator.InitConfig({
            invalidRoundRewardsSink: owner,
            votingToken: address(token),
            arbitrable: address(arbitrable),
            votingPeriod: votingPeriod,
            votingDelay: votingDelay,
            revealPeriod: revealPeriod,
            arbitrationCost: arbitrationCost,
            stakeVault: address(0),
            fixedBudgetTreasury: address(this),
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });

        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_ADDRESS.selector);
        _deployProxy(address(impl), _arbitratorInitData(cfg));
    }

    function test_initialize_config_reverts_when_stakeVault_goalTreasury_missing() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        InitConfigAuditStakeVaultMock badStakeVault = new InitConfigAuditStakeVaultMock(address(0));
        IERC20VotesArbitrator.InitConfig memory cfg = _defaultArbitratorInitConfig(
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );
        cfg.stakeVault = address(badStakeVault);

        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_GOAL_TREASURY.selector);
        _deployProxy(address(impl), _arbitratorInitData(cfg));
    }

    function test_initialize_config_reverts_when_stakeVault_budgetLedger_missing() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        InitConfigAuditGoalTreasuryMock badGoalTreasury = new InitConfigAuditGoalTreasuryMock(address(0), address(0));
        InitConfigAuditStakeVaultMock badStakeVault = new InitConfigAuditStakeVaultMock(address(badGoalTreasury));
        IERC20VotesArbitrator.InitConfig memory cfg = _defaultArbitratorInitConfig(
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );
        cfg.stakeVault = address(badStakeVault);

        vm.expectRevert(ERC20VotesArbitrator.INVALID_STAKE_VAULT_BUDGET_STAKE_LEDGER.selector);
        _deployProxy(address(impl), _arbitratorInitData(cfg));
    }

    function test_initialize_config_sets_stake_vault_and_fixed_budget_context() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        (address stakeVault_, address budgetTreasury_) = _deployValidFixedBudgetContext();

        IERC20VotesArbitrator.InitConfig memory cfg = IERC20VotesArbitrator.InitConfig({
            invalidRoundRewardsSink: owner,
            votingToken: address(token),
            arbitrable: address(arbitrable),
            votingPeriod: votingPeriod,
            votingDelay: votingDelay,
            revealPeriod: revealPeriod,
            arbitrationCost: arbitrationCost,
            stakeVault: stakeVault_,
            fixedBudgetTreasury: budgetTreasury_,
            wrongOrMissedSlashBps: 321,
            slashCallerBountyBps: 123
        });

        ERC20VotesArbitrator configured =
            ERC20VotesArbitrator(
                _deployProxy(address(impl), _arbitratorInitData(cfg))
            );

        assertEq(configured.stakeVault(), stakeVault_);
        assertEq(configured.fixedBudgetTreasury(), budgetTreasury_);
        assertEq(configured.wrongOrMissedSlashBps(), 321);
        assertEq(configured.slashCallerBountyBps(), 123);
    }

    function test_initialize_config_reverts_when_fixed_budget_context_is_invalid() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        (address stakeVault_, address budgetTreasury_) = _deployInvalidFixedBudgetContext();

        IERC20VotesArbitrator.InitConfig memory cfg = IERC20VotesArbitrator.InitConfig({
            invalidRoundRewardsSink: owner,
            votingToken: address(token),
            arbitrable: address(arbitrable),
            votingPeriod: votingPeriod,
            votingDelay: votingDelay,
            revealPeriod: revealPeriod,
            arbitrationCost: arbitrationCost,
            stakeVault: stakeVault_,
            fixedBudgetTreasury: budgetTreasury_,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });

        vm.expectRevert(IERC20VotesArbitrator.INVALID_FIXED_BUDGET_CONTEXT.selector);
        _deployProxy(address(impl), _arbitratorInitData(cfg));
    }

    function test_initialize_config_with_default_helper_uses_default_slash_values() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        (address stakeVault_, address budgetTreasury_) = _deployValidFixedBudgetContext();
        IERC20VotesArbitrator.InitConfig memory cfg = _defaultArbitratorInitConfig(
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );
        cfg.stakeVault = stakeVault_;
        cfg.fixedBudgetTreasury = budgetTreasury_;

        ERC20VotesArbitrator configured = ERC20VotesArbitrator(
            _deployProxy(
                address(impl),
                _arbitratorInitData(cfg)
            )
        );

        assertEq(configured.stakeVault(), stakeVault_);
        assertEq(configured.fixedBudgetTreasury(), budgetTreasury_);
        assertEq(configured.wrongOrMissedSlashBps(), configured.DEFAULT_WRONG_OR_MISSED_SLASH_BPS());
        assertEq(configured.slashCallerBountyBps(), configured.DEFAULT_SLASH_CALLER_BOUNTY_BPS());
    }

    function test_initialize_accepts_explicit_slash_config_and_reverts_on_caps() public {
        ERC20VotesArbitrator impl = new ERC20VotesArbitrator();
        IERC20VotesArbitrator.InitConfig memory cfg = _defaultArbitratorInitConfig(
            owner,
            address(token),
            address(arbitrable),
            votingPeriod,
            votingDelay,
            revealPeriod,
            arbitrationCost
        );

        cfg.wrongOrMissedSlashBps = 321;
        cfg.slashCallerBountyBps = 123;
        ERC20VotesArbitrator configured = ERC20VotesArbitrator(
            _deployProxy(address(impl), _arbitratorInitData(cfg))
        );
        assertEq(configured.wrongOrMissedSlashBps(), 321);
        assertEq(configured.slashCallerBountyBps(), 123);

        cfg.wrongOrMissedSlashBps = 10_001;
        cfg.slashCallerBountyBps = 0;
        vm.expectRevert(IERC20VotesArbitrator.INVALID_WRONG_OR_MISSED_SLASH_BPS.selector);
        _deployProxy(address(impl), _arbitratorInitData(cfg));

        cfg.wrongOrMissedSlashBps = 10_000;
        cfg.slashCallerBountyBps = 501;
        vm.expectRevert(IERC20VotesArbitrator.INVALID_SLASH_CALLER_BOUNTY_BPS.selector);
        _deployProxy(address(impl), _arbitratorInitData(cfg));
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

    function test_upgrade_selector_is_missing() public {
        bytes memory callData = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xBEEF), bytes(""));
        (bool success, bytes memory revertData) = address(arb).call(callData);
        assertFalse(success);
        assertEq(revertData.length, 0);

        vm.prank(address(arbitrable));
        (success, revertData) = address(arb).call(callData);
        assertFalse(success);
        assertEq(revertData.length, 0);
    }

    function _deployValidFixedBudgetContext() internal returns (address stakeVault_, address budgetTreasury_) {
        InitConfigAuditCodeMock budgetStakeLedger = new InitConfigAuditCodeMock();
        InitConfigAuditFlowMock goalFlow = new InitConfigAuditFlowMock(address(0));
        InitConfigAuditGoalTreasuryMock goalTreasury =
            new InitConfigAuditGoalTreasuryMock(address(budgetStakeLedger), address(goalFlow));
        InitConfigAuditStakeVaultMock stakeVault = new InitConfigAuditStakeVaultMock(address(goalTreasury));
        InitConfigAuditFlowMock budgetFlow = new InitConfigAuditFlowMock(address(goalFlow));
        InitConfigAuditBudgetTreasuryMock budgetTreasury = new InitConfigAuditBudgetTreasuryMock(address(budgetFlow));
        return (address(stakeVault), address(budgetTreasury));
    }

    function _deployInvalidFixedBudgetContext() internal returns (address stakeVault_, address budgetTreasury_) {
        InitConfigAuditCodeMock budgetStakeLedger = new InitConfigAuditCodeMock();
        InitConfigAuditFlowMock goalFlow = new InitConfigAuditFlowMock(address(0));
        InitConfigAuditGoalTreasuryMock goalTreasury =
            new InitConfigAuditGoalTreasuryMock(address(budgetStakeLedger), address(goalFlow));
        InitConfigAuditStakeVaultMock stakeVault = new InitConfigAuditStakeVaultMock(address(goalTreasury));
        InitConfigAuditFlowMock unrelatedFlow = new InitConfigAuditFlowMock(address(0));
        InitConfigAuditFlowMock budgetFlow = new InitConfigAuditFlowMock(address(unrelatedFlow));
        InitConfigAuditBudgetTreasuryMock budgetTreasury = new InitConfigAuditBudgetTreasuryMock(address(budgetFlow));
        return (address(stakeVault), address(budgetTreasury));
    }
}
