// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import { GoalTreasury } from "src/goals/GoalTreasury.sol";
import { BudgetTreasury } from "src/goals/BudgetTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBRulesetApprovalHook } from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { JBApprovalStatus } from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract TreasuryTerminalInvariantUnderlying is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TreasuryTerminalInvariantSuperToken is ERC20 {
    address private immutable _underlying;

    constructor(address underlying_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _underlying = underlying_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlying;
    }

    function downgrade(uint256 amount) external {
        _burn(msg.sender, amount);
        TreasuryTerminalInvariantUnderlying(_underlying).mint(msg.sender, amount);
    }
}

contract TreasuryTerminalInvariantFlow {
    ISuperToken private immutable _superToken;
    address private immutable _parent;
    address private _flowOperator;
    address private _sweeper;

    int96 private _maxSafeFlowRate;
    int96 private _totalFlowRate;
    int96 private _netFlowRateOverride;
    bool private _hasNetFlowRateOverride;

    uint256 public totalSwept;
    uint256 public setFlowRateCallCount;

    constructor(ISuperToken superToken_, address parent_) {
        _superToken = superToken_;
        _parent = parent_;
        _maxSafeFlowRate = type(int96).max;
        _flowOperator = msg.sender;
        _sweeper = msg.sender;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function parent() external view returns (address) {
        return _parent;
    }

    function getMaxSafeFlowRate() external view returns (int96) {
        return _maxSafeFlowRate;
    }

    function targetOutflowRate() external view returns (int96) {
        return _totalFlowRate;
    }

    function getActualFlowRate() external view returns (int96) {
        return _totalFlowRate;
    }

    function getNetFlowRate() external view returns (int96) {
        if (_hasNetFlowRateOverride) return _netFlowRateOverride;
        return -_totalFlowRate;
    }

    function setMaxSafeFlowRate(int96 flowRate) external {
        _maxSafeFlowRate = flowRate;
    }

    function setNetFlowRate(int96 netFlowRate_) external {
        _netFlowRateOverride = netFlowRate_;
        _hasNetFlowRateOverride = true;
    }

    function clearNetFlowRateOverride() external {
        _hasNetFlowRateOverride = false;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function setFlowOperator(address flowOperator_) external {
        _flowOperator = flowOperator_;
    }

    function sweeper() external view returns (address) {
        return _sweeper;
    }

    function setSweeper(address sweeper_) external {
        _sweeper = sweeper_;
    }

    function setTargetOutflowRate(int96 flowRate) external {
        _totalFlowRate = flowRate;
        setFlowRateCallCount += 1;
    }

    function sweepSuperToken(address to, uint256 amount) external returns (uint256 swept) {
        uint256 available = IERC20(address(_superToken)).balanceOf(address(this));
        swept = amount > available ? available : amount;
        if (swept != 0) IERC20(address(_superToken)).transfer(to, swept);
        totalSwept += swept;
    }
}

contract TreasuryTerminalInvariantStakeVault {
    address public goalTreasury;
    bool public goalResolved;
    uint256 public markCallCount;

    IERC20 private immutable _goalToken;
    IERC20 private immutable _cobuildToken;

    constructor(IERC20 goalToken_, IERC20 cobuildToken_) {
        _goalToken = goalToken_;
        _cobuildToken = cobuildToken_;
    }

    function setGoalTreasury(address goalTreasury_) external {
        goalTreasury = goalTreasury_;
    }

    function goalToken() external view returns (IERC20) {
        return _goalToken;
    }

    function cobuildToken() external view returns (IERC20) {
        return _cobuildToken;
    }

    function weightOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalWeight() external pure returns (uint256) {
        return 0;
    }

    function markGoalResolved() external {
        goalResolved = true;
        markCallCount += 1;
    }
}

contract TreasuryTerminalInvariantRulesets {
    struct RulesetPair {
        JBRuleset base;
        JBRuleset terminal;
        bool configured;
    }

    mapping(uint256 => uint112) private _weightOf;
    mapping(uint256 => RulesetPair) private _pairOf;

    function configureTwoRulesetSchedule(uint256 projectId, uint48 terminalStart, uint112 openWeight) external {
        uint48 nowTs = uint48(block.timestamp);
        RulesetPair storage pair = _pairOf[projectId];

        pair.base = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: nowTs,
            duration: 0,
            weight: openWeight,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });
        pair.terminal = JBRuleset({
            cycleNumber: 2,
            id: 2,
            basedOnId: 1,
            start: terminalStart,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        pair.configured = true;
        _weightOf[projectId] = openWeight;
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        ruleset.weight = _weightOf[projectId];
    }

    function latestQueuedOf(uint256 projectId) external view returns (JBRuleset memory ruleset, JBApprovalStatus status) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return (ruleset, JBApprovalStatus.Empty);
        return (pair.terminal, JBApprovalStatus.Approved);
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory ruleset) {
        RulesetPair storage pair = _pairOf[projectId];
        if (!pair.configured) return ruleset;
        if (rulesetId == pair.base.id) return pair.base;
        if (rulesetId == pair.terminal.id) return pair.terminal;
        return ruleset;
    }
}

contract TreasuryTerminalInvariantDirectory {
    mapping(uint256 => address) private _controllerOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }
}

