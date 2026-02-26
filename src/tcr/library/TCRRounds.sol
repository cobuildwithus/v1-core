// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { GeneralizedTCRStorageV1 } from "../storage/GeneralizedTCRStorageV1.sol";
import { IArbitrable } from "../interfaces/IArbitrable.sol";
import { CappedMath } from "../utils/CappedMath.sol";

library TCRRounds {
    using CappedMath for uint256;

    /**
     * @dev Returns the contribution value and remainder from available ERC20 tokens and required amount.
     *  @param _available The amount of ERC20 tokens available for the contribution.
     *  @param _requiredAmount The amount of ERC20 tokens required for the contribution.
     *  @return taken The amount of ERC20 tokens taken.
     *  @return remainder The amount of ERC20 tokens left from the contribution.
     */
    function _calculateContribution(
        uint256 _available,
        uint256 _requiredAmount
    ) internal pure returns (uint256 taken, uint256 remainder) {
        // Take whatever is available, return 0 as leftover ERC20 tokens.
        if (_requiredAmount > _available) return (_available, 0);
        // Take the required amount, return the remaining ERC20 tokens.
        else return (_requiredAmount, _available - _requiredAmount);
    }

    /**
     * @dev Make a fee contribution to a round.
     * @param round The round to contribute to.
     * @param side The side for which to contribute.
     * @param contributor The address of the contributor.
     * @param amount The amount of ERC20 tokens to contribute.
     * @param totalRequired The total amount required for this side.
     * @return contribution The amount of fees contributed.
     */
    function contribute(
        GeneralizedTCRStorageV1.Round storage round,
        IArbitrable.Party side,
        address contributor,
        uint256 amount,
        uint256 totalRequired
    ) public returns (uint256 contribution) {
        uint256 remainingERC20;
        (contribution, remainingERC20) = _calculateContribution(
            amount,
            totalRequired.subCap(round.amountPaid[uint256(side)])
        );
        round.contributions[contributor][uint256(side)] += contribution;
        round.amountPaid[uint256(side)] += contribution;
        round.feeRewards += contribution;

        return contribution;
    }

    /**
     * @dev Calculate and withdraw rewards for a beneficiary.
     * @param round The round to calculate rewards for.
     * @param ruling The ruling to calculate rewards for.
     * @param beneficiary The address of the beneficiary.
     * @return reward The amount of rewards to withdraw.
     */
    function calculateAndWithdrawRewards(
        GeneralizedTCRStorageV1.Round storage round,
        IArbitrable.Party ruling,
        address beneficiary
    ) public returns (uint256 reward) {
        if (
            !round.hasPaid[uint256(IArbitrable.Party.Requester)] ||
            !round.hasPaid[uint256(IArbitrable.Party.Challenger)]
        ) {
            // Reimburse if not enough fees were raised to appeal the ruling.
            reward =
                round.contributions[beneficiary][uint256(IArbitrable.Party.Requester)] +
                round.contributions[beneficiary][uint256(IArbitrable.Party.Challenger)];
        } else if (ruling == IArbitrable.Party.None) {
            // Reimburse unspent fees proportionally if there is no winner or loser.
            uint256 rewardRequester = round.amountPaid[uint256(IArbitrable.Party.Requester)] > 0
                ? (round.contributions[beneficiary][uint256(IArbitrable.Party.Requester)] * round.feeRewards) /
                    (round.amountPaid[uint256(IArbitrable.Party.Challenger)] +
                        round.amountPaid[uint256(IArbitrable.Party.Requester)])
                : 0;
            uint256 rewardChallenger = round.amountPaid[uint256(IArbitrable.Party.Challenger)] > 0
                ? (round.contributions[beneficiary][uint256(IArbitrable.Party.Challenger)] * round.feeRewards) /
                    (round.amountPaid[uint256(IArbitrable.Party.Challenger)] +
                        round.amountPaid[uint256(IArbitrable.Party.Requester)])
                : 0;

            reward = rewardRequester + rewardChallenger;
        } else {
            // Reward the winner.
            reward = round.amountPaid[uint256(ruling)] > 0
                ? (round.contributions[beneficiary][uint256(ruling)] * round.feeRewards) /
                    round.amountPaid[uint256(ruling)]
                : 0;
        }
        round.contributions[beneficiary][uint256(IArbitrable.Party.Requester)] = 0;
        round.contributions[beneficiary][uint256(IArbitrable.Party.Challenger)] = 0;
    }
}
