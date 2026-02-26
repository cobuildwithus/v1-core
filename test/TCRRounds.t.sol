// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {GeneralizedTCRStorageV1} from "src/tcr/storage/GeneralizedTCRStorageV1.sol";
import {TCRRounds} from "src/tcr/library/TCRRounds.sol";
import {IArbitrable} from "src/tcr/interfaces/IArbitrable.sol";

contract TCRRoundsHarness {
    using TCRRounds for GeneralizedTCRStorageV1.Round;

    GeneralizedTCRStorageV1.Round internal r;

    function contribute(IArbitrable.Party side, address contributor, uint256 amount, uint256 totalRequired)
        external
        returns (uint256)
    {
        return r.contribute(side, contributor, amount, totalRequired);
    }

    function setHasPaid(bool requesterPaid, bool challengerPaid) external {
        r.hasPaid[uint256(IArbitrable.Party.Requester)] = requesterPaid;
        r.hasPaid[uint256(IArbitrable.Party.Challenger)] = challengerPaid;
    }

    function setFeeRewards(uint256 feeRewards) external {
        r.feeRewards = feeRewards;
    }

    function setAmountPaid(uint256 reqPaid, uint256 chalPaid) external {
        r.amountPaid[uint256(IArbitrable.Party.Requester)] = reqPaid;
        r.amountPaid[uint256(IArbitrable.Party.Challenger)] = chalPaid;
    }

    function setContribution(address who, uint256 reqContrib, uint256 chalContrib) external {
        r.contributions[who][uint256(IArbitrable.Party.Requester)] = reqContrib;
        r.contributions[who][uint256(IArbitrable.Party.Challenger)] = chalContrib;
    }

    function getContribution(address who) external view returns (uint256 req, uint256 chal) {
        req = r.contributions[who][uint256(IArbitrable.Party.Requester)];
        chal = r.contributions[who][uint256(IArbitrable.Party.Challenger)];
    }

    function withdraw(IArbitrable.Party ruling, address beneficiary) external returns (uint256) {
        return r.calculateAndWithdrawRewards(ruling, beneficiary);
    }
}

contract TCRRoundsTest is Test {
    TCRRoundsHarness internal h;
    address internal alice = makeAddr("alice");

    function setUp() public {
        h = new TCRRoundsHarness();
    }

    function test_contribute_partial_and_overfund_paths() public {
        // totalRequired = 100
        // partial available = 40 => taken 40, remainder 0 (covers required>available branch)
        uint256 c1 = h.contribute(IArbitrable.Party.Requester, alice, 40, 100);
        assertEq(c1, 40);

        // overfund available = 200 => taken remaining required (100-40=60), remainder ignored by caller (covers else branch)
        uint256 c2 = h.contribute(IArbitrable.Party.Requester, alice, 200, 100);
        assertEq(c2, 60);
    }

    function test_withdraw_rewards_branch_not_enough_fees_raised() public {
        // if either side not fully paid -> reimburse contributions sum
        h.setHasPaid(true, false);
        h.setContribution(alice, 123, 456);

        uint256 reward = h.withdraw(IArbitrable.Party.Requester, alice);
        assertEq(reward, 579);

        (uint256 req, uint256 chal) = h.getContribution(alice);
        assertEq(req, 0);
        assertEq(chal, 0);
    }

    function test_withdraw_rewards_branch_not_enough_fees_requester_unpaid() public {
        h.setHasPaid(false, true);
        h.setContribution(alice, 10, 20);

        uint256 reward = h.withdraw(IArbitrable.Party.Requester, alice);
        assertEq(reward, 30);

        (uint256 req, uint256 chal) = h.getContribution(alice);
        assertEq(req, 0);
        assertEq(chal, 0);
    }

    function test_withdraw_rewards_branch_not_enough_fees_both_unpaid() public {
        h.setHasPaid(false, false);
        h.setContribution(alice, 7, 9);

        uint256 reward = h.withdraw(IArbitrable.Party.Requester, alice);
        assertEq(reward, 16);

        (uint256 req, uint256 chal) = h.getContribution(alice);
        assertEq(req, 0);
        assertEq(chal, 0);
    }

    function test_withdraw_rewards_branch_ruling_none_proportional() public {
        // both sides paid, ruling None -> proportional to contributions
        h.setHasPaid(true, true);

        // simulate totals
        // totalPaid = 100 + 100
        // feeRewards = 150
        h.setAmountPaid(100, 100);
        h.setFeeRewards(150);

        // Alice contributed 25 to requester and 75 to challenger
        h.setContribution(alice, 25, 75);

        uint256 reward = h.withdraw(IArbitrable.Party.None, alice);

        // rewardRequester = 25*150/200 = 18 (floor)
        // rewardChallenger = 75*150/200 = 56 (floor)
        // total 74
        assertEq(reward, 74);
    }

    function test_withdraw_rewards_ruling_none_requester_amountPaid_zero() public {
        h.setHasPaid(true, true);

        h.setAmountPaid(0, 100);
        h.setFeeRewards(100);

        h.setContribution(alice, 0, 50);

        uint256 reward = h.withdraw(IArbitrable.Party.None, alice);
        assertEq(reward, 50);
    }

    function test_withdraw_rewards_ruling_none_challenger_amountPaid_zero() public {
        h.setHasPaid(true, true);

        h.setAmountPaid(100, 0);
        h.setFeeRewards(100);

        h.setContribution(alice, 40, 0);

        uint256 reward = h.withdraw(IArbitrable.Party.None, alice);
        assertEq(reward, 40);
    }

    function test_withdraw_rewards_branch_winner_gets_share() public {
        h.setHasPaid(true, true);

        h.setAmountPaid(100, 50);
        h.setFeeRewards(120);

        // winner = requester, alice contributed 40 to requester
        h.setContribution(alice, 40, 0);

        uint256 reward = h.withdraw(IArbitrable.Party.Requester, alice);

        // reward = 40*120/100 = 48
        assertEq(reward, 48);
    }

    function test_withdraw_rewards_branch_winner_challenger_gets_share() public {
        h.setHasPaid(true, true);

        h.setAmountPaid(80, 120);
        h.setFeeRewards(200);

        // winner = challenger, alice contributed 60 to challenger
        h.setContribution(alice, 0, 60);

        uint256 reward = h.withdraw(IArbitrable.Party.Challenger, alice);

        // reward = 60*200/120 = 100
        assertEq(reward, 100);
    }
}
