// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {IUnderwriterSlasherRouter} from "src/interfaces/IUnderwriterSlasherRouter.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockVotesToken} from "test/mocks/MockVotesToken.sol";
import {SharedMockSuperToken} from "test/goals/helpers/TreasurySharedMocks.sol";

contract UnderwriterSlasherRouterTest is Test {
    uint256 internal constant GOAL_REVNET_ID = 88;

    event PremiumEscrowAuthorizationSet(address indexed premiumEscrow, bool authorized);
    event CobuildConversionFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 cobuildAmount, bytes reason
    );
    event UnderwriterSlashRouted(
        address indexed premiumEscrow,
        address indexed underwriter,
        uint256 requestedWeight,
        uint256 goalSlashedAmount,
        uint256 cobuildSlashedAmount,
        uint256 convertedGoalAmount,
        uint256 forwardedSuperTokenAmount
    );

    address internal underwriter = address(0xA11CE);
    address internal fundingTarget = address(0xF00D);
    address internal premiumEscrowEoa = address(0xE5C0);

    MockVotesToken internal goalToken;
    MockVotesToken internal cobuildToken;
    SharedMockSuperToken internal goalSuperToken;
    RouterMockStakeVault internal stakeVault;
    RouterMockDirectory internal directory;
    RouterMockTerminal internal terminal;
    RouterMockPremiumEscrow internal premiumEscrow;
    UnderwriterSlasherRouter internal router;

    function setUp() public {
        goalToken = new MockVotesToken("Goal", "GOAL");
        cobuildToken = new MockVotesToken("Cobuild", "COBUILD");
        goalSuperToken = new SharedMockSuperToken(address(goalToken));

        stakeVault = new RouterMockStakeVault(goalToken, cobuildToken);
        directory = new RouterMockDirectory();
        terminal = new RouterMockTerminal(cobuildToken, goalToken);
        premiumEscrow = new RouterMockPremiumEscrow();
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
    }

    function test_setAuthorizedPremiumEscrow_revertsWhenNotAuthority() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(IUnderwriterSlasherRouter.ONLY_AUTHORITY.selector);
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
    }

    function test_setAuthorizedPremiumEscrow_updatesAuthorization() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit PremiumEscrowAuthorizationSet(address(premiumEscrow), true);
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);

        assertTrue(router.isAuthorizedPremiumEscrow(address(premiumEscrow)));
    }

    function test_setAuthorizedPremiumEscrow_revertsOnZeroAddress() public {
        vm.expectRevert(IUnderwriterSlasherRouter.ADDRESS_ZERO.selector);
        router.setAuthorizedPremiumEscrow(address(0), true);
    }

    function test_setAuthorizedPremiumEscrow_allowsEoaAddress() public {
        router.setAuthorizedPremiumEscrow(premiumEscrowEoa, true);
        assertTrue(router.isAuthorizedPremiumEscrow(premiumEscrowEoa));
    }

    function test_setAuthorizedPremiumEscrow_canRevokeAuthorization() public {
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
        assertTrue(router.isAuthorizedPremiumEscrow(address(premiumEscrow)));

        vm.expectEmit(true, true, true, true, address(router));
        emit PremiumEscrowAuthorizationSet(address(premiumEscrow), false);
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), false);

        assertFalse(router.isAuthorizedPremiumEscrow(address(premiumEscrow)));
    }

    function test_slashUnderwriter_revertsWhenCallerNotAuthorizedEscrow() public {
        stakeVault.setNextSlash(3e18, 1e18);

        vm.expectRevert(IUnderwriterSlasherRouter.ONLY_AUTHORIZED_PREMIUM_ESCROW.selector);
        router.slashUnderwriter(underwriter, 10e18);
    }

    function test_slashUnderwriter_revertsOnZeroUnderwriter() public {
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);

        vm.prank(address(premiumEscrow));
        vm.expectRevert(IUnderwriterSlasherRouter.ADDRESS_ZERO.selector);
        router.slashUnderwriter(address(0), 10e18);
    }

    function test_slashUnderwriter_routesGoalOnlySlash_withoutCobuildConversionCall() public {
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
        stakeVault.setNextSlash(7e18, 0);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(terminal.payCallCount(), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 7e18);
    }

    function test_slashUnderwriter_routesSlash_convertsCobuild_andForwardsAsSuperToken() public {
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
        stakeVault.setNextSlash(7e18, 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit UnderwriterSlashRouted(address(premiumEscrow), underwriter, 25e18, 7e18, 5e18, 5e18, 12e18);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(stakeVault.lastUnderwriter(), underwriter);
        assertEq(stakeVault.lastWeightAmount(), 25e18);
        assertEq(stakeVault.lastRecipient(), address(router));

        assertEq(terminal.payCallCount(), 1);
        assertEq(terminal.lastPayAmount(), 5e18);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 12e18);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
    }

    function test_slashUnderwriter_emitsConversionFailure_andRetainsCobuildForLaterAttempt() public {
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
        terminal.setShouldRevertPay(true);
        stakeVault.setNextSlash(7e18, 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit CobuildConversionFailed(
            address(premiumEscrow), underwriter, 5e18, abi.encodeWithSelector(RouterMockTerminal.PAY_REVERT.selector)
        );

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(goalSuperToken.balanceOf(fundingTarget), 7e18);
        assertEq(cobuildToken.balanceOf(address(router)), 5e18);

        terminal.setShouldRevertPay(false);
        stakeVault.setNextSlash(0, 0);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 0);

        assertEq(goalSuperToken.balanceOf(fundingTarget), 12e18);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
        assertEq(terminal.payCallCount(), 1);
    }

    function test_constructor_revertsWhenSuperTokenUnderlyingMismatch() public {
        SharedMockSuperToken badSuperToken = new SharedMockSuperToken(address(cobuildToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderwriterSlasherRouter.GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH.selector,
                address(goalToken),
                address(cobuildToken)
            )
        );

        new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(badSuperToken)),
            fundingTarget
        );
    }

    function test_constructor_revertsWhenGoalTokenDoesNotMatchStakeVault() public {
        MockVotesToken wrongGoalToken = new MockVotesToken("Wrong Goal", "WGOAL");

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderwriterSlasherRouter.INVALID_GOAL_TOKEN.selector, address(goalToken), address(wrongGoalToken)
            )
        );

        new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(wrongGoalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            fundingTarget
        );
    }

    function test_constructor_revertsWhenCobuildTokenDoesNotMatchStakeVault() public {
        MockVotesToken wrongCobuildToken = new MockVotesToken("Wrong Cobuild", "WCOBUILD");

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderwriterSlasherRouter.INVALID_COBUILD_TOKEN.selector,
                address(cobuildToken),
                address(wrongCobuildToken)
            )
        );

        new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(wrongCobuildToken)),
            ISuperToken(address(goalSuperToken)),
            fundingTarget
        );
    }

    function test_constructor_missingGoalTerminal_conversionFailsAndRetainsCobuild() public {
        RouterMockDirectory emptyDirectory = new RouterMockDirectory();
        UnderwriterSlasherRouter routerWithMissingTerminal = new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(emptyDirectory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            fundingTarget
        );

        routerWithMissingTerminal.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
        stakeVault.setNextSlash(7e18, 5e18);

        vm.expectEmit(true, true, true, true, address(routerWithMissingTerminal));
        emit CobuildConversionFailed(
            address(premiumEscrow),
            underwriter,
            5e18,
            abi.encodeWithSelector(IUnderwriterSlasherRouter.INVALID_GOAL_TERMINAL.selector, address(0))
        );

        vm.prank(address(premiumEscrow));
        routerWithMissingTerminal.slashUnderwriter(underwriter, 25e18);

        assertEq(goalSuperToken.balanceOf(fundingTarget), 7e18);
        assertEq(cobuildToken.balanceOf(address(routerWithMissingTerminal)), 5e18);
    }
}

