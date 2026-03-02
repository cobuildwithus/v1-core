// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "./IAllocationKeyAccountResolver.sol";
import { IAllocationStrategy } from "./IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "./IBudgetStakeLedger.sol";

/// @notice Shared per-goal budget-flow strategy using caller-flow context to resolve budget recipient routing.
/// @dev Inherited `IAllocationStrategy` views (`currentWeight`, `canAllocate`, `canAccountAllocate`,
///      `accountAllocationWeight`) are sender-context hooks for in-flow runtime calls where `msg.sender` is the flow.
///      Off-chain callers should use the explicit `*ForFlow` views below.
interface IBudgetFlowRouterStrategy is IAllocationStrategy, IAllocationKeyAccountResolver {
    error ONLY_REGISTRAR(address caller, address registrar);
    error FLOW_ALREADY_REGISTERED(address flow);
    error INVALID_FLOW(address flow);
    error INVALID_FLOW_STRATEGY_COUNT(address flow, uint256 strategyCount);
    error INVALID_FLOW_STRATEGY(address flow, address expectedStrategy, address configuredStrategy);

    event FlowRecipientRegistered(address indexed flow, bytes32 indexed recipientId);

    function budgetStakeLedger() external view returns (IBudgetStakeLedger);
    function registrar() external view returns (address);

    function registerFlowRecipient(address flow, bytes32 recipientId) external;

    function recipientIdForFlow(address flow) external view returns (bytes32 recipientId, bool registered);

    /// @notice Returns live weight for `key` scoped to the provided flow.
    function currentWeightForFlow(address flow, uint256 key) external view returns (uint256);

    /// @notice Returns whether `caller` can allocate for `key` scoped to the provided flow.
    function canAllocateForFlow(address flow, uint256 key, address caller) external view returns (bool);

    /// @notice Returns whether `account` has positive allocation weight scoped to the provided flow.
    function canAccountAllocateForFlow(address flow, address account) external view returns (bool);

    /// @notice Returns current allocation weight for `account` scoped to the provided flow.
    function accountAllocationWeightForFlow(address flow, address account) external view returns (uint256);
}
