// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { CobuildSplitHook } from "src/hooks/CobuildSplitHook.sol";
import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";
import { CobuildCommunityTerminal } from "src/juicebox/CobuildCommunityTerminal.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

/// @notice Deterministic deployer for community-scoped split hooks plus same-transaction registration on the shared terminal.
contract CobuildCommunityTerminalFactory {
    bytes32 internal constant SPLIT_HOOK_SALT_DOMAIN = keccak256("CobuildCommunityTerminalFactory.SplitHook");

    error ADDRESS_ZERO();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error ROUTE_SETTER_HAS_NO_CODE(address routeSetter);
    error SPLIT_HOOK_ALREADY_DEPLOYED(address splitHook);
    error UNAUTHORIZED(address expected, address actual);

    struct DeployConfig {
        ICommunityGoalRegistry goalRegistry;
        address routeSetter;
        bytes32 salt;
        address paymentToken;
        uint256 paymentSourceRevnetId;
        bool directNativeAllowed;
    }

    event CommunitySplitHookDeployed(
        address indexed sender,
        address indexed splitHook,
        address indexed routeSetter,
        address directory,
        uint256 communityRevnetId,
        address communityToken,
        address goalRegistry,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed,
        bytes32 salt
    );

    address public immutable splitHookImplementation;

    constructor(address splitHookImplementation_) {
        if (splitHookImplementation_ == address(0)) revert ADDRESS_ZERO();
        if (splitHookImplementation_.code.length == 0) {
            revert IMPLEMENTATION_HAS_NO_CODE(splitHookImplementation_);
        }

        splitHookImplementation = splitHookImplementation_;
    }

    /// @notice Deploy a deterministic community split hook and register it on the shared terminal.
    /// @dev Deployment orchestration must atomically update the community revnet's live reserved-token split to the
    /// predicted hook address and call this function, otherwise permissionless reserved-token flushes can mint into the
    /// predicted address before the clone exists.
    function deployFor(DeployConfig calldata config) external returns (address splitHook) {
        ICommunityGoalRegistry goalRegistry = config.goalRegistry;
        address routeSetter = config.routeSetter;
        address goalRegistryAddress = address(goalRegistry);
        if (goalRegistryAddress == address(0)) revert ADDRESS_ZERO();
        if (goalRegistryAddress.code.length == 0) revert IMPLEMENTATION_HAS_NO_CODE(goalRegistryAddress);
        if (routeSetter == address(0)) revert ADDRESS_ZERO();
        if (routeSetter.code.length == 0) revert ROUTE_SETTER_HAS_NO_CODE(routeSetter);

        uint256 communityRevnetId = goalRegistry.communityRevnetId();
        address projectOwner = goalRegistry.directory().PROJECTS().ownerOf(communityRevnetId);
        if (msg.sender != projectOwner) revert UNAUTHORIZED(projectOwner, msg.sender);
        address communityToken = goalRegistry.communityToken();
        CobuildCommunityTerminal sharedTerminal = CobuildCommunityTerminal(payable(routeSetter));

        bytes32 splitHookSalt = deriveSplitHookSalt(msg.sender, goalRegistry, routeSetter, config.salt);
        splitHook = Clones.predictDeterministicAddress(splitHookImplementation, splitHookSalt, address(this));
        if (splitHook.code.length != 0) revert SPLIT_HOOK_ALREADY_DEPLOYED(splitHook);

        splitHook = Clones.cloneDeterministic(splitHookImplementation, splitHookSalt);

        CobuildSplitHook(payable(splitHook)).initialize(
            goalRegistry.directory(),
            communityRevnetId,
            communityToken,
            routeSetter,
            goalRegistry
        );

        sharedTerminal.registerCommunityFromFactory(
            msg.sender,
            communityRevnetId,
            ICobuildSplitHook(splitHook),
            config.paymentToken,
            config.paymentSourceRevnetId,
            config.directNativeAllowed
        );

        emit CommunitySplitHookDeployed(
            msg.sender,
            splitHook,
            routeSetter,
            address(goalRegistry.directory()),
            communityRevnetId,
            communityToken,
            goalRegistryAddress,
            config.paymentToken,
            config.paymentSourceRevnetId,
            config.directNativeAllowed,
            config.salt
        );
    }

    function deriveSplitHookSalt(
        address sender,
        ICommunityGoalRegistry goalRegistry,
        address routeSetter,
        bytes32 salt
    ) public pure returns (bytes32 derivedSalt) {
        derivedSalt = keccak256(abi.encode(SPLIT_HOOK_SALT_DOMAIN, sender, address(goalRegistry), routeSetter, salt));
    }

    function predictSplitHookAddress(
        address sender,
        ICommunityGoalRegistry goalRegistry,
        address routeSetter,
        bytes32 salt
    ) public view returns (address predicted) {
        predicted = Clones.predictDeterministicAddress(
            splitHookImplementation,
            deriveSplitHookSalt(sender, goalRegistry, routeSetter, salt),
            address(this)
        );
    }
}
