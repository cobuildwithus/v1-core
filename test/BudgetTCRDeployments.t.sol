// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import { BudgetTCRStackDeploymentLib, BudgetTCRStackComponentDeployer } from "src/tcr/library/BudgetTCRStackDeploymentLib.sol";
import { IBudgetTCR } from "src/tcr/interfaces/IBudgetTCR.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { GoalStakeVault } from "src/goals/GoalStakeVault.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { BudgetStakeStrategy } from "src/allocation-strategies/BudgetStakeStrategy.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

contract BudgetTCRStackDeploymentLibHarness {
    function deployTreasuryClone(address treasuryImplementation) external returns (address treasury) {
        treasury = Clones.clone(treasuryImplementation);
    }

    function prepareBudgetStack(
        address treasuryAnchor,
        IERC20 goalToken,
        IERC20 cobuildToken,
        IJBRulesets goalRulesets,
        uint256 goalRevnetId,
        uint8 paymentTokenDecimals,
        address stackComponentDeployer,
        address budgetStakeLedger,
        bytes32 recipientId
    ) external returns (BudgetTCRStackDeploymentLib.PreparationResult memory result) {
        result = BudgetTCRStackDeploymentLib.prepareBudgetStack(
            treasuryAnchor,
            goalToken,
            cobuildToken,
            goalRulesets,
            goalRevnetId,
            paymentTokenDecimals,
            stackComponentDeployer,
            budgetStakeLedger,
            recipientId
        );
    }

    function deployBudgetTreasury(
        address budgetTCR,
        address stakeVault,
        address childFlow,
        IBudgetTCR.BudgetListing calldata listing,
        address successResolver,
        uint64 successAssertionLiveness,
        uint256 successAssertionBond
    ) external returns (address budgetTreasury) {
        budgetTreasury = BudgetTCRStackDeploymentLib.deployBudgetTreasury(
            budgetTCR,
            stakeVault,
            childFlow,
            listing,
            successResolver,
            successAssertionLiveness,
            successAssertionBond
        );
    }
}

contract BudgetTCRStackDeploymentLibMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }
}

