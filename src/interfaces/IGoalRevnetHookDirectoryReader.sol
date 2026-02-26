// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";

interface IGoalRevnetHookDirectoryReader {
    function directory() external view returns (IJBDirectory);
}
