// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {FakeUMATreasurySuccessResolver} from "src/mocks/FakeUMATreasurySuccessResolver.sol";
import {ISuccessAssertionTreasury} from "src/interfaces/ISuccessAssertionTreasury.sol";
import {OptimisticOracleV3Interface} from "src/interfaces/uma/OptimisticOracleV3Interface.sol";
import {DeployGoalFactory} from "script/DeployGoalFactory.s.sol";
import {DeployGoalFromFactory} from "script/DeployGoalFromFactory.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";

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
        address internal constant REV_DEPLOYER = address(0x1001);
        address internal constant SUPERFLUID_HOST = address(0x1002);
        address internal constant FAKE_UMA_OWNER = address(0xF00D);
        address internal constant FAKE_UMA_ESCALATION_MANAGER = address(0xBEEF);
        bytes32 internal constant FAKE_UMA_DOMAIN_ID = bytes32(uint256(0x4d2));

        FakeResolverMockERC20 internal token;
        DeployGoalFactory internal deployScript;

        function setUp() public {
            token = new FakeResolverMockERC20();
            deployScript = new DeployGoalFactory();
        }

        function test_run_deploysFakeResolverWithConfiguredEnv() public {
            _setDeployEnv();

            address deployer = vm.addr(PRIVATE_KEY);
            uint64 nonceBefore = vm.getNonce(deployer);
            address expectedFakeResolver = vm.computeCreateAddress(deployer, uint256(nonceBefore) + 8);

            deployScript.run();

            assertGt(expectedFakeResolver.code.length, 0);

            FakeUMATreasurySuccessResolver fakeResolver = FakeUMATreasurySuccessResolver(expectedFakeResolver);
            assertEq(fakeResolver.owner(), FAKE_UMA_OWNER);
            assertEq(fakeResolver.escalationManager(), FAKE_UMA_ESCALATION_MANAGER);
            assertEq(fakeResolver.domainId(), FAKE_UMA_DOMAIN_ID);
            assertEq(address(fakeResolver.assertionCurrency()), address(token));
            assertEq(address(fakeResolver.optimisticOracle()), expectedFakeResolver);

            string memory artifactPath = string.concat("deploys/DeployGoalFactory.", vm.toString(block.chainid), ".txt");
            string memory artifact = vm.readFile(artifactPath);
            assertTrue(_stringContains(artifact, string.concat("ChainID: ", vm.toString(block.chainid))));
            assertTrue(_stringContains(artifact, string.concat("Deployer: ", vm.toString(deployer))));
            assertTrue(_stringContains(artifact, string.concat("REV_DEPLOYER: ", vm.toString(REV_DEPLOYER))));
            assertTrue(_stringContains(artifact, string.concat("SUPERFLUID_HOST: ", vm.toString(SUPERFLUID_HOST))));
            assertTrue(_stringContains(artifact, string.concat("COBUILD_TOKEN: ", vm.toString(address(token)))));
            assertTrue(_stringContains(artifact, "COBUILD_REVNET_ID: 138"));
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
        }

        function _setDeployEnv() internal {
            vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
            vm.setEnv("REV_DEPLOYER", vm.toString(REV_DEPLOYER));
            vm.setEnv("SUPERFLUID_HOST", vm.toString(SUPERFLUID_HOST));
            vm.setEnv("COBUILD_TOKEN", vm.toString(address(token)));
            vm.setEnv("COBUILD_REVNET_ID", "138");
            vm.setEnv("ESCROW_BOND_BPS", "5000");
            vm.setEnv("DEFAULT_BUDGET_TCR_GOVERNOR", "0x000000000000000000000000000000000000dEaD");
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
        uint32 internal constant MANAGER_REWARD_POOL_FLOW_RATE_PPM = 0;

        string internal constant SUCCESS_SPEC = "ipfs://success-spec";
        string internal constant SUCCESS_POLICY = "ipfs://success-policy";
        string internal constant FLOW_TAGLINE = "Goal tagline";
        string internal constant FLOW_URL = "https://goal.example";

        DeployGoalFromFactory internal deployScript;
        MockGoalFactoryForScript internal mockFactory;
        FakeResolverNoop internal successResolver;
        FakeResolverNoop internal budgetSuccessResolver;

        function setUp() public {
            deployScript = new DeployGoalFromFactory();
            mockFactory = new MockGoalFactoryForScript();
            successResolver = new FakeResolverNoop();
            budgetSuccessResolver = new FakeResolverNoop();
        }

        function test_run_wiresSuccessResolverParamsIntoFactoryCall() public {
            _setDeployEnv();

            address deployer = vm.addr(PRIVATE_KEY);

            deployScript.run();

            assertEq(mockFactory.lastSuccessResolver(), address(successResolver));
            assertEq(mockFactory.lastBudgetSuccessResolver(), address(budgetSuccessResolver));
            assertEq(mockFactory.lastSuccessLiveness(), SUCCESS_LIVENESS);
            assertEq(mockFactory.lastSuccessBond(), SUCCESS_BOND);
            assertEq(mockFactory.lastSpecHash(), keccak256(bytes(SUCCESS_SPEC)));
            assertEq(mockFactory.lastPolicyHash(), keccak256(bytes(SUCCESS_POLICY)));
            assertEq(mockFactory.lastFlowTagline(), FLOW_TAGLINE);
            assertEq(mockFactory.lastFlowUrl(), FLOW_URL);
            assertEq(mockFactory.lastManagerRewardPoolFlowRatePpm(), MANAGER_REWARD_POOL_FLOW_RATE_PPM);

            string memory artifactPath =
                string.concat("deploys/DeployGoalFromFactory.", vm.toString(block.chainid), ".txt");
            string memory artifact = vm.readFile(artifactPath);
            assertTrue(_stringContains(artifact, string.concat("ChainID: ", vm.toString(block.chainid))));
            assertTrue(_stringContains(artifact, string.concat("Deployer: ", vm.toString(deployer))));
            assertTrue(_stringContains(artifact, string.concat("GOAL_FACTORY: ", vm.toString(address(mockFactory)))));
            assertTrue(_stringContains(artifact, string.concat("GOAL_OWNER: ", vm.toString(deployer))));
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
            assertTrue(_stringContains(artifact, string.concat("goalStakeVault: ", vm.toString(address(0x5)))));
            assertTrue(_stringContains(artifact, string.concat("budgetStakeLedger: ", vm.toString(address(0x6)))));
            assertTrue(_stringContains(artifact, string.concat("splitHook: ", vm.toString(address(0x8)))));
            assertTrue(_stringContains(artifact, string.concat("budgetTCR: ", vm.toString(address(0x9)))));
            assertTrue(_stringContains(artifact, string.concat("arbitrator: ", vm.toString(address(0x10)))));
        }

        function _setDeployEnv() internal {
            vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
            vm.setEnv("GOAL_FACTORY", vm.toString(address(mockFactory)));
            vm.setEnv("SUCCESS_RESOLVER", vm.toString(address(successResolver)));
            vm.setEnv("BUDGET_SUCCESS_RESOLVER", vm.toString(address(budgetSuccessResolver)));
            vm.setEnv("SUCCESS_LIVENESS", vm.toString(uint256(SUCCESS_LIVENESS)));
            vm.setEnv("SUCCESS_BOND", vm.toString(SUCCESS_BOND));
            vm.setEnv("SUCCESS_SPEC", SUCCESS_SPEC);
            vm.setEnv("SUCCESS_POLICY", SUCCESS_POLICY);
            vm.setEnv("FLOW_TAGLINE", FLOW_TAGLINE);
            vm.setEnv("FLOW_URL", FLOW_URL);
            vm.setEnv("FLOW_MANAGER_REWARD_POOL_FLOW_RATE_PPM", vm.toString(uint256(MANAGER_REWARD_POOL_FLOW_RATE_PPM)));
        }
    }

    contract FakeResolverNoop {}

    contract MockGoalFactoryForScript {
        address public lastSuccessResolver;
        address public lastBudgetSuccessResolver;
        uint64 public lastSuccessLiveness;
        uint256 public lastSuccessBond;
        uint32 public lastManagerRewardPoolFlowRatePpm;
        bytes32 public lastSpecHash;
        bytes32 public lastPolicyHash;
        string public lastFlowTagline;
        string public lastFlowUrl;

        function deployGoal(GoalFactory.DeployParams calldata p)
            external
            returns (GoalFactory.DeployedGoalStack memory out)
        {
            lastSuccessResolver = p.success.successResolver;
            lastBudgetSuccessResolver = p.budgetTCR.budgetSuccessResolver;
            lastSuccessLiveness = p.success.successAssertionLiveness;
            lastSuccessBond = p.success.successAssertionBond;
            lastManagerRewardPoolFlowRatePpm = p.flowConfig.managerRewardPoolFlowRatePpm;
            lastSpecHash = p.success.successOracleSpecHash;
            lastPolicyHash = p.success.successAssertionPolicyHash;
            lastFlowTagline = p.flowMetadata.tagline;
            lastFlowUrl = p.flowMetadata.url;

            out.goalRevnetId = 1;
            out.goalToken = address(0x1);
            out.goalSuperToken = address(0x2);
            out.goalTreasury = address(0x3);
            out.goalFlow = address(0x4);
            out.goalStakeVault = address(0x5);
            out.budgetStakeLedger = address(0x6);
            out.splitHook = address(0x8);
            out.budgetTCR = address(0x9);
            out.arbitrator = address(0x10);
        }
    }
