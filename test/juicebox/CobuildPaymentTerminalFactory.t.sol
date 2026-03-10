// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Test} from "forge-std/Test.sol";

import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {CobuildPaymentTerminal} from "src/juicebox/CobuildPaymentTerminal.sol";
import {CobuildPaymentTerminalFactory} from "src/juicebox/CobuildPaymentTerminalFactory.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";

import {
    CobuildSplitHookMockDirectory,
    CobuildSplitHookMockGoalRegistry,
    CobuildSplitHookMockToken
} from "test/hooks/CobuildSplitHook.t.sol";

contract CobuildPaymentTerminalFactoryTest is Test {
    uint256 internal constant COMMUNITY_REVNET_ID = 777;
    uint256 internal constant COBUILD_REVNET_ID = 138;

    CobuildSplitHook internal splitHookImplementation;
    CobuildPaymentTerminalFactory internal factory;
    CobuildSplitHookMockDirectory internal directory;
    CobuildSplitHookMockToken internal communityToken;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildSplitHookMockGoalRegistry internal goalRegistry;

    function setUp() public {
        splitHookImplementation = new CobuildSplitHook();
        factory = new CobuildPaymentTerminalFactory(address(splitHookImplementation));
        directory = new CobuildSplitHookMockDirectory();
        communityToken = new CobuildSplitHookMockToken("Cobuild", "COB");
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        goalRegistry = new CobuildSplitHookMockGoalRegistry(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );
    }

    function test_deployFor_deploysPredictedPair_andInitializesHookAgainstTerminal() public {
        bytes32 salt = keccak256("pair");
        address predictedSplitHook = factory.predictSplitHookAddress(
            address(this),
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            ICommunityGoalRegistry(address(goalRegistry)),
            COBUILD_REVNET_ID,
            salt
        );
        address predictedTerminal = factory.predictPaymentTerminalAddress(
            address(this),
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            ICommunityGoalRegistry(address(goalRegistry)),
            COBUILD_REVNET_ID,
            salt
        );

        (address splitHookAddress, address terminalAddress) = factory.deployFor(_deployConfig(salt));

        assertEq(splitHookAddress, predictedSplitHook);
        assertEq(terminalAddress, predictedTerminal);

        CobuildSplitHook splitHook = CobuildSplitHook(payable(splitHookAddress));
        CobuildPaymentTerminal terminal = CobuildPaymentTerminal(payable(terminalAddress));

        assertEq(address(splitHook.directory()), address(directory));
        assertEq(splitHook.communityRevnetId(), COMMUNITY_REVNET_ID);
        assertEq(splitHook.communityToken(), address(communityToken));
        assertEq(splitHook.routeSetter(), terminalAddress);
        assertEq(address(terminal.DIRECTORY()), address(directory));
        assertEq(address(terminal.SPLIT_HOOK()), splitHookAddress);
        assertEq(terminal.COBUILD_TOKEN(), address(communityToken));
        assertEq(terminal.COBUILD_REVNET_ID(), COBUILD_REVNET_ID);
        assertEq(terminal.COMMUNITY_REVNET_ID(), COMMUNITY_REVNET_ID);
    }

    function test_deployFor_revertsWhenPairAlreadyExistsForSalt() public {
        bytes32 salt = keccak256("pair");

        factory.deployFor(_deployConfig(salt));

        address predictedSplitHook = factory.predictSplitHookAddress(
            address(this),
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            ICommunityGoalRegistry(address(goalRegistry)),
            COBUILD_REVNET_ID,
            salt
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminalFactory.SPLIT_HOOK_ALREADY_DEPLOYED.selector, predictedSplitHook
            )
        );
        factory.deployFor(_deployConfig(salt));
    }

    function test_predictSplitHookAddress_matchesDeterministicCloneFormula() public view {
        bytes32 salt = keccak256("pair");
        bytes32 splitHookSalt = factory.deriveSplitHookSalt(
            address(this),
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            ICommunityGoalRegistry(address(goalRegistry)),
            COBUILD_REVNET_ID,
            salt
        );

        assertEq(
            factory.predictSplitHookAddress(
                address(this),
                IJBDirectory(address(directory)),
                COMMUNITY_REVNET_ID,
                address(communityToken),
                ICommunityGoalRegistry(address(goalRegistry)),
                COBUILD_REVNET_ID,
                salt
            ),
            Clones.predictDeterministicAddress(address(splitHookImplementation), splitHookSalt, address(factory))
        );
    }

    function test_predictPaymentTerminalAddress_matchesCreate2Formula() public view {
        bytes32 salt = keccak256("pair");
        bytes32 paymentTerminalSalt = factory.derivePaymentTerminalSalt(
            address(this),
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            ICommunityGoalRegistry(address(goalRegistry)),
            COBUILD_REVNET_ID,
            salt
        );
        address predictedSplitHook = factory.predictSplitHookAddress(
            address(this),
            IJBDirectory(address(directory)),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            ICommunityGoalRegistry(address(goalRegistry)),
            COBUILD_REVNET_ID,
            salt
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CobuildPaymentTerminal).creationCode,
                abi.encode(
                    IJBDirectory(address(directory)),
                    ICobuildSplitHook(predictedSplitHook),
                    address(communityToken),
                    COBUILD_REVNET_ID,
                    COMMUNITY_REVNET_ID
                )
            )
        );

        assertEq(
            factory.predictPaymentTerminalAddress(
                address(this),
                IJBDirectory(address(directory)),
                COMMUNITY_REVNET_ID,
                address(communityToken),
                ICommunityGoalRegistry(address(goalRegistry)),
                COBUILD_REVNET_ID,
                salt
            ),
            Create2.computeAddress(paymentTerminalSalt, initCodeHash, address(factory))
        );
    }

    function _deployConfig(bytes32 salt) internal view returns (CobuildPaymentTerminalFactory.DeployConfig memory) {
        return CobuildPaymentTerminalFactory.DeployConfig({
            directory: IJBDirectory(address(directory)),
            communityRevnetId: COMMUNITY_REVNET_ID,
            communityToken: address(communityToken),
            goalRegistry: ICommunityGoalRegistry(address(goalRegistry)),
            cobuildRevnetId: COBUILD_REVNET_ID,
            salt: salt
        });
    }
}
