// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUMATreasurySuccessResolverConfig } from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";

contract TreasuryMockUmaResolverConfig is IUMATreasurySuccessResolverConfig {
    OptimisticOracleV3Interface public immutable override optimisticOracle;
    IERC20 public immutable override assertionCurrency;
    address public immutable override escalationManager;
    bytes32 public immutable override domainId;

    constructor(
        OptimisticOracleV3Interface optimisticOracle_,
        IERC20 assertionCurrency_,
        address escalationManager_,
        bytes32 domainId_
    ) {
        optimisticOracle = optimisticOracle_;
        assertionCurrency = assertionCurrency_;
        escalationManager = escalationManager_;
        domainId = domainId_;
    }
}

contract TreasuryMockOptimisticOracleV3 {
    mapping(bytes32 => OptimisticOracleV3Interface.Assertion) internal _assertions;

    function getAssertion(bytes32 assertionId) external view returns (OptimisticOracleV3Interface.Assertion memory) {
        return _assertions[assertionId];
    }

    function setAssertion(bytes32 assertionId, OptimisticOracleV3Interface.Assertion calldata assertion) external {
        _assertions[assertionId] = assertion;
    }
}
