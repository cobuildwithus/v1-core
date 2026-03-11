// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetFlowRouterStrategy } from "../interfaces/IBudgetFlowRouterStrategy.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IManagedFlow } from "../interfaces/IManagedFlow.sol";
import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Shared budget-flow strategy that resolves budget context from explicit flow addresses.
contract BudgetFlowRouterStrategy is AddressKeyAllocationStrategy, IBudgetFlowRouterStrategy, Initializable {
    IBudgetStakeLedger public override budgetStakeLedger;
    address public override registrar;

    string public constant STRATEGY_KEY = "BudgetStake";

    mapping(address flow => bytes32 recipientId) private _recipientIdByFlow;
    mapping(address flow => bool registered) private _flowRegistered;

    constructor() {
        _disableInitializers();
    }

    function initialize(address budgetStakeLedger_, address registrar_) external initializer {
        if (budgetStakeLedger_ == address(0)) revert ADDRESS_ZERO();
        if (registrar_ == address(0)) revert ADDRESS_ZERO();
        budgetStakeLedger = IBudgetStakeLedger(budgetStakeLedger_);
        registrar = registrar_;
    }

    function registerFlowRecipient(address flow, bytes32 recipientId) external override {
        if (msg.sender != registrar) revert ONLY_REGISTRAR(msg.sender, registrar);
        if (flow == address(0) || flow.code.length == 0) revert INVALID_FLOW(flow);
        if (_flowRegistered[flow]) revert FLOW_ALREADY_REGISTERED(flow);

        address configuredStrategy = _flowStrategy(flow);
        if (configuredStrategy != address(this)) {
            revert INVALID_FLOW_STRATEGY(flow, address(this), configuredStrategy);
        }

        _flowRegistered[flow] = true;
        _recipientIdByFlow[flow] = recipientId;

        emit FlowRecipientRegistered(flow, recipientId);
    }

    function recipientIdForFlow(address flow) external view override returns (bytes32 recipientId, bool registered) {
        registered = _flowRegistered[flow];
        recipientId = _recipientIdByFlow[flow];
    }

    function flowBudgetStatus(
        address flow
    ) external view override returns (address budgetTreasury, FlowBudgetStatus status) {
        return _effectiveTreasuryAndStatusForFlow(flow);
    }

    /// @notice Returns live weight for `key` in explicit `flow` context.
    function currentWeight(address flow, uint256 key) external view override returns (uint256) {
        return _accountAllocationWeightForFlow(flow, _accountForKey(key));
    }

    /// @notice Returns whether `caller` can allocate for `key` in explicit `flow` context.
    function canAllocate(address flow, uint256 key, address caller) external view override returns (bool) {
        address allocator = _accountForKey(key);
        return caller == allocator && _accountAllocationWeightForFlow(flow, allocator) > 0;
    }

    /// @notice Returns whether `account` has positive allocation weight in explicit `flow` context.
    function canAccountAllocate(address flow, address account) external view override returns (bool) {
        return _accountAllocationWeightForFlow(flow, account) > 0;
    }

    /// @notice Returns current allocation weight for `account` in explicit `flow` context.
    function accountAllocationWeight(address flow, address account) external view override returns (uint256) {
        return _accountAllocationWeightForFlow(flow, account);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _accountAllocationWeightForFlow(address flow, address account) internal view returns (uint256) {
        (address budgetTreasury, FlowBudgetStatus status) = _effectiveTreasuryAndStatusForFlow(flow);
        if (status != FlowBudgetStatus.Active) return 0;
        return budgetStakeLedger.userAllocatedStakeOnBudget(account, budgetTreasury);
    }

    function _flowStrategy(address flow) internal view returns (address configuredStrategy) {
        try IManagedFlow(flow).strategy() returns (IAllocationStrategy configuredStrategy_) {
            configuredStrategy = address(configuredStrategy_);
        } catch {
            revert INVALID_FLOW(flow);
        }
    }

    function _effectiveTreasuryAndStatusForFlow(
        address flow
    ) internal view returns (address effectiveBudgetTreasury, FlowBudgetStatus status) {
        if (!_flowRegistered[flow]) return (address(0), FlowBudgetStatus.FlowNotRegistered);

        effectiveBudgetTreasury = budgetStakeLedger.budgetForRecipient(_recipientIdByFlow[flow]);
        if (effectiveBudgetTreasury == address(0))
            return (effectiveBudgetTreasury, FlowBudgetStatus.MissingBudgetTreasury);
        if (effectiveBudgetTreasury.code.length == 0)
            return (effectiveBudgetTreasury, FlowBudgetStatus.InvalidBudgetTreasury);

        try IBudgetTreasury(effectiveBudgetTreasury).resolved() returns (bool resolved_) {
            if (resolved_) return (effectiveBudgetTreasury, FlowBudgetStatus.BudgetResolved);
            return (effectiveBudgetTreasury, FlowBudgetStatus.Active);
        } catch {
            return (effectiveBudgetTreasury, FlowBudgetStatus.BudgetProbeFailed);
        }
    }
}
