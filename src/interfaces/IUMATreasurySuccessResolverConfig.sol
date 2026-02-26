// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";

interface IUMATreasurySuccessResolverConfig {
    function optimisticOracle() external view returns (OptimisticOracleV3Interface);
    function assertionCurrency() external view returns (IERC20);
    function escalationManager() external view returns (address);
    function domainId() external view returns (bytes32);
}
