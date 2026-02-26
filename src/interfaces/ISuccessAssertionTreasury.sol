// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface ISuccessAssertionTreasury {
    enum TreasuryKind {
        Unknown,
        Goal,
        Budget
    }

    function treasuryKind() external view returns (TreasuryKind);
    function successResolver() external view returns (address);
    function successAssertionLiveness() external view returns (uint64);
    function successAssertionBond() external view returns (uint256);
    function successOracleSpecHash() external view returns (bytes32);
    function successAssertionPolicyHash() external view returns (bytes32);
    function pendingSuccessAssertionId() external view returns (bytes32);
    function pendingSuccessAssertionAt() external view returns (uint64);
    function reassertGraceDeadline() external view returns (uint64);
    function reassertGraceUsed() external view returns (bool);
    function isReassertGraceActive() external view returns (bool);

    function registerSuccessAssertion(bytes32 assertionId) external;
    function clearSuccessAssertion(bytes32 assertionId) external;
    function resolveSuccess() external;
}
