// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";

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
import {IJBSplitHook} from "@bananapus/core-v5/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v5/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v5/structs/JBSplit.sol";

import {CobuildSplitHookMockToken} from "test/hooks/CobuildSplitHook.t.sol";

contract CobuildCommunityTerminalFactoryTest is Test {
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
    address internal owner;

    function setUp() public {
        owner = makeAddr("owner");
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
        communityTerminal = new CobuildCommunityTerminal(
            IJBDirectory(address(directory)), IJBTerminalStore(address(store)), address(factory)
        );

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

    function test_registerCommunityFromFactory_revertsWhenCallerIsNotApprovedFactory() public {
        CobuildSplitHook splitHook = CobuildSplitHook(payable(Clones.clone(address(splitHookImplementation))));
        splitHook.initialize(
            goalRegistry.directory(),
            COMMUNITY_REVNET_ID,
            address(communityToken),
            address(communityTerminal),
            ICommunityGoalRegistry(address(goalRegistry))
        );
        controller.setLiveReservedSplit(
            COMMUNITY_REVNET_ID, IJBSplitHook(address(splitHook)), uint32(JBConstants.SPLITS_TOTAL_PERCENT)
        );

        address attacker = makeAddr("attacker");
        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.UNAUTHORIZED_FACTORY.selector, address(factory), attacker
            )
        );
        vm.prank(attacker);
        communityTerminal.registerCommunityFromFactory(
            owner,
            COMMUNITY_REVNET_ID,
            ICobuildSplitHook(address(splitHook)),
            address(communityToken),
            COMMUNITY_REVNET_ID,
            true
        );

        (, , , , bool exists) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertFalse(exists);
    }

    function test_deployFor_revertsWhenLiveReservedSplitGroupOmitsPredictedHook_andLeavesNoCloneDeployed() public {
        bytes32 salt = keccak256("hook");
        bytes32 wrongSalt = keccak256("wrong-hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        address wrongPredictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), wrongSalt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        controller.setLiveReservedSplit(
            COMMUNITY_REVNET_ID, IJBSplitHook(wrongPredictedSplitHook), uint32(JBConstants.SPLITS_TOTAL_PERCENT)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(0)
            )
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
    }

    function test_deployFor_revertsWhenLiveReservedSplitIsUnset_andLeavesNoCloneDeployed() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        controller.clearLiveReservedSplit(COMMUNITY_REVNET_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(0)
            )
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
    }

    function test_deployFor_allowsFractionalLiveReservedSplitForPredictedHook() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);
        controller.setLiveReservedSplit(COMMUNITY_REVNET_ID, IJBSplitHook(predictedSplitHook), 999_999_999);

        vm.prank(owner);
        address splitHookAddress = factory.deployFor(config);

        assertEq(splitHookAddress, predictedSplitHook);
        (, , , , bool exists) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertTrue(exists);
    }

    function test_deployFor_allowsMixedReservedSplitGroupWhenPredictedHookAppearsOnce() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        address otherPredictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), keccak256("hook-two"));
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);

        IJBSplitHook[] memory hooks = new IJBSplitHook[](2);
        hooks[0] = IJBSplitHook(predictedSplitHook);
        hooks[1] = IJBSplitHook(otherPredictedSplitHook);

        uint32[] memory percents = new uint32[](2);
        percents[0] = 500_000_000;
        percents[1] = 500_000_000;

        controller.setLiveReservedSplits(COMMUNITY_REVNET_ID, hooks, percents);

        vm.prank(owner);
        address splitHookAddress = factory.deployFor(config);

        assertEq(splitHookAddress, predictedSplitHook);
        (, , , , bool exists) = communityTerminal.communityConfigOf(COMMUNITY_REVNET_ID);
        assertTrue(exists);
    }

    function test_deployFor_revertsWhenLiveReservedSplitGroupContainsMultipleMatchingPredictedHooks() public {
        bytes32 salt = keccak256("hook");
        address predictedSplitHook =
            factory.predictSplitHookAddress(owner, ICommunityGoalRegistry(address(goalRegistry)), address(communityTerminal), salt);
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(salt);

        IJBSplitHook[] memory hooks = new IJBSplitHook[](2);
        hooks[0] = IJBSplitHook(predictedSplitHook);
        hooks[1] = IJBSplitHook(predictedSplitHook);

        uint32[] memory percents = new uint32[](2);
        percents[0] = 400_000_000;
        percents[1] = 600_000_000;

        controller.setLiveReservedSplits(COMMUNITY_REVNET_ID, hooks, percents);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_RESERVED_SPLIT_COUNT.selector, uint256(1), uint256(2)
            )
        );
        vm.prank(owner);
        factory.deployFor(config);

        assertEq(predictedSplitHook.code.length, 0);
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

    function test_deployFor_revertsWhenDirectNativePaymentSourceDoesNotMatchCommunity() public {
        CobuildCommunityTerminalFactory.DeployConfig memory config = _deployConfig(keccak256("hook"));
        config.paymentSourceRevnetId = COMMUNITY_REVNET_ID + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildCommunityTerminal.INVALID_DIRECT_NATIVE_PAYMENT_SOURCE.selector,
                COMMUNITY_REVNET_ID,
                COMMUNITY_REVNET_ID + 1
            )
        );
        vm.prank(owner);
        factory.deployFor(config);
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

    function test_deployFor_allowsContractCommunityProjectOwnerWithoutExtraSignature() public {
        CobuildCommunityTerminalFactoryContractOwner contractOwner = new CobuildCommunityTerminalFactoryContractOwner();
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
        controller.setLiveReservedSplit(
            COMMUNITY_REVNET_ID, IJBSplitHook(predictedSplitHook), uint32(JBConstants.SPLITS_TOTAL_PERCENT)
        );

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
        controller.setLiveReservedSplit(
            COMMUNITY_REVNET_ID, IJBSplitHook(predictedSplitHook), uint32(JBConstants.SPLITS_TOTAL_PERCENT)
        );

        return CobuildCommunityTerminalFactory.DeployConfig({
            goalRegistry: ICommunityGoalRegistry(address(goalRegistry)),
            routeSetter: address(communityTerminal),
            salt: salt,
            paymentToken: address(communityToken),
            paymentSourceRevnetId: COMMUNITY_REVNET_ID,
            directNativeAllowed: true
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
    uint48 internal constant CURRENT_RULESET_ID = 1;

    CobuildCommunityTerminalFactoryTokensMock internal immutable _tokens;
    CobuildCommunityTerminalFactorySplitsMock internal immutable _splits;

    constructor(CobuildCommunityTerminalFactoryTokensMock tokens_) {
        _tokens = tokens_;
        _splits = new CobuildCommunityTerminalFactorySplitsMock();
    }

    function TOKENS() external view returns (CobuildCommunityTerminalFactoryTokensMock) {
        return _tokens;
    }

    function SPLITS() external view returns (CobuildCommunityTerminalFactorySplitsMock) {
        return _splits;
    }

    function currentRulesetOf(uint256) external view returns (JBRuleset memory ruleset, JBRulesetMetadata memory) {
        ruleset.id = CURRENT_RULESET_ID;
        ruleset.cycleNumber = uint48(CURRENT_RULESET_ID);
        ruleset.start = uint48(block.timestamp);
    }

    function setLiveReservedSplit(uint256 projectId, IJBSplitHook hook, uint32 percent) external {
        _splits.setReservedSplit(projectId, uint256(CURRENT_RULESET_ID), hook, percent);
    }

    function setLiveReservedSplits(uint256 projectId, IJBSplitHook[] memory hooks, uint32[] memory percents) external {
        _splits.setReservedSplits(projectId, uint256(CURRENT_RULESET_ID), hooks, percents);
    }

    function clearLiveReservedSplit(uint256 projectId) external {
        _splits.clearReservedSplits(projectId, uint256(CURRENT_RULESET_ID));
    }
}

contract CobuildCommunityTerminalFactorySplitsMock {
    uint256 internal constant FALLBACK_RULESET_ID = 0;
    uint256 internal constant RESERVED_TOKENS_GROUP_ID = 1;

    mapping(uint256 projectId => mapping(uint256 rulesetId => JBSplit[])) internal _reservedSplitsOf;

    function setReservedSplit(uint256 projectId, uint256 rulesetId, IJBSplitHook hook, uint32 percent) external {
        IJBSplitHook[] memory hooks = new IJBSplitHook[](1);
        hooks[0] = hook;

        uint32[] memory percents = new uint32[](1);
        percents[0] = percent;

        this.setReservedSplits(projectId, rulesetId, hooks, percents);
    }

    function setReservedSplits(uint256 projectId, uint256 rulesetId, IJBSplitHook[] memory hooks, uint32[] memory percents)
        external
    {
        require(hooks.length == percents.length, "LENGTH_MISMATCH");

        delete _reservedSplitsOf[projectId][rulesetId];

        for (uint256 i; i < hooks.length; i++) {
            _reservedSplitsOf[projectId][rulesetId].push(
                JBSplit({
                    percent: percents[i],
                    projectId: 0,
                    beneficiary: payable(address(0)),
                    preferAddToBalance: false,
                    lockedUntil: 0,
                    hook: hooks[i]
                })
            );
        }
    }

    function clearReservedSplits(uint256 projectId, uint256 rulesetId) external {
        delete _reservedSplitsOf[projectId][rulesetId];
    }

    function splitsOf(uint256 projectId, uint256 rulesetId, uint256 groupId)
        external
        view
        returns (JBSplit[] memory splits)
    {
        if (groupId != RESERVED_TOKENS_GROUP_ID) return new JBSplit[](0);

        splits = _copyReservedSplits(projectId, rulesetId);

        if (splits.length == 0 && rulesetId != FALLBACK_RULESET_ID) {
            splits = _copyReservedSplits(projectId, FALLBACK_RULESET_ID);
        }
    }

    function _copyReservedSplits(uint256 projectId, uint256 rulesetId) internal view returns (JBSplit[] memory splits) {
        JBSplit[] storage storedSplits = _reservedSplitsOf[projectId][rulesetId];
        uint256 splitCount = storedSplits.length;
        splits = new JBSplit[](splitCount);

        for (uint256 i; i < splitCount; i++) {
            splits[i] = storedSplits[i];
        }
    }
}

contract CobuildCommunityTerminalFactoryContractOwner {}
