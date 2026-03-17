// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {IBudgetTCR} from "src/tcr/interfaces/IBudgetTCR.sol";

contract ManagedGoalAuthority {
    error ADDRESS_ZERO();
    error ONLY_OWNER();

    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address owner_) {
        if (owner_ == address(0)) revert ADDRESS_ZERO();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ONLY_OWNER();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ADDRESS_ZERO();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable onlyOwner returns (bytes memory result) {
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }

    receive() external payable {}
}

contract DeployManagedGoalWithDefaults is DeployScript {
    bytes32 internal constant DEFAULT_SPEND_POLICY_OPTION_HASH = keccak256(bytes("default"));
    string internal constant DEFAULT_IMPLEMENTATIONS_TOML_FILE = "deploys/LATEST_IMPLEMENTATIONS.toml";
    string internal constant DEFAULT_GOAL_FACTORY_ARTIFACT_FILE = "deploys/DeployGoalFactory.txt";

    address internal goalFactoryAddressOut;
    address internal managedSafeOut;
    address internal managedAuthorityOwnerOut;
    bool internal managedSafeDeployedOut;
    address internal goalSpendPolicyOut;
    address internal budgetSpendPolicyOut;
    address internal successResolverOut;
    address internal budgetSuccessResolverOut;

    uint256 internal goalRevnetIdOut;
    address internal goalTokenOut;
    address internal goalSuperTokenOut;
    address internal goalTreasuryOut;
    address internal goalFlowOut;
    address internal goalAllocatorStrategyOut;
    address internal goalFlowAllocationLedgerPipelineOut;
    address internal stakeVaultOut;
    address internal budgetStakeLedgerOut;
    address internal splitHookOut;
    address internal budgetControllerOut;
    address internal arbitratorOut;
    string internal implementationsTomlPathOut;
    string internal implementationsTomlContent;
    string internal goalFactoryArtifactPathOut;
    string internal goalFactoryArtifactContent;

    function deploy() internal override {
        implementationsTomlPathOut = "";
        implementationsTomlContent = "";
        goalFactoryArtifactPathOut = "";
        goalFactoryArtifactContent = "";
        managedAuthorityOwnerOut = address(0);
        managedSafeDeployedOut = false;

        GoalFactory factory = _resolveGoalFactory();
        goalFactoryAddressOut = address(factory);

        managedSafeOut = _resolveOptionalEnvAddress("MANAGED_SAFE", address(0));
        if (managedSafeOut == address(0)) {
            managedAuthorityOwnerOut = _resolveOptionalEnvAddress("MANAGED_AUTHORITY_OWNER", deployerAddress);
            managedSafeOut = address(new ManagedGoalAuthority(managedAuthorityOwnerOut));
            managedSafeDeployedOut = true;
        }
        if (managedSafeOut.code.length == 0) revert MANAGED_SAFE_NOT_CONTRACT(managedSafeOut);

        address managedBudgetGatePolicy = _resolveOptionalEnvAddress("MANAGED_BUDGET_GATE_POLICY", address(0));
        string memory goalName = vm.envOr("GOAL_NAME", string("Managed Goal"));
        string memory goalTicker = vm.envOr("GOAL_TICKER", string("MGOAL"));
        string memory goalUri = vm.envOr("GOAL_URI", string("ipfs://MANAGED_GOAL"));
        address paymentToken = _resolvePaymentToken();
        uint256 paymentRevnetId = _resolvePaymentRevnetId();

        uint32 duration = uint32(vm.envOr("GOAL_DURATION_SECONDS", uint256(7 days)));
        uint16 reservedPercent = uint16(vm.envOr("GOAL_RESERVED_PERCENT_BPS", uint256(0)));
        uint16 cashOutTax = uint16(vm.envOr("GOAL_CASHOUT_TAX_BPS", uint256(0)));
        uint112 issuance = uint112(vm.envOr("GOAL_ISSUANCE", uint256(1e18)));

        uint256 minRaise = vm.envOr("GOAL_MIN_RAISE", uint256(0));
        uint32 minRaiseWindow = uint32(vm.envOr("GOAL_MIN_RAISE_WINDOW_SECONDS", uint256(0)));

        (bool hasSuccessResolver, address explicitSuccessResolver) = _envAddressOrUnset("SUCCESS_RESOLVER");
        address successResolver = hasSuccessResolver ? explicitSuccessResolver : _resolveDefaultSuccessResolver();
        uint64 successLiveness = uint64(vm.envOr("SUCCESS_LIVENESS", uint256(1 days)));
        uint256 successBond = vm.envOr("SUCCESS_BOND", uint256(0));
        bytes32 specHash = keccak256(bytes(vm.envOr("SUCCESS_SPEC", string("MANAGED_GOAL_SPEC"))));
        bytes32 policyHash = keccak256(bytes(vm.envOr("SUCCESS_POLICY", string("MANAGED_GOAL_POLICY"))));

        string memory flowTitle = vm.envOr("FLOW_TITLE", string("Managed Goal"));
        string memory flowDesc = vm.envOr("FLOW_DESC", string("Managed goal flow"));
        string memory flowImage = vm.envOr("FLOW_IMAGE", string("ipfs://MANAGED_IMAGE"));
        string memory flowTagline = vm.envOr("FLOW_TAGLINE", string(""));
        string memory flowUrl = vm.envOr("FLOW_URL", string(""));
        address goalSpendPolicy = _resolveGoalSpendPolicy(factory);
        address budgetSpendPolicy = _resolveBudgetSpendPolicy(factory);

        (bool hasBudgetSuccessResolver, address explicitBudgetSuccessResolver) =
            _envAddressOrUnset("BUDGET_SUCCESS_RESOLVER");
        address budgetSuccessResolver = hasBudgetSuccessResolver ? explicitBudgetSuccessResolver : successResolver;

        if (goalSpendPolicy == BURN) revert GOAL_SPEND_POLICY_REQUIRED();
        if (goalSpendPolicy.code.length == 0) revert GOAL_SPEND_POLICY_NOT_CONTRACT(goalSpendPolicy);
        _requireValidSpendPolicy(goalSpendPolicy, true);
        if (budgetSpendPolicy == BURN) revert BUDGET_SPEND_POLICY_REQUIRED();
        if (budgetSpendPolicy.code.length == 0) revert BUDGET_SPEND_POLICY_NOT_CONTRACT(budgetSpendPolicy);
        _requireValidSpendPolicy(budgetSpendPolicy, false);
        if (successResolver == BURN) revert SUCCESS_RESOLVER_REQUIRED();
        if (successResolver.code.length == 0) revert SUCCESS_RESOLVER_NOT_CONTRACT(successResolver);
        if (budgetSuccessResolver == BURN) revert BUDGET_SUCCESS_RESOLVER_REQUIRED();
        if (budgetSuccessResolver.code.length == 0) {
            revert BUDGET_SUCCESS_RESOLVER_NOT_CONTRACT(budgetSuccessResolver);
        }

        uint64 budgetSuccessLiveness = uint64(_resolveBudgetSuccessLiveness());
        uint256 budgetSuccessBond = _resolveBudgetSuccessBond();

        GoalFactory.CommonGoalParams memory common = GoalFactory.CommonGoalParams({
            funding: GoalFactory.FundingContext({paymentToken: paymentToken, paymentRevnetId: paymentRevnetId}),
            revnet: GoalFactory.RevnetParams({
                name: goalName,
                ticker: goalTicker,
                uri: goalUri,
                initialIssuance: issuance,
                cashOutTaxRate: cashOutTax,
                reservedPercent: reservedPercent,
                durationSeconds: duration
            }),
            timing: GoalFactory.GoalTimingParams({minRaise: minRaise, minRaiseDurationSeconds: minRaiseWindow}),
            success: GoalFactory.SuccessParams({
                successResolver: successResolver,
                successAssertionLiveness: successLiveness,
                successAssertionBond: successBond,
                successOracleSpecHash: specHash,
                successAssertionPolicyHash: policyHash
            }),
            flowMetadata: GoalFactory.FlowMetadataParams({
                title: flowTitle, description: flowDesc, image: flowImage, tagline: flowTagline, url: flowUrl
            }),
            underwriting: GoalFactory.UnderwritingParams({budgetPremiumPpm: 0, budgetSlashPpm: 0}),
            goalSpendPolicy: goalSpendPolicy
        });
        GoalFactory.BudgetRuntimeParams memory budgetRuntime = GoalFactory.BudgetRuntimeParams({
            budgetSuccessResolver: budgetSuccessResolver,
            budgetSpendPolicy: budgetSpendPolicy,
            oracleBounds: IBudgetTCR.OracleValidationBounds({
                liveness: budgetSuccessLiveness,
                bondAmount: budgetSuccessBond
            })
        });

        GoalFactory.ManagedGoalParams memory params = GoalFactory.ManagedGoalParams({
            common: common,
            managedSafe: managedSafeOut,
            managedBudgetGatePolicy: managedBudgetGatePolicy,
            budgetRuntime: budgetRuntime
        });

        GoalFactory.DeployedGoalStack memory out = factory.deployManagedGoal(params);

        goalSpendPolicyOut = goalSpendPolicy;
        budgetSpendPolicyOut = budgetSpendPolicy;
        successResolverOut = successResolver;
        budgetSuccessResolverOut = budgetSuccessResolver;

        goalRevnetIdOut = out.goalRevnetId;
        goalTokenOut = out.goalToken;
        goalSuperTokenOut = out.goalSuperToken;
        goalTreasuryOut = out.goalTreasury;
        goalFlowOut = out.goalFlow;
        goalAllocatorStrategyOut = out.goalAllocatorStrategy;
        goalFlowAllocationLedgerPipelineOut = out.goalFlowAllocationLedgerPipeline;
        stakeVaultOut = out.stakeVault;
        budgetStakeLedgerOut = out.budgetStakeLedger;
        splitHookOut = out.splitHook;
        budgetControllerOut = out.budgetController;
        arbitratorOut = out.arbitrator;

        console2.log("Goal deployed by:", deployerAddress);
        console2.log("managedSafe:", managedSafeOut);
        if (managedAuthorityOwnerOut != address(0)) {
            console2.log("managedAuthorityOwner:", managedAuthorityOwnerOut);
        }
        console2.log("goalSpendPolicy:", goalSpendPolicyOut);
        console2.log("budgetSpendPolicy:", budgetSpendPolicyOut);
        console2.log("successResolver:", successResolverOut);
        console2.log("budgetSuccessResolver:", budgetSuccessResolverOut);
        console2.log("goalRevnetId:", goalRevnetIdOut);
        console2.log("goalToken:", goalTokenOut);
        console2.log("goalSuperToken:", goalSuperTokenOut);
        console2.log("goalTreasury:", goalTreasuryOut);
        console2.log("goalFlow:", goalFlowOut);
        console2.log("goalAllocatorStrategy:", goalAllocatorStrategyOut);
        console2.log("goalFlowAllocationLedgerPipeline:", goalFlowAllocationLedgerPipelineOut);
        console2.log("stakeVault:", stakeVaultOut);
        console2.log("budgetStakeLedger:", budgetStakeLedgerOut);
        console2.log("splitHook:", splitHookOut);
        console2.log("budgetController:", budgetControllerOut);
        console2.log("arbitrator:", arbitratorOut);
    }

    function deploymentName() internal pure override returns (string memory) {
        return "DeployManagedGoalWithDefaults";
    }

    function writeDeploymentDetails(string memory filePath) internal override {
        if (bytes(goalFactoryArtifactPathOut).length != 0) {
            vm.writeLine(filePath, string(abi.encodePacked("GOAL_FACTORY_ARTIFACT_FILE: ", goalFactoryArtifactPathOut)));
        }
        if (bytes(implementationsTomlPathOut).length != 0) {
            vm.writeLine(filePath, string(abi.encodePacked("IMPLEMENTATIONS_TOML_FILE: ", implementationsTomlPathOut)));
        }
        _writeAddressLine(filePath, "GOAL_FACTORY", goalFactoryAddressOut);
        _writeAddressLine(filePath, "MANAGED_SAFE", managedSafeOut);
        vm.writeLine(
            filePath,
            string(
                abi.encodePacked(
                    "MANAGED_SAFE_DEPLOYED: ", managedSafeDeployedOut ? "true" : "false"
                )
            )
        );
        if (managedAuthorityOwnerOut != address(0)) {
            _writeAddressLine(filePath, "MANAGED_AUTHORITY_OWNER", managedAuthorityOwnerOut);
        }
        _writeAddressLine(filePath, "GOAL_SPEND_POLICY", goalSpendPolicyOut);
        _writeAddressLine(filePath, "BUDGET_SPEND_POLICY", budgetSpendPolicyOut);
        _writeAddressLine(filePath, "SUCCESS_RESOLVER", successResolverOut);
        _writeAddressLine(filePath, "BUDGET_SUCCESS_RESOLVER", budgetSuccessResolverOut);

        _writeUintLine(filePath, "goalRevnetId", goalRevnetIdOut);
        _writeAddressLine(filePath, "goalToken", goalTokenOut);
        _writeAddressLine(filePath, "goalSuperToken", goalSuperTokenOut);
        _writeAddressLine(filePath, "goalTreasury", goalTreasuryOut);
        _writeAddressLine(filePath, "goalFlow", goalFlowOut);
        _writeAddressLine(filePath, "goalAllocatorStrategy", goalAllocatorStrategyOut);
        _writeAddressLine(filePath, "goalFlowAllocationLedgerPipeline", goalFlowAllocationLedgerPipelineOut);
        _writeAddressLine(filePath, "stakeVault", stakeVaultOut);
        _writeAddressLine(filePath, "budgetStakeLedger", budgetStakeLedgerOut);
        _writeAddressLine(filePath, "splitHook", splitHookOut);
        _writeAddressLine(filePath, "budgetController", budgetControllerOut);
        _writeAddressLine(filePath, "arbitrator", arbitratorOut);
    }

    function _requireValidSpendPolicy(address spendPolicy, bool goalPolicy) internal view {
        try ISpendPolicy(spendPolicy).syncMode() returns (ISpendPolicy.SyncMode mode) {
            if (uint8(mode) > uint8(ISpendPolicy.SyncMode.LinearSpendDownFallback)) {
                if (goalPolicy) revert GOAL_SPEND_POLICY_INVALID(spendPolicy);
                revert BUDGET_SPEND_POLICY_INVALID(spendPolicy);
            }
        } catch {
            if (goalPolicy) revert GOAL_SPEND_POLICY_INVALID(spendPolicy);
            revert BUDGET_SPEND_POLICY_INVALID(spendPolicy);
        }

        try ISpendPolicy(spendPolicy).targetFlowRate(_spendPolicyValidationContext()) returns (int96) {}
        catch {
            if (goalPolicy) revert GOAL_SPEND_POLICY_INVALID(spendPolicy);
            revert BUDGET_SPEND_POLICY_INVALID(spendPolicy);
        }
    }

    function _spendPolicyValidationContext() internal view returns (ISpendPolicy.SpendContext memory ctx) {
        uint64 nowTs = uint64(block.timestamp);
        ctx = ISpendPolicy.SpendContext({
            nowTs: nowTs,
            activatedAt: nowTs,
            deadline: nowTs + 1,
            treasuryBalance: 1,
            timeRemaining: 1,
            incomingRate: 0,
            currentOutflowRate: 0
        });
    }

    function _resolveGoalSpendPolicy(GoalFactory factory) internal view returns (address spendPolicy) {
        return _resolveSpendPolicy(
            "GOAL_SPEND_POLICY", "GOAL_SPEND_POLICY_OPTION", factory.DEFAULT_GOAL_SPEND_POLICY(), true
        );
    }

    function _resolveBudgetSpendPolicy(GoalFactory factory) internal view returns (address spendPolicy) {
        return _resolveSpendPolicy(
            "BUDGET_SPEND_POLICY", "BUDGET_SPEND_POLICY_OPTION", factory.DEFAULT_BUDGET_SPEND_POLICY(), false
        );
    }

    function _resolveSpendPolicy(
        string memory spendPolicyEnvKey,
        string memory spendPolicyOptionEnvKey,
        address defaultSpendPolicy,
        bool goalPolicy
    ) internal view returns (address spendPolicy) {
        (bool hasExplicitSpendPolicy, address explicitSpendPolicy) = _envAddressOrUnset(spendPolicyEnvKey);
        if (hasExplicitSpendPolicy) return explicitSpendPolicy;

        string memory option = _envStringOrEmpty(spendPolicyOptionEnvKey);
        if (bytes(option).length == 0) return defaultSpendPolicy;
        if (keccak256(bytes(option)) == DEFAULT_SPEND_POLICY_OPTION_HASH) return defaultSpendPolicy;
        if (goalPolicy) revert GOAL_SPEND_POLICY_OPTION_INVALID(option);
        revert BUDGET_SPEND_POLICY_OPTION_INVALID(option);
    }

    function _resolveGoalFactory() internal returns (GoalFactory factory) {
        address goalFactoryAddress;
        (bool hasGoalFactory, address explicitGoalFactory) = _envAddressOrUnset("GOAL_FACTORY");
        if (hasGoalFactory) {
            goalFactoryAddress = explicitGoalFactory;
        } else {
            _ensureGoalFactoryArtifactLoaded();
            if (bytes(goalFactoryArtifactContent).length == 0) {
                revert GOAL_FACTORY_ARTIFACT_NOT_FOUND(_expectedGoalFactoryArtifactPath());
            }
            goalFactoryAddress = vm.parseAddress(_artifactValueForKey(goalFactoryArtifactContent, "GoalFactory"));
        }

        if (goalFactoryAddress.code.length == 0) revert GOAL_FACTORY_NOT_CONTRACT(goalFactoryAddress);
        factory = GoalFactory(goalFactoryAddress);
    }

    function _resolvePaymentToken() internal returns (address paymentToken) {
        (bool hasGoalPaymentToken, address explicitGoalPaymentToken) = _envAddressOrUnset("GOAL_PAYMENT_TOKEN");
        if (hasGoalPaymentToken) return explicitGoalPaymentToken;
        return _resolveAddress("COBUILD_TOKEN", "$.core.cobuildToken", BURN);
    }

    function _resolvePaymentRevnetId() internal returns (uint256 paymentRevnetId) {
        (bool hasGoalPaymentRevnetId, uint256 explicitGoalPaymentRevnetId) = _envUintOrUnset("GOAL_PAYMENT_REVNET_ID");
        if (hasGoalPaymentRevnetId) return explicitGoalPaymentRevnetId;
        return _resolveUint("COBUILD_REVNET_ID", "$.core.cobuildRevnetId", 138);
    }

    function _resolveDefaultSuccessResolver() internal returns (address resolver) {
        (bool hasFakeSuccessResolver, address fakeSuccessResolver) = _envAddressOrUnset("FAKE_SUCCESS_RESOLVER");
        if (hasFakeSuccessResolver) return fakeSuccessResolver;
        return _resolveTomlAddress("$.fakeUma.resolver", BURN);
    }

    function _resolveBudgetSuccessLiveness() internal view returns (uint256 liveness) {
        (bool hasBudgetSuccessLiveness, uint256 explicitBudgetSuccessLiveness) =
            _envUintOrUnset("BUDGET_SUCCESS_LIVENESS");
        if (hasBudgetSuccessLiveness) return explicitBudgetSuccessLiveness;

        (bool hasLegacyBudgetSuccessLiveness, uint256 legacyBudgetSuccessLiveness) =
            _envUintOrUnset("TCR_ORACLE_LIVENESS");
        if (hasLegacyBudgetSuccessLiveness) return legacyBudgetSuccessLiveness;

        return 1 days;
    }

    function _resolveBudgetSuccessBond() internal view returns (uint256 bondAmount) {
        (bool hasBudgetSuccessBond, uint256 explicitBudgetSuccessBond) = _envUintOrUnset("BUDGET_SUCCESS_BOND");
        if (hasBudgetSuccessBond) return explicitBudgetSuccessBond;

        (bool hasLegacyBudgetSuccessBond, uint256 legacyBudgetSuccessBond) = _envUintOrUnset("TCR_ORACLE_BOND");
        if (hasLegacyBudgetSuccessBond) return legacyBudgetSuccessBond;

        return 0;
    }

    function _loadImplementationsToml() internal {
        string memory explicitPath = _envStringOrEmpty("IMPLEMENTATIONS_TOML_FILE");
        if (bytes(explicitPath).length != 0) {
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

    function _loadGoalFactoryArtifact() internal {
        string memory explicitPath = _envStringOrEmpty("GOAL_FACTORY_ARTIFACT_FILE");
        if (bytes(explicitPath).length != 0) {
            if (!vm.isFile(explicitPath)) revert GOAL_FACTORY_ARTIFACT_NOT_FOUND(explicitPath);
            goalFactoryArtifactPathOut = explicitPath;
            goalFactoryArtifactContent = vm.readFile(explicitPath);
            _assertGoalFactoryArtifactChainId();
            return;
        }

        string memory chainScopedPath = _expectedGoalFactoryArtifactPath();
        if (vm.isFile(chainScopedPath)) {
            goalFactoryArtifactPathOut = chainScopedPath;
            goalFactoryArtifactContent = vm.readFile(chainScopedPath);
            _assertGoalFactoryArtifactChainId();
            return;
        }

        if (vm.isFile(DEFAULT_GOAL_FACTORY_ARTIFACT_FILE)) {
            goalFactoryArtifactPathOut = DEFAULT_GOAL_FACTORY_ARTIFACT_FILE;
            goalFactoryArtifactContent = vm.readFile(DEFAULT_GOAL_FACTORY_ARTIFACT_FILE);
            _assertGoalFactoryArtifactChainId();
        }
    }

    function _ensureImplementationsTomlLoaded() internal {
        if (bytes(implementationsTomlContent).length != 0 || bytes(implementationsTomlPathOut).length != 0) return;
        _loadImplementationsToml();
    }

    function _ensureGoalFactoryArtifactLoaded() internal {
        if (bytes(goalFactoryArtifactContent).length != 0 || bytes(goalFactoryArtifactPathOut).length != 0) return;
        _loadGoalFactoryArtifact();
    }

    function _expectedGoalFactoryArtifactPath() internal view returns (string memory path) {
        path = string.concat("deploys/DeployGoalFactory.", vm.toString(chainId), ".txt");
    }

    function _resolveAddress(string memory envKey, string memory tomlKey, address fallbackValue)
        internal
        returns (address value)
    {
        (bool hasEnvValue, address envValue) = _envAddressOrUnset(envKey);
        if (hasEnvValue) return envValue;
        _ensureImplementationsTomlLoaded();
        return _resolveTomlAddress(tomlKey, fallbackValue);
    }

    function _resolveUint(string memory envKey, string memory tomlKey, uint256 fallbackValue)
        internal
        returns (uint256 value)
    {
        (bool hasEnvValue, uint256 envValue) = _envUintOrUnset(envKey);
        if (hasEnvValue) return envValue;
        _ensureImplementationsTomlLoaded();
        if (_hasTomlKey(tomlKey)) return vm.parseTomlUint(implementationsTomlContent, tomlKey);
        return fallbackValue;
    }

    function _resolveTomlAddress(string memory tomlKey, address fallbackValue) internal returns (address value) {
        _ensureImplementationsTomlLoaded();
        if (_hasTomlKey(tomlKey)) return vm.parseTomlAddress(implementationsTomlContent, tomlKey);
        return fallbackValue;
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

    function _assertGoalFactoryArtifactChainId() internal view {
        string memory chainIdValue = _artifactValueForKeyOrEmpty(goalFactoryArtifactContent, "ChainID");
        if (bytes(chainIdValue).length == 0) {
            revert GOAL_FACTORY_ARTIFACT_CHAIN_ID_MISSING(goalFactoryArtifactPathOut);
        }

        uint256 configuredChainId = vm.parseUint(chainIdValue);
        if (configuredChainId != chainId) {
            revert GOAL_FACTORY_ARTIFACT_CHAIN_ID_MISMATCH(chainId, configuredChainId, goalFactoryArtifactPathOut);
        }
    }

    function _resolveOptionalEnvAddress(string memory envKey, address fallbackValue)
        internal
        view
        returns (address value)
    {
        (bool hasValue, address envValue) = _envAddressOrUnset(envKey);
        if (hasValue) return envValue;
        return fallbackValue;
    }

    function _envAddressOrUnset(string memory envKey) internal view returns (bool hasValue, address value) {
        string memory raw = _envStringOrEmpty(envKey);
        if (bytes(raw).length == 0) return (false, address(0));
        return (true, vm.parseAddress(raw));
    }

    function _envUintOrUnset(string memory envKey) internal view returns (bool hasValue, uint256 value) {
        string memory raw = _envStringOrEmpty(envKey);
        if (bytes(raw).length == 0) return (false, 0);
        return (true, vm.parseUint(raw));
    }

    function _envStringOrEmpty(string memory envKey) internal view returns (string memory value) {
        if (!vm.envExists(envKey)) return "";
        return vm.envString(envKey);
    }

    function _artifactValueForKey(string memory artifact, string memory key) internal view returns (string memory value) {
        value = _artifactValueForKeyOrEmpty(artifact, key);
        if (bytes(value).length != 0) return value;
        revert GOAL_FACTORY_ARTIFACT_KEY_NOT_FOUND(key, goalFactoryArtifactPathOut);
    }

    function _artifactValueForKeyOrEmpty(string memory artifact, string memory key)
        internal
        pure
        returns (string memory value)
    {
        bytes memory artifactBytes = bytes(artifact);
        bytes memory prefixBytes = bytes(string.concat(key, ": "));
        uint256 artifactLength = artifactBytes.length;
        uint256 prefixLength = prefixBytes.length;

        for (uint256 i = 0; i + prefixLength <= artifactLength; i++) {
            if (i != 0 && artifactBytes[i - 1] != bytes1("\n")) continue;

            bool isMatch = true;
            for (uint256 j = 0; j < prefixLength; j++) {
                if (artifactBytes[i + j] != prefixBytes[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (!isMatch) continue;

            uint256 valueStart = i + prefixLength;
            uint256 valueEnd = valueStart;
            while (valueEnd < artifactLength && artifactBytes[valueEnd] != bytes1("\n")) {
                valueEnd++;
            }
            bytes memory valueBytes = new bytes(valueEnd - valueStart);
            for (uint256 k = 0; k < valueBytes.length; k++) {
                valueBytes[k] = artifactBytes[valueStart + k];
            }
            return string(valueBytes);
        }

        return "";
    }

    error MANAGED_SAFE_NOT_CONTRACT(address managedSafe);
    error GOAL_FACTORY_NOT_CONTRACT(address goalFactory);
    error GOAL_FACTORY_ARTIFACT_NOT_FOUND(string path);
    error GOAL_FACTORY_ARTIFACT_CHAIN_ID_MISSING(string path);
    error GOAL_FACTORY_ARTIFACT_CHAIN_ID_MISMATCH(uint256 expectedChainId, uint256 configuredChainId, string path);
    error GOAL_FACTORY_ARTIFACT_KEY_NOT_FOUND(string key, string path);
    error IMPLEMENTATIONS_TOML_NOT_FOUND(string path);
    error IMPLEMENTATIONS_CHAIN_ID_MISSING(string path);
    error IMPLEMENTATIONS_CHAIN_ID_MISMATCH(uint256 expectedChainId, uint256 configuredChainId, string path);
    error GOAL_SPEND_POLICY_REQUIRED();
    error GOAL_SPEND_POLICY_NOT_CONTRACT(address spendPolicy);
    error GOAL_SPEND_POLICY_INVALID(address spendPolicy);
    error GOAL_SPEND_POLICY_OPTION_INVALID(string option);
    error BUDGET_SPEND_POLICY_REQUIRED();
    error BUDGET_SPEND_POLICY_NOT_CONTRACT(address spendPolicy);
    error BUDGET_SPEND_POLICY_INVALID(address spendPolicy);
    error BUDGET_SPEND_POLICY_OPTION_INVALID(string option);
    error SUCCESS_RESOLVER_REQUIRED();
    error SUCCESS_RESOLVER_NOT_CONTRACT(address resolver);
    error BUDGET_SUCCESS_RESOLVER_REQUIRED();
    error BUDGET_SUCCESS_RESOLVER_NOT_CONTRACT(address resolver);
}
