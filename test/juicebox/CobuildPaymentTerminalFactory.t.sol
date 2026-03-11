// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {CobuildPaymentTerminal} from "src/juicebox/CobuildPaymentTerminal.sol";
import {CobuildPaymentTerminalFactory} from "src/juicebox/CobuildPaymentTerminalFactory.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

import {CobuildSplitHookMockToken} from "test/hooks/CobuildSplitHook.t.sol";

contract CobuildPaymentTerminalFactoryTest is Test {
    using MessageHashUtils for bytes32;

    uint256 internal constant COMMUNITY_REVNET_ID = 777;

    CobuildSplitHook internal splitHookImplementation;
    CobuildPaymentTerminalFactory internal factory;
    CobuildPaymentTerminalFactoryDirectoryMock internal directory;
    CobuildPaymentTerminalFactoryTokensMock internal tokens;
    CobuildPaymentTerminalFactoryControllerMock internal controller;
    CobuildSplitHookMockToken internal communityToken;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildPaymentTerminalFactoryGoalRegistryMock internal goalRegistry;
    CobuildPaymentTerminal internal paymentTerminal;
    uint256 internal ownerPrivateKey;
    address internal owner;
    uint256 internal registrationDeadline;

    function setUp() public {
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        splitHookImplementation = new CobuildSplitHook();
        factory = new CobuildPaymentTerminalFactory(address(splitHookImplementation));
        directory = new CobuildPaymentTerminalFactoryDirectoryMock();
        tokens = new CobuildPaymentTerminalFactoryTokensMock();
        controller = new CobuildPaymentTerminalFactoryControllerMock(tokens);
        communityToken = new CobuildSplitHookMockToken("Cobuild", "COB");
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        goalRegistry = new CobuildPaymentTerminalFactoryGoalRegistryMock(
            owner,
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );
        paymentTerminal = new CobuildPaymentTerminal(IJBDirectory(address(directory)));
        registrationDeadline = block.timestamp + 1 days;

        tokens.setTokenOf(COMMUNITY_REVNET_ID, address(communityToken));
        directory.setController(COMMUNITY_REVNET_ID, IJBController(address(controller)));
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(paymentTerminal)));
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, address(communityToken), IJBTerminal(address(paymentTerminal)));
    }

    function test_deployFor_deploysPredictedHook_initializesIt_andRegistersCanonicalTerminal() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt);
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(salt);

        vm.prank(owner);
        address splitHookAddress = factory.deployFor(config);

        assertEq(splitHookAddress, predictedSplitHook);

        CobuildSplitHook splitHook = CobuildSplitHook(payable(splitHookAddress));
        assertEq(address(splitHook.directory()), address(directory));
        assertEq(splitHook.communityRevnetId(), COMMUNITY_REVNET_ID);
        assertEq(splitHook.communityToken(), address(communityToken));
        assertEq(splitHook.routeSetter(), address(paymentTerminal));
        assertEq(splitHook.goalRegistry(), address(goalRegistry));

        (ICobuildSplitHook registeredHook, address paymentToken, uint256 paymentSourceRevnetId, bool directNativeAllowed, bool exists)
        = paymentTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertEq(address(registeredHook), splitHookAddress);
        assertEq(paymentToken, address(communityToken));
        assertEq(paymentSourceRevnetId, COMMUNITY_REVNET_ID);
        assertTrue(directNativeAllowed);
        assertTrue(exists);
    }

    function test_deployFor_revertsWhenCallerIsNotGoalRegistryOwner() public {
        address notOwner = makeAddr("not-owner");
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));

        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminalFactory.UNAUTHORIZED.selector, owner, notOwner)
        );
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenSplitHookAlreadyExistsForSalt() public {
        bytes32 salt = keccak256("hook");
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        vm.prank(owner);
        factory.deployFor(config);

        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminalFactory.SPLIT_HOOK_ALREADY_DEPLOYED.selector, predictedSplitHook)
        );
        vm.prank(owner);
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenRouteSetterHasNoCode() public {
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));
        config.routeSetter = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminalFactory.ROUTE_SETTER_HAS_NO_CODE.selector, address(0xBEEF))
        );
        vm.prank(owner);
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenRegistrationSignatureMissing() public {
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));
        config.registrationSignature = bytes("");

        vm.expectRevert(CobuildPaymentTerminalFactory.REGISTRATION_SIGNATURE_REQUIRED.selector);
        vm.prank(owner);
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenRegistrationSignatureDoesNotMatchOwner_andLeavesNoCloneDeployed() public {
        uint256 wrongOwnerPrivateKey = 0xB0B;
        address wrongOwner = vm.addr(wrongOwnerPrivateKey);
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt);
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        bytes32 digest = paymentTerminal.registrationDigestOf(
            owner,
            COMMUNITY_REVNET_ID,
            predictedSplitHook,
            address(communityToken),
            COMMUNITY_REVNET_ID,
            true,
            registrationDeadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongOwnerPrivateKey, digest.toEthSignedMessageHash());
        config.registrationSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.INVALID_REGISTRATION_SIGNATURE.selector, owner, wrongOwner)
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
    }

    function test_deployFor_revertsWhenRegistrationDeadlineExpired_andLeavesNoCloneDeployed() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt);
        CobuildPaymentTerminalFactory.DeployConfig memory config = _deployConfig(salt);

        vm.warp(registrationDeadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.REGISTRATION_DEADLINE_EXPIRED.selector, registrationDeadline, block.timestamp
            )
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
    }

    function test_deployFor_revertsWhenCommunityAlreadyRegistered_andLeavesNoSecondCloneDeployed() public {
        CobuildPaymentTerminalFactory.DeployConfig memory firstConfig = _deployConfig(keccak256("hook-one"));
        vm.prank(owner);
        factory.deployFor(firstConfig);

        bytes32 secondSalt = keccak256("hook-two");
        address secondPredictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), secondSalt);
        CobuildPaymentTerminalFactory.DeployConfig memory secondConfig = _deployConfig(secondSalt);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.COMMUNITY_ALREADY_REGISTERED.selector, COMMUNITY_REVNET_ID)
        );
        vm.prank(owner);
        factory.deployFor(secondConfig);

        assertEq(secondPredictedSplitHook.code.length, 0);
    }

    function test_predictSplitHookAddress_matchesDeterministicCloneFormula() public view {
        bytes32 salt = keccak256("hook");
        bytes32 splitHookSalt =
            factory.deriveSplitHookSalt(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt);

        assertEq(
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt),
            Clones.predictDeterministicAddress(address(splitHookImplementation), splitHookSalt, address(factory))
        );
    }

    function _deployConfig(bytes32 salt) internal returns (CobuildPaymentTerminalFactory.DeployConfig memory) {
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(paymentTerminal), salt);
        bytes32 digest = paymentTerminal.registrationDigestOf(
            owner,
            COMMUNITY_REVNET_ID,
            predictedSplitHook,
            address(communityToken),
            COMMUNITY_REVNET_ID,
            true,
            registrationDeadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest.toEthSignedMessageHash());

        return CobuildPaymentTerminalFactory.DeployConfig({
            goalRegistry: ICommunityGoalRegistry(address(goalRegistry)),
            routeSetter: address(paymentTerminal),
            salt: salt,
            paymentToken: address(communityToken),
            paymentSourceRevnetId: COMMUNITY_REVNET_ID,
            directNativeAllowed: true,
            registrationDeadline: registrationDeadline,
            registrationSignature: abi.encodePacked(r, s, v)
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

contract CobuildPaymentTerminalFactoryDirectoryMock {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;
    mapping(uint256 => IJBController) internal _controllerOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }

    function setController(uint256 projectId, IJBController controller_) external {
        _controllerOf[projectId] = controller_;
    }

    function controllerOf(uint256 projectId) external view returns (IJBController) {
        return _controllerOf[projectId];
    }
}

contract CobuildPaymentTerminalFactoryTokensMock {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract CobuildPaymentTerminalFactoryControllerMock {
    CobuildPaymentTerminalFactoryTokensMock internal immutable _tokens;

    constructor(CobuildPaymentTerminalFactoryTokensMock tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (CobuildPaymentTerminalFactoryTokensMock) {
        return _tokens;
    }
}
