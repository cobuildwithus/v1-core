// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { IFlow } from "src/interfaces/IFlow.sol";
import { TreasuryFlowRateSync } from "src/goals/library/TreasuryFlowRateSync.sol";
import { FlowSuperfluidFrameworkDeployer } from "test/utils/FlowSuperfluidFrameworkDeployer.sol";

import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { ERC1820RegistryCompiled } from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";

contract TreasuryFlowRateSyncSuperfluidIntegrationTest is Test {
    int96 internal constant MAX_TARGET_RATE = type(int96).max;

    FlowSuperfluidFrameworkDeployer internal sfDeployer;
    FlowSuperfluidFrameworkDeployer.Framework internal sf;
    TestToken internal underlyingToken;
    SuperToken internal superToken;
    TreasuryFlowRateSyncIntegrationHarness internal harness;
    TreasuryFlowRateSyncIntegrationFlow internal flow;

    address internal constant RECEIVER = address(0xBEEF);

    function setUp() public {
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);

        sfDeployer = new FlowSuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();
        sf = sfDeployer.getFramework();

        (TestToken underlying, SuperToken superToken_) =
            sfDeployer.deployWrapperSuperToken("MockUSD", "mUSD", 18, type(uint256).max, address(this));
        underlyingToken = underlying;
        superToken = superToken_;

        harness = new TreasuryFlowRateSyncIntegrationHarness();
        flow = new TreasuryFlowRateSyncIntegrationFlow(ISuperToken(address(superToken)), RECEIVER);

        _mintAndUpgrade(address(this), 2_000_000e18);
        superToken.transfer(address(flow), 1_000_000e18);
    }

    function test_applyCappedFlowRate_matchesCfaMaxRateFromBalanceOf_freshBalance() public {
        _assertApplyCappedRateMatchesExpectedMax(address(flow));
    }

    function test_applyCappedFlowRate_matchesCfaMaxRateFromBalanceOf_withExistingFlowAndBalanceChanges() public {
        int96 initialMaxRate = _expectedMaxRateFromBalance(address(flow));
        int96 seedRate = initialMaxRate / 3;
        if (seedRate == 0) seedRate = 1;

        flow.setTargetOutflowRate(seedRate);

        uint256[] memory topUps = new uint256[](3);
        topUps[0] = 0;
        topUps[1] = 50_000e18;
        topUps[2] = 0;

        uint256[] memory warps = new uint256[](3);
        warps[0] = 1 hours;
        warps[1] = 2 hours;
        warps[2] = 30 minutes;

        for (uint256 i = 0; i < topUps.length; ++i) {
            if (topUps[i] > 0) {
                superToken.transfer(address(flow), topUps[i]);
            }

            vm.warp(block.timestamp + warps[i]);

            _assertApplyCappedRateMatchesExpectedMax(address(flow));
        }
    }

    function _assertApplyCappedRateMatchesExpectedMax(address account) internal {
        _assertBalanceOfMatchesRealtimeAvailable(account);
        int96 expectedMaxRate = _expectedMaxRateFromBalance(account);
        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), MAX_TARGET_RATE);
        assertEq(applied, expectedMaxRate);
        assertEq(flow.targetOutflowRate(), expectedMaxRate);
    }

    function _expectedMaxRateFromBalance(address account) internal view returns (int96) {
        uint256 available = superToken.balanceOf(account);
        return sf.cfa.getMaximumFlowRateFromDeposit(ISuperToken(address(superToken)), available);
    }

    function _assertBalanceOfMatchesRealtimeAvailable(address account) internal view {
        uint256 balance = superToken.balanceOf(account);
        (int256 availableBalance, , ,) = superToken.realtimeBalanceOfNow(account);
        uint256 expectedBalance = availableBalance < 0 ? 0 : uint256(availableBalance);
        assertEq(balance, expectedBalance);
    }

    function _mintAndUpgrade(address to, uint256 amount) internal {
        vm.startPrank(to);
        underlyingToken.mint(to, amount);
        underlyingToken.approve(address(superToken), amount);
        ISuperToken(address(superToken)).upgrade(amount);
        vm.stopPrank();
    }
}

contract TreasuryFlowRateSyncIntegrationHarness {
    function applyCappedFlowRate(IFlow flow, int96 targetRate) external returns (int96 appliedRate) {
        return TreasuryFlowRateSync.applyCappedFlowRate(flow, targetRate);
    }
}

contract TreasuryFlowRateSyncIntegrationFlow {
    using SuperTokenV1Library for ISuperToken;

    ISuperToken private immutable _superToken;
    address private immutable _receiver;
    int96 private _targetOutflowRate;

    constructor(ISuperToken superToken_, address receiver_) {
        _superToken = superToken_;
        _receiver = receiver_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function targetOutflowRate() external view returns (int96) {
        return _targetOutflowRate;
    }

    function setTargetOutflowRate(int96 rate) external {
        _superToken.flow(_receiver, rate);
        _targetOutflowRate = rate;
    }

    function refreshTargetOutflowRate() external {
        int96 cachedRate = _targetOutflowRate;
        if (cachedRate <= 0) return;
        _superToken.flow(_receiver, cachedRate);
    }
}
