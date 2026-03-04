// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {JurorSlasherRouter} from "src/goals/JurorSlasherRouter.sol";

contract JurorSlasherRouterTest is Test {
    MockStakeVaultForJurorSlasherRouter internal stakeVault;
    address internal authority;
    address internal slasher;
    address internal juror;
    address internal recipient;

    function setUp() public {
        stakeVault = new MockStakeVaultForJurorSlasherRouter();
        authority = makeAddr("authority");
        slasher = makeAddr("slasher");
        juror = makeAddr("juror");
        recipient = makeAddr("recipient");
    }

    function test_constructor_initializes_runtime_when_non_sentinel_config() public {
        JurorSlasherRouter router = new JurorSlasherRouter(IStakeVault(address(stakeVault)), authority);

        assertEq(address(router.stakeVault()), address(stakeVault));
        assertEq(router.authority(), authority);
    }

    function test_clone_initialize_sets_state_and_rejects_reinitialize() public {
        JurorSlasherRouter implementation = new JurorSlasherRouter(IStakeVault(address(0)), address(0));
        assertEq(address(implementation.stakeVault()), address(0));
        assertEq(implementation.authority(), address(0));

        JurorSlasherRouter clone = JurorSlasherRouter(Clones.clone(address(implementation)));
        clone.initialize(IStakeVault(address(stakeVault)), authority);

        assertEq(address(clone.stakeVault()), address(stakeVault));
        assertEq(clone.authority(), authority);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(IStakeVault(address(stakeVault)), authority);
    }

    function test_implementation_instance_rejects_initialize() public {
        JurorSlasherRouter implementation = new JurorSlasherRouter(IStakeVault(address(0)), address(0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(IStakeVault(address(stakeVault)), authority);
    }

    function test_setAuthorizedSlasher_onlyAuthority() public {
        JurorSlasherRouter router = new JurorSlasherRouter(IStakeVault(address(stakeVault)), authority);

        vm.expectRevert(JurorSlasherRouter.ONLY_AUTHORITY.selector);
        router.setAuthorizedSlasher(slasher, true);

        vm.prank(authority);
        router.setAuthorizedSlasher(slasher, true);
        assertTrue(router.isAuthorizedSlasher(slasher));
    }

    function test_slashJurorStake_requiresAuthorization_and_forwards_to_stake_vault() public {
        JurorSlasherRouter router = new JurorSlasherRouter(IStakeVault(address(stakeVault)), authority);

        vm.expectRevert(JurorSlasherRouter.ONLY_AUTHORIZED_SLASHER.selector);
        router.slashJurorStake(juror, 123, recipient);

        vm.prank(authority);
        router.setAuthorizedSlasher(slasher, true);

        vm.prank(slasher);
        router.slashJurorStake(juror, 123, recipient);

        assertEq(stakeVault.lastJuror(), juror);
        assertEq(stakeVault.lastWeightAmount(), 123);
        assertEq(stakeVault.lastRecipient(), recipient);
        assertEq(stakeVault.slashCalls(), 1);
    }
}

contract MockStakeVaultForJurorSlasherRouter {
    address internal _lastJuror;
    uint256 internal _lastWeightAmount;
    address internal _lastRecipient;
    uint256 internal _slashCalls;

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external {
        _lastJuror = juror;
        _lastWeightAmount = weightAmount;
        _lastRecipient = recipient;
        _slashCalls += 1;
    }

    function lastJuror() external view returns (address) {
        return _lastJuror;
    }

    function lastWeightAmount() external view returns (uint256) {
        return _lastWeightAmount;
    }

    function lastRecipient() external view returns (address) {
        return _lastRecipient;
    }

    function slashCalls() external view returns (uint256) {
        return _slashCalls;
    }
}
