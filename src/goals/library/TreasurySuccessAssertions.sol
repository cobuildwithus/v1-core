// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IUMATreasurySuccessResolverConfig } from "src/interfaces/IUMATreasurySuccessResolverConfig.sol";
import { OptimisticOracleV3Interface } from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library TreasurySuccessAssertions {
    bytes32 internal constant UMA_ASSERT_TRUTH_IDENTIFIER = bytes32("ASSERT_TRUTH2");

    struct State {
        bytes32 pendingId;
        uint64 pendingAt;
    }

    enum FailClosedReason {
        None,
        ResolverConfigOracleReadFailed,
        OracleAddressZero,
        OracleAssertionReadFailed
    }

    error SUCCESS_ASSERTION_ALREADY_PENDING(bytes32 assertionId);
    error SUCCESS_ASSERTION_NOT_PENDING();
    error SUCCESS_ASSERTION_ID_MISMATCH(bytes32 expected, bytes32 actual);
    error INVALID_ASSERTION_ID();
    error SUCCESS_ASSERTION_NOT_VERIFIED();

    function pendingId(State storage self) internal view returns (bytes32) {
        return self.pendingId;
    }

    function pendingAt(State storage self) internal view returns (uint64) {
        return self.pendingAt;
    }

    function registerPending(State storage self, bytes32 assertionId) internal returns (uint64 assertedAt) {
        if (assertionId == bytes32(0)) revert INVALID_ASSERTION_ID();
        bytes32 activeAssertionId = self.pendingId;
        if (activeAssertionId != bytes32(0)) {
            revert SUCCESS_ASSERTION_ALREADY_PENDING(activeAssertionId);
        }

        self.pendingId = assertionId;
        assertedAt = uint64(block.timestamp);
        self.pendingAt = assertedAt;
    }

    function clearMatching(State storage self, bytes32 assertionId) internal returns (bytes32 clearedAssertionId) {
        bytes32 activeAssertionId = self.pendingId;
        if (activeAssertionId == bytes32(0)) revert SUCCESS_ASSERTION_NOT_PENDING();
        if (assertionId != activeAssertionId) {
            revert SUCCESS_ASSERTION_ID_MISMATCH(activeAssertionId, assertionId);
        }

        return _clear(self);
    }

    function clear(State storage self) internal returns (bytes32 clearedAssertionId) {
        return _clear(self);
    }

    function requirePending(State storage self) internal view returns (bytes32 assertionId) {
        assertionId = self.pendingId;
        if (assertionId == bytes32(0)) revert SUCCESS_ASSERTION_NOT_PENDING();
    }

    function requireTruthful(
        State storage self,
        address resolver,
        uint64 assertionLiveness,
        uint256 assertionBond
    ) internal view {
        if (!isTruthful(self.pendingId, self.pendingAt, resolver, assertionLiveness, assertionBond)) {
            revert SUCCESS_ASSERTION_NOT_VERIFIED();
        }
    }

    function isTruthful(
        bytes32 assertionId,
        uint64 assertedAt,
        address resolver,
        uint64 assertionLiveness,
        uint256 assertionBond
    ) internal view returns (bool) {
        IUMATreasurySuccessResolverConfig resolverConfig = IUMATreasurySuccessResolverConfig(resolver);
        OptimisticOracleV3Interface.Assertion memory assertion = resolverConfig.optimisticOracle().getAssertion(
            assertionId
        );

        if (!assertion.settled) return false;
        if (!assertion.settlementResolution) return false;
        if (assertion.callbackRecipient != resolver) return false;
        if (assertion.escalationManagerSettings.assertingCaller != resolver) return false;
        if (assertion.escalationManagerSettings.escalationManager != resolverConfig.escalationManager()) return false;
        if (address(assertion.currency) != address(resolverConfig.assertionCurrency())) return false;
        if (assertion.domainId != resolverConfig.domainId()) return false;

        return _matchesAssertionTail(assertion, assertedAt, assertionLiveness, assertionBond);
    }

    function pendingSuccessAssertionResolution(
        State storage self,
        bytes32 assertionId,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) internal view returns (bool isResolved, bool truthful) {
        (isResolved, truthful, ) = pendingSuccessAssertionResolutionWithReason(
            self,
            assertionId,
            successResolver,
            successAssertionLiveness,
            successAssertionBond
        );
    }

    function pendingSuccessAssertionResolutionWithReason(
        State storage self,
        bytes32 assertionId,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) internal view returns (bool isResolved, bool truthful, FailClosedReason failClosedReason) {
        IUMATreasurySuccessResolverConfig resolverConfig = IUMATreasurySuccessResolverConfig(successResolver);

        OptimisticOracleV3Interface assertionOracle;
        try resolverConfig.optimisticOracle() returns (OptimisticOracleV3Interface resolvedOracle) {
            assertionOracle = resolvedOracle;
        } catch {
            // A pending assertion cannot be validated without resolver config; fail closed to avoid indefinite lockup.
            return (true, false, FailClosedReason.ResolverConfigOracleReadFailed);
        }
        if (address(assertionOracle) == address(0)) return (true, false, FailClosedReason.OracleAddressZero);

        OptimisticOracleV3Interface.Assertion memory assertion;
        try assertionOracle.getAssertion(assertionId) returns (
            OptimisticOracleV3Interface.Assertion memory fetchedAssertion
        ) {
            assertion = fetchedAssertion;
        } catch {
            // Assertion reads must remain reliable post-deadline; fail closed when oracle access is unavailable.
            return (true, false, FailClosedReason.OracleAssertionReadFailed);
        }

        if (!assertion.settled) return (false, false, FailClosedReason.None);

        return (
            true,
            _isAssertionTruthfulFailClosed(
                assertion,
                self.pendingAt,
                resolverConfig,
                successResolver,
                successAssertionLiveness,
                successAssertionBond
            ),
            FailClosedReason.None
        );
    }

    function _isAssertionTruthfulFailClosed(
        OptimisticOracleV3Interface.Assertion memory assertion,
        uint64 assertedAt,
        IUMATreasurySuccessResolverConfig resolverConfig,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) private view returns (bool) {
        if (!assertion.settlementResolution) return false;
        if (assertion.callbackRecipient != successResolver) return false;
        if (assertion.escalationManagerSettings.assertingCaller != successResolver) return false;

        address expectedEscalationManager;
        try resolverConfig.escalationManager() returns (address escalationManager_) {
            expectedEscalationManager = escalationManager_;
        } catch {
            return false;
        }
        if (assertion.escalationManagerSettings.escalationManager != expectedEscalationManager) return false;

        IERC20 expectedCurrency;
        try resolverConfig.assertionCurrency() returns (IERC20 assertionCurrency_) {
            expectedCurrency = assertionCurrency_;
        } catch {
            return false;
        }
        if (address(assertion.currency) != address(expectedCurrency)) return false;

        bytes32 expectedDomainId;
        try resolverConfig.domainId() returns (bytes32 domainId_) {
            expectedDomainId = domainId_;
        } catch {
            return false;
        }
        if (assertion.domainId != expectedDomainId) return false;

        return _matchesAssertionTail(assertion, assertedAt, successAssertionLiveness, successAssertionBond);
    }

    function _matchesAssertionTail(
        OptimisticOracleV3Interface.Assertion memory assertion,
        uint64 assertedAt,
        uint64 assertionLiveness,
        uint256 assertionBond
    ) private pure returns (bool) {
        if (assertion.identifier != UMA_ASSERT_TRUTH_IDENTIFIER) return false;
        if (assertion.assertionTime != assertedAt) return false;
        if (assertion.expirationTime != assertedAt + assertionLiveness) return false;
        if (assertion.bond < assertionBond) return false;

        return true;
    }

    function _clear(State storage self) private returns (bytes32 clearedAssertionId) {
        clearedAssertionId = self.pendingId;
        if (clearedAssertionId == bytes32(0)) return bytes32(0);

        delete self.pendingId;
        delete self.pendingAt;
    }
}
