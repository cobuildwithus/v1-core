// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v5/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v5/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v5/structs/JBTokenAmount.sol";

contract MockTerminalStore {
    IJBDirectory public immutable DIRECTORY;

    mapping(address terminal => mapping(uint256 projectId => mapping(address token => uint256))) public balanceOf;
    mapping(uint256 projectId => uint256) internal _recordedTokenCountOf;
    mapping(uint256 projectId => JBPayHookSpecification) internal _payHookSpecificationOf;

    bytes public lastMetadata;

    bool internal _paymentsPaused;

    error PAYMENT_PAUSED();

    constructor(IJBDirectory directory) {
        DIRECTORY = directory;
    }

    function setRecordedTokenCount(uint256 projectId, uint256 tokenCount) external {
        _recordedTokenCountOf[projectId] = tokenCount;
    }

    function setPaymentsPaused(bool paused) external {
        _paymentsPaused = paused;
    }

    function setPayHookSpecification(uint256 projectId, IJBPayHook hook, uint256 amount, bytes calldata metadata)
        external
    {
        _payHookSpecificationOf[projectId] = JBPayHookSpecification({hook: hook, amount: amount, metadata: metadata});
    }

    function currentSurplusOf(
        address terminal,
        uint256 projectId,
        JBAccountingContext[] calldata accountingContexts,
        uint256 decimals,
        uint256 currency
    ) external view returns (uint256 surplus) {
        uint256 contextsLength = accountingContexts.length;
        for (uint256 i; i < contextsLength; i++) {
            JBAccountingContext memory accountingContext = accountingContexts[i];
            if (accountingContext.token == address(0) || accountingContext.currency != currency) continue;

            uint256 balance = balanceOf[terminal][projectId][accountingContext.token];
            if (balance == 0) continue;

            if (accountingContext.decimals == decimals) {
                surplus += balance;
                continue;
            }

            if (accountingContext.decimals > decimals) {
                surplus += balance / 10 ** (accountingContext.decimals - decimals);
            } else {
                surplus += balance * 10 ** (decimals - accountingContext.decimals);
            }
        }
    }

    function recordAddedBalanceFor(uint256 projectId, address token, uint256 amount) external {
        balanceOf[msg.sender][projectId][token] += amount;
    }

    function recordPaymentFrom(
        address,
        JBTokenAmount calldata amount,
        uint256 projectId,
        address,
        bytes calldata metadata
    )
        external
        returns (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications)
    {
        if (_paymentsPaused) revert PAYMENT_PAUSED();

        lastMetadata = metadata;
        balanceOf[msg.sender][projectId][amount.token] += amount.value;
        tokenCount = _recordedTokenCountOf[projectId] == 0 ? amount.value : _recordedTokenCountOf[projectId];
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: uint256(amount.currency) << 36
        });

        JBPayHookSpecification storage payHookSpecification = _payHookSpecificationOf[projectId];
        if (address(payHookSpecification.hook) == address(0)) {
            hookSpecifications = new JBPayHookSpecification[](0);
        } else {
            hookSpecifications = new JBPayHookSpecification[](1);
            hookSpecifications[0] = JBPayHookSpecification({
                hook: payHookSpecification.hook,
                amount: payHookSpecification.amount,
                metadata: payHookSpecification.metadata
            });
        }
    }

    function recordTerminalMigration(uint256 projectId, address token) external returns (uint256 balance) {
        balance = balanceOf[msg.sender][projectId][token];
        balanceOf[msg.sender][projectId][token] = 0;
    }
}
