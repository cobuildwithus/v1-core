// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import { GoalRevnetSplitHook } from "src/hooks/GoalRevnetSplitHook.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBSplitHook } from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBSplitHookContext } from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract GoalHookInvariantUnderlying is ERC20 {
    constructor() ERC20("Invariant Underlying", "iUND") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GoalHookInvariantSuperToken is ERC20 {
    address private immutable _underlying;

    constructor(address underlying_) ERC20("Invariant Super", "iSUP") {
        _underlying = underlying_;
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlying;
    }

    function upgrade(uint256 amount) external {
        require(IERC20(_underlying).transferFrom(msg.sender, address(this), amount), "UNDERLYING_TRANSFER_FROM_FAILED");
        _mint(msg.sender, amount);
    }
}

contract GoalHookInvariantFlow {
    ISuperToken private immutable _superToken;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }
}

contract GoalHookInvariantDirectory {
    mapping(uint256 => address) private _controllerOf;

    function setController(uint256 projectId, address controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (address) {
        return _controllerOf[projectId];
    }
}

contract GoalHookInvariantTreasury {
    error GOAL_TREASURY_REJECTED();

    bool public accepted = true;
    bool public canAccept = true;
    bool public mintingOpen;
    bool public resolved;

    IGoalTreasury.GoalState public state = IGoalTreasury.GoalState.Funding;
    address public rewardEscrow;

    uint256 public callCount;
    uint256 public totalRecordedFunding;
    uint256 public deferredHookSuperTokenAmount;
    uint32 public successSettlementRewardEscrowPpm;
    ISuperToken public superToken;
    address public flow;
    address public burnController;
    uint256 public burnProjectId;

    function setAccepted(bool accepted_) external {
        accepted = accepted_;
    }

    function setCanAccept(bool canAccept_) external {
        canAccept = canAccept_;
    }

    function setMintingOpen(bool mintingOpen_) external {
        mintingOpen = mintingOpen_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }

    function setState(IGoalTreasury.GoalState state_) external {
        state = state_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }

    function setSuccessSettlementRewardEscrowPpm(uint32 successSettlementRewardEscrowPpm_) external {
        successSettlementRewardEscrowPpm = successSettlementRewardEscrowPpm_;
    }

    function setHookRuntime(address flow_, ISuperToken superToken_, address burnController_, uint256 burnProjectId_) external {
        flow = flow_;
        superToken = superToken_;
        burnController = burnController_;
        burnProjectId = burnProjectId_;
    }

    function canAcceptHookFunding() public view returns (bool) {
        if (!canAccept || resolved) return false;
        return state == IGoalTreasury.GoalState.Funding || state == IGoalTreasury.GoalState.Active;
    }

    function isMintingOpen() external view returns (bool) {
        return mintingOpen;
    }

    function recordHookFunding(uint256 amount) external returns (bool) {
        callCount += 1;
        if (accepted) totalRecordedFunding += amount;
        return accepted;
    }

    function processHookSplit(
        address sourceToken,
        uint256 sourceAmount
    )
        external
        returns (IGoalTreasury.HookSplitAction action, uint256 superTokenAmount, uint256 rewardAmount, uint256 burnAmount)
    {
        if (canAcceptHookFunding()) {
            if (!accepted) revert GOAL_TREASURY_REJECTED();

            if (sourceToken == address(superToken)) {
                require(IERC20(sourceToken).transfer(flow, sourceAmount), "FLOW_TRANSFER_FAILED");
                superTokenAmount = sourceAmount;
            } else {
                IERC20 underlying = IERC20(superToken.getUnderlyingToken());
                underlying.approve(address(superToken), 0);
                underlying.approve(address(superToken), sourceAmount);
                uint256 superBefore = IERC20(address(superToken)).balanceOf(address(this));
                superToken.upgrade(sourceAmount);
                underlying.approve(address(superToken), 0);
                superTokenAmount = IERC20(address(superToken)).balanceOf(address(this)) - superBefore;
                require(IERC20(address(superToken)).transfer(flow, superTokenAmount), "FLOW_SUPER_TRANSFER_FAILED");
            }

            callCount += 1;
            totalRecordedFunding += superTokenAmount;
            return (IGoalTreasury.HookSplitAction.Funded, superTokenAmount, 0, 0);
        }

        if (state == IGoalTreasury.GoalState.Succeeded && mintingOpen) {
            rewardAmount = (sourceAmount * successSettlementRewardEscrowPpm) / 1_000_000;
            burnAmount = sourceAmount - rewardAmount;

            if (rewardAmount != 0) {
                require(IERC20(sourceToken).transfer(rewardEscrow, rewardAmount), "REWARD_TRANSFER_FAILED");
            }
            if (burnAmount != 0) {
                GoalHookInvariantReservedTokenController(burnController).burnTokensOf(
                    address(this), burnProjectId, burnAmount, "GOAL_SUCCESS_SETTLEMENT_BURN"
                );
            }
            return (IGoalTreasury.HookSplitAction.SuccessSettled, 0, rewardAmount, burnAmount);
        }

        if (resolved) {
            burnAmount = sourceAmount;
            if (burnAmount != 0) {
                GoalHookInvariantReservedTokenController(burnController).burnTokensOf(
                    address(this), burnProjectId, burnAmount, "GOAL_TERMINAL_RESIDUAL_BURN"
                );
            }
            return (IGoalTreasury.HookSplitAction.TerminalSettled, sourceAmount, 0, burnAmount);
        }

        deferredHookSuperTokenAmount += sourceAmount;
        return (IGoalTreasury.HookSplitAction.Deferred, sourceAmount, 0, 0);
    }
}

contract GoalHookInvariantReservedTokenController {
    uint256 public burnCallCount;
    uint256 public totalBurned;

    function burnTokensOf(address, uint256, uint256 tokenCount, string calldata) external {
        burnCallCount += 1;
        totalBurned += tokenCount;
    }

    function sendReservedSplit(
        GoalRevnetSplitHook hook,
        IERC20 transferToken,
        address contextToken,
        uint256 amount,
        uint256 projectId,
        uint256 groupId
    )
        external
    {
        if (amount != 0) require(transferToken.transfer(address(hook), amount), "TRANSFER_FAILED");

        hook.processSplitWith(
            JBSplitHookContext({
                token: contextToken,
                amount: amount,
                decimals: 18,
                projectId: projectId,
                groupId: groupId,
                split: JBSplit({
                    percent: 0,
                    projectId: 0,
                    beneficiary: payable(address(0)),
                    preferAddToBalance: false,
                    lockedUntil: 0,
                    hook: IJBSplitHook(address(0))
                })
            })
        );
    }
}

contract GoalHookRoutingSplitInvariantHandler is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant RESERVED_GROUP_ID = 1;
    uint32 internal constant SCALE_1E6 = 1_000_000;
    uint32 internal constant SETTLEMENT_REWARD_SCALED = 250_000;
    uint256 internal constant MAX_AMOUNT = 1e24;

    GoalHookInvariantUnderlying public underlying;
    GoalHookInvariantSuperToken public superToken;
    GoalHookInvariantFlow public flow;
    GoalHookInvariantDirectory public directory;
    GoalHookInvariantTreasury public treasury;
    GoalHookInvariantReservedTokenController public controller;
    GoalRevnetSplitHook public hook;

    address public rewardEscrowSink;

    uint256 public expectedFundingAmount;
    uint256 public expectedFundingCalls;
    uint256 public expectedSuccessAmount;
    uint256 public expectedSuccessCalls;
    uint256 public expectedRewardAmount;
    uint256 public expectedBurnAmount;
    uint256 public expectedTerminalAmount;
    uint256 public expectedTerminalCalls;
    uint256 public expectedDeferredAmount;

    constructor() {
        rewardEscrowSink = address(0xE5C0);

        underlying = new GoalHookInvariantUnderlying();
        superToken = new GoalHookInvariantSuperToken(address(underlying));
        flow = new GoalHookInvariantFlow(ISuperToken(address(superToken)));
        directory = new GoalHookInvariantDirectory();
        treasury = new GoalHookInvariantTreasury();
        controller = new GoalHookInvariantReservedTokenController();

        treasury.setSuccessSettlementRewardEscrowPpm(SETTLEMENT_REWARD_SCALED);
        treasury.setRewardEscrow(rewardEscrowSink);
        treasury.setHookRuntime(address(flow), ISuperToken(address(superToken)), address(controller), PROJECT_ID);
        directory.setController(PROJECT_ID, address(controller));

        hook = new GoalRevnetSplitHook(
            IJBDirectory(address(directory)),
            IGoalTreasury(address(treasury)),
            IFlow(address(flow)),
            PROJECT_ID
        );
    }

    function controllerSend(uint256 amountSeed, uint256 modeSeed) external {
        uint256 amount = bound(amountSeed, 0, MAX_AMOUNT);
        uint256 mode = modeSeed % 4;

        if (mode == 0) {
            // Funding mode.
            treasury.setCanAccept(true);
            treasury.setResolved(false);
            treasury.setState(IGoalTreasury.GoalState.Funding);
            treasury.setMintingOpen(false);
        } else if (mode == 1) {
            // Success-settlement mode.
            treasury.setCanAccept(false);
            treasury.setResolved(true);
            treasury.setState(IGoalTreasury.GoalState.Succeeded);
            treasury.setMintingOpen(true);
        } else if (mode == 2) {
            // Deferred mode.
            treasury.setCanAccept(false);
            treasury.setResolved(false);
            treasury.setState(IGoalTreasury.GoalState.Active);
            treasury.setMintingOpen(false);
        } else {
            // Terminal-settlement mode.
            treasury.setCanAccept(false);
            treasury.setResolved(true);
            treasury.setState(IGoalTreasury.GoalState.Succeeded);
            treasury.setMintingOpen(false);
        }

        if (amount != 0) underlying.mint(address(controller), amount);

        try controller.sendReservedSplit(
            hook,
            IERC20(address(underlying)),
            address(underlying),
            amount,
            PROJECT_ID,
            RESERVED_GROUP_ID
        ) {
            if (amount == 0) return;

            if (mode == 0) {
                expectedFundingAmount += amount;
                expectedFundingCalls += 1;
                return;
            }

            if (mode == 1) {
                uint256 reward = (amount * SETTLEMENT_REWARD_SCALED) / SCALE_1E6;
                uint256 burnAmount = amount - reward;

                expectedSuccessAmount += amount;
                expectedSuccessCalls += 1;
                expectedRewardAmount += reward;
                expectedBurnAmount += burnAmount;
                return;
            }

            if (mode == 3) {
                expectedTerminalAmount += amount;
                expectedTerminalCalls += 1;
                return;
            }

            expectedDeferredAmount += amount;
        } catch { }
    }

    function invalidContextCall(uint256 amountSeed, uint256 variantSeed) external {
        uint256 amount = bound(amountSeed, 0, MAX_AMOUNT);
        uint256 variant = variantSeed % 3;
        uint256 projectId = variant == 0 ? PROJECT_ID + 1 : PROJECT_ID;
        uint256 groupId = variant == 1 ? 0 : RESERVED_GROUP_ID;
        address token = variant == 2 ? address(superToken) : address(underlying);

        treasury.setCanAccept(true);
        treasury.setResolved(false);
        treasury.setState(IGoalTreasury.GoalState.Funding);
        treasury.setMintingOpen(false);

        if (amount != 0) underlying.mint(address(controller), amount);

        try controller.sendReservedSplit(hook, IERC20(address(underlying)), token, amount, projectId, groupId) { } catch { }
    }
}

