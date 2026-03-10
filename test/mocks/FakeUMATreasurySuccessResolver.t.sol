// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {FakeUMATreasurySuccessResolver} from "src/mocks/FakeUMATreasurySuccessResolver.sol";
import {ISuccessAssertionTreasury} from "src/interfaces/ISuccessAssertionTreasury.sol";
import {ISpendPolicy} from "src/interfaces/ISpendPolicy.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {DeployGoalFactory} from "script/DeployGoalFactory.s.sol";
import {DeployGoalFactoryImplementations} from "script/DeployGoalFactoryImplementations.s.sol";
import {DeployGoalFromFactory} from "script/DeployGoalFromFactory.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";
import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

function _stringContains(string memory haystack, string memory needle) pure returns (bool) {
    bytes memory haystackBytes = bytes(haystack);
    bytes memory needleBytes = bytes(needle);

    if (needleBytes.length == 0) return true;
    if (needleBytes.length > haystackBytes.length) return false;

    for (uint256 i = 0; i <= haystackBytes.length - needleBytes.length; i++) {
        bool isMatch = true;
        for (uint256 j = 0; j < needleBytes.length; j++) {
            if (haystackBytes[i + j] != needleBytes[j]) {
                isMatch = false;
                break;
            }
        }
        if (isMatch) return true;
    }

    return false;
}

