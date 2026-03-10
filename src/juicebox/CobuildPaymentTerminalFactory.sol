// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";

import { CobuildSplitHook } from "src/hooks/CobuildSplitHook.sol";
import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

import { CobuildPaymentTerminal } from "./CobuildPaymentTerminal.sol";

contract CobuildPaymentTerminalFactory {
    bytes32 internal constant SPLIT_HOOK_SALT_DOMAIN = keccak256("CobuildPaymentTerminalFactory.SplitHook");
    bytes32 internal constant PAYMENT_TERMINAL_SALT_DOMAIN = keccak256("CobuildPaymentTerminalFactory.PaymentTerminal");

    error ADDRESS_ZERO();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);
    error SPLIT_HOOK_ALREADY_DEPLOYED(address splitHook);
    error PAYMENT_TERMINAL_ALREADY_DEPLOYED(address paymentTerminal);
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_COMMUNITY_TOKEN(address expectedToken, address actualToken);
    error INVALID_ROUTE_SETTER(address expectedRouteSetter, address actualRouteSetter);

    struct DeployConfig {
        IJBDirectory directory;
        uint256 communityRevnetId;
        address communityToken;
        ICommunityGoalRegistry goalRegistry;
        uint256 cobuildRevnetId;
        bytes32 salt;
    }

    event CommunityRoutingPairDeployed(
        address indexed sender,
        address indexed splitHook,
        address indexed paymentTerminal,
        address directory,
        uint256 communityRevnetId,
        address communityToken,
        address goalRegistry,
        uint256 cobuildRevnetId,
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

    function deployFor(DeployConfig calldata config) external returns (address splitHook, address paymentTerminal) {
        if (address(config.directory) == address(0)) revert ADDRESS_ZERO();
        if (config.communityToken == address(0)) revert ADDRESS_ZERO();
        if (address(config.goalRegistry) == address(0)) revert ADDRESS_ZERO();
        if (config.communityRevnetId == 0 || config.cobuildRevnetId == 0) revert ADDRESS_ZERO();

        bytes32 splitHookSalt = deriveSplitHookSalt(
            msg.sender,
            config.directory,
            config.communityRevnetId,
            config.communityToken,
            config.goalRegistry,
            config.cobuildRevnetId,
            config.salt
        );
        bytes32 paymentTerminalSalt = derivePaymentTerminalSalt(
            msg.sender,
            config.directory,
            config.communityRevnetId,
            config.communityToken,
            config.goalRegistry,
            config.cobuildRevnetId,
            config.salt
        );
        splitHook = Clones.predictDeterministicAddress(splitHookImplementation, splitHookSalt, address(this));
        if (splitHook.code.length != 0) revert SPLIT_HOOK_ALREADY_DEPLOYED(splitHook);

        paymentTerminal = _predictPaymentTerminalAddress(
            splitHook,
            config.directory,
            config.communityToken,
            config.cobuildRevnetId,
            config.communityRevnetId,
            paymentTerminalSalt
        );
        if (paymentTerminal.code.length != 0) revert PAYMENT_TERMINAL_ALREADY_DEPLOYED(paymentTerminal);

        splitHook = Clones.cloneDeterministic(splitHookImplementation, splitHookSalt);
        paymentTerminal = address(
            new CobuildPaymentTerminal{ salt: paymentTerminalSalt }(
                config.directory,
                ICobuildSplitHook(splitHook),
                config.communityToken,
                config.cobuildRevnetId,
                config.communityRevnetId
            )
        );

        CobuildSplitHook(payable(splitHook)).initialize(
            config.directory,
            config.communityRevnetId,
            config.communityToken,
            paymentTerminal,
            config.goalRegistry
        );

        _requirePairConfiguration(
            ICobuildSplitHook(splitHook),
            paymentTerminal,
            config.communityRevnetId,
            config.communityToken
        );

        emit CommunityRoutingPairDeployed(
            msg.sender,
            splitHook,
            paymentTerminal,
            address(config.directory),
            config.communityRevnetId,
            config.communityToken,
            address(config.goalRegistry),
            config.cobuildRevnetId,
            config.salt
        );
    }

    function deriveSplitHookSalt(
        address sender,
        IJBDirectory directory,
        uint256 communityRevnetId,
        address communityToken,
        ICommunityGoalRegistry goalRegistry,
        uint256 cobuildRevnetId,
        bytes32 salt
    ) public pure returns (bytes32 derivedSalt) {
        derivedSalt = keccak256(
            abi.encode(
                SPLIT_HOOK_SALT_DOMAIN,
                sender,
                address(directory),
                communityRevnetId,
                communityToken,
                address(goalRegistry),
                cobuildRevnetId,
                salt
            )
        );
    }

    function derivePaymentTerminalSalt(
        address sender,
        IJBDirectory directory,
        uint256 communityRevnetId,
        address communityToken,
        ICommunityGoalRegistry goalRegistry,
        uint256 cobuildRevnetId,
        bytes32 salt
    ) public pure returns (bytes32 derivedSalt) {
        derivedSalt = keccak256(
            abi.encode(
                PAYMENT_TERMINAL_SALT_DOMAIN,
                sender,
                address(directory),
                communityRevnetId,
                communityToken,
                address(goalRegistry),
                cobuildRevnetId,
                salt
            )
        );
    }

    function predictSplitHookAddress(
        address sender,
        IJBDirectory directory,
        uint256 communityRevnetId,
        address communityToken,
        ICommunityGoalRegistry goalRegistry,
        uint256 cobuildRevnetId,
        bytes32 salt
    ) public view returns (address predicted) {
        predicted = Clones.predictDeterministicAddress(
            splitHookImplementation,
            deriveSplitHookSalt(
                sender,
                directory,
                communityRevnetId,
                communityToken,
                goalRegistry,
                cobuildRevnetId,
                salt
            ),
            address(this)
        );
    }

    function predictPaymentTerminalAddress(
        address sender,
        IJBDirectory directory,
        uint256 communityRevnetId,
        address communityToken,
        ICommunityGoalRegistry goalRegistry,
        uint256 cobuildRevnetId,
        bytes32 salt
    ) public view returns (address predicted) {
        bytes32 paymentTerminalSalt = derivePaymentTerminalSalt(
            sender,
            directory,
            communityRevnetId,
            communityToken,
            goalRegistry,
            cobuildRevnetId,
            salt
        );
        address predictedSplitHook = predictSplitHookAddress(
            sender,
            directory,
            communityRevnetId,
            communityToken,
            goalRegistry,
            cobuildRevnetId,
            salt
        );

        predicted = _predictPaymentTerminalAddress(
            predictedSplitHook,
            directory,
            communityToken,
            cobuildRevnetId,
            communityRevnetId,
            paymentTerminalSalt
        );
    }

    function _predictPaymentTerminalAddress(
        address splitHook,
        IJBDirectory directory,
        address communityToken,
        uint256 cobuildRevnetId,
        uint256 communityRevnetId,
        bytes32 paymentTerminalSalt
    ) internal view returns (address predicted) {
        predicted = Create2.computeAddress(
            paymentTerminalSalt,
            _paymentTerminalInitCodeHash(splitHook, directory, communityToken, cobuildRevnetId, communityRevnetId),
            address(this)
        );
    }

    function _paymentTerminalInitCodeHash(
        address splitHook,
        IJBDirectory directory,
        address communityToken,
        uint256 cobuildRevnetId,
        uint256 communityRevnetId
    ) internal pure returns (bytes32 initCodeHash) {
        initCodeHash = keccak256(
            abi.encodePacked(
                type(CobuildPaymentTerminal).creationCode,
                abi.encode(directory, ICobuildSplitHook(splitHook), communityToken, cobuildRevnetId, communityRevnetId)
            )
        );
    }

    function _requirePairConfiguration(
        ICobuildSplitHook splitHook,
        address paymentTerminal,
        uint256 communityRevnetId,
        address communityToken
    ) internal view {
        uint256 configuredCommunityRevnetId = splitHook.communityRevnetId();
        if (configuredCommunityRevnetId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, configuredCommunityRevnetId);
        }

        address configuredCommunityToken = splitHook.communityToken();
        if (configuredCommunityToken != communityToken) {
            revert INVALID_COMMUNITY_TOKEN(communityToken, configuredCommunityToken);
        }

        address configuredRouteSetter = splitHook.routeSetter();
        if (configuredRouteSetter != paymentTerminal) {
            revert INVALID_ROUTE_SETTER(paymentTerminal, configuredRouteSetter);
        }
    }
}
