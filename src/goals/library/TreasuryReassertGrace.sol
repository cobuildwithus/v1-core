// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

library TreasuryReassertGrace {
    struct State {
        uint64 deadline;
        bool used;
    }

    error INVALID_REASSERT_GRACE_DURATION();

    function isActive(State storage self) internal view returns (bool) {
        uint64 graceDeadline = self.deadline;
        return graceDeadline != 0 && block.timestamp < graceDeadline;
    }

    function clearDeadline(State storage self) internal {
        self.deadline = 0;
    }

    function consumeIfActive(State storage self) internal returns (bool consumed) {
        if (!isActive(self)) return false;
        self.deadline = 0;
        return true;
    }

    function activateOnce(
        State storage self,
        uint64 graceDuration
    ) internal returns (bool activated, uint64 graceDeadline) {
        if (self.used) return (false, self.deadline);
        if (graceDuration == 0) revert INVALID_REASSERT_GRACE_DURATION();
        self.used = true;

        uint256 computedDeadline = block.timestamp + graceDuration;
        if (computedDeadline > type(uint64).max) computedDeadline = type(uint64).max;
        graceDeadline = uint64(computedDeadline);
        self.deadline = graceDeadline;

        return (true, graceDeadline);
    }
}