contract GoalHookRoutingSplitInvariantTest is StdInvariant, Test {
    GoalHookRoutingSplitInvariantHandler internal handler;
    GoalRevnetSplitHook internal hook;
    GoalHookInvariantUnderlying internal underlying;
    GoalHookInvariantSuperToken internal superToken;
    GoalHookInvariantFlow internal flow;
    GoalHookInvariantTreasury internal treasury;
    GoalHookInvariantReservedTokenController internal controller;

    function setUp() public {
        handler = new GoalHookRoutingSplitInvariantHandler();

        hook = handler.hook();
        underlying = handler.underlying();
        superToken = handler.superToken();
        flow = handler.flow();
        treasury = handler.treasury();
        controller = handler.controller();

        targetContract(address(handler));
    }

    function invariant_fundingRouteRecordsAndForwardsToFlow() public view {
        assertEq(treasury.totalRecordedFunding(), handler.expectedFundingAmount());
        assertEq(treasury.callCount(), handler.expectedFundingCalls());
        assertEq(superToken.balanceOf(address(flow)), handler.expectedFundingAmount());
    }

    function invariant_successSettlementSplitIsConservative() public view {
        assertEq(underlying.balanceOf(handler.rewardEscrowSink()), handler.expectedRewardAmount());
        assertEq(controller.totalBurned(), handler.expectedBurnAmount() + handler.expectedTerminalAmount());
        assertEq(controller.burnCallCount(), handler.expectedSuccessCalls() + handler.expectedTerminalCalls());
        assertEq(handler.expectedRewardAmount() + handler.expectedBurnAmount(), handler.expectedSuccessAmount());
    }

    function invariant_hookBalancesMatchRoutedOutcomes() public view {
        assertEq(underlying.balanceOf(address(hook)), 0);
        assertEq(superToken.balanceOf(address(hook)), 0);
    }

    function invariant_treasuryHoldsDeferredAndBurnSideAmounts() public view {
        assertEq(
            underlying.balanceOf(address(treasury)),
            handler.expectedBurnAmount() + handler.expectedTerminalAmount() + handler.expectedDeferredAmount()
        );
        assertEq(treasury.deferredHookSuperTokenAmount(), handler.expectedDeferredAmount());
    }
}
