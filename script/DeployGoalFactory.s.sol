// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {ISubmissionDepositStrategy} from "src/tcr/interfaces/ISubmissionDepositStrategy.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {CobuildGoalTerminal} from "src/juicebox/CobuildGoalTerminal.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";

contract GoalFactoryPairDeployer {
    error GOAL_FACTORY_PREDICTION_MISMATCH(address predicted, address actual);
    error UNSUPPORTED_CREATE_NONCE(uint256 nonce);

    struct BudgetTcrFactoryConfig {
        address budgetTcrImplementation;
        address arbitratorImplementation;
        address stackDeployerImplementation;
        uint256 escrowBondBps;
    }

    struct GoalFactoryConfig {
        address revDeployer;
        address superfluidHost;
        address goalDeploymentRegistry;
        address goalDeploymentRegistryRegistrarAdmin;
        address cobuildToken;
        uint256 cobuildRevnetId;
        address goalPaymentTerminal;
        address jbMultiTerminal;
        address buybackHookDataHook;
        address buybackHook;
        address goalTreasuryImpl;
        address stakeVaultImpl;
        address customFlowImpl;
        address splitHookImpl;
        address budgetStakeLedgerImpl;
        address goalFlowAllocationLedgerPipelineImpl;
        address premiumEscrowImpl;
        address jurorSlasherRouterImpl;
        address underwriterSlasherRouterImpl;
        address openBudgetGatePolicy;
        address defaultGoalSpendPolicy;
        address defaultBudgetSpendPolicy;
        address defaultSubmissionDepositStrategy;
        address defaultAllocationMechanismAdmin;
        address defaultInvalidRoundRewardsSink;
    }

    address public immutable budgetTcrFactory;
    address public immutable goalDeploymentRegistry;
    address public immutable goalPaymentTerminal;
    address public immutable goalFactory;

    constructor(BudgetTcrFactoryConfig memory budgetTcrConfig, GoalFactoryConfig memory goalFactoryConfig) {
        bool deployGoalDeploymentRegistry = goalFactoryConfig.goalDeploymentRegistry == address(0);
        bool deployGoalPaymentTerminal = goalFactoryConfig.goalPaymentTerminal == address(0);
        // Pair deployer constructor creation order is:
        // optional GoalDeploymentRegistry, optional CobuildGoalTerminal, BudgetTCRFactory, GoalFactory.
        uint256 goalFactoryCreateNonce =
            2 + (deployGoalDeploymentRegistry ? 1 : 0) + (deployGoalPaymentTerminal ? 1 : 0);
        address predictedGoalFactory = _computeCreateAddress(address(this), goalFactoryCreateNonce);

        address goalDeploymentRegistry_ = goalFactoryConfig.goalDeploymentRegistry;
        if (deployGoalDeploymentRegistry) {
            GoalDeploymentRegistry deployedGoalDeploymentRegistry =
                new GoalDeploymentRegistry(goalFactoryConfig.goalDeploymentRegistryRegistrarAdmin, predictedGoalFactory);
            goalDeploymentRegistry_ = address(deployedGoalDeploymentRegistry);
        }

        address goalPaymentTerminal_ = goalFactoryConfig.goalPaymentTerminal;
        if (deployGoalPaymentTerminal) {
            goalPaymentTerminal_ = address(
                new CobuildGoalTerminal(
                    IREVDeployer(goalFactoryConfig.revDeployer).DIRECTORY(),
                    IGoalDeploymentRegistry(goalDeploymentRegistry_)
                )
            );
        }

        BudgetTCRFactory budgetTcrFactory_ = new BudgetTCRFactory(
            budgetTcrConfig.budgetTcrImplementation,
            budgetTcrConfig.arbitratorImplementation,
            budgetTcrConfig.stackDeployerImplementation,
            predictedGoalFactory,
            budgetTcrConfig.escrowBondBps
        );

        GoalFactory goalFactory_ = new GoalFactory(
            IREVDeployer(goalFactoryConfig.revDeployer),
            ISuperfluid(goalFactoryConfig.superfluidHost),
            budgetTcrFactory_,
            IGoalDeploymentRegistry(goalDeploymentRegistry_),
            goalPaymentTerminal_,
            goalFactoryConfig.jbMultiTerminal,
            goalFactoryConfig.buybackHookDataHook,
            goalFactoryConfig.buybackHook,
            goalFactoryConfig.goalTreasuryImpl,
            goalFactoryConfig.stakeVaultImpl,
            goalFactoryConfig.customFlowImpl,
            goalFactoryConfig.splitHookImpl,
            goalFactoryConfig.budgetStakeLedgerImpl,
            goalFactoryConfig.goalFlowAllocationLedgerPipelineImpl,
            goalFactoryConfig.premiumEscrowImpl,
            goalFactoryConfig.jurorSlasherRouterImpl,
            goalFactoryConfig.underwriterSlasherRouterImpl,
            goalFactoryConfig.openBudgetGatePolicy,
            goalFactoryConfig.defaultGoalSpendPolicy,
            goalFactoryConfig.defaultBudgetSpendPolicy,
            goalFactoryConfig.defaultSubmissionDepositStrategy,
            goalFactoryConfig.defaultAllocationMechanismAdmin,
            goalFactoryConfig.defaultInvalidRoundRewardsSink
        );

        if (address(goalFactory_) != predictedGoalFactory) {
            revert GOAL_FACTORY_PREDICTION_MISMATCH(predictedGoalFactory, address(goalFactory_));
        }

        budgetTcrFactory = address(budgetTcrFactory_);
        goalDeploymentRegistry = goalDeploymentRegistry_;
        goalPaymentTerminal = goalPaymentTerminal_;
        goalFactory = address(goalFactory_);
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address predicted) {
        if (nonce > 0x7f) revert UNSUPPORTED_CREATE_NONCE(nonce);
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)))
                    )
                )
            )
        );
    }
}