contract FakeUMATreasurySuccessResolverTest is Test {
    address internal constant ATTACKER = address(0xBEEF);
    address internal constant ESCALATION_MANAGER = address(0xA11CE);
    bytes32 internal constant DOMAIN_ID = keccak256("fake-domain");

    FakeResolverMockERC20 internal token;
    FakeResolverMockTreasury internal treasury;
    FakeUMATreasurySuccessResolver internal resolver;

    function setUp() public {
        token = new FakeResolverMockERC20();
        treasury = new FakeResolverMockTreasury(4 hours, 125e6);
        resolver = new FakeUMATreasurySuccessResolver(token, ESCALATION_MANAGER, DOMAIN_ID, address(this));
    }

    function test_constructor_setsConfigAndSelfOracle() public view {
        assertEq(address(resolver.optimisticOracle()), address(resolver));
        assertEq(address(resolver.assertionCurrency()), address(token));
        assertEq(resolver.escalationManager(), ESCALATION_MANAGER);
        assertEq(resolver.domainId(), DOMAIN_ID);
        assertEq(resolver.defaultIdentifier(), bytes32("ASSERT_TRUTH2"));
        assertEq(resolver.getMinimumBond(address(token)), 0);
    }

    function test_constructor_revertsWhenCurrencyIsZero() public {
        vm.expectRevert(FakeUMATreasurySuccessResolver.ADDRESS_ZERO.selector);
        new FakeUMATreasurySuccessResolver(ERC20(address(0)), ESCALATION_MANAGER, DOMAIN_ID, address(this));
    }

    function test_prepareAssertionForTreasury_revertsWhenCallerIsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        resolver.prepareAssertionForTreasury(address(treasury), false);
    }

    function test_prepareAssertionForTreasury_revertsOnZeroTreasury() public {
        vm.expectRevert(FakeUMATreasurySuccessResolver.ADDRESS_ZERO.selector);
        resolver.prepareAssertionForTreasury(address(0), false);
    }

    function test_prepareAssertionForTreasury_registersAssertionAndPopulatesOracleState() public {
        bytes32 assertionId = resolver.prepareAssertionForTreasury(address(treasury), false);

        assertEq(treasury.registerSuccessAssertionCalls(), 1);
        assertEq(treasury.pendingSuccessAssertionId(), assertionId);
        assertEq(treasury.pendingSuccessAssertionAt(), uint64(block.timestamp));

        OptimisticOracleV3Interface.Assertion memory assertion = resolver.getAssertion(assertionId);
        assertEq(assertion.assertionTime, treasury.pendingSuccessAssertionAt());
        assertEq(assertion.expirationTime, treasury.pendingSuccessAssertionAt() + treasury.successAssertionLiveness());
        assertEq(assertion.identifier, bytes32("ASSERT_TRUTH2"));
        assertEq(address(assertion.currency), address(token));
        assertEq(assertion.domainId, DOMAIN_ID);
        assertEq(assertion.escalationManagerSettings.assertingCaller, address(resolver));
        assertEq(assertion.escalationManagerSettings.escalationManager, ESCALATION_MANAGER);
        assertEq(assertion.callbackRecipient, address(resolver));
        assertEq(assertion.asserter, address(resolver));
        assertEq(assertion.bond, treasury.successAssertionBond());
        assertTrue(assertion.settled);
        assertFalse(assertion.settlementResolution);
        assertEq(assertion.disputer, address(0));

        resolver.settleAssertion(assertionId);
        assertFalse(resolver.getAssertionResult(assertionId));
        assertFalse(resolver.settleAndGetAssertionResult(assertionId));
    }

    function test_prepareTruthfulAssertionForTreasury_setsTruthfulOutcome() public {
        bytes32 assertionId = resolver.prepareTruthfulAssertionForTreasury(address(treasury));
        assertTrue(resolver.getAssertionResult(assertionId));
    }

    function test_setSettlementResolution_updatesResultAndRevertsWhenUnknown() public {
        bytes32 missingId = keccak256("missing-assertion");
        vm.expectRevert(abi.encodeWithSelector(FakeUMATreasurySuccessResolver.ASSERTION_NOT_FOUND.selector, missingId));
        resolver.setSettlementResolution(missingId, true);

        bytes32 assertionId = resolver.prepareAssertionForTreasury(address(treasury), false);
        resolver.setSettlementResolution(assertionId, true);
        assertTrue(resolver.getAssertionResult(assertionId));
    }

    function test_setAssertionTail_overridesAssertionTimingAndBond() public {
        bytes32 assertionId = resolver.prepareAssertionForTreasury(address(treasury), false);

        resolver.setAssertionTail(assertionId, 11, 22, 333);
        OptimisticOracleV3Interface.Assertion memory assertion = resolver.getAssertion(assertionId);

        assertEq(assertion.assertionTime, 11);
        assertEq(assertion.expirationTime, 33);
        assertEq(assertion.bond, 333);
    }

    function test_setterMutators_revertWhenCallerIsNotOwner() public {
        bytes32 assertionId = resolver.prepareAssertionForTreasury(address(treasury), false);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        resolver.setSettlementResolution(assertionId, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        resolver.setAssertionTail(assertionId, 1, 2, 3);
    }

    function test_resolveTreasurySuccess_callsResolveOnTreasuryAndRevertsForInvalidCallerOrTarget() public {
        vm.expectRevert(abi.encodeWithSelector(FakeUMATreasurySuccessResolver.NOT_A_CONTRACT.selector, ATTACKER));
        resolver.resolveTreasurySuccess(ATTACKER);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        resolver.resolveTreasurySuccess(address(treasury));

        resolver.resolveTreasurySuccess(address(treasury));
        assertEq(treasury.resolveSuccessCalls(), 1);
    }

    function test_oracleReadMethods_revertForUnknownAssertion() public {
        bytes32 missingId = keccak256("missing-assertion");

        vm.expectRevert(abi.encodeWithSelector(FakeUMATreasurySuccessResolver.ASSERTION_NOT_FOUND.selector, missingId));
        resolver.getAssertion(missingId);

        vm.expectRevert(abi.encodeWithSelector(FakeUMATreasurySuccessResolver.ASSERTION_NOT_FOUND.selector, missingId));
        resolver.settleAssertion(missingId);

        vm.expectRevert(abi.encodeWithSelector(FakeUMATreasurySuccessResolver.ASSERTION_NOT_FOUND.selector, missingId));
        resolver.getAssertionResult(missingId);
    }

    function test_unsupportedUmaEntryPoints_revert() public {
        vm.expectRevert(FakeUMATreasurySuccessResolver.UNSUPPORTED.selector);
        resolver.assertTruthWithDefaults("", address(this));

        vm.expectRevert(FakeUMATreasurySuccessResolver.UNSUPPORTED.selector);
        resolver.assertTruth("", address(this), address(this), address(this), 1, token, 0, bytes32(0), bytes32(0));

        vm.expectRevert(FakeUMATreasurySuccessResolver.UNSUPPORTED.selector);
        resolver.disputeAssertion(bytes32(0), address(this));

        vm.expectRevert(FakeUMATreasurySuccessResolver.UNSUPPORTED.selector);
        resolver.syncUmaParams(bytes32(0), address(token));
    }
}

