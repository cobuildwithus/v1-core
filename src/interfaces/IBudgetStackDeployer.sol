// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IBudgetStackControllerReader } from "./IBudgetStackControllerReader.sol";
import { IBudgetMechanismProvider } from "./IBudgetMechanismProvider.sol";
import { IBudgetStackRuntimeDeployer } from "./IBudgetStackRuntimeDeployer.sol";

interface IBudgetStackDeployer is IBudgetStackControllerReader, IBudgetStackRuntimeDeployer, IBudgetMechanismProvider {}
