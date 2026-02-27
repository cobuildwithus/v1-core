// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { TreasuryFlowRateSync } from "src/goals/library/TreasuryFlowRateSync.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { ISuperAgreement, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract TreasuryFlowRateSyncBranchCoverageTest is Test {
    bytes32 private constant _FLOW_RATE_SYNC_MANUAL_SIG =
        keccak256("FlowRateSyncManualInterventionRequired(address,int96,int96,int96)");
    bytes32 private constant _FLOW_RATE_SYNC_CALL_FAILED_SIG =
        keccak256("FlowRateSyncCallFailed(address,bytes4,int96,bytes)");

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

    function test_applyCappedFlowRate_failsClosedWhenSuperTokenMissing() public {
        flow.setTargetOutflowRateForTest(5);
        flow.setSuperToken(address(0));

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 50);
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
        superToken.setBalance(1);
        cfa.setMaxRate(500);

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 200, 1_000, 1);
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

    function test_applyCappedFlowRate_failsClosedWhenHostAgreementLookupReverts() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        host.setRevertGetAgreementClass(true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 200);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyCappedFlowRate_failsClosedWhenHostLookupReverts() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        superToken.setRevertGetHost(true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 200);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyCappedFlowRate_failsClosedWhenAgreementAddressIsZero() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        host.setAgreement(address(0));

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 200);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyCappedFlowRate_failsClosedWhenCfaMaxRateLookupReverts() public {
        flow.setTargetOutflowRateForTest(0);
        superToken.setBalance(1);
        cfa.setRevertGetMaxRate(true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 200);
        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
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
        superToken.setBalance(1);
        cfa.setMaxRate(50);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 25);

        assertEq(applied, 25);
        assertEq(flow.targetOutflowRate(), 25);
        assertEq(flow.refreshCallCount(), 1);
    }

    function test_applyCappedFlowRate_emitsManualInterventionWhenRefreshReverts() public {
        flow.setTargetOutflowRateForTest(25);
        superToken.setBalance(1);
        cfa.setMaxRate(50);
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
        superToken.setBalance(1);
        cfa.setMaxRate(80);
        flow.setRevertOnRate(80, true);

        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 80);

        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyLinearSpendDownWithFallback_fallsBackWhenTargetWriteReverts() public {
        flow.setTargetOutflowRateForTest(10);
        superToken.setBalance(1);
        cfa.setMaxRate(100);
        flow.setRevertOnRate(50, true);

        int96 applied = harness.applyLinearSpendDownWithFallback(IFlow(address(flow)), 50, 1, 1);

        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
    }

    function test_applyCappedFlowRate_emitsManualInterventionWhenFallbackAndZeroWritesRevert() public {
        flow.setTargetOutflowRateForTest(10);
        superToken.setBalance(1);
        cfa.setMaxRate(50);
        flow.setRevertAllWrites(true);

        vm.expectEmit(true, false, false, true, address(harness));
        emit FlowRateSyncManualInterventionRequired(address(flow), 50, 50, 10);
        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), 50);

        assertEq(applied, 10);
        assertEq(flow.targetOutflowRate(), 10);
    }

    function test_applyCappedFlowRate_emitsCallFailed_thenFallsBackToZero_whenCappedFallbackWriteReverts() public {
        flow.setTargetOutflowRateForTest(10);
        superToken.setBalance(100);
        cfa.setUseGasAsRate(true);
        flow.setRevertNonZeroWrites(true);

        vm.recordLogs();
        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), type(int96).max);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(applied, 0);
        assertEq(flow.targetOutflowRate(), 0);
        assertTrue(_hasCallFailed(entries));
        (bool hasManual,,,) = _manualRates(entries);
        assertFalse(hasManual);
    }

    function test_applyCappedFlowRate_emitsCallFailed_andManualIntervention_whenCappedFallbackAndZeroWritesRevert()
        public
    {
        flow.setTargetOutflowRateForTest(10);
        superToken.setBalance(100);
        cfa.setUseGasAsRate(true);
        flow.setRevertAllWrites(true);

        vm.recordLogs();
        int96 applied = harness.applyCappedFlowRate(IFlow(address(flow)), type(int96).max);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(applied, 10);
        assertEq(flow.targetOutflowRate(), 10);
        assertTrue(_hasCallFailed(entries));
        (bool hasManual, int96 targetRate, int96 fallbackRate, int96 currentRate) = _manualRates(entries);
        assertTrue(hasManual);
        assertLt(fallbackRate, targetRate);
        assertEq(currentRate, 10);
    }

    function test_applyLinearSpendDownWithFallback_recomputesLowerFallback_afterBalanceDropBetweenComputeAndWrite()
        public
    {
        flow.setTargetOutflowRateForTest(10);
        superToken.setBalance(100);
        cfa.setUseGasAsRate(true);
        flow.setRevertAllWrites(true);

        vm.recordLogs();
        int96 applied = harness.applyLinearSpendDownWithFallback(
            IFlow(address(flow)),
            type(int96).max,
            type(uint128).max,
            1
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(applied, 10);
        (bool hasManual, int96 targetRate, int96 fallbackRate, int96 currentRate) = _manualRates(entries);
        assertTrue(hasManual);
        assertLt(fallbackRate, targetRate);
        assertEq(currentRate, 10);
    }

    function _hasCallFailed(Vm.Log[] memory entries) internal view returns (bool) {
        for (uint256 i = 0; i < entries.length; ) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 3 && logEntry.topics[0] == _FLOW_RATE_SYNC_CALL_FAILED_SIG) {
                if (address(uint160(uint256(logEntry.topics[1]))) != address(flow)) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
                if (bytes4(logEntry.topics[2]) != IFlow.setTargetOutflowRate.selector) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _manualRates(
        Vm.Log[] memory entries
    ) internal view returns (bool found, int96 targetRate, int96 fallbackRate, int96 currentRate) {
        for (uint256 i = 0; i < entries.length; ) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 2 && logEntry.topics[0] == _FLOW_RATE_SYNC_MANUAL_SIG) {
                if (address(uint160(uint256(logEntry.topics[1]))) != address(flow)) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
                (targetRate, fallbackRate, currentRate) = abi.decode(logEntry.data, (int96, int96, int96));
                return (true, targetRate, fallbackRate, currentRate);
            }
            unchecked {
                ++i;
            }
        }
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
    bool private _revertNonZeroWrites;
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

    function setRevertNonZeroWrites(bool shouldRevert) external {
        _revertNonZeroWrites = shouldRevert;
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
        if (_revertAllWrites || (_revertNonZeroWrites && targetRate != 0) || _revertOnRate[targetRate]) {
            revert("setTargetOutflowRate");
        }
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
    bool private _revertGetHost;

    function setBalance(uint256 balance_) external {
        _balance = balance_;
    }

    function setHost(address host_) external {
        _host = host_;
    }

    function setRevertGetHost(bool shouldRevert) external {
        _revertGetHost = shouldRevert;
    }

    function balanceOf(address) external view returns (uint256) {
        return _balance;
    }

    function getHost() external view returns (address) {
        if (_revertGetHost) revert("getHost");
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
    bool private _useDepositAsRate;
    bool private _useGasAsRate;

    function setMaxRate(int96 maxRate) external {
        _maxRate = maxRate;
    }

    function setRevertGetMaxRate(bool shouldRevert) external {
        _revertGetMaxRate = shouldRevert;
    }

    function setUseDepositAsRate(bool shouldUseDepositAsRate) external {
        _useDepositAsRate = shouldUseDepositAsRate;
    }

    function setUseGasAsRate(bool shouldUseGasAsRate) external {
        _useGasAsRate = shouldUseGasAsRate;
    }

    function getMaximumFlowRateFromDeposit(ISuperToken, uint256 available) external view returns (int96) {
        if (_revertGetMaxRate) revert("getMaximumFlowRateFromDeposit");
        if (_useGasAsRate) {
            uint256 gasRate = gasleft();
            if (gasRate > uint256(uint96(type(int96).max))) return type(int96).max;
            return int96(uint96(gasRate));
        }
        if (_useDepositAsRate) {
            if (available > uint256(uint96(type(int96).max))) return type(int96).max;
            return int96(uint96(available));
        }
        return _maxRate;
    }
}
