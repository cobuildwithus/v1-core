// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUMATreasurySuccessResolverConfig} from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";

contract TreasuryMockUmaResolverConfig is IUMATreasurySuccessResolverConfig {
    OptimisticOracleV3Interface public immutable override optimisticOracle;
    IERC20 public immutable override assertionCurrency;

    constructor(OptimisticOracleV3Interface optimisticOracle_, IERC20 assertionCurrency_) {
        optimisticOracle = optimisticOracle_;
        assertionCurrency = assertionCurrency_;
    }
}

    contract TreasuryMockUmaResolverConfigWithFinalize is TreasuryMockUmaResolverConfig {
        error FINALIZE_REVERT();

        bytes32 public lastFinalizedAssertionId;
        uint256 public finalizeCallCount;
        bool public shouldRevertFinalize;

        constructor(OptimisticOracleV3Interface optimisticOracle_, IERC20 assertionCurrency_)
            TreasuryMockUmaResolverConfig(optimisticOracle_, assertionCurrency_)
        {}

        function setShouldRevertFinalize(bool value) external {
            shouldRevertFinalize = value;
        }

        function finalize(bytes32 assertionId) external returns (bool applied) {
            finalizeCallCount += 1;
            lastFinalizedAssertionId = assertionId;
            if (shouldRevertFinalize) revert FINALIZE_REVERT();
            return false;
        }
    }

    contract TreasuryMockOptimisticOracleV3 {
        mapping(bytes32 => OptimisticOracleV3Interface.Assertion) internal _assertions;

        function getAssertion(bytes32 assertionId)
            external
            view
            returns (OptimisticOracleV3Interface.Assertion memory)
        {
            return _assertions[assertionId];
        }

        function setAssertion(bytes32 assertionId, OptimisticOracleV3Interface.Assertion calldata assertion) external {
            _assertions[assertionId] = assertion;
        }
    }

    library TreasuryUmaResolverMockFactory {
        function deployResolver(IERC20 assertionCurrency) internal returns (TreasuryMockUmaResolverConfig resolver) {
            resolver = new TreasuryMockUmaResolverConfig(
                OptimisticOracleV3Interface(address(new TreasuryMockOptimisticOracleV3())), assertionCurrency
            );
        }
    }
