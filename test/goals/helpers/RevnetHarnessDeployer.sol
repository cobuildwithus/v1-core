// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Vm } from "forge-std/Vm.sol";

import { RevnetTestHarness } from "test/goals/helpers/RevnetTestHarness.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

interface IRevnetHarness {
    function directory() external view returns (IJBDirectory);
    function rulesets() external view returns (IJBRulesets);
    function createRevnet(uint112 weight) external returns (uint256 revnetId);
    function createRevnetWithMintClose(uint112 weight, uint40 mintCloseTimestamp) external returns (uint256 revnetId);
    function setTokenProjectId(address token, uint256 projectId) external;
}

library RevnetHarnessDeployer {
    function deploy(Vm) internal returns (IRevnetHarness harness) {
        harness = IRevnetHarness(address(new RevnetTestHarness()));
    }
}
