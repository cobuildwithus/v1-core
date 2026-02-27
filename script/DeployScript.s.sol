// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Shared deploy-script helper that standardizes broadcaster setup and address artifact outputs.
abstract contract DeployScript is Script {
    uint256 internal deployerKey;
    address internal deployerAddress;
    uint256 internal chainId;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    error EMPTY_DEPLOYMENT_NAME();

    function setUp() public virtual {
        _loadRuntimeConfig();
    }

    function run() public virtual {
        _loadRuntimeConfig();

        vm.startBroadcast(deployerKey);
        deploy();
        vm.stopBroadcast();

        _writeDeploymentArtifact();
    }

    function _loadRuntimeConfig() internal {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployerAddress = vm.addr(deployerKey);
        chainId = block.chainid;
    }

    function deploy() internal virtual;
    function deploymentName() internal pure virtual returns (string memory);
    function writeDeploymentDetails(string memory filePath) internal virtual;

    function _writeDeploymentArtifact() internal {
        string memory name = deploymentName();
        if (bytes(name).length == 0) revert EMPTY_DEPLOYMENT_NAME();

        vm.createDir("deploys", true);
        string memory filePath = string(abi.encodePacked("deploys/", name, ".", vm.toString(chainId), ".txt"));

        vm.writeFile(filePath, "");
        vm.writeLine(filePath, string(abi.encodePacked("ChainID: ", vm.toString(chainId))));
        vm.writeLine(filePath, string(abi.encodePacked("Deployer: ", vm.toString(deployerAddress))));
        writeDeploymentDetails(filePath);

        console2.log("Deployment artifact written:", filePath);
    }

    function _writeAddressLine(string memory filePath, string memory key, address value) internal {
        vm.writeLine(filePath, string(abi.encodePacked(key, ": ", vm.toString(value))));
    }

    function _writeUintLine(string memory filePath, string memory key, uint256 value) internal {
        vm.writeLine(filePath, string(abi.encodePacked(key, ": ", vm.toString(value))));
    }
}
