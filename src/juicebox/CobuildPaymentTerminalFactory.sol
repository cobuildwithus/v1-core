// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { CobuildSplitHook } from "src/hooks/CobuildSplitHook.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

/// @notice Deterministic deployer for community-scoped split hooks that point at a shared payment terminal.
contract CobuildPaymentTerminalFactory {
    bytes32 internal constant SPLIT_HOOK_SALT_DOMAIN = keccak256("CobuildPaymentTerminalFactory.SplitHook");

    error ADDRESS_ZERO();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error ROUTE_SETTER_HAS_NO_CODE(address routeSetter);
    error SPLIT_HOOK_ALREADY_DEPLOYED(address splitHook);
    error UNAUTHORIZED(address expected, address actual);

    struct DeployConfig {
        ICommunityGoalRegistry goalRegistry;
        address routeSetter;
        bytes32 salt;
    }

    event CommunitySplitHookDeployed(
        address indexed sender,
        address indexed splitHook,
        address indexed routeSetter,
        address directory,
        uint256 communityRevnetId,
        address communityToken,
        address goalRegistry,
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

    function deployFor(DeployConfig calldata config) external returns (address splitHook) {
        address goalRegistryAddress = address(config.goalRegistry);
        if (goalRegistryAddress == address(0)) revert ADDRESS_ZERO();
        if (goalRegistryAddress.code.length == 0) revert IMPLEMENTATION_HAS_NO_CODE(goalRegistryAddress);
        if (config.routeSetter == address(0)) revert ADDRESS_ZERO();
        if (config.routeSetter.code.length == 0) revert ROUTE_SETTER_HAS_NO_CODE(config.routeSetter);

        address registryOwner = config.goalRegistry.owner();
        if (msg.sender != registryOwner) revert UNAUTHORIZED(registryOwner, msg.sender);

        bytes32 splitHookSalt = deriveSplitHookSalt(msg.sender, config.goalRegistry, config.routeSetter, config.salt);
        splitHook = Clones.predictDeterministicAddress(splitHookImplementation, splitHookSalt, address(this));
        if (splitHook.code.length != 0) revert SPLIT_HOOK_ALREADY_DEPLOYED(splitHook);

        splitHook = Clones.cloneDeterministic(splitHookImplementation, splitHookSalt);

        CobuildSplitHook(payable(splitHook)).initialize(
            config.goalRegistry.directory(),
            config.goalRegistry.communityRevnetId(),
            config.goalRegistry.communityToken(),
            config.routeSetter,
            config.goalRegistry
        );

        emit CommunitySplitHookDeployed(
            msg.sender,
            splitHook,
            config.routeSetter,
            address(config.goalRegistry.directory()),
            config.goalRegistry.communityRevnetId(),
            config.goalRegistry.communityToken(),
            goalRegistryAddress,
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
