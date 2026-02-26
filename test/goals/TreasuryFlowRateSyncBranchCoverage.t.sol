// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { TreasuryFlowRateSync } from "src/goals/library/TreasuryFlowRateSync.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { ISuperAgreement, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract TreasuryFlowRateSyncBranchCoverageTest is Test {
    event FlowRateSyncManualInterventionRequired(
        address indexed flow, int96 targetRate, int96 fallbackRate, int96 currentRate
    );

    TreasuryFlowRateSyncHarness internal harness;
    TreasuryFlowRateSyncMockFlow internal flow;
    TreasuryFlowRateSyncMockSuperToken internal superToken;
    TreasuryFlowRateSyncMockHost internal host;
    TreasuryFlowRateSyncMockCFA internal cfa;

    function setUp() public {
        harness = new TreasuryFlowRateSyncHarness();
        flow = new TreasuryFlowRateSyncMockFlow();
        superToken = new TreasuryFlowRateSyncMockSuperToken();
        host = new TreasuryFlowRateSyncMockHost();
        cfa = new TreasuryFlowRateSyncMockCFA();

        flow.setSuperToken(address(superToken));
        superToken.setHost(address(host));
        host.setAgreement(address(cfa));
    }

    function test_applyCappedFlowRate_clampsNegativeTargetToZero() public {
        flow.setTargetOutflowRateForTest(1);
        flow.setSuperToken(address(0));

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), -5);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyLinearSpendDownWithFallback_returnsZeroWhenTreasuryBalanceIsZero() public {
        flow.setTargetOutflowRateForTest(1);
        flow.setSuperToken(address(0));

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 50, 0, 1);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyLinearSpendDownWithFallback_returnsZeroWhenTimeRemainingIsZero() public {
        flow.setTargetOutflowRateForTest(1);
        flow.setSuperToken(address(0));

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 50, 1, 0);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyLinearSpendDownWithFallback_returnsZeroWhenMaxBufferRateIsZero() public {
        flow.setTargetOutflowRateForTest(1);
        superToken.setBalance(0);

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 50, 1000, 1000);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyLinearSpendDownWithFallback_appliesTargetWhenDirectWriteSucceeds() public {
        flow.setTargetOutflowRateForTest(0);
        flow.setSuperToken(address(0));

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 200, 1, 1);
        assertEq(applied, 200);
        assertEq(flow.targetOutflowRate(), 200);
    }

    function test_applyLinearSpendDownWithFallback_skipsLinearCapWhenTimeRemainingMulWouldOverflow() public {
        flow.setTargetOutflowRateForTest(1);
        superToken.setBalance(1);
        cfa.setMaxRate(100);

        int96 applied = harness.applyLinearSpendDownWithFallback(
            IFlow(address(flow)),
            80,
            1,
            type(uint256).max
        );
        assertEq(applied, 80);
        assertEq(flow.targetOutflowRate(), 80);
    }

    function test_applyLinearSpendDownWithFallback_skipsLinearCapWhenHorizonCostAddWouldOverflow() public {
        flow.setTargetOutflowRateForTest(1);
        superToken.setBalance(1);
        cfa.setMaxRate(100);

        int96 applied = harness.applyLinearSpendDownWithFallback(
            IFlow(address(flow)),
            80,
            type(uint256).max,
            2
        );
        assertEq(applied, 80);
        assertEq(flow.targetOutflowRate(), 80);
    }

    function test_applyCappedFlowRate_ignoresBufferLimitWhenHostAgreementLookupReverts() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        host.setRevertGetAgreementClass(true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 200);
        assertEq(applied, 200);
        assertEq(flow.targetOutflowRate(), 200);
    }

    function test_applyCappedFlowRate_ignoresBufferLimitWhenAgreementAddressIsZero() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        host.setAgreement(address(0));

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 200);
        assertEq(applied, 200);
        assertEq(flow.targetOutflowRate(), 200);
    }

    function test_applyCappedFlowRate_clampsToZeroWhenCfaReturnsNegativeMaxRate() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        cfa.setMaxRate(-1);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 50);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyCappedFlowRate_clampsToPositiveCfaMaxRate() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        cfa.setMaxRate(40);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 80);
        assertEq(applied, 40);
        assertEq(flow.targetOutflowRate(), 40);
    }

    function test_applyCappedFlowRate_retriesWithBufferFallbackWhenTargetWriteReverts() public {
        flow.setTargetOutflowRateForTest(10);
        superToken.setBalance(1);
        cfa.setMaxRate(40);
        flow.setRevertOnRate(80, true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 80);
        assertEq(applied, 40);
        assertEq(flow.targetOutflowRate(), 40);
    }

    function test_applyCappedFlowRate_refreshesWhenTargetAlreadySet() public {
        flow.setTargetOutflowRateForTest(25);
        flow.setSuperToken(address(0));

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 25);

        assertEq(applied, 25);
        assertEq(flow.targetOutflowRate(), 25);
        assertEq(flow.refreshCallCount(), 1);
    }

    function test_applyCappedFlowRate_emitsManualInterventionWhenRefreshReverts() public {
        flow.setTargetOutflowRateForTest(25);
        flow.setSuperToken(address(0));
        flow.setRevertRefresh(true);

        vm.expectEmit(true, false, false, true, address(harness));
        emit FlowRateSyncManualInterventionRequired(address(flow), 25, 25, 25);
        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 25);

        assertEq(applied, 25);
        assertEq(flow.targetOutflowRate(), 25);
        assertEq(flow.refreshCallCount(), 0);
    }

    function test_applyCappedFlowRate_fallsBackWhenTargetWriteReverts() public {
        flow.setTargetOutflowRateForTest(10);
        flow.setSuperToken(address(0));
        flow.setRevertOnRate(80, true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 80);

        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyLinearSpendDownWithFallback_fallsBackWhenTargetWriteReverts() public {
        flow.setTargetOutflowRateForTest(10);
        flow.setSuperToken(address(0));
        flow.setRevertOnRate(50, true);

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 50, 1, 1);

        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyCappedFlowRate_emitsManualInterventionWhenFallbackAndZeroWritesRevert() public {
        flow.setTargetOutflowRateForTest(10);
        flow.setSuperToken(address(0));
        flow.setRevertAllWrites(true);

        vm.expectEmit(true, false, false, true, address(harness));
        emit FlowRateSyncManualInterventionRequired(address(flow), 50, 50, 10);
        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 50);

        assertEq(applied, 10);
        assertEq(flow.targetOutflowRate(), 10);
    }
}