contract TreasuryTerminalInvariantController {
    uint256 public burnCallCount;
    uint256 public totalBurned;

    function burnTokensOf(address, uint256, uint256 tokenCount, string calldata) external {
        burnCallCount += 1;
        totalBurned += tokenCount;
    }
}

contract TreasuryTerminalInvariantHook {
    TreasuryTerminalInvariantDirectory private immutable _directory;
    IGoalTreasury private _treasury;

    constructor(TreasuryTerminalInvariantDirectory directory_) {
        _directory = directory_;
    }

    function setTreasury(IGoalTreasury treasury_) external {
        _treasury = treasury_;
    }

    function directory() external view returns (IJBDirectory) {
        return IJBDirectory(address(_directory));
    }

    function pushFunding(uint256 amount) external returns (bool accepted) {
        accepted = _treasury.recordHookFunding(amount);
    }
}

contract TreasuryTerminalLifecycleInvariantHandler is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant MAX_AMOUNT = 1e24;

    TreasuryTerminalInvariantUnderlying public goalUnderlying;
    TreasuryTerminalInvariantSuperToken public goalSuperToken;
    TreasuryTerminalInvariantFlow public goalFlow;
    TreasuryTerminalInvariantStakeVault public goalStakeVault;
    TreasuryTerminalInvariantRulesets public goalRulesets;
    TreasuryTerminalInvariantDirectory public goalDirectory;
    TreasuryTerminalInvariantController public goalController;
    TreasuryTerminalInvariantHook public goalHook;
    GoalTreasury public goalTreasury;

    TreasuryTerminalInvariantUnderlying public budgetUnderlying;
    TreasuryTerminalInvariantSuperToken public budgetSuperToken;
    TreasuryTerminalInvariantFlow public budgetFlow;
    TreasuryTerminalInvariantStakeVault public budgetStakeVault;
    BudgetTreasury public budgetTreasury;

    uint256 public totalGoalFlowMinted;
    uint256 public totalBudgetFlowMinted;

    constructor() {
        goalUnderlying = new TreasuryTerminalInvariantUnderlying("Invariant Goal Underlying", "iGUND");
        goalSuperToken = new TreasuryTerminalInvariantSuperToken(
            address(goalUnderlying), "Invariant Goal Super", "iGSUP"
        );
        goalFlow = new TreasuryTerminalInvariantFlow(ISuperToken(address(goalSuperToken)), address(0xABCD));
        goalStakeVault = new TreasuryTerminalInvariantStakeVault(IERC20(address(goalUnderlying)), IERC20(address(0)));

        goalRulesets = new TreasuryTerminalInvariantRulesets();
        goalRulesets.configureTwoRulesetSchedule(PROJECT_ID, uint48(block.timestamp + 21 days), 1e18);

        goalDirectory = new TreasuryTerminalInvariantDirectory();
        goalController = new TreasuryTerminalInvariantController();
        goalDirectory.setController(PROJECT_ID, address(goalController));

        goalHook = new TreasuryTerminalInvariantHook(goalDirectory);
        address predictedGoalTreasury = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        goalStakeVault.setGoalTreasury(predictedGoalTreasury);
        goalFlow.setFlowOperator(predictedGoalTreasury);
        goalFlow.setSweeper(predictedGoalTreasury);
        goalTreasury = new GoalTreasury(
            address(this),
            IGoalTreasury.GoalConfig({
                flow: address(goalFlow),
                stakeVault: address(goalStakeVault),
                rewardEscrow: address(0),
                hook: address(goalHook),
                goalRulesets: address(goalRulesets),
                goalRevnetId: PROJECT_ID,
                minRaiseDeadline: uint64(block.timestamp + 3 days),
                minRaise: 100e18,
                treasurySettlementRewardEscrowScaled: 0,
                successResolver: address(this),
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("goal-oracle-spec"),
                successAssertionPolicyHash: keccak256("goal-assertion-policy")
            })
        );
        goalHook.setTreasury(goalTreasury);

        budgetUnderlying = new TreasuryTerminalInvariantUnderlying("Invariant Budget Underlying", "iBUND");
        budgetSuperToken = new TreasuryTerminalInvariantSuperToken(
            address(budgetUnderlying), "Invariant Budget Super", "iBSUP"
        );
        budgetFlow = new TreasuryTerminalInvariantFlow(ISuperToken(address(budgetSuperToken)), address(0xBEEF));
        budgetStakeVault =
            new TreasuryTerminalInvariantStakeVault(IERC20(address(budgetUnderlying)), IERC20(address(0)));
        BudgetTreasury budgetTreasuryImplementation = new BudgetTreasury();
        budgetTreasury = BudgetTreasury(Clones.clone(address(budgetTreasuryImplementation)));
        budgetStakeVault.setGoalTreasury(address(budgetTreasury));
        budgetFlow.setFlowOperator(address(budgetTreasury));
        budgetFlow.setSweeper(address(budgetTreasury));
        budgetTreasury.initialize(
            address(this),
            IBudgetTreasury.BudgetConfig({
                flow: address(budgetFlow),
                stakeVault: address(budgetStakeVault),
                fundingDeadline: uint64(block.timestamp + 3 days),
                executionDuration: uint64(7 days),
                activationThreshold: 50e18,
                runwayCap: 0,
                successResolver: address(this),
                successAssertionLiveness: uint64(1 days),
                successAssertionBond: 10e18,
                successOracleSpecHash: keccak256("budget-oracle-spec"),
                successAssertionPolicyHash: keccak256("budget-assertion-policy")
            })
        );
    }

    function warpTime(uint256 seed) external {
        uint256 jump = bound(seed, 1 hours, 10 days);
        vm.warp(block.timestamp + jump);
    }

    function goalRecordHookFunding(uint256 amount) external {
        if (goalTreasury.resolved()) return;
        uint256 boundedAmount = bound(amount, 1, MAX_AMOUNT);
        try goalHook.pushFunding(boundedAmount) returns (bool) { } catch { }
    }

    function goalMintFlowBalance(uint256 amount) external {
        if (goalTreasury.resolved()) return;
        uint256 boundedAmount = bound(amount, 0, MAX_AMOUNT);
        goalSuperToken.mint(address(goalFlow), boundedAmount);
        totalGoalFlowMinted += boundedAmount;
    }

    function goalActivate() external {
        if (goalTreasury.resolved()) return;
        if (goalTreasury.state() != IGoalTreasury.GoalState.Funding) return;
        try goalTreasury.sync() { } catch { }
    }

    function goalSync() external {
        if (goalTreasury.resolved()) return;
        try goalTreasury.sync() { } catch { }
    }

    function goalResolveSuccess() external {
        if (goalTreasury.resolved()) return;
        try goalTreasury.resolveSuccess() { } catch { }
    }

    function goalSyncAtDeadline(uint256 seed) external {
        if (goalTreasury.resolved()) return;
        uint256 jump = bound(seed, 1 days, 30 days);
        vm.warp(block.timestamp + jump);
        try goalTreasury.sync() { } catch { }
    }

    function goalSettleLateResidual(uint256 amount) external {
        if (!goalTreasury.resolved()) return;

        uint256 boundedAmount = bound(amount, 0, MAX_AMOUNT);
        if (boundedAmount != 0) {
            goalSuperToken.mint(address(goalFlow), boundedAmount);
            totalGoalFlowMinted += boundedAmount;
        }

        try goalTreasury.settleLateResidual() { } catch { }
    }

    function budgetMintFlowBalance(uint256 amount) external {
        if (budgetTreasury.resolved()) return;
        uint256 boundedAmount = bound(amount, 0, MAX_AMOUNT);
        budgetSuperToken.mint(address(budgetFlow), boundedAmount);
        totalBudgetFlowMinted += boundedAmount;
    }

    function budgetActivate() external {
        if (budgetTreasury.resolved()) return;
        if (budgetTreasury.state() != IBudgetTreasury.BudgetState.Funding) return;
        try budgetTreasury.sync() { } catch { }
    }

    function budgetSync() external {
        if (budgetTreasury.resolved()) return;
        try budgetTreasury.sync() { } catch { }
    }

    function budgetResolveSuccess() external {
        if (budgetTreasury.resolved()) return;
        try budgetTreasury.resolveSuccess() { } catch { }
    }

    function budgetResolveFailure() external {
        if (budgetTreasury.resolved()) return;

        IBudgetTreasury.BudgetState state = budgetTreasury.state();
        if (state == IBudgetTreasury.BudgetState.Funding) {
            vm.warp(budgetTreasury.fundingDeadline() + 1);
        } else if (state == IBudgetTreasury.BudgetState.Active) {
            vm.warp(budgetTreasury.deadline());
        }

        try budgetTreasury.resolveFailure() { } catch { }
    }

}

