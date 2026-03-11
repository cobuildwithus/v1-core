// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IAllocationKeyAccountResolver } from "./IAllocationKeyAccountResolver.sol";
import { IAllocationStrategy } from "./IAllocationStrategy.sol";
import { IBudgetStakeLedger } from "./IBudgetStakeLedger.sol";

/// @notice Shared per-goal budget-flow strategy using explicit flow context to resolve budget recipient routing.
interface IBudgetFlowRouterStrategy is IAllocationStrategy, IAllocationKeyAccountResolver {
    enum FlowBudgetStatus {
        Active,
        FlowNotRegistered,
        MissingBudgetTreasury,
        InvalidBudgetTreasury,
        BudgetProbeFailed,
        BudgetResolved
    }

    error ONLY_REGISTRAR(address caller, address registrar);
    error FLOW_ALREADY_REGISTERED(address flow);
    error INVALID_FLOW(address flow);
    error INVALID_FLOW_STRATEGY(address flow, address expectedStrategy, address configuredStrategy);

    event FlowRecipientRegistered(address indexed flow, bytes32 indexed recipientId);

    function budgetStakeLedger() external view returns (IBudgetStakeLedger);
    function registrar() external view returns (address);

    function registerFlowRecipient(address flow, bytes32 recipientId) external;

    function recipientIdForFlow(address flow) external view returns (bytes32 recipientId, bool registered);

    /// @notice Returns budget resolution status for the provided flow.
    function flowBudgetStatus(address flow) external view returns (address budgetTreasury, FlowBudgetStatus status);

    /// @notice Returns whether `account` has positive allocation weight scoped to the provided flow.
    function canAccountAllocate(address flow, address account) external view returns (bool);

    /// @notice Returns current allocation weight for `account` scoped to the provided flow.
    function accountAllocationWeight(address flow, address account) external view returns (uint256);
}
