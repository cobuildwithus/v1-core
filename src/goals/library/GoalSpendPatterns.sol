// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

library GoalSpendPatterns {
    enum SpendPattern {
        Linear
    }

    function targetFlowRate(
        SpendPattern pattern,
        uint256 treasuryBalance,
        uint256 timeRemaining
    ) internal pure returns (int96 targetRate) {
        if (timeRemaining == 0) return 0;

        if (pattern == SpendPattern.Linear) {
            targetRate = _linearTargetFlowRate(treasuryBalance, timeRemaining);
            return targetRate;
        }

        return 0;
    }

    function _linearTargetFlowRate(uint256 treasuryBalance, uint256 timeRemaining) private pure returns (int96) {
        uint256 rate = treasuryBalance / timeRemaining;
        if (rate > uint256(uint96(type(int96).max))) return type(int96).max;
        return int96(uint96(rate));
    }
}
