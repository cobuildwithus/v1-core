// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CobuildSplitHook} from "src/hooks/CobuildSplitHook.sol";
import {GoalDeploymentRegistry} from "src/goals/GoalDeploymentRegistry.sol";
import {IGoalDeploymentRegistry} from "src/interfaces/IGoalDeploymentRegistry.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";
import {CobuildCommunityTerminal} from "src/juicebox/CobuildCommunityTerminal.sol";
import {CobuildCommunityTerminalFactory} from "src/juicebox/CobuildCommunityTerminalFactory.sol";
import {ICommunityGoalRegistry} from "src/tcr/interfaces/ICommunityGoalRegistry.sol";
import {MockTerminalStore} from "test/juicebox/helpers/MockTerminalStore.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

import {CobuildSplitHookMockToken} from "test/hooks/CobuildSplitHook.t.sol";

contract CobuildCommunityTerminalFactoryTest is Test {
    using MessageHashUtils for bytes32;

    uint256 internal constant COMMUNITY_REVNET_ID = 777;

    CobuildSplitHook internal splitHookImplementation;
    CobuildCommunityTerminalFactory internal factory;
    CobuildCommunityTerminalFactoryDirectoryMock internal directory;
    CobuildCommunityTerminalFactoryTokensMock internal tokens;
    CobuildCommunityTerminalFactoryControllerMock internal controller;
    CobuildSplitHookMockToken internal communityToken;
    GoalDeploymentRegistry internal goalDeploymentRegistry;
    CobuildCommunityTerminalFactoryGoalRegistryMock internal goalRegistry;
    MockTerminalStore internal store;
    CobuildCommunityTerminal internal communityTerminal;
    uint256 internal ownerPrivateKey;
    address internal owner;
    uint256 internal registrationDeadline;

    function setUp() public {
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        splitHookImplementation = new CobuildSplitHook();
        factory = new CobuildCommunityTerminalFactory(address(splitHookImplementation));
        directory = new CobuildCommunityTerminalFactoryDirectoryMock();
        tokens = new CobuildCommunityTerminalFactoryTokensMock();
        controller = new CobuildCommunityTerminalFactoryControllerMock(tokens);
        communityToken = new CobuildSplitHookMockToken("Cobuild", "COB");
        goalDeploymentRegistry = new GoalDeploymentRegistry(address(this), address(this));
        goalRegistry = new CobuildCommunityTerminalFactoryGoalRegistryMock(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );
        store = new MockTerminalStore(IJBDirectory(address(directory)));
        communityTerminal = new CobuildCommunityTerminal(IJBDirectory(address(directory)), IJBTerminalStore(address(store)));
        registrationDeadline = block.timestamp + 1 days;

        tokens.setTokenOf(COMMUNITY_REVNET_ID, address(communityToken));
        directory.setController(COMMUNITY_REVNET_ID, IJBController(address(controller)));
        directory.setProjectOwner(COMMUNITY_REVNET_ID, owner);
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(communityTerminal)));
        directory.setPrimaryTerminal(COMMUNITY_REVNET_ID, address(communityToken), IJBTerminal(address(communityTerminal)));
    }

    function test_deployFor_deploysPredictedHook_initializesIt_andRegistersCanonicalTerminal() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);

        vm.prank(owner);
        address splitHookAddress = factory.deployFor(config);

        assertEq(splitHookAddress, predictedSplitHook);

        CobuildSplitHook splitHook = CobuildSplitHook(payable(splitHookAddress));
        assertEq(address(splitHook.directory()), address(directory));
        assertEq(splitHook.communityRevnetId(), COMMUNITY_REVNET_ID);
        assertEq(splitHook.communityToken(), address(communityToken));
        assertEq(splitHook.routeSetter(), address(communityTerminal));
        assertEq(splitHook.goalRegistry(), address(goalRegistry));

        (ICobuildSplitHook registeredHook, address paymentToken, uint256 paymentSourceRevnetId, bool directNativeAllowed, bool exists)
        = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertEq(address(registeredHook), splitHookAddress);
        assertEq(paymentToken, address(communityToken));
        assertEq(paymentSourceRevnetId, COMMUNITY_REVNET_ID);
        assertTrue(directNativeAllowed);
        assertTrue(exists);
    }

    function test_deployFor_revertsWhenCallerIsNotCommunityProjectOwner() public {
        address notOwner = makeAddr("not-owner");
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));

        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminalFactory.UNAUTHORIZED.selector, owner, notOwner)
        );
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenSplitHookAlreadyExistsForSalt() public {
        bytes32 salt = keccak256("hook");
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        vm.prank(owner);
        factory.deployFor(config);

        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminalFactory.SPLIT_HOOK_ALREADY_DEPLOYED.selector, predictedSplitHook)
        );
        vm.prank(owner);
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenRouteSetterHasNoCode() public {
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));
        config.routeSetter = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminalFactory.ROUTE_SETTER_HAS_NO_CODE.selector, address(0xBEEF))
        );
        vm.prank(owner);
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenRegistrationSignatureMissing() public {
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));
        config.registrationSignature = bytes("");

        vm.expectRevert(CobuildCommunityTerminalFactory.REGISTRATION_SIGNATURE_REQUIRED.selector);
        vm.prank(owner);
        factory.deployFor(config);
    }

    function test_deployFor_revertsWhenRegistrationSignatureDoesNotMatchOwner_andLeavesNoCloneDeployed() public {
        uint256 wrongOwnerPrivateKey = 0xB0B;
        address wrongOwner = vm.addr(wrongOwnerPrivateKey);
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        bytes32 digest = communityTerminal.registrationDigestOf(
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
            abi.encodeWithSelector(CobuildCommunityTerminal.INVALID_REGISTRATION_SIGNATURE.selector, owner, wrongOwner)
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
    }

    function test_deployFor_revertsWhenRegistrationDeadlineExpired_andLeavesNoCloneDeployed() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);

        vm.warp(registrationDeadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.REGISTRATION_DEADLINE_EXPIRED.selector, registrationDeadline, block.timestamp
            )
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
    }

    function test_deployFor_revertsWhenCommunityAlreadyRegistered_andLeavesNoSecondCloneDeployed() public {
        CobuildCommunityTerminalFactory.DeployConfig memory firstConfig = _deployConfig(keccak256("hook-one"));
        vm.prank(owner);
        factory.deployFor(firstConfig);

        bytes32 secondSalt = keccak256("hook-two");
        address secondPredictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), secondSalt);
        CobuildCommunityTerminalFactory.DeployConfig memory secondConfig = _deployConfig(secondSalt);

        vm.expectRevert(
            abi.encodeWithSelector(CobuildCommunityTerminal.COMMUNITY_ALREADY_REGISTERED.selector, COMMUNITY_REVNET_ID)
        );
        vm.prank(owner);
        factory.deployFor(secondConfig);

        assertEq(secondPredictedSplitHook.code.length, 0);
    }

    function test_deployFor_allowsEip1271CommunityProjectOwnerSignature() public {
        CobuildCommunityTerminalFactoryEip1271Owner contractOwner = new CobuildCommunityTerminalFactoryEip1271Owner();
        goalRegistry = new CobuildCommunityTerminalFactoryGoalRegistryMock(
            IJBDirectory(address(directory)),
            IGoalDeploymentRegistry(address(goalDeploymentRegistry)),
            COMMUNITY_REVNET_ID,
            address(communityToken)
        );
        directory.setProjectOwner(COMMUNITY_REVNET_ID, address(contractOwner));

        bytes32 salt = keccak256("hook-eip1271");
        address predictedSplitHook =
            factory.predictSplitHookAddress(address(contractOwner), ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        bytes32 digest = communityTerminal.registrationDigestOf(
            address(contractOwner),
            COMMUNITY_REVNET_ID,
            predictedSplitHook,
            address(communityToken),
            COMMUNITY_REVNET_ID,
            true,
            registrationDeadline
        );
        config.registrationSignature = contractOwner.signatureFor(digest.toEthSignedMessageHash());

        vm.prank(address(contractOwner));
        address splitHookAddress = factory.deployFor(config);

        assertEq(splitHookAddress, predictedSplitHook);
        (, , , , bool exists) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertTrue(exists);
    }

    function test_predictSplitHookAddress_matchesDeterministicCloneFormula() public view {
        bytes32 salt = keccak256("hook");
        bytes32 splitHookSalt =
            factory.deriveSplitHookSalt(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);

        assertEq(
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt),
            Clones.predictDeterministicAddress(address(splitHookImplementation), splitHookSalt, address(factory))
        );
    }

    function _deployConfig(bytes32 salt) internal returns (CobuildCommunityTerminalFactory.DeployConfig memory) {
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        bytes32 digest = communityTerminal.registrationDigestOf(
            owner,
            COMMUNITY_REVNET_ID,
            predictedSplitHook,
            address(communityToken),
            COMMUNITY_REVNET_ID,
            true,
            registrationDeadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest.toEthSignedMessageHash());

        return CobuildCommunityTerminalFactory.DeployConfig({
            goalRegistry: ICommunityGoalRegistry(address(goalRegistry)),
            routeSetter: address(communityTerminal),
            salt: salt,
            paymentToken: address(communityToken),
            paymentSourceRevnetId: COMMUNITY_REVNET_ID,
            directNativeAllowed: true,
            registrationDeadline: registrationDeadline,
            registrationSignature: abi.encodePacked(r, s, v)
        });
    }
}

