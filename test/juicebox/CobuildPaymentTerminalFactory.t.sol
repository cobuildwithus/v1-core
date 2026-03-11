// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";

import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {CobuildPaymentTerminalFactory} from "src/juicebox/CobuildPaymentTerminalFactory.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";

import {
    CobuildSplitHookMockDirectory,
    CobuildSplitHookMockToken
} from "test/hooks/CobuildSplitHook.t.sol";

contract CobuildPaymentTerminalFactoryTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 777;

    CobuildSplitHook internal splitHookImplementation;
    CobuildPaymentTerminalFactory internal factory;
    CobuildSplitHookMockDirectory internal directory;
    CobuildSplitHookMockToken internal communityToken;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildPaymentTerminalFactoryGoalRegistryMock internal goalRegistry;
    address internal routeSetter;

    function setUp() public {
        splitHookImplementation = new CobuildSplitHook();
        factory = new CobuildPaymentTerminalFactory(address(splitHookImplementation));
        directory = new CobuildSplitHookMockDirectory();
        communityToken = new CobuildSplitHookMockToken("Cobuild", "COB");
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        goalRegistry = new CobuildPaymentTerminalFactoryGoalRegistryMock(
            address(this),
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );
        routeSetter = address(new CobuildPaymentTerminalFactoryRouteSetterMock());
    }

    function test_deployFor_deploysPredictedHook_andInitializesAgainstSharedRouteSetter() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(address(this), ICommunityGoalRegistry(address(goalRegistry)), routeSetter, salt);

        address splitHookAddress = factory.deployFor(_deployConfig(salt));

        assertEq(splitHookAddress, predictedSplitHook);

        CobuildSplitHook splitHook = CobuildSplitHook(payable(splitHookAddress));
        assertEq(address(splitHook.directory()), address(directory));
        assertEq(splitHook.communityRevnetId(), COMMUNITY_REVNET_ID);
        assertEq(splitHook.communityToken(), address(communityToken));
        assertEq(splitHook.routeSetter(), routeSetter);
        assertEq(splitHook.goalRegistry(), address(goalRegistry));
    }

    function test_deployFor_revertsWhenCallerIsNotGoalRegistryOwner() public {
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminalFactory.UNAUTHORIZED.selector, address(this), makeAddr("not-owner"))
        );
        factory.deployFor(_deployConfig(keccak256("hook")));
    }

    function test_deployFor_revertsWhenSplitHookAlreadyExistsForSalt() public {
        bytes32 salt = keccak256("hook");
        factory.deployFor(_deployConfig(salt));

        address predictedSplitHook =
            factory.predictSplitHookAddress(address(this), ICommunityGoalRegistry(address(goalRegistry)), routeSetter, salt);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminalFactory.SPLIT_HOOK_ALREADY_DEPLOYED.selector, predictedSplitHook)
        );
        factory.deployFor(_deployConfig(salt));
    }

    function test_deployFor_revertsWhenRouteSetterHasNoCode() public {
        goalRegistry = new CobuildPaymentTerminalFactoryGoalRegistryMock(
            address(this),
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminalFactory.ROUTE_SETTER_HAS_NO_CODE.selector, address(0xBEEF))
        );
        factory.deployFor(
            CobuildPaymentTerminalFactory.DeployConfig({
                goalRegistry: ICommunityGoalRegistry(address(goalRegistry)),
                routeSetter: address(0xBEEF),
                salt: keccak256("hook")
            })
        );
    }

    function test_predictSplitHookAddress_matchesDeterministicCloneFormula() public view {
        bytes32 salt = keccak256("hook");
        bytes32 splitHookSalt =
            factory.deriveSplitHookSalt(address(this), ICommunityGoalRegistry(address(goalRegistry)), routeSetter, salt);

        assertEq(
            factory.predictSplitHookAddress(address(this), ICommunityGoalRegistry(address(goalRegistry)), routeSetter, salt),
            Clones.predictDeterministicAddress(address(splitHookImplementation), splitHookSalt, address(factory))
        );
    }

    function _deployConfig(bytes32 salt) internal view returns (CobuildPaymentTerminalFactory.DeployConfig memory) {
        return CobuildPaymentTerminalFactory.DeployConfig({
            goalRegistry: ICommunityGoalRegistry(address(goalRegistry)),
            routeSetter: routeSetter,
            salt: salt
        });
    }
}

contract CobuildPaymentTerminalFactoryGoalRegistryMock {
    address public owner;
    IJBDirectory public directory;
    IGoalDeploymentRegistry public goalDeploymentRegistry;
    uint256 public communityRevnetId;
    address public communityToken;

    constructor(
        address owner_,
        IJBDirectory directory_,
        IGoalDeploymentRegistry goalDeploymentRegistry_,
        uint256 communityRevnetId_,
        address communityToken_
    ) {
        owner = owner_;
        directory = directory_;
        goalDeploymentRegistry = goalDeploymentRegistry_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
    }
}

contract CobuildPaymentTerminalFactoryRouteSetterMock {}