contract RouterMockStakeVault {
    IERC20 private immutable _goalToken;
    IERC20 private immutable _cobuildToken;

    uint256 private _nextGoalSlashAmount;
    uint256 private _nextCobuildSlashAmount;

    address private _lastUnderwriter;
    uint256 private _lastWeightAmount;
    address private _lastRecipient;

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

    function slashUnderwriterStake(address underwriter, uint256 weightAmount, address recipient) external {
        _lastUnderwriter = underwriter;
        _lastWeightAmount = weightAmount;
        _lastRecipient = recipient;

        uint256 goalAmount = _nextGoalSlashAmount;
        uint256 cobuildAmount = _nextCobuildSlashAmount;
        _nextGoalSlashAmount = 0;
        _nextCobuildSlashAmount = 0;

        if (goalAmount != 0) _goalToken.transfer(recipient, goalAmount);
        if (cobuildAmount != 0) _cobuildToken.transfer(recipient, cobuildAmount);
    }

    function lastUnderwriter() external view returns (address) {
        return _lastUnderwriter;
    }

    function lastWeightAmount() external view returns (uint256) {
        return _lastWeightAmount;
    }

    function lastRecipient() external view returns (address) {
        return _lastRecipient;
    }
}

contract RouterMockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) private _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract RouterMockTerminal {
    error PAY_REVERT();

    IERC20 public immutable cobuildToken;
    IERC20 public immutable goalToken;

    bool public shouldRevertPay;
    uint256 public payCallCount;
    uint256 public lastPayAmount;

    constructor(IERC20 cobuildToken_, IERC20 goalToken_) {
        cobuildToken = cobuildToken_;
        goalToken = goalToken_;
    }

    function setShouldRevertPay(bool shouldRevert) external {
        shouldRevertPay = shouldRevert;
    }

    function pay(uint256, address token, uint256 amount, address beneficiary, uint256, string calldata, bytes calldata)
        external
        returns (uint256 beneficiaryTokenCount)
    {
        if (shouldRevertPay) revert PAY_REVERT();
        if (token != address(cobuildToken)) revert PAY_REVERT();

        payCallCount += 1;
        lastPayAmount = amount;

        cobuildToken.transferFrom(msg.sender, address(this), amount);
        goalToken.transfer(beneficiary, amount);
        return amount;
    }
}

contract RouterMockPremiumEscrow {}
