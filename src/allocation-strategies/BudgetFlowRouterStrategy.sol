// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IBudgetFlowRouterStrategy } from "../interfaces/IBudgetFlowRouterStrategy.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";
import { IManagedFlow } from "../interfaces/IManagedFlow.sol";
import { AddressKeyAllocationStrategy } from "./AddressKeyAllocationStrategy.sol";

/// @notice Shared budget-flow strategy that resolves budget context from the caller flow address.
contract BudgetFlowRouterStrategy is AddressKeyAllocationStrategy, IBudgetFlowRouterStrategy {
    IBudgetStakeLedger public immutable override budgetStakeLedger;
    address public immutable override registrar;

    string public constant STRATEGY_KEY = "BudgetStake";

    mapping(address flow => bytes32 recipientId) private _recipientIdByFlow;
    mapping(address flow => bool registered) private _flowRegistered;

    constructor(IBudgetStakeLedger budgetStakeLedger_, address registrar_) {
        if (address(budgetStakeLedger_) == address(0)) revert ADDRESS_ZERO();
        if (registrar_ == address(0)) revert ADDRESS_ZERO();
        budgetStakeLedger = budgetStakeLedger_;
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

    function currentWeight(uint256 key) external view override returns (uint256) {
        return _currentWeightForFlow(msg.sender, key);
    }

    function canAllocate(uint256 key, address caller) external view override returns (bool) {
        return _canAllocateForFlow(msg.sender, key, caller);
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        return _canAccountAllocateForFlow(msg.sender, account);
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        return _accountAllocationWeightForFlow(msg.sender, account);
    }

    function currentWeightForFlow(address flow, uint256 key) external view override returns (uint256) {
        return _currentWeightForFlow(flow, key);
    }

    function canAllocateForFlow(address flow, uint256 key, address caller) external view override returns (bool) {
        return _canAllocateForFlow(flow, key, caller);
    }

    function canAccountAllocateForFlow(address flow, address account) external view override returns (bool) {
        return _canAccountAllocateForFlow(flow, account);
    }

    function accountAllocationWeightForFlow(address flow, address account) external view override returns (uint256) {
        return _accountAllocationWeightForFlow(flow, account);
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _currentWeightForFlow(address flow, uint256 key) internal view returns (uint256) {
        return _accountAllocationWeightForFlow(flow, _accountForKey(key));
    }

    function _canAllocateForFlow(address flow, uint256 key, address caller) internal view returns (bool) {
        address allocator = _accountForKey(key);
        if (caller != allocator) return false;
        return _accountAllocationWeightForFlow(flow, allocator) > 0;
    }

    function _canAccountAllocateForFlow(address flow, address account) internal view returns (bool) {
        return _accountAllocationWeightForFlow(flow, account) > 0;
    }

    function _accountAllocationWeightForFlow(address flow, address account) internal view returns (uint256) {
        (address budgetTreasury, bool closed) = _effectiveTreasuryAndClosedForFlow(flow);
        if (closed) return 0;
        return budgetStakeLedger.userAllocatedStakeOnBudget(account, budgetTreasury);
    }

    function _flowStrategy(address flow) internal view returns (address configuredStrategy) {
        IAllocationStrategy[] memory strategies;
        try IManagedFlow(flow).strategies() returns (IAllocationStrategy[] memory configuredStrategies) {
            strategies = configuredStrategies;
        } catch {
            revert INVALID_FLOW(flow);
        }

        uint256 strategyCount = strategies.length;
        if (strategyCount != 1) revert INVALID_FLOW_STRATEGY_COUNT(flow, strategyCount);
        configuredStrategy = address(strategies[0]);
    }

    function _effectiveTreasuryAndClosedForFlow(
        address flow
    ) internal view returns (address effectiveBudgetTreasury, bool closed) {
        if (!_flowRegistered[flow]) return (address(0), true);

        effectiveBudgetTreasury = budgetStakeLedger.budgetForRecipient(_recipientIdByFlow[flow]);
        if (effectiveBudgetTreasury == address(0)) return (effectiveBudgetTreasury, true);
        if (effectiveBudgetTreasury.code.length == 0) return (effectiveBudgetTreasury, true);

        try IBudgetTreasury(effectiveBudgetTreasury).resolved() returns (bool resolved_) {
            return (effectiveBudgetTreasury, resolved_);
        } catch {
            return (effectiveBudgetTreasury, true);
        }
    }
}