contract TreasuryTerminalLifecycleInvariantTest is StdInvariant, Test {
    TreasuryTerminalLifecycleInvariantHandler internal handler;

    GoalTreasury internal goalTreasury;
    BudgetTreasury internal budgetTreasury;
    TreasuryTerminalInvariantFlow internal goalFlow;
    TreasuryTerminalInvariantFlow internal budgetFlow;
    TreasuryTerminalInvariantSuperToken internal goalSuperToken;
    TreasuryTerminalInvariantSuperToken internal budgetSuperToken;
    TreasuryTerminalInvariantStakeVault internal goalStakeVault;
    TreasuryTerminalInvariantStakeVault internal budgetStakeVault;

    function setUp() public {
        handler = new TreasuryTerminalLifecycleInvariantHandler();

        goalTreasury = handler.goalTreasury();
        budgetTreasury = handler.budgetTreasury();
        goalFlow = handler.goalFlow();
        budgetFlow = handler.budgetFlow();
        goalSuperToken = handler.goalSuperToken();
        budgetSuperToken = handler.budgetSuperToken();
        goalStakeVault = handler.goalStakeVault();
        budgetStakeVault = handler.budgetStakeVault();

        targetContract(address(handler));
    }

    function invariant_goalTerminalLifecycleIsConsistent() public view {
        if (!goalTreasury.resolved()) return;

        IGoalTreasury.GoalState state = goalTreasury.state();
        assertTrue(state == IGoalTreasury.GoalState.Succeeded || state == IGoalTreasury.GoalState.Expired);
        assertFalse(goalTreasury.canAcceptHookFunding());
        assertEq(goalFlow.targetOutflowRate(), 0);
        assertTrue(goalStakeVault.goalResolved());
        assertEq(goalSuperToken.balanceOf(address(goalFlow)), 0);
    }

    function invariant_budgetTerminalLifecycleIsConsistent() public view {
        if (!budgetTreasury.resolved()) return;

        IBudgetTreasury.BudgetState state = budgetTreasury.state();
        assertTrue(
            state == IBudgetTreasury.BudgetState.Succeeded || state == IBudgetTreasury.BudgetState.Failed
                || state == IBudgetTreasury.BudgetState.Expired
        );
        assertFalse(budgetTreasury.canAcceptFunding());
        assertEq(budgetFlow.targetOutflowRate(), 0);
        assertTrue(budgetStakeVault.goalResolved());
        assertGt(budgetTreasury.resolvedAt(), 0);
        assertEq(budgetSuperToken.balanceOf(address(budgetFlow)), 0);
    }

    function invariant_goalFlowFundsConserved() public view {
        uint256 tracked = goalSuperToken.balanceOf(address(goalFlow)) + goalFlow.totalSwept();
        assertEq(tracked, handler.totalGoalFlowMinted());
    }

    function invariant_budgetFlowFundsConserved() public view {
        uint256 tracked = budgetSuperToken.balanceOf(address(budgetFlow)) + budgetFlow.totalSwept();
        assertEq(tracked, handler.totalBudgetFlowMinted());
    }
}