contract BudgetTCRStackDeploymentLibMockChildFlow {
    error NOT_RECIPIENT_ADMIN();

    address public recipientAdmin;
    address private immutable _superToken;

    constructor(address recipientAdmin_, address superToken_) {
        recipientAdmin = recipientAdmin_;
        _superToken = superToken_;
    }

    function setRecipientAdmin(address newRecipientAdmin) external {
        if (msg.sender != recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        recipientAdmin = newRecipientAdmin;
    }

    function superToken() external view returns (address) {
        return _superToken;
    }
}

contract BudgetTCRStackDeploymentLibMockBudgetStakeLedger {
    mapping(bytes32 => address) internal _budgetByRecipient;
    mapping(address => mapping(address => uint256)) internal _allocatedStake;

    function setBudget(bytes32 recipientId, address budgetTreasury) external {
        _budgetByRecipient[recipientId] = budgetTreasury;
    }

    function budgetForRecipient(bytes32 recipientId) external view returns (address) {
        return _budgetByRecipient[recipientId];
    }

    function setAllocatedStake(address account, address budgetTreasury, uint256 amount) external {
        _allocatedStake[account][budgetTreasury] = amount;
    }

    function userAllocatedStakeOnBudget(address account, address budgetTreasury) external view returns (uint256) {
        return _allocatedStake[account][budgetTreasury];
    }
}

contract BudgetTCRStackDeploymentLibMockStakeVault {
    address internal immutable _goalTreasury;

    constructor(address goalTreasury_) {
        _goalTreasury = goalTreasury_;
    }

    function goalTreasury() external view returns (address) {
        return _goalTreasury;
    }
}

contract BudgetTCRStackDeploymentLibPermissiveFallbackTreasury {
    fallback() external payable {
        assembly ("memory-safe") {
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

contract BudgetTCRStackDeploymentLibRecordingComponentDeployer {
    uint256 public callCount;
    address public lastStakeVaultTreasuryAnchor;
    address public lastGoalToken;
    address public lastCobuildToken;
    address public lastGoalRulesets;
    uint256 public lastGoalRevnetId;
    uint8 public lastPaymentTokenDecimals;
    address public lastBudgetStakeLedger;
    bytes32 public lastRecipientId;

    address internal immutable _stakeVaultToReturn;
    address internal immutable _strategyToReturn;

    constructor(address stakeVaultToReturn_, address strategyToReturn_) {
        _stakeVaultToReturn = stakeVaultToReturn_;
        _strategyToReturn = strategyToReturn_;
    }

    function deployComponents(
        address treasuryAnchor,
        IERC20 goalToken,
        IERC20 cobuildToken,
        IJBRulesets goalRulesets,
        uint256 goalRevnetId,
        uint8 paymentTokenDecimals,
        address budgetStakeLedger,
        bytes32 recipientId
    ) external returns (address stakeVault, address strategy) {
        callCount += 1;
        lastStakeVaultTreasuryAnchor = treasuryAnchor;
        lastGoalToken = address(goalToken);
        lastCobuildToken = address(cobuildToken);
        lastGoalRulesets = address(goalRulesets);
        lastGoalRevnetId = goalRevnetId;
        lastPaymentTokenDecimals = paymentTokenDecimals;
        lastBudgetStakeLedger = budgetStakeLedger;
        lastRecipientId = recipientId;

        return (_stakeVaultToReturn, _strategyToReturn);
    }
}

contract BudgetTCRStackDeploymentLibTest is Test {
    BudgetTCRStackDeploymentLibHarness internal harness;
    BudgetTCRStackComponentDeployer internal stackComponentDeployer;
    BudgetTCRStackDeploymentLibMockToken internal goalToken;
    BudgetTCRStackDeploymentLibMockToken internal cobuildToken;
    BudgetTCRStackDeploymentLibMockBudgetStakeLedger internal budgetStakeLedger;
    BudgetTreasury internal budgetTreasuryImplementation;
    uint64 internal constant SUCCESS_ASSERTION_LIVENESS = 1 days;
    uint256 internal constant SUCCESS_ASSERTION_BOND = 10e18;

    address internal budgetTCR = makeAddr("budgetTCR");
    bytes32 internal recipientId = bytes32(uint256(1234));

    function setUp() public {
        harness = new BudgetTCRStackDeploymentLibHarness();
        stackComponentDeployer = new BudgetTCRStackComponentDeployer();
        goalToken = new BudgetTCRStackDeploymentLibMockToken("Goal", "GOAL");
        cobuildToken = new BudgetTCRStackDeploymentLibMockToken("Cobuild", "COB");
        budgetStakeLedger = new BudgetTCRStackDeploymentLibMockBudgetStakeLedger();
        budgetTreasuryImplementation = new BudgetTreasury();
    }

    function test_prepareAndDeploy_linksTreasuryAnchor_andStrategyUsesRecipientMapping() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            treasuryAnchor,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(stackComponentDeployer),
            address(budgetStakeLedger),
            recipientId
        );

        assertTrue(prepared.stakeVault != address(0));
        assertTrue(prepared.strategy != address(0));
        assertEq(GoalStakeVault(prepared.stakeVault).goalTreasury(), treasuryAnchor);
        assertEq(BudgetStakeStrategy(prepared.strategy).recipientId(), recipientId);

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken));

        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        address budgetTreasury = _deployBudgetTreasury(
            budgetTCR, prepared.stakeVault, address(childFlow), listing, budgetTCR
        );

        assertEq(budgetTreasury, treasuryAnchor);
        assertEq(childFlow.recipientAdmin(), budgetTCR);
        assertEq(BudgetTreasury(budgetTreasury).successAssertionLiveness(), SUCCESS_ASSERTION_LIVENESS);
        assertEq(BudgetTreasury(budgetTreasury).successAssertionBond(), SUCCESS_ASSERTION_BOND);

        BudgetStakeStrategy strategy = BudgetStakeStrategy(prepared.strategy);
        address allocator = makeAddr("allocator");
        uint256 allocatorKey = uint256(uint160(allocator));

        // No registered budget for recipient yet.
        assertEq(strategy.currentWeight(allocatorKey), 0);
        assertEq(strategy.accountAllocationWeight(allocator), 0);
        assertFalse(strategy.canAllocate(allocatorKey, allocator));
        assertFalse(strategy.canAccountAllocate(allocator));

        budgetStakeLedger.setBudget(recipientId, budgetTreasury);
        budgetStakeLedger.setAllocatedStake(allocator, budgetTreasury, 42e18);

        assertEq(strategy.currentWeight(allocatorKey), 42e18);
        assertEq(strategy.accountAllocationWeight(allocator), 42e18);
        assertTrue(strategy.canAllocate(allocatorKey, allocator));
        assertTrue(strategy.canAccountAllocate(allocator));
    }

    function test_deployBudgetTreasury_revertsWhenStakeVaultAnchorsNonContractAddress() public {
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            address(0xCAFE),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(stackComponentDeployer),
            address(budgetStakeLedger),
            recipientId
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken));

        vm.expectRevert(
            abi.encodeWithSelector(BudgetTCRStackDeploymentLib.INVALID_TREASURY_ANCHOR.selector, address(0xCAFE))
        );
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), _defaultListing(), budgetTCR);
    }

    function test_deployBudgetTreasury_revertsWhenStakeVaultAnchorsZeroAddress() public {
        BudgetTCRStackDeploymentLibMockStakeVault stakeVault = new BudgetTCRStackDeploymentLibMockStakeVault(address(0));
        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken));

        vm.expectRevert(abi.encodeWithSelector(BudgetTCRStackDeploymentLib.INVALID_TREASURY_ANCHOR.selector, address(0)));
        _deployBudgetTreasury(budgetTCR, address(stakeVault), address(childFlow), _defaultListing(), budgetTCR);
    }

    function test_deployBudgetTreasury_revertsWhenStakeVaultAnchorsNonTreasuryContract() public {
        BudgetTCRStackDeploymentLibPermissiveFallbackTreasury invalidTreasury =
            new BudgetTCRStackDeploymentLibPermissiveFallbackTreasury();

        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            address(invalidTreasury),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(stackComponentDeployer),
            address(budgetStakeLedger),
            recipientId
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                BudgetTCRStackDeploymentLib.INVALID_TREASURY_CONFIGURATION.selector, address(invalidTreasury)
            )
        );
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), _defaultListing(), budgetTCR);
    }

    function test_deployBudgetTreasury_revertsWhenTreasuryCloneAlreadyInitialized() public {
        address treasuryAnchor = harness.deployTreasuryClone(address(budgetTreasuryImplementation));
        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            treasuryAnchor,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(stackComponentDeployer),
            address(budgetStakeLedger),
            recipientId
        );

        BudgetTCRStackDeploymentLibMockChildFlow childFlow = new BudgetTCRStackDeploymentLibMockChildFlow(budgetTCR, address(goalToken));
        IBudgetTCR.BudgetListing memory listing = _defaultListing();
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), listing, budgetTCR);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _deployBudgetTreasury(budgetTCR, prepared.stakeVault, address(childFlow), listing, budgetTCR);
    }

    function test_deployBudgetTreasury_revertsOnZeroCriticalAddresses() public {
        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(address(0), makeAddr("vault"), makeAddr("flow"), _defaultListing(), budgetTCR);

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(budgetTCR, address(0), makeAddr("flow"), _defaultListing(), budgetTCR);

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(budgetTCR, makeAddr("vault"), address(0), _defaultListing(), budgetTCR);

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        _deployBudgetTreasury(budgetTCR, makeAddr("vault"), makeAddr("flow"), _defaultListing(), address(0));
    }

    function test_prepareBudgetStack_revertsOnZeroCriticalAddresses() public {
        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        harness.prepareBudgetStack(
            address(0),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(stackComponentDeployer),
            address(budgetStakeLedger),
            recipientId
        );

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        harness.prepareBudgetStack(
            makeAddr("predicted"),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(0),
            address(budgetStakeLedger),
            recipientId
        );

        vm.expectRevert(BudgetTCRStackDeploymentLib.ADDRESS_ZERO.selector);
        harness.prepareBudgetStack(
            makeAddr("predicted"),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            address(stackComponentDeployer),
            address(0),
            recipientId
        );
    }

    function test_prepareBudgetStack_usesProvidedStackComponentDeployer_andForwardsParameters() public {
        address expectedStakeVault = makeAddr("expected-stake-vault");
        address expectedStrategy = makeAddr("expected-strategy");
        BudgetTCRStackDeploymentLibRecordingComponentDeployer recordingDeployer =
            new BudgetTCRStackDeploymentLibRecordingComponentDeployer(expectedStakeVault, expectedStrategy);

        address treasuryAnchor = makeAddr("prepared-treasury");
        uint256 goalRevnetId = 42;
        uint8 paymentTokenDecimals = 6;
        bytes32 configuredRecipientId = bytes32(uint256(999));
        address configuredRulesets = address(0x1234);

        BudgetTCRStackDeploymentLib.PreparationResult memory prepared = harness.prepareBudgetStack(
            treasuryAnchor,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(configuredRulesets),
            goalRevnetId,
            paymentTokenDecimals,
            address(recordingDeployer),
            address(budgetStakeLedger),
            configuredRecipientId
        );

        assertEq(prepared.stakeVault, expectedStakeVault);
        assertEq(prepared.strategy, expectedStrategy);
        assertEq(recordingDeployer.callCount(), 1);
        assertEq(recordingDeployer.lastStakeVaultTreasuryAnchor(), treasuryAnchor);
        assertEq(recordingDeployer.lastGoalToken(), address(goalToken));
        assertEq(recordingDeployer.lastCobuildToken(), address(cobuildToken));
        assertEq(recordingDeployer.lastGoalRulesets(), configuredRulesets);
        assertEq(recordingDeployer.lastGoalRevnetId(), goalRevnetId);
        assertEq(recordingDeployer.lastPaymentTokenDecimals(), paymentTokenDecimals);
        assertEq(recordingDeployer.lastBudgetStakeLedger(), address(budgetStakeLedger));
        assertEq(recordingDeployer.lastRecipientId(), configuredRecipientId);
    }

    function test_prepareBudgetStack_revertsWhenStackComponentDeployerHasNoCode() public {
        vm.expectRevert();
        harness.prepareBudgetStack(
            makeAddr("predicted"),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(0x1234)),
            1,
            18,
            makeAddr("stack-component-deployer-without-code"),
            address(budgetStakeLedger),
            recipientId
        );
    }

    function _deployBudgetTreasury(
        address budgetTCR_,
        address stakeVault,
        address childFlow,
        IBudgetTCR.BudgetListing memory listing,
        address successResolver
    ) internal returns (address budgetTreasury) {
        budgetTreasury = harness.deployBudgetTreasury(
            budgetTCR_,
            stakeVault,
            childFlow,
            listing,
            successResolver,
            SUCCESS_ASSERTION_LIVENESS,
            SUCCESS_ASSERTION_BOND
        );
    }

    function _defaultListing() internal view returns (IBudgetTCR.BudgetListing memory listing) {
        listing.metadata = FlowTypes.RecipientMetadata({
            title: "Budget",
            description: "Budget description",
            image: "ipfs://image",
            tagline: "tagline",
            url: "https://example.com"
        });
        listing.fundingDeadline = uint64(block.timestamp + 7 days);
        listing.executionDuration = uint64(14 days);
        listing.activationThreshold = 100e18;
        listing.runwayCap = 1_000e18;
        listing.oracleConfig = IBudgetTCR.OracleConfig({
            oracleType: 1,
            oracleSpecHash: keccak256("oracle-spec"),
            assertionPolicyHash: keccak256("oracle-policy")
        });
    }
}
