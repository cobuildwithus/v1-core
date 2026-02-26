// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBMultiTerminal } from "@bananapus/core-v5/interfaces/IJBMultiTerminal.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBTerminalConfig } from "@bananapus/core-v5/structs/JBTerminalConfig.sol";

interface IREVDeployer {
    struct REVDescription {
        string name;
        string ticker;
        string uri;
    }

    struct REVLoanSource {
        address token;
        address terminal;
    }

    struct REVBuybackPoolConfig {
        address token;
        uint24 fee;
        uint32 twapWindow;
    }

    struct REVBuybackHookConfig {
        address dataHook;
        address hookToConfigure;
        REVBuybackPoolConfig[] poolConfigurations;
    }

    struct REVStageConfig {
        uint48 startsAtOrAfter;
        uint16 splitPercent;
        uint112 initialIssuance;
        uint32 issuanceCutFrequency;
        uint32 issuanceCutPercent;
        uint16 cashOutTaxRate;
        uint16 extraMetadata;
        JBSplit[] splits;
    }

    struct REVConfig {
        REVDescription description;
        uint32 baseCurrency;
        address splitOperator;
        REVStageConfig[] stageConfigurations;
        REVLoanSource[] loanSources;
        address loans;
    }

    struct JBSuckerDeployerConfig {
        address deployer;
        uint32 domain;
    }

    struct REVSuckerDeploymentConfig {
        JBSuckerDeployerConfig[] deployerConfigurations;
        bytes32 salt;
    }

    function deployFor(
        address revnetOwner,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        REVBuybackHookConfig calldata buybackHookConfiguration,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    ) external returns (uint256 revnetId);

    function CONTROLLER() external view returns (IJBController);
    function DIRECTORY() external view returns (IJBDirectory);
    function MULTI_TERMINAL() external view returns (IJBMultiTerminal);
}
