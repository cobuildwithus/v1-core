// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v5/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {IUniswapV3Factory} from "src/interfaces/external/uniswap-v3/IUniswapV3Factory.sol";
import {CobuildRoutedV4Hook} from "src/hooks/CobuildRoutedV4Hook.sol";

/// @notice Deploys Cobuild's routed v4 hook using CREATE2 with mined hook flags.
contract DeployCobuildRoutedV4Hook is DeployScript {
    address internal constant DEFAULT_CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Matches CobuildRoutedV4Hook.getHookPermissions():
    // afterInitialize, afterAddLiquidity, afterRemoveLiquidity, beforeSwap, afterSwap, beforeSwapReturnDelta.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    address internal revDeployerAddressOut;
    address internal create2DeployerOut;
    address internal directoryOut;
    address internal pricesOut;
    address internal tokensOut;
    address internal v4PoolManagerOut;
    address internal v3FactoryOut;
    address internal backingTokenOut;
    uint32 internal twapWindowOut;
    bytes32 internal hookSaltOut;
    address internal predictedHookOut;
    address internal deployedHookOut;

    error CREATE2_DEPLOY_FAILED(bytes reason);
    error HOOK_NOT_DEPLOYED(address expectedHook);
    error INVALID_TWAP_WINDOW();

    function deploy() internal override {
        revDeployerAddressOut = vm.envOr("REV_DEPLOYER", address(0x2cA27BDe7e7D33E353b44c27aCfCf6c78ddE251d));
        create2DeployerOut = vm.envOr("CREATE2_DEPLOYER", DEFAULT_CREATE2_DEPLOYER);
        v4PoolManagerOut = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        v3FactoryOut = vm.envAddress("UNISWAP_V3_FACTORY");
        backingTokenOut = vm.envOr("COBUILD_TOKEN", address(0x62f05B1aD94c5d7B9f989A294d2A0f36a1AE10Fb));
        twapWindowOut = uint32(vm.envOr("V4_HOOK_TWAP_WINDOW", uint256(1 hours)));
        if (twapWindowOut == 0) revert INVALID_TWAP_WINDOW();

        IREVDeployer revDeployer = IREVDeployer(revDeployerAddressOut);
        IJBController controller = revDeployer.CONTROLLER();
        IJBDirectory directory = revDeployer.DIRECTORY();
        IJBPrices prices = controller.PRICES();
        IJBTokens tokens = controller.TOKENS();

        directoryOut = address(directory);
        pricesOut = address(prices);
        tokensOut = address(tokens);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(v4PoolManagerOut),
            directory,
            prices,
            tokens,
            IUniswapV3Factory(v3FactoryOut),
            backingTokenOut,
            twapWindowOut
        );
        bytes memory creationCodeWithArgs = abi.encodePacked(type(CobuildRoutedV4Hook).creationCode, constructorArgs);

        (predictedHookOut, hookSaltOut) = HookMiner.find(
            create2DeployerOut, HOOK_FLAGS, type(CobuildRoutedV4Hook).creationCode, constructorArgs
        );

        bytes memory deployCalldata = abi.encodePacked(hookSaltOut, creationCodeWithArgs);
        (bool success, bytes memory reason) = create2DeployerOut.call(deployCalldata);
        if (!success) revert CREATE2_DEPLOY_FAILED(reason);

        deployedHookOut = predictedHookOut;
        if (deployedHookOut.code.length == 0) revert HOOK_NOT_DEPLOYED(deployedHookOut);

        console2.log("Deployer:", deployerAddress);
        console2.log("REV_DEPLOYER:", revDeployerAddressOut);
        console2.log("CREATE2_DEPLOYER:", create2DeployerOut);
        console2.log("UNISWAP_V4_POOL_MANAGER:", v4PoolManagerOut);
        console2.log("UNISWAP_V3_FACTORY:", v3FactoryOut);
        console2.log("DIRECTORY:", directoryOut);
        console2.log("PRICES:", pricesOut);
        console2.log("TOKENS:", tokensOut);
        console2.log("BACKING_TOKEN:", backingTokenOut);
        console2.log("TWAP_WINDOW:", twapWindowOut);
        console2.log("HOOK_FLAGS:", HOOK_FLAGS);
        console2.log("HOOK_SALT:");
        console2.logBytes32(hookSaltOut);
        console2.log("CobuildRoutedV4Hook:", deployedHookOut);
    }

    function deploymentName() internal pure override returns (string memory) {
        return "DeployCobuildRoutedV4Hook";
    }

    function writeDeploymentDetails(string memory filePath) internal override {
        _writeAddressLine(filePath, "REV_DEPLOYER", revDeployerAddressOut);
        _writeAddressLine(filePath, "CREATE2_DEPLOYER", create2DeployerOut);
        _writeAddressLine(filePath, "UNISWAP_V4_POOL_MANAGER", v4PoolManagerOut);
        _writeAddressLine(filePath, "UNISWAP_V3_FACTORY", v3FactoryOut);
        _writeAddressLine(filePath, "DIRECTORY", directoryOut);
        _writeAddressLine(filePath, "PRICES", pricesOut);
        _writeAddressLine(filePath, "TOKENS", tokensOut);
        _writeAddressLine(filePath, "BACKING_TOKEN", backingTokenOut);
        _writeUintLine(filePath, "TWAP_WINDOW", twapWindowOut);
        _writeUintLine(filePath, "HOOK_FLAGS", HOOK_FLAGS);
        vm.writeLine(filePath, string(abi.encodePacked("HOOK_SALT: ", vm.toString(hookSaltOut))));
        _writeAddressLine(filePath, "CobuildRoutedV4Hook", deployedHookOut);
    }
}
