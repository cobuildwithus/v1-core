// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBCashOutHook} from "@bananapus/core-v5/interfaces/IJBCashOutHook.sol";
import {IJBPayHook} from "@bananapus/core-v5/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v5/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v5/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v5/structs/JBTokenAmount.sol";

contract MockTerminalStore {
    struct CashOutConfig {
        uint256 reclaimAmount;
        uint256 cashOutTaxRate;
        IJBCashOutHook hook;
        uint256 hookAmount;
        bytes hookMetadata;
    }

    IJBDirectory public immutable DIRECTORY;

    mapping(address terminal => mapping(uint256 projectId => mapping(address token => uint256))) public balanceOf;
    mapping(uint256 projectId => uint256) internal _recordedTokenCountOf;
    mapping(uint256 projectId => JBPayHookSpecification) internal _payHookSpecificationOf;
    mapping(uint256 projectId => mapping(address token => CashOutConfig)) internal _cashOutConfigOf;
    mapping(uint256 projectId => bytes) internal _lastCashOutMetadataOf;
    mapping(uint256 projectId => uint256) public cashOutCallCountOf;

    bytes public lastMetadata;
    bytes public lastCashOutMetadata;

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

    function setCashOutConfig(
        uint256 projectId,
        address token,
        uint256 reclaimAmount,
        uint256 cashOutTaxRate,
        IJBCashOutHook hook,
        uint256 hookAmount,
        bytes calldata hookMetadata
    ) external {
        _cashOutConfigOf[projectId][token] = CashOutConfig({
            reclaimAmount: reclaimAmount,
            cashOutTaxRate: cashOutTaxRate,
            hook: hook,
            hookAmount: hookAmount,
            hookMetadata: hookMetadata
        });
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
        ruleset = _mockRuleset(amount.currency);

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

    function recordCashOutFor(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        JBAccountingContext calldata accountingContext,
        JBAccountingContext[] calldata,
        bytes calldata metadata
    )
        external
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        lastCashOutMetadata = metadata;
        _lastCashOutMetadataOf[projectId] = metadata;
        cashOutCallCountOf[projectId] += 1;

        CashOutConfig storage cashOutConfig = _cashOutConfigOf[projectId][accountingContext.token];
        reclaimAmount = cashOutConfig.reclaimAmount == 0 ? cashOutCount : cashOutConfig.reclaimAmount;
        cashOutTaxRate = cashOutConfig.cashOutTaxRate;

        uint256 totalOutbound = reclaimAmount + cashOutConfig.hookAmount;
        balanceOf[msg.sender][projectId][accountingContext.token] -= totalOutbound;

        ruleset = _mockRuleset(accountingContext.currency);

        if (address(cashOutConfig.hook) == address(0)) {
            hookSpecifications = new JBCashOutHookSpecification[](0);
        } else {
            hookSpecifications = new JBCashOutHookSpecification[](1);
            hookSpecifications[0] = JBCashOutHookSpecification({
                hook: cashOutConfig.hook, amount: cashOutConfig.hookAmount, metadata: cashOutConfig.hookMetadata
            });
        }
    }

    function recordTerminalMigration(uint256 projectId, address token) external returns (uint256 balance) {
        balance = balanceOf[msg.sender][projectId][token];
        balanceOf[msg.sender][projectId][token] = 0;
    }

    function lastCashOutMetadataOf(uint256 projectId) external view returns (bytes memory metadata) {
        metadata = _lastCashOutMetadataOf[projectId];
    }

    function _mockRuleset(uint256 currency) internal pure returns (JBRuleset memory ruleset) {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: currency << 36
        });
    }
}
