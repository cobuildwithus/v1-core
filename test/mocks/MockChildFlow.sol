// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

contract MockChildFlow {
    int96 public actual;
    int96 public maxSafe;
    bool public tooHigh;
    uint256 public requiredBuffer;

    bool public revertOnGetRequiredBuffer;
    bool public revertOnIsTooHigh;
    bool public revertOnGetActual;
    bool public revertOnGetMaxSafe;
    bool public revertOnGetActualAfterIncrease;
    bool public revertOnIncrease;
    bool public revertOnDecrease;

    // 10000 == full requested increase; lower values simulate partial increase.
    uint16 public partialIncreaseBps = 10_000;

    int96 public lastIncreaseAmount;

    function setActual(int96 v) external {
        actual = v;
    }

    function setMaxSafe(int96 v) external {
        maxSafe = v;
    }

    function setTooHigh(bool v) external {
        tooHigh = v;
    }

    function setRequiredBuffer(uint256 v) external {
        requiredBuffer = v;
    }

    function setRevertOnGetRequiredBuffer(bool v) external {
        revertOnGetRequiredBuffer = v;
    }

    function setRevertOnIsTooHigh(bool v) external {
        revertOnIsTooHigh = v;
    }

    function setRevertOnGetActual(bool v) external {
        revertOnGetActual = v;
    }

    function setRevertOnGetMaxSafe(bool v) external {
        revertOnGetMaxSafe = v;
    }

    function setRevertOnGetActualAfterIncrease(bool v) external {
        revertOnGetActualAfterIncrease = v;
    }

    function setRevertOnIncrease(bool v) external {
        revertOnIncrease = v;
    }

    function setRevertOnDecrease(bool v) external {
        revertOnDecrease = v;
    }

    function setPartialIncreaseBps(uint16 bps) external {
        partialIncreaseBps = bps;
    }

    function getActualFlowRate() external view returns (int96) {
        if (revertOnGetActual) revert("actual");
        return actual;
    }

    function getMaxSafeFlowRate() external view returns (int96) {
        if (revertOnGetMaxSafe) revert("maxsafe");
        return maxSafe;
    }

    function isFlowRateTooHigh() external view returns (bool) {
        if (revertOnIsTooHigh) revert("toohigh");
        return tooHigh;
    }

    function getRequiredBufferAmount(int96) external view returns (uint256) {
        if (revertOnGetRequiredBuffer) revert("buffer");
        return requiredBuffer;
    }

    function increaseFlowRate(int96 amount) external {
        if (revertOnIncrease) revert("increase");
        lastIncreaseAmount = amount;
        int96 inc = int96((int256(amount) * int256(uint256(partialIncreaseBps))) / 10_000);
        actual += inc;
        if (revertOnGetActualAfterIncrease) revertOnGetActual = true;
    }

    function capFlowRateToMaxSafe() external {
        if (revertOnDecrease) revert("decrease");
        if (actual > maxSafe) actual = maxSafe;
    }
}
