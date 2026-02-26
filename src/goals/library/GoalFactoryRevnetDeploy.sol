// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";

import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBAccountingContext } from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBTerminalConfig } from "@bananapus/core-v5/structs/JBTerminalConfig.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

library GoalFactoryRevnetDeploy {
    error ADDRESS_ZERO();

    struct RevnetDeploymentRequest {
        IREVDeployer revDeployer;
        address cobuildToken;
        uint8 cobuildDecimals;
        uint256 cobuildRevnetId;
        address splitHook;
        address owner;
        string name;
        string ticker;
        string uri;
        uint112 initialIssuance;
        uint16 cashOutTaxRate;
        uint16 reservedPercent;
        uint32 durationSeconds;
        address burnAddress;
    }

    struct RevnetDeploymentResult {
        IJBDirectory directory;
        IJBController controller;
        IJBRulesets rulesets;
        uint256 goalRevnetId;
        address goalToken;
    }

    function deployRevnet(
        RevnetDeploymentRequest memory request
    ) external returns (RevnetDeploymentResult memory) {
        uint32 cobuildCurrency = uint32(uint160(request.cobuildToken));
        uint48 start = uint48(block.timestamp);

        JBSplit[] memory reservedSplits = new JBSplit[](1);
        reservedSplits[0] = JBSplit({
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: payable(request.splitHook),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(request.splitHook)
        });

        IREVDeployer.REVStageConfig[] memory stages = new IREVDeployer.REVStageConfig[](2);
        stages[0] = IREVDeployer.REVStageConfig({
            startsAtOrAfter: start,
            autoIssuances: new IREVDeployer.REVAutoIssuance[](0),
            splitPercent: request.reservedPercent,
            splits: reservedSplits,
            initialIssuance: request.initialIssuance,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: request.cashOutTaxRate,
            extraMetadata: 0
        });
        stages[1] = IREVDeployer.REVStageConfig({
            startsAtOrAfter: start + request.durationSeconds,
            autoIssuances: new IREVDeployer.REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: 0,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: request.cashOutTaxRate,
            extraMetadata: 0
        });

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: request.cobuildToken,
            decimals: request.cobuildDecimals,
            currency: cobuildCurrency
        });

        IJBDirectory directory = request.revDeployer.DIRECTORY();
        IJBTerminal goalTerminal = directory.primaryTerminalOf(request.cobuildRevnetId, request.cobuildToken);
        if (address(goalTerminal) == address(0)) revert ADDRESS_ZERO();

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] =
            JBTerminalConfig({ terminal: goalTerminal, accountingContextsToAccept: contexts });

        uint256 goalRevnetId = request.revDeployer.deployFor(
            0,
            IREVDeployer.REVConfig({
                description: IREVDeployer.REVDescription({
                    name: request.name,
                    ticker: request.ticker,
                    uri: request.uri,
                    salt: bytes32(uint256(uint160(request.owner)))
                }),
                baseCurrency: cobuildCurrency,
                splitOperator: request.burnAddress,
                stageConfigurations: stages,
                loanSources: new IREVDeployer.REVLoanSource[](0),
                loans: address(0)
            }),
            terminalConfigs,
            IREVDeployer.REVBuybackHookConfig({
                dataHook: address(0),
                hookToConfigure: address(0),
                poolConfigurations: new IREVDeployer.REVBuybackPoolConfig[](0)
            }),
            IREVDeployer.REVSuckerDeploymentConfig({
                deployerConfigurations: new IREVDeployer.JBSuckerDeployerConfig[](0),
                salt: bytes32(0)
            })
        );

        IJBController controller = request.revDeployer.CONTROLLER();
        IJBTokens tokens = controller.TOKENS();
        address goalToken = address(tokens.tokenOf(goalRevnetId));
        if (goalToken == address(0)) revert ADDRESS_ZERO();

        return RevnetDeploymentResult({
            directory: directory,
            controller: controller,
            rulesets: controller.RULESETS(),
            goalRevnetId: goalRevnetId,
            goalToken: goalToken
        });
    }
}
