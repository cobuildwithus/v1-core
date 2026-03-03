// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {IUnderwriterSlasherRouter} from "src/interfaces/IUnderwriterSlasherRouter.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
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
    event GoalSuperTokenUpgradeFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 goalAmount, bytes reason
    );
    event GoalSuperTokenForwardingFailed(
        address indexed premiumEscrow, address indexed underwriter, uint256 superTokenAmount, bytes reason
    );
    event GoalSuperTokenForwardingRetried(
        address indexed caller,
        uint256 goalBalanceBefore,
        uint256 superTokenBalanceBefore,
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

    function test_initialize_revertsWhenAlreadyInitialized() public {
        vm.expectRevert(UnderwriterSlasherRouter.ALREADY_INITIALIZED.selector);
        router.initialize(
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

    function test_initialize_cloneSetsState_andReinitializeReverts() public {
        UnderwriterSlasherRouter implementation = new UnderwriterSlasherRouter(
            IStakeVault(address(0)),
            address(0),
            IJBDirectory(address(0)),
            0,
            IERC20(address(0)),
            IERC20(address(0)),
            ISuperToken(address(0)),
            address(0)
        );

        UnderwriterSlasherRouter clone = UnderwriterSlasherRouter(Clones.clone(address(implementation)));
        _initializeRouter(clone);

        assertEq(address(clone.stakeVault()), address(stakeVault));
        assertEq(clone.authority(), address(this));
        assertEq(address(clone.directory()), address(directory));
        assertEq(address(clone.goalToken()), address(goalToken));
        assertEq(address(clone.cobuildToken()), address(cobuildToken));
        assertEq(address(clone.goalSuperToken()), address(goalSuperToken));
        assertEq(clone.goalFundingTarget(), fundingTarget);
        assertEq(clone.goalRevnetId(), GOAL_REVNET_ID);

        vm.expectRevert(UnderwriterSlasherRouter.ALREADY_INITIALIZED.selector);
        _initializeRouter(clone);
    }

    function test_constructor_allZeroSentinel_locksImplementation_andCloneCanInitialize() public {
        UnderwriterSlasherRouter implementation = new UnderwriterSlasherRouter(
            IStakeVault(address(0)),
            address(0),
            IJBDirectory(address(0)),
            0,
            IERC20(address(0)),
            IERC20(address(0)),
            ISuperToken(address(0)),
            address(0)
        );

        assertEq(address(implementation.stakeVault()), address(0));
        assertEq(implementation.authority(), address(0));
        assertEq(address(implementation.directory()), address(0));
        assertEq(implementation.goalRevnetId(), 0);
        assertEq(address(implementation.goalToken()), address(0));
        assertEq(address(implementation.cobuildToken()), address(0));
        assertEq(address(implementation.goalSuperToken()), address(0));
        assertEq(implementation.goalFundingTarget(), address(0));

        vm.expectRevert(UnderwriterSlasherRouter.ALREADY_INITIALIZED.selector);
        _initializeRouter(implementation);

        UnderwriterSlasherRouter clone = UnderwriterSlasherRouter(Clones.clone(address(implementation)));
        _initializeRouter(clone);
        assertEq(address(clone.stakeVault()), address(stakeVault));
        assertEq(clone.authority(), address(this));
        assertEq(address(clone.directory()), address(directory));
        assertEq(clone.goalRevnetId(), GOAL_REVNET_ID);
        assertEq(address(clone.goalToken()), address(goalToken));
        assertEq(address(clone.cobuildToken()), address(cobuildToken));
        assertEq(address(clone.goalSuperToken()), address(goalSuperToken));
        assertEq(clone.goalFundingTarget(), fundingTarget);
    }

    function test_constructor_partialZeroConfig_doesNotBypassValidation() public {
        vm.expectRevert(IUnderwriterSlasherRouter.ADDRESS_ZERO.selector);
        new UnderwriterSlasherRouter(
            IStakeVault(address(stakeVault)),
            address(this),
            IJBDirectory(address(directory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            address(0)
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
        _authorizePremiumEscrow();
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
        _authorizePremiumEscrow();

        vm.prank(address(premiumEscrow));
        vm.expectRevert(IUnderwriterSlasherRouter.ADDRESS_ZERO.selector);
        router.slashUnderwriter(address(0), 10e18);
    }

    function test_slashUnderwriter_routesGoalOnlySlash_withoutCobuildConversionCall() public {
        _authorizePremiumEscrow();
        stakeVault.setNextSlash(7e18, 0);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(terminal.payCallCount(), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 7e18);
    }

    function test_slashUnderwriter_upgradeFailure_doesNotRevert_andRetainsGoal() public {
        _authorizePremiumEscrow();
        stakeVault.setNextSlash(7e18, 0);

        bytes memory reason = bytes("UPGRADE_FAIL");
        vm.mockCallRevert(address(goalSuperToken), abi.encodeWithSelector(ISuperToken.upgrade.selector, 7e18), reason);

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenUpgradeFailed(address(premiumEscrow), underwriter, 7e18, reason);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(stakeVault.lastUnderwriter(), underwriter);
        assertEq(goalToken.balanceOf(address(router)), 7e18);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 0);
    }

    function test_slashUnderwriter_superTokenForwardRevert_doesNotRevert_andRetainsSuperToken() public {
        _authorizePremiumEscrow();
        stakeVault.setNextSlash(7e18, 0);

        bytes memory reason = bytes("FORWARD_FAIL");
        vm.mockCallRevert(
            address(goalSuperToken), abi.encodeWithSelector(IERC20.transfer.selector, fundingTarget, 7e18), reason
        );

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingFailed(address(premiumEscrow), underwriter, 7e18, reason);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(stakeVault.lastUnderwriter(), underwriter);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), 7e18);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 0);
    }

    function test_slashUnderwriter_superTokenForwardReturnsFalse_retainsSuperToken() public {
        _authorizePremiumEscrow();
        stakeVault.setNextSlash(7e18, 0);

        vm.mockCall(
            address(goalSuperToken), abi.encodeWithSelector(IERC20.transfer.selector, fundingTarget, 7e18), abi.encode(false)
        );

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingFailed(
            address(premiumEscrow),
            underwriter,
            7e18,
            abi.encodeWithSelector(IUnderwriterSlasherRouter.SUPER_TOKEN_TRANSFER_RETURNED_FALSE.selector, fundingTarget, 7e18)
        );

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(stakeVault.lastUnderwriter(), underwriter);
        assertEq(goalSuperToken.balanceOf(address(router)), 7e18);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 0);
    }

    function test_slashUnderwriter_routesSlash_convertsCobuild_andForwardsAsSuperToken() public {
        _authorizePremiumEscrow();
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

    function test_slashUnderwriter_smokeRealStakeVault_routesAndForwardsConvertedGoal() public {
        RouterMockStakeVaultLinkTokens stakeVaultTokens = new RouterMockStakeVaultLinkTokens();
        stakeVaultTokens.setProjectIdFor(address(goalToken), GOAL_REVNET_ID);

        RouterMockStakeVaultLinkController stakeVaultController =
            new RouterMockStakeVaultLinkController(IJBTokens(address(stakeVaultTokens)));
        RouterMockStakeVaultLinkDirectory stakeVaultDirectory = new RouterMockStakeVaultLinkDirectory();
        stakeVaultDirectory.setController(GOAL_REVNET_ID, IJBController(address(stakeVaultController)));

        RouterMockStakeVaultRulesets stakeVaultRulesets =
            new RouterMockStakeVaultRulesets(IJBDirectory(address(stakeVaultDirectory)), 1e18);

        StakeVault realStakeVault = new StakeVault(
            address(this),
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            IJBRulesets(address(stakeVaultRulesets)),
            GOAL_REVNET_ID,
            18
        );

        RouterMockDirectory realDirectory = new RouterMockDirectory();
        RouterMockTerminal realTerminal = new RouterMockTerminal(cobuildToken, goalToken);
        realDirectory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(address(realTerminal)));
        goalToken.mint(address(realTerminal), 1_000_000e18);

        UnderwriterSlasherRouter realRouter = new UnderwriterSlasherRouter(
            IStakeVault(address(realStakeVault)),
            address(this),
            IJBDirectory(address(realDirectory)),
            GOAL_REVNET_ID,
            IERC20(address(goalToken)),
            IERC20(address(cobuildToken)),
            ISuperToken(address(goalSuperToken)),
            fundingTarget
        );

        realStakeVault.setUnderwriterSlasher(address(realRouter));
        realRouter.setAuthorizedPremiumEscrow(address(premiumEscrow), true);

        uint256 goalStakeAmount = 70e18;
        uint256 cobuildStakeAmount = 50e18;
        goalToken.mint(underwriter, goalStakeAmount);
        cobuildToken.mint(underwriter, cobuildStakeAmount);

        vm.startPrank(underwriter);
        goalToken.approve(address(realStakeVault), goalStakeAmount);
        cobuildToken.approve(address(realStakeVault), cobuildStakeAmount);
        realStakeVault.depositGoal(goalStakeAmount);
        realStakeVault.depositCobuild(cobuildStakeAmount);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(realRouter));
        emit UnderwriterSlashRouted(address(premiumEscrow), underwriter, 60e18, 35e18, 25e18, 25e18, 60e18);

        vm.prank(address(premiumEscrow));
        realRouter.slashUnderwriter(underwriter, 60e18);

        assertEq(realTerminal.payCallCount(), 1);
        assertEq(realTerminal.lastPayAmount(), 25e18);
        assertEq(realStakeVault.stakedGoalOf(underwriter), 35e18);
        assertEq(realStakeVault.stakedCobuildOf(underwriter), 25e18);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 60e18);
        assertEq(goalToken.balanceOf(address(realRouter)), 0);
        assertEq(cobuildToken.balanceOf(address(realRouter)), 0);
    }

    function test_slashUnderwriter_queriesGoalTerminalWithCobuildTokenKey() public {
        _authorizePremiumEscrow();
        stakeVault.setNextSlash(0, 5e18);

        vm.expectCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, GOAL_REVNET_ID, address(cobuildToken)),
            uint64(1)
        );

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(terminal.payCallCount(), 1);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 5e18);
    }

    function test_slashUnderwriter_emitsConversionFailure_routesGoalSlash_andRetainsCobuildForLaterAttempt() public {
        _authorizePremiumEscrow();
        terminal.setShouldRevertPay(true);
        stakeVault.setNextSlash(7e18, 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit CobuildConversionFailed(
            address(premiumEscrow), underwriter, 5e18, abi.encodeWithSelector(RouterMockTerminal.PAY_REVERT.selector)
        );

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(goalSuperToken.balanceOf(fundingTarget), 7e18);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 5e18);
        assertEq(terminal.payCallCount(), 0);

        terminal.setShouldRevertPay(false);
        stakeVault.setNextSlash(0, 0);

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 0);

        assertEq(goalSuperToken.balanceOf(fundingTarget), 12e18);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
        assertEq(terminal.payCallCount(), 1);
    }

    function test_retryForwarding_forwardsHeldGoalAndSuperToken() public {
        uint256 heldGoal = 5e18;
        uint256 heldSuper = 3e18;
        goalToken.mint(address(router), heldGoal);
        goalSuperToken.mint(address(router), heldSuper);

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingRetried(address(this), heldGoal, heldSuper, heldGoal + heldSuper);
        uint256 forwarded = router.retryForwarding();

        assertEq(forwarded, heldGoal + heldSuper);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), heldGoal + heldSuper);
    }

    function test_retryForwarding_permissionlessCaller_forwardsToFixedFundingTarget() public {
        uint256 heldGoal = 5e18;
        address randomCaller = address(0xBEEF);
        goalToken.mint(address(router), heldGoal);

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingRetried(randomCaller, heldGoal, 0, heldGoal);

        vm.prank(randomCaller);
        uint256 forwarded = router.retryForwarding();

        assertEq(forwarded, heldGoal);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), heldGoal);
        assertEq(goalSuperToken.balanceOf(randomCaller), 0);
    }

    function test_retryForwarding_forwardRevert_doesNotRevert_andRetainsSuperToken() public {
        uint256 heldSuper = 3e18;
        address randomCaller = address(0xBEEF);
        bytes memory reason = bytes("RETRY_FORWARD_FAIL");
        goalSuperToken.mint(address(router), heldSuper);

        vm.mockCallRevert(
            address(goalSuperToken), abi.encodeWithSelector(IERC20.transfer.selector, fundingTarget, heldSuper), reason
        );

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingFailed(address(0), address(0), heldSuper, reason);

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingRetried(randomCaller, 0, heldSuper, 0);

        vm.prank(randomCaller);
        uint256 forwarded = router.retryForwarding();

        assertEq(forwarded, 0);
        assertEq(goalSuperToken.balanceOf(address(router)), heldSuper);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 0);
        assertEq(goalSuperToken.balanceOf(randomCaller), 0);
    }

    function test_retryConversionAndForward_permissionlessCaller_convertsHeldCobuild_andForwardsToFixedTarget()
        public
    {
        uint256 heldCobuild = 5e18;
        uint256 heldGoal = 2e18;
        uint256 heldSuper = 3e18;
        uint256 expectedForwarded = heldCobuild + heldGoal + heldSuper;
        address randomCaller = address(0xBEEF);

        cobuildToken.mint(address(router), heldCobuild);
        goalToken.mint(address(router), heldGoal);
        goalSuperToken.mint(address(router), heldSuper);

        vm.prank(randomCaller);
        (uint256 convertedGoalAmount, uint256 forwardedSuperTokenAmount) = router.retryConversionAndForward();

        assertEq(convertedGoalAmount, heldCobuild);
        assertEq(forwardedSuperTokenAmount, expectedForwarded);
        assertEq(terminal.payCallCount(), 1);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), expectedForwarded);
        assertEq(goalSuperToken.balanceOf(randomCaller), 0);
    }

    function test_retryConversionAndForward_conversionFailure_doesNotRevert_andStillForwardsHeldGoal() public {
        uint256 heldCobuild = 5e18;
        uint256 heldGoal = 2e18;
        uint256 expectedForwarded = heldGoal;
        terminal.setShouldRevertPay(true);

        cobuildToken.mint(address(router), heldCobuild);
        goalToken.mint(address(router), heldGoal);

        vm.expectEmit(true, true, true, true, address(router));
        emit CobuildConversionFailed(
            address(0), address(0), heldCobuild, abi.encodeWithSelector(RouterMockTerminal.PAY_REVERT.selector)
        );

        (uint256 convertedGoalAmount, uint256 forwardedSuperTokenAmount) = router.retryConversionAndForward();

        assertEq(convertedGoalAmount, 0);
        assertEq(forwardedSuperTokenAmount, expectedForwarded);
        assertEq(terminal.payCallCount(), 0);
        assertEq(cobuildToken.balanceOf(address(router)), heldCobuild);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(fundingTarget), expectedForwarded);
    }

    function test_retryConversionAndForward_forwardRevert_doesNotRevert_andRetainsConvertedSuperToken() public {
        uint256 heldCobuild = 5e18;
        bytes memory reason = bytes("RETRY_CONVERT_FORWARD_FAIL");
        address randomCaller = address(0xBEEF);
        cobuildToken.mint(address(router), heldCobuild);

        vm.mockCallRevert(
            address(goalSuperToken), abi.encodeWithSelector(IERC20.transfer.selector, fundingTarget, heldCobuild), reason
        );

        vm.expectEmit(true, true, true, true, address(router));
        emit GoalSuperTokenForwardingFailed(address(0), address(0), heldCobuild, reason);

        vm.prank(randomCaller);
        (uint256 convertedGoalAmount, uint256 forwardedSuperTokenAmount) = router.retryConversionAndForward();

        assertEq(convertedGoalAmount, heldCobuild);
        assertEq(forwardedSuperTokenAmount, 0);
        assertEq(terminal.payCallCount(), 1);
        assertEq(terminal.lastPayAmount(), heldCobuild);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 0);
        assertEq(goalSuperToken.balanceOf(address(router)), heldCobuild);
        assertEq(goalSuperToken.balanceOf(fundingTarget), 0);
        assertEq(goalSuperToken.balanceOf(randomCaller), 0);
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

    function test_slashUnderwriter_nonContractGoalTerminal_emitsFailureAndRetainsCobuild() public {
        _authorizePremiumEscrow();
        address nonContractTerminal = address(0xBEEF);
        directory.setPrimaryTerminal(GOAL_REVNET_ID, address(cobuildToken), IJBTerminal(nonContractTerminal));
        stakeVault.setNextSlash(7e18, 5e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit CobuildConversionFailed(
            address(premiumEscrow),
            underwriter,
            5e18,
            abi.encodeWithSelector(IUnderwriterSlasherRouter.INVALID_GOAL_TERMINAL.selector, nonContractTerminal)
        );

        vm.prank(address(premiumEscrow));
        router.slashUnderwriter(underwriter, 25e18);

        assertEq(goalSuperToken.balanceOf(fundingTarget), 7e18);
        assertEq(goalToken.balanceOf(address(router)), 0);
        assertEq(cobuildToken.balanceOf(address(router)), 5e18);
        assertEq(terminal.payCallCount(), 0);
    }

    function _authorizePremiumEscrow() internal {
        router.setAuthorizedPremiumEscrow(address(premiumEscrow), true);
    }

    function _initializeRouter(UnderwriterSlasherRouter target) internal {
        target.initialize(
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

contract RouterMockStakeVaultRulesets {
    IJBDirectory private immutable _directory;
    uint112 private immutable _weight;

    constructor(IJBDirectory directory_, uint112 weight_) {
        _directory = directory_;
        _weight = weight_;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return _directory;
    }

    function currentOf(uint256) external view returns (JBRuleset memory ruleset) {
        ruleset.weight = _weight;
    }
}

contract RouterMockStakeVaultLinkDirectory {
    mapping(uint256 => IJBController) private _controllerOf;

    function setController(uint256 projectId, IJBController controller) external {
        _controllerOf[projectId] = controller;
    }

    function controllerOf(uint256 projectId) external view returns (IJBController) {
        return _controllerOf[projectId];
    }
}

contract RouterMockStakeVaultLinkController {
    IJBTokens private immutable _tokens;

    constructor(IJBTokens tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (IJBTokens) {
        return _tokens;
    }
}

contract RouterMockStakeVaultLinkTokens {
    mapping(address => uint256) private _projectIdOf;

    function setProjectIdFor(address token, uint256 projectId) external {
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}
