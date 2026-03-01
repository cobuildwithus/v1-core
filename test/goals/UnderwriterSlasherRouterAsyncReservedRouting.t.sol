// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {SharedMockSuperToken} from "test/goals/helpers/TreasurySharedMocks.sol";

contract UnderwriterSlasherRouterAsyncReservedRoutingTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 88;

    event UnderwriterSlashRouted(
        address indexed premiumEscrow,
        address indexed underwriter,
        uint256 requestedWeight,
        uint256 goalSlashedAmount,
        uint256 cobuildSlashedAmount,
        uint256 convertedGoalAmount,
        uint256 forwardedSuperTokenAmount
    );
    event GoalSuperTokenForwardingRetried(
        address indexed caller,
        uint256 goalBalanceBefore,
        uint256 superTokenBalanceBefore,
        uint256 forwardedSuperTokenAmount
    );

    address internal underwriter = address(0xA11CE);
    address internal fundingTarget = address(0xF00D);
    address internal premiumEscrow = address(0xE5C0);

    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    SharedMockSuperToken internal goalSuperToken;
    AsyncReservedMockStakeVault internal stakeVault;
    AsyncReservedMockDirectory internal directory;
    AsyncReservedMockTerminal internal terminal;
    UnderwriterSlasherRouter internal router;

    function setUp() public {
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        goalSuperToken = new SharedMockSuperToken(address(goalToken));

        stakeVault = new AsyncReservedMockStakeVault(goalToken, cobuildToken);
        directory = new AsyncReservedMockDirectory();
        terminal = new AsyncReservedMockTerminal(cobuildToken, goalToken);
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(terminal)));

        goalToken.mint(address(stakeVault), 1_000_000e18);
        cobuildToken.mint(address(stakeVault), 1_000_000e18);
        goalToken.mint(address(terminal), 1_000_000e18);

        router = new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            fundingTarget
        );
        router.setAuthorizedPremiumEscrow(premiumEscrow, true);
    }

    function test_slashUnderwriter_allowsAsyncReservedRouting_whenImmediateGoalMintIsZero() public {
        terminal.setShouldDeferGoalPayout(true);
        stakeVault.setNextSlash(0, 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit UnderwriterSlashRouted(premiumEscrow, underwriter, 25e18, 0, 5e18, 0, 0);

        vm.prank(premiumEscrow);
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(terminal.payCallCount(), 1);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 0);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(terminal)), 5e18);

        terminal.settleDeferredGoal(address(router), 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingRetried(address(this), 5e18, 0, 5e18);
        uint256 forwarded = router.retryForwarding();

        assertEq(forwarded, 5e18);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 5e18);
    }
}

contract AsyncReservedMockStakeVault {
    IERC20 private immutable _goalToken;
    IERC20 private immutable _cobuildToken;
    uint256 private _nextGoalSlashAmount;
    uint256 private _nextCobuildSlashAmount;

    constructor(IERC20 goalToken_, IERC20 cobuildToken_) {
        _goalToken = goalToken_;
        _cobuildToken = cobuildToken_;
    }

    function setNextSlash(uint256 goalAmount, uint256 cobuildAmount) external {
        _nextGoalSlashAmount = goalAmount;
        _nextCobuildSlashAmount = cobuildAmount;
    }

    function goalToken() external view returns (IERC20) {
        return _goalToken;
    }

    function cobuildToken() external view returns (IERC20) {
        return _cobuildToken;
    }

    function slashUnderwriterStake(address, uint256, address recipient) external {
        uint256 goalAmount = _nextGoalSlashAmount;
        uint256 cobuildAmount = _nextCobuildSlashAmount;
        _nextGoalSlashAmount = 0;
        _nextCobuildSlashAmount = 0;

        if (goalAmount != 0) _goalToken.transfer(recipient, goalAmount);
        if (cobuildAmount != 0) _cobuildToken.transfer(recipient, cobuildAmount);
    }
}

contract AsyncReservedMockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) private _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract AsyncReservedMockTerminal {
    IERC20 public immutable cobuildToken;
    IERC20 public immutable goalToken;

    bool public shouldDeferGoalPayout;
    uint256 public payCallCount;

    constructor(IERC20 cobuildToken_, IERC20 goalToken_) {
        cobuildToken = cobuildToken_;
        goalToken = goalToken_;
    }

    function setShouldDeferGoalPayout(bool shouldDefer) external {
        shouldDeferGoalPayout = shouldDefer;
    }

    function settleDeferredGoal(address beneficiary, uint256 amount) external {
        goalToken.transfer(beneficiary, amount);
    }

    function pay(uint256, address token, uint256 amount, address beneficiary, uint256, string calldata, bytes calldata)
        external
        returns (uint256 beneficiaryTokenCount)
    {
        require(token == address(cobuildToken), "INVALID_TOKEN");

        payCallCount += 1;

        cobuildToken.transferFrom(msg.sender, address(this), amount);
        if (!shouldDeferGoalPayout) {
            goalToken.transfer(beneficiary, amount);
        }
        return amount;
    }
}
