// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GoalFactoryRevnetDeploy} from "src/goals/library/GoalFactoryRevnetDeploy.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/structs/JBTerminalConfig.sol";

contract GoalFactoryRevnetDeployTest is Test {
    MockRevDeployer internal revDeployer;
    MockDirectory internal directory;
    MockController internal controller;
    MockRulesets internal rulesets;
    MockTokens internal tokens;

    function setUp() public {
        directory = new MockDirectory();
        rulesets = new MockRulesets();
        tokens = new MockTokens();
        controller = new MockController(address(tokens), address(rulesets));
        revDeployer = new MockRevDeployer(address(directory), address(controller));
    }

    function test_deployRevnet_configuresCobuildBuybackPoolAndTerminals() public {
        address cobuildToken = address(0xC0B1D);
        uint8 cobuildDecimals = 18;
        uint256 cobuildRevnetId = 7;
        address splitHook = address(0x5157);
        address buybackHookDataHook = address(0x1111);
        address buybackHook = address(0x2222);
        uint24 buybackPoolFee = 3_000;
        uint32 buybackTwapWindow = 1 hours;

        address cobuildTerminal = address(new DummyTerminal());
        address cobuildNativePaymentTerminal = address(new DummyTerminal());
        address goalToken = address(0xABCD);
        uint256 deployedRevnetId = 99;

        directory.setPrimaryTerminal(cobuildRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(cobuildNativePaymentTerminal));
        revDeployer.setNextRevnetId(deployedRevnetId);
        tokens.setTokenOf(deployedRevnetId, goalToken);

        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory request = GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
            revDeployer: IREVDeployer(address(revDeployer)),
            cobuildToken: cobuildToken,
            cobuildDecimals: cobuildDecimals,
            cobuildRevnetId: cobuildRevnetId,
            cobuildTerminal: cobuildTerminal,
            splitHook: splitHook,
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 123,
            cashOutTaxRate: 250,
            reservedPercent: 500,
            durationSeconds: 7 days,
            buybackHookDataHook: buybackHookDataHook,
            buybackHook: buybackHook,
            buybackPoolFee: buybackPoolFee,
            buybackTwapWindow: buybackTwapWindow,
            burnAddress: address(0xB0A1)
        });

        GoalFactoryRevnetDeploy.RevnetDeploymentResult memory result = GoalFactoryRevnetDeploy.deployRevnet(request);

        assertEq(revDeployer.lastBaseCurrency(), uint32(uint160(cobuildToken)));
        assertEq(revDeployer.lastBuybackDataHook(), buybackHookDataHook);
        assertEq(revDeployer.lastBuybackHookToConfigure(), buybackHook);
        assertEq(revDeployer.lastBuybackPoolCount(), 1);
        assertEq(revDeployer.lastBuybackPoolToken(), cobuildToken);
        assertEq(revDeployer.lastBuybackPoolFee(), buybackPoolFee);
        assertEq(revDeployer.lastBuybackPoolTwapWindow(), buybackTwapWindow);

        assertEq(revDeployer.lastTerminalConfigCount(), 2);
        assertEq(revDeployer.lastTerminal0(), cobuildTerminal);
        assertEq(revDeployer.lastTerminal1(), cobuildNativePaymentTerminal);

        assertEq(revDeployer.lastTerminal0ContextToken(), JBConstants.NATIVE_TOKEN);
        assertEq(revDeployer.lastTerminal0ContextDecimals(), 18);
        assertEq(revDeployer.lastTerminal0ContextCurrency(), uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertEq(revDeployer.lastTerminal1ContextToken(), cobuildToken);
        assertEq(revDeployer.lastTerminal1ContextDecimals(), cobuildDecimals);
        assertEq(revDeployer.lastTerminal1ContextCurrency(), uint32(uint160(cobuildToken)));

        assertEq(address(result.directory), address(directory));
        assertEq(address(result.controller), address(controller));
        assertEq(address(result.rulesets), address(rulesets));
        assertEq(result.goalRevnetId, deployedRevnetId);
        assertEq(result.goalToken, goalToken);
    }

    function test_deployRevnet_revertsWhenCobuildNativePaymentTerminalMissing() public {
        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory request = GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
            revDeployer: IREVDeployer(address(revDeployer)),
            cobuildToken: address(0xC0B1D),
            cobuildDecimals: 18,
            cobuildRevnetId: 7,
            cobuildTerminal: address(new DummyTerminal()),
            splitHook: address(0x5157),
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 123,
            cashOutTaxRate: 250,
            reservedPercent: 500,
            durationSeconds: 7 days,
            buybackHookDataHook: address(0x1111),
            buybackHook: address(0x2222),
            buybackPoolFee: 3_000,
            buybackTwapWindow: 1 hours,
            burnAddress: address(0xB0A1)
        });

        vm.expectRevert(GoalFactoryRevnetDeploy.ADDRESS_ZERO.selector);
        GoalFactoryRevnetDeploy.deployRevnet(request);
    }

    function test_deployRevnet_revertsWhenCobuildTerminalIsZero() public {
        uint256 cobuildRevnetId = 7;
        address cobuildNativePaymentTerminal = address(new DummyTerminal());
        directory.setPrimaryTerminal(cobuildRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(cobuildNativePaymentTerminal));

        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory request = GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
            revDeployer: IREVDeployer(address(revDeployer)),
            cobuildToken: address(0xC0B1D),
            cobuildDecimals: 18,
            cobuildRevnetId: cobuildRevnetId,
            cobuildTerminal: address(0),
            splitHook: address(0x5157),
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 123,
            cashOutTaxRate: 250,
            reservedPercent: 500,
            durationSeconds: 7 days,
            buybackHookDataHook: address(0x1111),
            buybackHook: address(0x2222),
            buybackPoolFee: 3_000,
            buybackTwapWindow: 1 hours,
            burnAddress: address(0xB0A1)
        });

        vm.expectRevert(GoalFactoryRevnetDeploy.ADDRESS_ZERO.selector);
        GoalFactoryRevnetDeploy.deployRevnet(request);
    }

    function test_deployRevnet_revertsWhenGoalTokenMissingAfterDeploy() public {
        uint256 cobuildRevnetId = 7;
        uint256 deployedRevnetId = 99;
        address cobuildTerminal = address(new DummyTerminal());
        address cobuildNativePaymentTerminal = address(new DummyTerminal());

        directory.setPrimaryTerminal(cobuildRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(cobuildNativePaymentTerminal));
        revDeployer.setNextRevnetId(deployedRevnetId);

        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory request = GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
            revDeployer: IREVDeployer(address(revDeployer)),
            cobuildToken: address(0xC0B1D),
            cobuildDecimals: 18,
            cobuildRevnetId: cobuildRevnetId,
            cobuildTerminal: cobuildTerminal,
            splitHook: address(0x5157),
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 123,
            cashOutTaxRate: 250,
            reservedPercent: 500,
            durationSeconds: 7 days,
            buybackHookDataHook: address(0x1111),
            buybackHook: address(0x2222),
            buybackPoolFee: 3_000,
            buybackTwapWindow: 1 hours,
            burnAddress: address(0xB0A1)
        });

        vm.expectRevert(GoalFactoryRevnetDeploy.ADDRESS_ZERO.selector);
        GoalFactoryRevnetDeploy.deployRevnet(request);
    }

    function test_deployRevnet_saltUsesCallerAndSplitHook() public {
        uint256 cobuildRevnetId = 7;
        uint256 deployedRevnetId = 99;
        address cobuildTerminal = address(new DummyTerminal());
        address cobuildNativePaymentTerminal = address(new DummyTerminal());
        address splitHook = address(0x5157);

        directory.setPrimaryTerminal(cobuildRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(cobuildNativePaymentTerminal));
        revDeployer.setNextRevnetId(deployedRevnetId);
        tokens.setTokenOf(deployedRevnetId, address(0xABCD));

        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory request = GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
            revDeployer: IREVDeployer(address(revDeployer)),
            cobuildToken: address(0xC0B1D),
            cobuildDecimals: 18,
            cobuildRevnetId: cobuildRevnetId,
            cobuildTerminal: cobuildTerminal,
            splitHook: splitHook,
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 123,
            cashOutTaxRate: 250,
            reservedPercent: 500,
            durationSeconds: 7 days,
            buybackHookDataHook: address(0x1111),
            buybackHook: address(0x2222),
            buybackPoolFee: 3_000,
            buybackTwapWindow: 1 hours,
            burnAddress: address(0xB0A1)
        });

        GoalFactoryRevnetDeploy.deployRevnet(request);

        assertEq(revDeployer.lastSalt(), _expectedSalt(splitHook));
    }

    function test_deployRevnet_saltVariesAcrossDistinctSplitHooks() public {
        uint256 cobuildRevnetId = 7;
        address cobuildTerminal = address(new DummyTerminal());
        address cobuildNativePaymentTerminal = address(new DummyTerminal());
        address firstSplitHook = address(0x5157);
        address secondSplitHook = address(0x5257);

        directory.setPrimaryTerminal(cobuildRevnetId, JBConstants.NATIVE_TOKEN, IJBTerminal(cobuildNativePaymentTerminal));

        revDeployer.setNextRevnetId(99);
        tokens.setTokenOf(99, address(0xABCD));
        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory first = GoalFactoryRevnetDeploy.RevnetDeploymentRequest({
            revDeployer: IREVDeployer(address(revDeployer)),
            cobuildToken: address(0xC0B1D),
            cobuildDecimals: 18,
            cobuildRevnetId: cobuildRevnetId,
            cobuildTerminal: cobuildTerminal,
            splitHook: firstSplitHook,
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 123,
            cashOutTaxRate: 250,
            reservedPercent: 500,
            durationSeconds: 7 days,
            buybackHookDataHook: address(0x1111),
            buybackHook: address(0x2222),
            buybackPoolFee: 3_000,
            buybackTwapWindow: 1 hours,
            burnAddress: address(0xB0A1)
        });
        GoalFactoryRevnetDeploy.deployRevnet(first);
        bytes32 firstSalt = revDeployer.lastSalt();

        revDeployer.setNextRevnetId(100);
        tokens.setTokenOf(100, address(0xABCE));
        GoalFactoryRevnetDeploy.RevnetDeploymentRequest memory second = first;
        second.splitHook = secondSplitHook;
        GoalFactoryRevnetDeploy.deployRevnet(second);
        bytes32 secondSalt = revDeployer.lastSalt();

        assertTrue(firstSalt != secondSalt);
        assertEq(firstSalt, _expectedSalt(firstSplitHook));
        assertEq(secondSalt, _expectedSalt(secondSplitHook));
    }

    function _expectedSalt(address splitHook) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), splitHook));
    }
}

