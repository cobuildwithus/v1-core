// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IERC20Votes is IVotes, IERC20, IERC20Metadata {}
