// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {LinearSpendPolicy} from "src/goals/policies/LinearSpendPolicy.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";

abstract contract SpendPolicyTestUtils {
    function _deployLinearSpendPolicy(bool includeIncomingRate, uint256 maxTargetFlowRate, ISpendPolicy.SyncMode syncMode)
        internal
        returns (LinearSpendPolicy policy)
    {
        LinearSpendPolicy implementation = new LinearSpendPolicy();
        policy = LinearSpendPolicy(Clones.clone(address(implementation)));
        policy.initialize(includeIncomingRate, maxTargetFlowRate, syncMode);
    }
}