contract DummyTerminal {}

contract MockRevDeployer {
    address internal immutable _directory;
    address internal immutable _controller;

    uint256 internal _nextRevnetId = 1;

    uint32 internal _lastBaseCurrency;
    address internal _lastBuybackDataHook;
    address internal _lastBuybackHookToConfigure;
    uint256 internal _lastBuybackPoolCount;
    address internal _lastBuybackPoolToken;
    uint24 internal _lastBuybackPoolFee;
    uint32 internal _lastBuybackPoolTwapWindow;
    bytes32 internal _lastSalt;

    uint256 internal _lastTerminalConfigCount;
    address internal _lastTerminal0;
    address internal _lastTerminal1;
    address internal _lastTerminal0ContextToken;
    uint8 internal _lastTerminal0ContextDecimals;
    uint32 internal _lastTerminal0ContextCurrency;
    address internal _lastTerminal1ContextToken;
    uint8 internal _lastTerminal1ContextDecimals;
    uint32 internal _lastTerminal1ContextCurrency;

    constructor(address directory_, address controller_) {
        _directory = directory_;
        _controller = controller_;
    }

    function setNextRevnetId(uint256 revnetId) external {
        _nextRevnetId = revnetId;
    }

    function deployFor(
        uint256,
        IREVDeployer.REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        IREVDeployer.REVBuybackHookConfig calldata buybackHookConfiguration,
        IREVDeployer.REVSuckerDeploymentConfig calldata
    ) external returns (uint256 revnetId) {
        _lastBaseCurrency = configuration.baseCurrency;
        _lastSalt = configuration.description.salt;

        _lastBuybackDataHook = buybackHookConfiguration.dataHook;
        _lastBuybackHookToConfigure = buybackHookConfiguration.hookToConfigure;
        _lastBuybackPoolCount = buybackHookConfiguration.poolConfigurations.length;
        if (buybackHookConfiguration.poolConfigurations.length != 0) {
            _lastBuybackPoolToken = buybackHookConfiguration.poolConfigurations[0].token;
            _lastBuybackPoolFee = buybackHookConfiguration.poolConfigurations[0].fee;
            _lastBuybackPoolTwapWindow = buybackHookConfiguration.poolConfigurations[0].twapWindow;
        }

        _lastTerminalConfigCount = terminalConfigurations.length;
        if (terminalConfigurations.length > 0) {
            _lastTerminal0 = address(terminalConfigurations[0].terminal);
            if (terminalConfigurations[0].accountingContextsToAccept.length > 0) {
                _lastTerminal0ContextToken = terminalConfigurations[0].accountingContextsToAccept[0].token;
                _lastTerminal0ContextDecimals = terminalConfigurations[0].accountingContextsToAccept[0].decimals;
                _lastTerminal0ContextCurrency = terminalConfigurations[0].accountingContextsToAccept[0].currency;
            }
        }
        if (terminalConfigurations.length > 1) {
            _lastTerminal1 = address(terminalConfigurations[1].terminal);
            if (terminalConfigurations[1].accountingContextsToAccept.length > 0) {
                _lastTerminal1ContextToken = terminalConfigurations[1].accountingContextsToAccept[0].token;
                _lastTerminal1ContextDecimals = terminalConfigurations[1].accountingContextsToAccept[0].decimals;
                _lastTerminal1ContextCurrency = terminalConfigurations[1].accountingContextsToAccept[0].currency;
            }
        }

        revnetId = _nextRevnetId;
    }

    function CONTROLLER() external view returns (IJBController) {
        return IJBController(_controller);
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(_directory);
    }

    function PROJECTS() external pure returns (address) {
        return address(0);
    }

    function lastBaseCurrency() external view returns (uint32) {
        return _lastBaseCurrency;
    }

    function lastBuybackDataHook() external view returns (address) {
        return _lastBuybackDataHook;
    }

    function lastBuybackHookToConfigure() external view returns (address) {
        return _lastBuybackHookToConfigure;
    }

    function lastBuybackPoolCount() external view returns (uint256) {
        return _lastBuybackPoolCount;
    }

    function lastBuybackPoolToken() external view returns (address) {
        return _lastBuybackPoolToken;
    }

    function lastBuybackPoolFee() external view returns (uint24) {
        return _lastBuybackPoolFee;
    }

    function lastBuybackPoolTwapWindow() external view returns (uint32) {
        return _lastBuybackPoolTwapWindow;
    }

    function lastSalt() external view returns (bytes32) {
        return _lastSalt;
    }

    function lastTerminalConfigCount() external view returns (uint256) {
        return _lastTerminalConfigCount;
    }

    function lastTerminal0() external view returns (address) {
        return _lastTerminal0;
    }

    function lastTerminal1() external view returns (address) {
        return _lastTerminal1;
    }

    function lastTerminal0ContextToken() external view returns (address) {
        return _lastTerminal0ContextToken;
    }

    function lastTerminal0ContextDecimals() external view returns (uint8) {
        return _lastTerminal0ContextDecimals;
    }

    function lastTerminal0ContextCurrency() external view returns (uint32) {
        return _lastTerminal0ContextCurrency;
    }

    function lastTerminal1ContextToken() external view returns (address) {
        return _lastTerminal1ContextToken;
    }

    function lastTerminal1ContextDecimals() external view returns (uint8) {
        return _lastTerminal1ContextDecimals;
    }

    function lastTerminal1ContextCurrency() external view returns (uint32) {
        return _lastTerminal1ContextCurrency;
    }
}

contract MockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }
}

contract MockController {
    address internal immutable _tokens;
    address internal immutable _rulesets;

    constructor(address tokens_, address rulesets_) {
        _tokens = tokens_;
        _rulesets = rulesets_;
    }

    function TOKENS() external view returns (IJBTokens) {
        return IJBTokens(_tokens);
    }

    function RULESETS() external view returns (IJBRulesets) {
        return IJBRulesets(_rulesets);
    }
}

contract MockTokens {
    mapping(uint256 => address) internal _tokenOf;

    function setTokenOf(uint256 projectId, address token) external {
        _tokenOf[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokenOf[projectId];
    }
}

contract MockRulesets {}