contract TreasuryFlowRateSyncHarness {
    function applyCappedFlowRate(IFlow flow, int96 targetRate) external returns (int96 appliedRate) {
        return TreasuryFlowRateSync.applyCappedFlowRate(flow, targetRate);
    }

    function applyLinearSpendDownWithFallback(
        IFlow flow,
        int96 targetRate,
        uint256 treasuryBalance,
        uint256 timeRemaining
    ) external returns (int96 appliedRate) {
        return TreasuryFlowRateSync.applyLinearSpendDownWithFallback(flow, targetRate, treasuryBalance, timeRemaining);
    }
}

contract TreasuryFlowRateSyncMockFlow {
    int96 private _targetOutflowRate;
    address private _superToken;
    bool private _revertAllWrites;
    bool private _revertRefresh;
    uint256 private _refreshCallCount;

    mapping(int96 => bool) private _revertOnRate;

    function setTargetOutflowRateForTest(int96 targetRate) external {
        _targetOutflowRate = targetRate;
    }

    function setSuperToken(address superToken_) external {
        _superToken = superToken_;
    }

    function setRevertAllWrites(bool shouldRevert) external {
        _revertAllWrites = shouldRevert;
    }

    function setRevertOnRate(int96 rate, bool shouldRevert) external {
        _revertOnRate[rate] = shouldRevert;
    }

    function setRevertRefresh(bool shouldRevert) external {
        _revertRefresh = shouldRevert;
    }

    function refreshCallCount() external view returns (uint256) {
        return _refreshCallCount;
    }

    function targetOutflowRate() external view returns (int96) {
        return _targetOutflowRate;
    }

    function setTargetOutflowRate(int96 targetRate) external {
        if (_revertAllWrites || _revertOnRate[targetRate]) revert("setTargetOutflowRate");
        _targetOutflowRate = targetRate;
    }

    function refreshTargetOutflowRate() external {
        _refreshCallCount += 1;
        if (_revertRefresh) revert("refreshTargetOutflowRate");
    }

    function superToken() external view returns (ISuperToken) {
        return ISuperToken(_superToken);
    }
}

contract TreasuryFlowRateSyncMockSuperToken {
    uint256 private _balance;
    address private _host;

    function setBalance(uint256 balance_) external {
        _balance = balance_;
    }

    function setHost(address host_) external {
        _host = host_;
    }

    function balanceOf(address) external view returns (uint256) {
        return _balance;
    }

    function getHost() external view returns (address) {
        return _host;
    }
}

contract TreasuryFlowRateSyncMockHost {
    address private _agreement;
    bool private _revertGetAgreementClass;

    function setAgreement(address agreement_) external {
        _agreement = agreement_;
    }

    function setRevertGetAgreementClass(bool shouldRevert) external {
        _revertGetAgreementClass = shouldRevert;
    }

    function getAgreementClass(bytes32) external view returns (ISuperAgreement) {
        if (_revertGetAgreementClass) revert("getAgreementClass");
        return ISuperAgreement(_agreement);
    }
}

contract TreasuryFlowRateSyncMockCFA {
    int96 private _maxRate;
    bool private _revertGetMaxRate;

    function setMaxRate(int96 maxRate) external {
        _maxRate = maxRate;
    }

    function setRevertGetMaxRate(bool shouldRevert) external {
        _revertGetMaxRate = shouldRevert;
    }

    function getMaximumFlowRateFromDeposit(ISuperToken, uint256) external view returns (int96) {
        if (_revertGetMaxRate) revert("getMaximumFlowRateFromDeposit");
        return _maxRate;
    }
}