contract CobuildCommunityTerminalFactoryGoalRegistryMock {
    IJBDirectory public directory;
    IGoalDeploymentRegistry public goalDeploymentRegistry;
    uint256 public communityRevnetId;
    address public communityToken;

    constructor(
        IJBDirectory directory_,
        IGoalDeploymentRegistry goalDeploymentRegistry_,
        uint256 communityRevnetId_,
        address communityToken_
    ) {
        directory = directory_;
        goalDeploymentRegistry = goalDeploymentRegistry_;
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
    }
}

contract CobuildCommunityTerminalFactoryDirectoryMock {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;
    mapping(uint256 => IJBController) internal _controllerOf;
    CobuildCommunityTerminalFactoryProjectsMock internal _projects = new CobuildCommunityTerminalFactoryProjectsMock();

    function PROJECTS() external view returns (CobuildCommunityTerminalFactoryProjectsMock) {
        return _projects;
    }

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

    function setProjectOwner(uint256 projectId, address owner) external {
        _projects.setOwner(projectId, owner);
    }
}

contract CobuildCommunityTerminalFactoryProjectsMock {
    mapping(uint256 => address) internal _ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }
}

contract CobuildCommunityTerminalFactoryTokensMock {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract CobuildCommunityTerminalFactoryControllerMock {
    CobuildCommunityTerminalFactoryTokensMock internal immutable _tokens;

    constructor(CobuildCommunityTerminalFactoryTokensMock tokens_) {
        _tokens = tokens_;
    }

    function TOKENS() external view returns (CobuildCommunityTerminalFactoryTokensMock) {
        return _tokens;
    }
}

contract CobuildCommunityTerminalFactoryEip1271Owner {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    bytes32 internal _approvedHash;
    bytes internal _approvedSignature;

    function signatureFor(bytes32 hash) external returns (bytes memory signature) {
        _approvedHash = hash;
        _approvedSignature = abi.encode(hash, address(this));
        return _approvedSignature;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (hash == _approvedHash && keccak256(signature) == keccak256(_approvedSignature)) {
            return MAGIC_VALUE;
        }

        return bytes4(0);
    }
}