contract FakeResolverMockTreasury is ISuccessAssertionTreasury {
    address public override successResolver;
    uint64 public override successAssertionLiveness;
    uint256 public override successAssertionBond;
    bytes32 public override successOracleSpecHash;
    bytes32 public override successAssertionPolicyHash;
    bytes32 public override pendingSuccessAssertionId;
    uint64 public override pendingSuccessAssertionAt;
    uint64 public override reassertGraceDeadline;
    bool public override reassertGraceUsed;
    bool public override isReassertGraceActive;

    uint256 public registerSuccessAssertionCalls;
    uint256 public resolveSuccessCalls;

    constructor(uint64 liveness_, uint256 bond_) {
        successResolver = address(this);
        successAssertionLiveness = liveness_;
        successAssertionBond = bond_;
        successOracleSpecHash = keccak256("mock-spec");
        successAssertionPolicyHash = keccak256("mock-policy");
    }

    function treasuryKind() external pure override returns (TreasuryKind) {
        return TreasuryKind.Goal;
    }

    function registerSuccessAssertion(bytes32 assertionId) external override {
        registerSuccessAssertionCalls++;
        pendingSuccessAssertionId = assertionId;
        pendingSuccessAssertionAt = uint64(block.timestamp);
    }

    function clearSuccessAssertion(bytes32 assertionId) external override {
        if (pendingSuccessAssertionId == assertionId) {
            pendingSuccessAssertionId = bytes32(0);
            pendingSuccessAssertionAt = 0;
        }
    }

    function resolveSuccess() external override {
        resolveSuccessCalls++;
    }
}

    contract FakeResolverMockERC20 is ERC20 {
        constructor() ERC20("Mock USDC", "mUSDC") {}
    }

    contract DeployGoalFactoryScriptWiringTest is Test {
        uint256 internal constant PRIVATE_KEY = 0xA11CE;
        address internal constant SUPERFLUID_HOST = address(0x1002);
        address internal constant FAKE_UMA_OWNER = address(0xF00D);
        address internal constant FAKE_UMA_ESCALATION_MANAGER = address(0xBEEF);
        bytes32 internal constant FAKE_UMA_DOMAIN_ID = bytes32(uint256(0x4d2));
        string internal constant LATEST_IMPLEMENTATIONS_FILE = "deploys/LATEST_IMPLEMENTATIONS.txt";
        string internal constant HISTORY_DIR = "deploys/history";
        error ARTIFACT_KEY_NOT_FOUND(string key);

        FakeResolverMockERC20 internal token;
        DeployGoalFactoryImplementations internal deployImplementationsScript;
        DeployGoalFactory internal deployFactoryScript;
        address internal revDeployerAddress;
        address internal buybackHookDataHookAddress;
        address internal buybackHookAddress;
        address internal jbMultiTerminalAddress;
        MockDirectoryForScript internal revnetDirectory;
        MockTokensForScript internal revnetTokens;
        MockControllerForScript internal revnetController;

        function setUp() public {
            token = new FakeResolverMockERC20();
            revnetDirectory = new MockDirectoryForScript();
            revnetTokens = new MockTokensForScript();
            revnetController = new MockControllerForScript(address(revnetTokens));
            revDeployerAddress = address(
                new MockRevDeployerForScript(address(revnetDirectory), address(revnetController))
            );
            address nativeTerminal = address(new FakeResolverNoop());
            revnetDirectory.setPrimaryTerminal(138, JBConstants.NATIVE_TOKEN, IJBTerminal(nativeTerminal));
            revnetTokens.setTokenOf(138, address(token));
            buybackHookDataHookAddress = address(new FakeResolverNoop());
            buybackHookAddress = address(new FakeResolverNoop());
            jbMultiTerminalAddress = address(new FakeResolverNoop());
            deployImplementationsScript = new DeployGoalFactoryImplementations();
            deployFactoryScript = new DeployGoalFactory();
        }

        function test_run_deploysFakeResolverWithConfiguredEnv() public {
            _setDeployEnv();
            deployImplementationsScript.run();

            string memory latestTomlPath = _latestImplementationsTomlPath();
            string memory latestToml = vm.readFile(latestTomlPath);
            address expectedFakeResolver = vm.parseTomlAddress(latestToml, "$.fakeUma.resolver");
            address expectedCobuildTerminal = vm.parseTomlAddress(latestToml, "$.core.cobuildTerminal");
            address expectedBuybackHookDataHook = vm.parseTomlAddress(latestToml, "$.core.buybackHookDataHook");
            address expectedBuybackHook = vm.parseTomlAddress(latestToml, "$.core.buybackHook");
            assertEq(expectedBuybackHookDataHook, buybackHookDataHookAddress);
            assertEq(expectedBuybackHook, buybackHookAddress);

            FakeUMATreasurySuccessResolver fakeResolver = FakeUMATreasurySuccessResolver(expectedFakeResolver);
            assertEq(fakeResolver.owner(), FAKE_UMA_OWNER);
            assertEq(fakeResolver.escalationManager(), FAKE_UMA_ESCALATION_MANAGER);
            assertEq(fakeResolver.domainId(), FAKE_UMA_DOMAIN_ID);
            assertEq(address(fakeResolver.assertionCurrency()), address(token));
            assertEq(address(fakeResolver.optimisticOracle()), expectedFakeResolver);

            address deployer = vm.addr(PRIVATE_KEY);
            string memory artifactPath =
                string.concat("deploys/DeployGoalFactoryImplementations.", vm.toString(block.chainid), ".txt");
            string memory artifact = vm.readFile(artifactPath);
            assertTrue(_stringContains(artifact, string.concat("ChainID: ", vm.toString(block.chainid))));
            assertTrue(_stringContains(artifact, string.concat("Deployer: ", vm.toString(deployer))));
            assertTrue(_stringContains(artifact, string.concat("REV_DEPLOYER: ", vm.toString(revDeployerAddress))));
            assertTrue(_stringContains(artifact, string.concat("SUPERFLUID_HOST: ", vm.toString(SUPERFLUID_HOST))));
            assertTrue(_stringContains(artifact, string.concat("COBUILD_TOKEN: ", vm.toString(address(token)))));
            assertTrue(_stringContains(artifact, "COBUILD_REVNET_ID: 138"));
            assertTrue(
                _stringContains(artifact, string.concat("COBUILD_TERMINAL: ", vm.toString(expectedCobuildTerminal)))
            );
            assertTrue(_stringContains(artifact, "GoalTreasuryImpl: 0x"));
            assertTrue(_stringContains(artifact, "StakeVaultImpl: 0x"));
            assertTrue(_stringContains(artifact, "BudgetStakeLedgerImpl: 0x"));
            assertTrue(_stringContains(artifact, "GoalFlowAllocationLedgerPipelineImpl: 0x"));
            assertTrue(_stringContains(artifact, "PremiumEscrowImpl: 0x"));
            assertTrue(_stringContains(artifact, "UnderwriterSlasherRouterImpl: 0x"));
            assertTrue(_stringContains(artifact, "CustomFlowImpl: 0x"));
            assertTrue(_stringContains(artifact, "GoalRevnetSplitHookImpl: 0x"));
            assertTrue(_stringContains(artifact, "BudgetTCRImpl: 0x"));
            assertTrue(_stringContains(artifact, "ERC20VotesArbitratorImpl: 0x"));
            assertTrue(_stringContains(artifact, "BudgetTCRDeployerImpl: 0x"));
            assertTrue(
                _stringContains(
                    artifact, string.concat("FakeUMATreasurySuccessResolver: ", vm.toString(expectedFakeResolver))
                )
            );
            assertTrue(_stringContains(artifact, string.concat("FAKE_UMA_OWNER: ", vm.toString(FAKE_UMA_OWNER))));
            assertTrue(
                _stringContains(
                    artifact, string.concat("FAKE_UMA_ESCALATION_MANAGER: ", vm.toString(FAKE_UMA_ESCALATION_MANAGER))
                )
            );
            assertTrue(
                _stringContains(artifact, string.concat("FAKE_UMA_DOMAIN_ID: ", vm.toString(FAKE_UMA_DOMAIN_ID)))
            );

            string memory latestArtifact = vm.readFile(LATEST_IMPLEMENTATIONS_FILE);
            assertTrue(_stringContains(latestArtifact, "StakeVaultImpl: 0x"));
            assertTrue(_stringContains(latestArtifact, "BudgetStakeLedgerImpl: 0x"));
            assertTrue(_stringContains(latestArtifact, "GoalFlowAllocationLedgerPipelineImpl: 0x"));
            assertTrue(_stringContains(latestArtifact, "PremiumEscrowImpl: 0x"));
            assertTrue(_stringContains(latestArtifact, "UnderwriterSlasherRouterImpl: 0x"));
            assertTrue(_stringContains(latestArtifact, "BudgetTCRDeployerImpl: 0x"));
            assertTrue(_stringContains(latestArtifact, "FakeUMATreasurySuccessResolver: 0x"));

            string memory historyPath =
                _historyPathContainingResolver(expectedFakeResolver, "DeployGoalFactoryImplementations");
            string memory historyArtifact = vm.readFile(historyPath);
            assertTrue(
                _stringContains(
                    historyArtifact,
                    string.concat("FakeUMATreasurySuccessResolver: ", vm.toString(expectedFakeResolver))
                )
            );
        }

        function test_run_wiresFactoryCloneImplementations_andLocksImplementationInitialization() public {
            _setDeployEnv();
            deployImplementationsScript.run();
            address deployer = vm.addr(PRIVATE_KEY);

            deployFactoryScript.run();
            string memory latestToml = vm.readFile(_latestImplementationsTomlPath());
            address expectedCobuildTerminal = vm.parseTomlAddress(latestToml, "$.core.cobuildTerminal");
            address expectedJbMultiTerminal = jbMultiTerminalAddress;
            string memory artifactPath = string.concat("deploys/DeployGoalFactory.", vm.toString(block.chainid), ".txt");
            string memory artifact = vm.readFile(artifactPath);
            address expectedGoalFactory = _artifactAddressForKey(artifact, "GoalFactory");
            address budgetTcrFactory = _artifactAddressForKey(artifact, "BudgetTCRFactory");
            address pairDeployer = _artifactAddressForKey(artifact, "GoalFactoryPairDeployer");
            address predictedBudgetTcrFactory = _predictCreateAddress(pairDeployer, 1);
            address predictedGoalFactory = _predictCreateAddress(pairDeployer, 2);

            assertGt(pairDeployer.code.length, 0);
            assertGt(expectedGoalFactory.code.length, 0);
            assertGt(budgetTcrFactory.code.length, 0);
            assertEq(budgetTcrFactory, predictedBudgetTcrFactory);
            assertEq(expectedGoalFactory, predictedGoalFactory);
            assertEq(BudgetTCRFactory(budgetTcrFactory).authorizedCaller(), predictedGoalFactory);

            GoalFactory deployedFactory = GoalFactory(expectedGoalFactory);
            assertEq(deployedFactory.COBUILD_TERMINAL(), expectedCobuildTerminal);
            assertEq(deployedFactory.JB_MULTI_TERMINAL(), expectedJbMultiTerminal);
            assertEq(deployedFactory.COBUILD_TOKEN(), address(token));
            assertEq(deployedFactory.COBUILD_REVNET_ID(), 138);
            assertEq(deployedFactory.BUYBACK_HOOK_DATA_HOOK(), buybackHookDataHookAddress);
            assertEq(deployedFactory.BUYBACK_HOOK(), buybackHookAddress);

            address stakeVaultImpl = deployedFactory.STAKE_VAULT_IMPL();
            address budgetStakeLedgerImpl = deployedFactory.BUDGET_STAKE_LEDGER_IMPL();
            address goalFlowAllocationLedgerPipelineImpl = deployedFactory.GOAL_FLOW_ALLOCATION_LEDGER_PIPELINE_IMPL();
            assertGt(stakeVaultImpl.code.length, 0);
            assertGt(budgetStakeLedgerImpl.code.length, 0);
            assertGt(goalFlowAllocationLedgerPipelineImpl.code.length, 0);

            StakeVault stakeVault = StakeVault(stakeVaultImpl);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            stakeVault.initialize(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);

            BudgetStakeLedger budgetStakeLedger = BudgetStakeLedger(budgetStakeLedgerImpl);
            assertEq(budgetStakeLedger.goalTreasury(), deployer);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            budgetStakeLedger.initialize(address(0xBEEF));

            GoalFlowAllocationLedgerPipeline allocationPipeline =
                GoalFlowAllocationLedgerPipeline(goalFlowAllocationLedgerPipelineImpl);
            assertEq(allocationPipeline.allocationLedger(), address(0));
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            allocationPipeline.initialize(address(0xBEEF));
        }

        function _historyPathContainingResolver(address resolver, string memory deploymentName)
            internal
            view
            returns (string memory matchPath)
        {
            Vm.DirEntry[] memory entries = vm.readDir(HISTORY_DIR);
            string memory prefix = _historyPrefixFor(deploymentName);
            string memory resolverLine = string.concat("FakeUMATreasurySuccessResolver: ", vm.toString(resolver));

            uint256 length = entries.length;
            for (uint256 i = 0; i < length; i++) {
                if (entries[i].isDir) continue;
                if (!_stringContains(entries[i].path, prefix)) continue;
                string memory artifact = vm.readFile(entries[i].path);
                if (!_stringContains(artifact, resolverLine)) continue;
                if (bytes(matchPath).length == 0 || _isLexicographicallyAfter(entries[i].path, matchPath)) {
                    matchPath = entries[i].path;
                }
            }

            assertGt(bytes(matchPath).length, 0);
        }

        function _historyPrefixFor(string memory deploymentName) internal view returns (string memory) {
            return string.concat(HISTORY_DIR, "/", deploymentName, ".", vm.toString(block.chainid), ".");
        }

        function _latestImplementationsTomlPath() internal view returns (string memory path) {
            path = string.concat("deploys/LATEST_IMPLEMENTATIONS.", vm.toString(block.chainid), ".toml");
            if (!vm.isFile(path)) {
                path = "deploys/LATEST_IMPLEMENTATIONS.toml";
            }
        }

        function _predictCreateAddress(address deployer, uint256 nonce) internal pure returns (address predicted) {
            predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)))))
                )
            );
        }

        function _artifactAddressForKey(string memory artifact, string memory key) internal pure returns (address) {
            return vm.parseAddress(_artifactValueForKey(artifact, key));
        }

        function _artifactValueForKey(string memory artifact, string memory key)
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

            revert ARTIFACT_KEY_NOT_FOUND(key);
        }

        function _isLexicographicallyAfter(string memory a, string memory b) internal pure returns (bool) {
            bytes memory aBytes = bytes(a);
            bytes memory bBytes = bytes(b);
            uint256 minLen = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;

            for (uint256 i = 0; i < minLen; i++) {
                if (aBytes[i] > bBytes[i]) return true;
                if (aBytes[i] < bBytes[i]) return false;
            }

            return aBytes.length > bBytes.length;
        }

        function _setDeployEnv() internal {
            vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
            vm.setEnv("REV_DEPLOYER", vm.toString(revDeployerAddress));
            vm.setEnv("SUPERFLUID_HOST", vm.toString(SUPERFLUID_HOST));
            vm.setEnv("COBUILD_TOKEN", vm.toString(address(token)));
            vm.setEnv("COBUILD_REVNET_ID", "138");
            vm.setEnv("JB_MULTI_TERMINAL", vm.toString(jbMultiTerminalAddress));
            vm.setEnv("BUYBACK_HOOK_DATA_HOOK", vm.toString(buybackHookDataHookAddress));
            vm.setEnv("BUYBACK_HOOK", vm.toString(buybackHookAddress));
            vm.setEnv("ESCROW_BOND_BPS", "5000");
            vm.setEnv("DEFAULT_ALLOCATION_MECHANISM_ADMIN", "0x000000000000000000000000000000000000dEaD");
            vm.setEnv("DEFAULT_INVALID_ROUND_REWARDS_SINK", "0x000000000000000000000000000000000000dEaD");
            vm.setEnv("FAKE_UMA_OWNER", vm.toString(FAKE_UMA_OWNER));
            vm.setEnv("FAKE_UMA_ESCALATION_MANAGER", vm.toString(FAKE_UMA_ESCALATION_MANAGER));
            vm.setEnv("FAKE_UMA_DOMAIN_ID", "0x00000000000000000000000000000000000000000000000000000000000004d2");
        }
    }

    contract DeployGoalFromFactoryScriptWiringTest is Test {
        uint256 internal constant PRIVATE_KEY = 0xB0B;
        uint64 internal constant SUCCESS_LIVENESS = 7200;
        uint256 internal constant SUCCESS_BOND = 123e6;
        uint256 internal constant DEPRECATED_FLOW_MANAGER_REWARD_PPM = 1_000_001;
        address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

        string internal constant SUCCESS_SPEC = "ipfs://success-spec";
        string internal constant SUCCESS_POLICY = "ipfs://success-policy";
        string internal constant FLOW_TAGLINE = "Goal tagline";
        string internal constant FLOW_URL = "https://goal.example";

        DeployGoalFromFactory internal deployScript;
        MockGoalFactoryForScript internal mockFactory;
        MockScriptSpendPolicy internal goalSpendPolicy;
        FakeResolverNoop internal successResolver;
        FakeResolverNoop internal budgetSuccessResolver;

        function setUp() public {
            deployScript = new DeployGoalFromFactory();
            mockFactory = new MockGoalFactoryForScript();
            goalSpendPolicy = new MockScriptSpendPolicy();
            successResolver = new FakeResolverNoop();
            budgetSuccessResolver = new FakeResolverNoop();
        }

        function test_run_wiresGoalSpendPolicyAndRejectsInvalidEnvVariants() public {
            _setDeployEnv();

            address deployer = vm.addr(PRIVATE_KEY);

            deployScript.run();

            assertEq(mockFactory.lastGoalSpendPolicy(), address(goalSpendPolicy));
            assertEq(mockFactory.lastSuccessResolver(), address(successResolver));
            assertEq(mockFactory.lastBudgetSuccessResolver(), address(budgetSuccessResolver));
            assertEq(mockFactory.lastSuccessLiveness(), SUCCESS_LIVENESS);
            assertEq(mockFactory.lastSuccessBond(), SUCCESS_BOND);
            assertEq(mockFactory.lastSpecHash(), keccak256(bytes(SUCCESS_SPEC)));
            assertEq(mockFactory.lastPolicyHash(), keccak256(bytes(SUCCESS_POLICY)));
            assertEq(mockFactory.lastFlowTagline(), FLOW_TAGLINE);
            assertEq(mockFactory.lastFlowUrl(), FLOW_URL);

            string memory artifactPath =
                string.concat("deploys/DeployGoalFromFactory.", vm.toString(block.chainid), ".txt");
            string memory artifact = vm.readFile(artifactPath);
            assertTrue(_stringContains(artifact, string.concat("ChainID: ", vm.toString(block.chainid))));
            assertTrue(_stringContains(artifact, string.concat("Deployer: ", vm.toString(deployer))));
            assertTrue(_stringContains(artifact, string.concat("GOAL_FACTORY: ", vm.toString(address(mockFactory)))));
            assertTrue(_stringContains(artifact, string.concat("GOAL_OWNER: ", vm.toString(deployer))));
            assertTrue(
                _stringContains(artifact, string.concat("GOAL_SPEND_POLICY: ", vm.toString(address(goalSpendPolicy))))
            );
            assertTrue(
                _stringContains(artifact, string.concat("SUCCESS_RESOLVER: ", vm.toString(address(successResolver))))
            );
            assertTrue(
                _stringContains(
                    artifact, string.concat("BUDGET_SUCCESS_RESOLVER: ", vm.toString(address(budgetSuccessResolver)))
                )
            );
            assertTrue(_stringContains(artifact, "goalRevnetId: 1"));
            assertTrue(_stringContains(artifact, string.concat("goalToken: ", vm.toString(address(0x1)))));
            assertTrue(_stringContains(artifact, string.concat("goalSuperToken: ", vm.toString(address(0x2)))));
            assertTrue(_stringContains(artifact, string.concat("goalTreasury: ", vm.toString(address(0x3)))));
            assertTrue(_stringContains(artifact, string.concat("goalFlow: ", vm.toString(address(0x4)))));
            assertTrue(_stringContains(artifact, string.concat("stakeVault: ", vm.toString(address(0x5)))));
            assertFalse(_stringContains(artifact, "goalStakeVault:"));
            assertTrue(_stringContains(artifact, string.concat("budgetStakeLedger: ", vm.toString(address(0x6)))));
            assertTrue(_stringContains(artifact, string.concat("splitHook: ", vm.toString(address(0x8)))));
            assertTrue(_stringContains(artifact, string.concat("budgetTCR: ", vm.toString(address(0x9)))));
            assertTrue(_stringContains(artifact, string.concat("arbitrator: ", vm.toString(address(0x10)))));
            vm.setEnv("FLOW_MANAGER_REWARD_POOL_FLOW_RATE_PPM", vm.toString(DEPRECATED_FLOW_MANAGER_REWARD_PPM));

            deployScript.run();

            assertEq(mockFactory.lastSuccessResolver(), address(successResolver));
            assertEq(mockFactory.lastBudgetSuccessResolver(), address(budgetSuccessResolver));
            vm.setEnv("GOAL_SPEND_POLICY", vm.toString(BURN));

            vm.expectRevert(DeployGoalFromFactory.GOAL_SPEND_POLICY_REQUIRED.selector);
            deployScript.run();
            vm.stopBroadcast();

            _setDeployEnv();
            address invalidPolicy = address(0xBEEF);
            vm.setEnv("GOAL_SPEND_POLICY", vm.toString(invalidPolicy));

            vm.expectRevert(
                abi.encodeWithSelector(DeployGoalFromFactory.GOAL_SPEND_POLICY_NOT_CONTRACT.selector, invalidPolicy)
            );
            deployScript.run();
            vm.stopBroadcast();

            _setDeployEnv();
            ZeroContextOnlyScriptSpendPolicy invalidConfiguredPolicy = new ZeroContextOnlyScriptSpendPolicy();
            vm.setEnv("GOAL_SPEND_POLICY", vm.toString(address(invalidConfiguredPolicy)));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployGoalFromFactory.GOAL_SPEND_POLICY_INVALID.selector, address(invalidConfiguredPolicy)
                )
            );
            deployScript.run();
            vm.stopBroadcast();
        }

        function _setDeployEnv() internal {
            vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
            vm.setEnv("GOAL_FACTORY", vm.toString(address(mockFactory)));
            vm.setEnv("GOAL_SPEND_POLICY", vm.toString(address(goalSpendPolicy)));
            vm.setEnv("SUCCESS_RESOLVER", vm.toString(address(successResolver)));
            vm.setEnv("BUDGET_SUCCESS_RESOLVER", vm.toString(address(budgetSuccessResolver)));
            vm.setEnv("SUCCESS_LIVENESS", vm.toString(uint256(SUCCESS_LIVENESS)));
            vm.setEnv("SUCCESS_BOND", vm.toString(SUCCESS_BOND));
            vm.setEnv("SUCCESS_SPEC", SUCCESS_SPEC);
            vm.setEnv("SUCCESS_POLICY", SUCCESS_POLICY);
            vm.setEnv("FLOW_TAGLINE", FLOW_TAGLINE);
            vm.setEnv("FLOW_URL", FLOW_URL);
        }
    }

    contract FakeResolverNoop {}

    contract MockScriptSpendPolicy is ISpendPolicy {
        function targetFlowRate(SpendContext calldata) external pure returns (int96) {
            return 0;
        }

        function syncMode() external pure returns (SyncMode) {
            return SyncMode.Capped;
        }
    }

    contract ZeroContextOnlyScriptSpendPolicy is ISpendPolicy {
        error ACTIVE_CONTEXT_REJECTED();

        function targetFlowRate(SpendContext calldata ctx) external pure returns (int96) {
            if (ctx.timeRemaining == 0 && ctx.totalRecipientUnits == 0) return 0;
            revert ACTIVE_CONTEXT_REJECTED();
        }

        function syncMode() external pure returns (SyncMode) {
            return SyncMode.Capped;
        }
    }

    contract MockGoalFactoryForScript {
        address public lastGoalSpendPolicy;
        address public lastSuccessResolver;
        address public lastBudgetSuccessResolver;
        uint64 public lastSuccessLiveness;
        uint256 public lastSuccessBond;
        bytes32 public lastSpecHash;
        bytes32 public lastPolicyHash;
        string public lastFlowTagline;
        string public lastFlowUrl;

        function deployGoal(GoalFactory.DeployParams calldata p)
            external
            returns (GoalFactory.DeployedGoalStack memory out)
        {
            lastGoalSpendPolicy = p.goalSpendPolicy;
            lastSuccessResolver = p.success.successResolver;
            lastBudgetSuccessResolver = p.budgetTCR.budgetSuccessResolver;
            lastSuccessLiveness = p.success.successAssertionLiveness;
            lastSuccessBond = p.success.successAssertionBond;
            lastSpecHash = p.success.successOracleSpecHash;
            lastPolicyHash = p.success.successAssertionPolicyHash;
            lastFlowTagline = p.flowMetadata.tagline;
            lastFlowUrl = p.flowMetadata.url;

            out.goalRevnetId = 1;
            out.goalToken = address(0x1);
            out.goalSuperToken = address(0x2);
            out.goalTreasury = address(0x3);
            out.goalFlow = address(0x4);
            out.goalFlowAllocationLedgerPipeline = address(0x7);
            out.stakeVault = address(0x5);
            out.budgetStakeLedger = address(0x6);
            out.splitHook = address(0x8);
            out.budgetTCR = address(0x9);
            out.arbitrator = address(0x10);
        }
    }

    contract MockRevDeployerForScript {
        address internal immutable _directory;
        address internal immutable _controller;

        constructor(address directory_, address controller_) {
            _directory = directory_;
            _controller = controller_;
        }

        function DIRECTORY() external view returns (address) {
            return _directory;
        }

        function CONTROLLER() external view returns (address) {
            return _controller;
        }
    }

    contract MockControllerForScript {
        address internal immutable _tokens;

        constructor(address tokens_) {
            _tokens = tokens_;
        }

        function TOKENS() external view returns (address) {
            return _tokens;
        }
    }

    contract MockTokensForScript {
        mapping(uint256 => address) internal _tokenOf;

        function setTokenOf(uint256 projectId, address token) external {
            _tokenOf[projectId] = token;
        }

        function tokenOf(uint256 projectId) external view returns (address) {
            return _tokenOf[projectId];
        }
    }

    contract MockDirectoryForScript {
        mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

        function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
            _primaryTerminalOf[projectId][token] = terminal;
        }

        function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
            return _primaryTerminalOf[projectId][token];
        }
    }