/// @notice Factory-stage deployment script.
/// @dev Expects implementations to be predeployed (for example by DeployGoalFactoryImplementations).
contract DeployGoalFactory is DeployScript {
    string internal constant DEFAULT_IMPLEMENTATIONS_TOML_FILE = "deploys/LATEST_IMPLEMENTATIONS.toml";

    address internal revDeployerAddressOut;
    address internal superfluidHostAddressOut;
    address internal cobuildTokenAddressOut;
    uint256 internal cobuildRevnetIdOut;
    address internal goalPaymentTerminalOut;
    address internal jbMultiTerminalOut;
    address internal buybackHookDataHookOut;
    address internal buybackHookOut;

    address internal goalTreasuryImplOut;
    address internal stakeVaultImplOut;
    address internal budgetStakeLedgerImplOut;
    address internal goalFlowAllocationLedgerPipelineImplOut;
    address internal premiumEscrowImplOut;
    address internal jurorSlasherRouterImplOut;
    address internal underwriterSlasherRouterImplOut;
    address internal customFlowImplOut;
    address internal splitHookImplOut;
    address internal budgetTcrImplOut;
    address internal erc20VotesArbitratorImplOut;
    address internal budgetTcrDeployerImplOut;

    uint256 internal escrowBondBpsOut;
    address internal goalFactoryPairDeployerOut;
    address internal goalDeploymentRegistryOut;
    address internal budgetTcrFactoryOut;
    address internal defaultSubmissionDepositStrategyOut;
    address internal defaultOpenBudgetGatePolicyOut;
    address internal defaultGoalSpendPolicyOut;
    address internal defaultBudgetSpendPolicyOut;
    address internal goalFactoryOut;
    address internal goalDeploymentRegistryRegistrarAdminOut;

    address internal defaultAllocationMechanismAdminOut;
    address internal defaultInvalidRoundRewardsSinkOut;

    string internal implementationsTomlPathOut;
    string internal implementationsTomlContent;

    error BUDGET_TCR_FACTORY_CALLER_MISMATCH(address expectedCaller, address actualCaller, address budgetTcrFactory);
    error IMPLEMENTATIONS_TOML_NOT_FOUND(string path);
    error IMPLEMENTATIONS_CHAIN_ID_MISSING(string sourcePath);
    error IMPLEMENTATIONS_CHAIN_ID_MISMATCH(uint256 expectedChainId, uint256 configuredChainId, string sourcePath);
    error REQUIRED_CONFIG_MISSING(string envKey, string tomlKey, string tomlPath);
    error GOAL_DEPLOYMENT_REGISTRY_REGISTRAR_ADMIN_MISMATCH(
        address expectedRegistrarAdmin, address actualRegistrarAdmin, address registry
    );
    error SUBMISSION_DEPOSIT_STRATEGY_NOT_CONTRACT(address strategy);
    error SUBMISSION_DEPOSIT_STRATEGY_TOKEN_MISMATCH(address expectedToken, address actualToken, address strategy);

    function deploy() internal override {
        _loadImplementationsToml();

        revDeployerAddressOut =
            _resolveAddress("REV_DEPLOYER", "$.core.revDeployer", address(0x2cA27BDe7e7D33E353b44c27aCfCf6c78ddE251d));
        superfluidHostAddressOut = _resolveAddress(
            "SUPERFLUID_HOST", "$.core.superfluidHost", address(0x4C073B3baB6d8826b8C5b229f3cfdC1eC6E47E74)
        );
        cobuildTokenAddressOut = _resolveAddress(
            "COBUILD_TOKEN", "$.core.cobuildToken", address(0x62f05B1aD94c5d7B9f989A294d2A0f36a1AE10Fb)
        );
        cobuildRevnetIdOut = _resolveUint("COBUILD_REVNET_ID", "$.core.cobuildRevnetId", 138);
        goalPaymentTerminalOut = _resolveAddress("GOAL_PAYMENT_TERMINAL", "$.core.goalPaymentTerminal", address(0));
        jbMultiTerminalOut = _resolveAddress(
            "JB_MULTI_TERMINAL", "$.core.jbMultiTerminal", address(0x2dB6d704058E552DeFE415753465df8dF0361846)
        );
        buybackHookDataHookOut = _requireConfigAddress("BUYBACK_HOOK_DATA_HOOK", "$.core.buybackHookDataHook");
        buybackHookOut = _requireConfigAddress("BUYBACK_HOOK", "$.core.buybackHook");

        escrowBondBpsOut = _resolveUint("ESCROW_BOND_BPS", "$.defaults.escrowBondBps", 5000);
        goalDeploymentRegistryOut = _resolveAddress("GOAL_DEPLOYMENT_REGISTRY", "$.defaults.goalDeploymentRegistry", address(0));
        goalDeploymentRegistryRegistrarAdminOut = _resolveAddress(
            "GOAL_DEPLOYMENT_REGISTRY_REGISTRAR_ADMIN",
            "$.defaults.goalDeploymentRegistryRegistrarAdmin",
            deployerAddress
        );
        defaultAllocationMechanismAdminOut = _resolveAddress(
            "DEFAULT_ALLOCATION_MECHANISM_ADMIN", "$.defaults.allocationMechanismAdmin", deployerAddress
        );
        defaultInvalidRoundRewardsSinkOut =
            _resolveAddress("DEFAULT_INVALID_ROUND_REWARDS_SINK", "$.defaults.invalidRoundRewardsSink", BURN);
        defaultOpenBudgetGatePolicyOut =
            _requireConfigAddress("DEFAULT_OPEN_BUDGET_GATE_POLICY", "$.defaults.openBudgetGatePolicy");
        defaultGoalSpendPolicyOut = _requireConfigAddress("DEFAULT_GOAL_SPEND_POLICY", "$.defaults.goalSpendPolicy");
        defaultBudgetSpendPolicyOut =
            _requireConfigAddress("DEFAULT_BUDGET_SPEND_POLICY", "$.defaults.budgetSpendPolicy");

        goalTreasuryImplOut = _requireConfigAddress("GOAL_TREASURY_IMPL", "$.implementations.goalTreasury");
        stakeVaultImplOut = _requireConfigAddress("STAKE_VAULT_IMPL", "$.implementations.stakeVault");
        budgetStakeLedgerImplOut =
            _requireConfigAddress("BUDGET_STAKE_LEDGER_IMPL", "$.implementations.budgetStakeLedger");
        goalFlowAllocationLedgerPipelineImplOut = _requireConfigAddress(
            "GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL", "$.implementations.goalFlowAllocationLedgerPipeline"
        );
        premiumEscrowImplOut = _requireConfigAddress("PREMIUM_ESCROW_IMPL", "$.implementations.premiumEscrow");
        jurorSlasherRouterImplOut =
            _requireConfigAddress("JUROR_SLASHER_ROUTER_IMPL", "$.implementations.jurorSlasherRouter");
        underwriterSlasherRouterImplOut =
            _requireConfigAddress("UNDERWRITER_SLASHER_ROUTER_IMPL", "$.implementations.underwriterSlasherRouter");
        customFlowImplOut = _requireConfigAddress("CUSTOM_FLOW_IMPL", "$.implementations.customFlow");
        splitHookImplOut = _requireConfigAddress("GOAL_REVNET_SPLIT_HOOK_IMPL", "$.implementations.goalRevnetSplitHook");
        budgetTcrImplOut = _requireConfigAddress("BUDGET_TCR_IMPL", "$.implementations.budgetTCR");
        erc20VotesArbitratorImplOut =
            _requireConfigAddress("ERC20_VOTES_ARBITRATOR_IMPL", "$.implementations.erc20VotesArbitrator");
        budgetTcrDeployerImplOut =
            _requireConfigAddress("BUDGET_TCR_DEPLOYER_IMPL", "$.implementations.budgetTCRDeployer");
        defaultSubmissionDepositStrategyOut =
            _requireConfigAddress("DEFAULT_SUBMISSION_DEPOSIT_STRATEGY", "$.defaults.submissionDepositStrategy");
        if (defaultSubmissionDepositStrategyOut.code.length == 0) {
            revert SUBMISSION_DEPOSIT_STRATEGY_NOT_CONTRACT(defaultSubmissionDepositStrategyOut);
        }
        address strategyToken = address(ISubmissionDepositStrategy(defaultSubmissionDepositStrategyOut).token());
        if (strategyToken != cobuildTokenAddressOut) {
            revert SUBMISSION_DEPOSIT_STRATEGY_TOKEN_MISMATCH(
                cobuildTokenAddressOut, strategyToken, defaultSubmissionDepositStrategyOut
            );
        }

        (goalFactoryPairDeployerOut, goalDeploymentRegistryOut, budgetTcrFactoryOut, goalFactoryOut) = _deployFactoryPair();
        _assertBudgetTcrFactoryAuthorizedCaller(goalFactoryOut);
        _ensureGoalFactoryAuthorizedRegistrar();

        console2.log("Deployer:", deployerAddress);
        if (bytes(implementationsTomlPathOut).length != 0) {
            console2.log("Implementations TOML:", implementationsTomlPathOut);
        }
        console2.log("--- Core addresses ---");
        console2.log("REV_DEPLOYER:", revDeployerAddressOut);
        console2.log("SUPERFLUID_HOST:", superfluidHostAddressOut);
        console2.log("COBUILD_TOKEN:", cobuildTokenAddressOut);
        console2.log("COBUILD_REVNET_ID:", cobuildRevnetIdOut);
        console2.log("GOAL_PAYMENT_TERMINAL:", goalPaymentTerminalOut);
        console2.log("JB_MULTI_TERMINAL:", jbMultiTerminalOut);
        console2.log("BUYBACK_HOOK_DATA_HOOK:", buybackHookDataHookOut);
        console2.log("BUYBACK_HOOK:", buybackHookOut);
        console2.log("--- Impl addresses ---");
        console2.log("GoalTreasury impl:", goalTreasuryImplOut);
        console2.log("StakeVault impl:", stakeVaultImplOut);
        console2.log("BudgetStakeLedger impl:", budgetStakeLedgerImplOut);
        console2.log("GoalFlowAllocationLedgerPipeline impl:", goalFlowAllocationLedgerPipelineImplOut);
        console2.log("PremiumEscrow impl:", premiumEscrowImplOut);
        console2.log("JurorSlasherRouter impl:", jurorSlasherRouterImplOut);
        console2.log("UnderwriterSlasherRouter impl:", underwriterSlasherRouterImplOut);
        console2.log("CustomFlow impl:", customFlowImplOut);
        console2.log("GoalRevnetSplitHook impl:", splitHookImplOut);
        console2.log("BudgetTCR impl:", budgetTcrImplOut);
        console2.log("ERC20VotesArbitrator impl:", erc20VotesArbitratorImplOut);
        console2.log("BudgetTCRDeployer impl:", budgetTcrDeployerImplOut);
        console2.log("--- BudgetTCR stack ---");
        console2.log("FactoryPairDeployer:", goalFactoryPairDeployerOut);
        console2.log("BudgetTCRFactory:", budgetTcrFactoryOut);
        console2.log("DepositStrategy:", defaultSubmissionDepositStrategyOut);
        console2.log("--- Goal factory ---");
        console2.log("DefaultOpenBudgetGatePolicy:", defaultOpenBudgetGatePolicyOut);
        console2.log("DefaultGoalSpendPolicy:", defaultGoalSpendPolicyOut);
        console2.log("DefaultBudgetSpendPolicy:", defaultBudgetSpendPolicyOut);
        console2.log("GoalDeploymentRegistry:", goalDeploymentRegistryOut);
        console2.log("GoalFactory:", goalFactoryOut);
    }

    function deploymentName() internal pure override returns (string memory) {
        return "DeployGoalFactory";
    }

    function writeDeploymentDetails(string memory filePath) internal override {
        if (bytes(implementationsTomlPathOut).length != 0) {
            vm.writeLine(filePath, string(abi.encodePacked("IMPLEMENTATIONS_TOML_FILE: ", implementationsTomlPathOut)));
        }
        _writeAddressLine(filePath, "REV_DEPLOYER", revDeployerAddressOut);
        _writeAddressLine(filePath, "SUPERFLUID_HOST", superfluidHostAddressOut);
        _writeAddressLine(filePath, "COBUILD_TOKEN", cobuildTokenAddressOut);
        _writeUintLine(filePath, "COBUILD_REVNET_ID", cobuildRevnetIdOut);
        _writeAddressLine(filePath, "GOAL_PAYMENT_TERMINAL", goalPaymentTerminalOut);
        _writeAddressLine(filePath, "JB_MULTI_TERMINAL", jbMultiTerminalOut);
        _writeAddressLine(filePath, "BUYBACK_HOOK_DATA_HOOK", buybackHookDataHookOut);
        _writeAddressLine(filePath, "BUYBACK_HOOK", buybackHookOut);

        _writeAddressLine(filePath, "GoalTreasuryImpl", goalTreasuryImplOut);
        _writeAddressLine(filePath, "StakeVaultImpl", stakeVaultImplOut);
        _writeAddressLine(filePath, "BudgetStakeLedgerImpl", budgetStakeLedgerImplOut);
        _writeAddressLine(filePath, "GoalFlowAllocationLedgerPipelineImpl", goalFlowAllocationLedgerPipelineImplOut);
        _writeAddressLine(filePath, "PremiumEscrowImpl", premiumEscrowImplOut);
        _writeAddressLine(filePath, "JurorSlasherRouterImpl", jurorSlasherRouterImplOut);
        _writeAddressLine(filePath, "UnderwriterSlasherRouterImpl", underwriterSlasherRouterImplOut);
        _writeAddressLine(filePath, "CustomFlowImpl", customFlowImplOut);
        _writeAddressLine(filePath, "GoalRevnetSplitHookImpl", splitHookImplOut);
        _writeAddressLine(filePath, "BudgetTCRImpl", budgetTcrImplOut);
        _writeAddressLine(filePath, "ERC20VotesArbitratorImpl", erc20VotesArbitratorImplOut);
        _writeAddressLine(filePath, "BudgetTCRDeployerImpl", budgetTcrDeployerImplOut);

        _writeAddressLine(filePath, "BudgetTCRFactory", budgetTcrFactoryOut);
        _writeAddressLine(filePath, "GoalFactoryPairDeployer", goalFactoryPairDeployerOut);
        _writeAddressLine(filePath, "GoalDeploymentRegistry", goalDeploymentRegistryOut);
        _writeAddressLine(filePath, "DefaultSubmissionDepositStrategy", defaultSubmissionDepositStrategyOut);
        _writeAddressLine(filePath, "DefaultOpenBudgetGatePolicy", defaultOpenBudgetGatePolicyOut);
        _writeAddressLine(filePath, "DefaultGoalSpendPolicy", defaultGoalSpendPolicyOut);
        _writeAddressLine(filePath, "DefaultBudgetSpendPolicy", defaultBudgetSpendPolicyOut);
        _writeUintLine(filePath, "ESCROW_BOND_BPS", escrowBondBpsOut);
        _writeAddressLine(filePath, "GoalFactory", goalFactoryOut);

        _writeAddressLine(filePath, "DEFAULT_ALLOCATION_MECHANISM_ADMIN", defaultAllocationMechanismAdminOut);
        _writeAddressLine(filePath, "DEFAULT_INVALID_ROUND_REWARDS_SINK", defaultInvalidRoundRewardsSinkOut);
    }

    function _loadImplementationsToml() internal {
        if (vm.envExists("IMPLEMENTATIONS_TOML_FILE")) {
            string memory explicitPath = vm.envString("IMPLEMENTATIONS_TOML_FILE");
            if (!vm.isFile(explicitPath)) revert IMPLEMENTATIONS_TOML_NOT_FOUND(explicitPath);
            implementationsTomlPathOut = explicitPath;
            implementationsTomlContent = vm.readFile(explicitPath);
            _assertImplementationsChainId();
            return;
        }

        string memory chainScopedPath =
            string(abi.encodePacked("deploys/LATEST_IMPLEMENTATIONS.", vm.toString(chainId), ".toml"));
        if (vm.isFile(chainScopedPath)) {
            implementationsTomlPathOut = chainScopedPath;
            implementationsTomlContent = vm.readFile(chainScopedPath);
            _assertImplementationsChainId();
            return;
        }

        if (vm.isFile(DEFAULT_IMPLEMENTATIONS_TOML_FILE)) {
            implementationsTomlPathOut = DEFAULT_IMPLEMENTATIONS_TOML_FILE;
            implementationsTomlContent = vm.readFile(DEFAULT_IMPLEMENTATIONS_TOML_FILE);
            _assertImplementationsChainId();
        }
    }

    function _deployFactoryPair()
        internal
        returns (address pairDeployer, address goalDeploymentRegistry, address budgetTcrFactory, address goalFactory)
    {
        GoalFactoryPairDeployer deployedPair = new GoalFactoryPairDeployer(
            GoalFactoryPairDeployer.BudgetTcrFactoryConfig({
                budgetTcrImplementation: budgetTcrImplOut,
                arbitratorImplementation: erc20VotesArbitratorImplOut,
                stackDeployerImplementation: budgetTcrDeployerImplOut,
                escrowBondBps: escrowBondBpsOut
            }),
            GoalFactoryPairDeployer.GoalFactoryConfig({
                revDeployer: revDeployerAddressOut,
                superfluidHost: superfluidHostAddressOut,
                goalDeploymentRegistry: goalDeploymentRegistryOut,
                goalDeploymentRegistryRegistrarAdmin: goalDeploymentRegistryRegistrarAdminOut,
                cobuildToken: cobuildTokenAddressOut,
                cobuildRevnetId: cobuildRevnetIdOut,
                goalPaymentTerminal: goalPaymentTerminalOut,
                jbMultiTerminal: jbMultiTerminalOut,
                buybackHookDataHook: buybackHookDataHookOut,
                buybackHook: buybackHookOut,
                goalTreasuryImpl: goalTreasuryImplOut,
                stakeVaultImpl: stakeVaultImplOut,
                customFlowImpl: customFlowImplOut,
                splitHookImpl: splitHookImplOut,
                budgetStakeLedgerImpl: budgetStakeLedgerImplOut,
                goalFlowAllocationLedgerPipelineImpl: goalFlowAllocationLedgerPipelineImplOut,
                premiumEscrowImpl: premiumEscrowImplOut,
                jurorSlasherRouterImpl: jurorSlasherRouterImplOut,
                underwriterSlasherRouterImpl: underwriterSlasherRouterImplOut,
                openBudgetGatePolicy: defaultOpenBudgetGatePolicyOut,
                defaultGoalSpendPolicy: defaultGoalSpendPolicyOut,
                defaultBudgetSpendPolicy: defaultBudgetSpendPolicyOut,
                defaultSubmissionDepositStrategy: defaultSubmissionDepositStrategyOut,
                defaultAllocationMechanismAdmin: defaultAllocationMechanismAdminOut,
                defaultInvalidRoundRewardsSink: defaultInvalidRoundRewardsSinkOut
            })
        );

        pairDeployer = address(deployedPair);
        goalDeploymentRegistry = deployedPair.goalDeploymentRegistry();
        budgetTcrFactory = deployedPair.budgetTcrFactory();
        goalFactory = deployedPair.goalFactory();
    }

    function _ensureGoalFactoryAuthorizedRegistrar() internal {
        GoalDeploymentRegistry goalDeploymentRegistry = GoalDeploymentRegistry(goalDeploymentRegistryOut);
        if (goalDeploymentRegistry.isRegistrar(goalFactoryOut)) return;

        address currentRegistrarAdmin = goalDeploymentRegistry.registrarAdmin();
        if (currentRegistrarAdmin != deployerAddress) {
            revert GOAL_DEPLOYMENT_REGISTRY_REGISTRAR_ADMIN_MISMATCH(
                deployerAddress, currentRegistrarAdmin, goalDeploymentRegistryOut
            );
        }

        goalDeploymentRegistry.setRegistrar(goalFactoryOut, true);
    }

    function _assertBudgetTcrFactoryAuthorizedCaller(address expectedCaller) internal view {
        address configuredAuthorizedCaller = BudgetTCRFactory(budgetTcrFactoryOut).authorizedCaller();
        if (configuredAuthorizedCaller != expectedCaller) {
            revert BUDGET_TCR_FACTORY_CALLER_MISMATCH(expectedCaller, configuredAuthorizedCaller, budgetTcrFactoryOut);
        }
    }

    function _resolveAddress(string memory envKey, string memory tomlKey, address fallbackValue)
        internal
        view
        returns (address value)
    {
        if (vm.envExists(envKey)) return vm.envAddress(envKey);
        if (_hasTomlKey(tomlKey)) return vm.parseTomlAddress(implementationsTomlContent, tomlKey);
        return fallbackValue;
    }

    function _resolveUint(string memory envKey, string memory tomlKey, uint256 fallbackValue)
        internal
        view
        returns (uint256 value)
    {
        if (vm.envExists(envKey)) return vm.envUint(envKey);
        if (_hasTomlKey(tomlKey)) return vm.parseTomlUint(implementationsTomlContent, tomlKey);
        return fallbackValue;
    }

    function _requireConfigAddress(string memory envKey, string memory tomlKey) internal view returns (address value) {
        if (vm.envExists(envKey)) return vm.envAddress(envKey);
        if (_hasTomlKey(tomlKey)) return vm.parseTomlAddress(implementationsTomlContent, tomlKey);
        revert REQUIRED_CONFIG_MISSING(envKey, tomlKey, implementationsTomlPathOut);
    }

    function _hasTomlKey(string memory tomlKey) internal view returns (bool) {
        return bytes(implementationsTomlContent).length != 0 && vm.keyExistsToml(implementationsTomlContent, tomlKey);
    }

    function _assertImplementationsChainId() internal view {
        if (!_hasTomlKey("$.core.chainId")) {
            revert IMPLEMENTATIONS_CHAIN_ID_MISSING(implementationsTomlPathOut);
        }
        uint256 configuredChainId = vm.parseTomlUint(implementationsTomlContent, "$.core.chainId");
        if (configuredChainId != chainId) {
            revert IMPLEMENTATIONS_CHAIN_ID_MISMATCH(chainId, configuredChainId, implementationsTomlPathOut);
        }
    }
}
