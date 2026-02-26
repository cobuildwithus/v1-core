// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IFlow } from "../../interfaces/IFlow.sol";
import { ITreasuryFlowRateSyncEvents } from "../../interfaces/ITreasuryFlowRateSyncEvents.sol";
import { ISuperAgreement, ISuperfluid, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library TreasuryFlowRateSync {
    bytes32 private constant CFA_V1_TYPE = keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");

    function applyCappedFlowRate(IFlow flow, int96 targetRate) internal returns (int96 appliedRate) {
        return _applyTargetWithFallback(flow, _fallbackRate(flow, targetRate));
    }

    function applyLinearSpendDownWithFallback(
        IFlow flow,
        int96 targetRate,
        uint256 treasuryBalance,
        uint256 timeRemaining
    ) internal returns (int96 appliedRate) {
        int96 spendDownSafeRate = _linearSpendDownCap(flow, targetRate, treasuryBalance, timeRemaining);
        return _applyTargetWithFallback(flow, spendDownSafeRate);
    }

    function _applyTargetWithFallback(IFlow flow, int96 targetRate) private returns (int96 appliedRate) {
        if (flow.targetOutflowRate() == targetRate) {
            if (targetRate <= 0) return targetRate;
            try flow.refreshTargetOutflowRate() {
                return targetRate;
            } catch {
                int96 currentRate;
                try flow.targetOutflowRate() returns (int96 observedRate) {
                    currentRate = observedRate;
                } catch {
                    currentRate = targetRate;
                }
                emit ITreasuryFlowRateSyncEvents.FlowRateSyncManualInterventionRequired(
                    address(flow),
                    targetRate,
                    targetRate,
                    currentRate
                );
                return currentRate;
            }
        }

        try flow.setTargetOutflowRate(targetRate) {
            return targetRate;
        } catch {
            int96 fallbackRate = _fallbackRate(flow, targetRate);
            if (fallbackRate != targetRate) {
                int96 currentRateBeforeFallbackWrite = flow.targetOutflowRate();
                if (currentRateBeforeFallbackWrite == fallbackRate) {
                    return fallbackRate;
                }
                try flow.setTargetOutflowRate(fallbackRate) {
                    return fallbackRate;
                } catch (bytes memory reason) {
                    emit ITreasuryFlowRateSyncEvents.FlowRateSyncCallFailed(
                        address(flow),
                        IFlow.setTargetOutflowRate.selector,
                        fallbackRate,
                        reason
                    );
                }
            }

            int96 currentRate = flow.targetOutflowRate();
            if (currentRate == 0) {
                return 0;
            }
            try flow.setTargetOutflowRate(0) {
                return 0;
            } catch {
                emit ITreasuryFlowRateSyncEvents.FlowRateSyncManualInterventionRequired(
                    address(flow),
                    targetRate,
                    fallbackRate,
                    currentRate
                );
                return currentRate;
            }
        }
    }

    function _fallbackRate(IFlow flow, int96 targetRate) private view returns (int96 fallbackRate) {
        fallbackRate = targetRate;
        if (fallbackRate < 0) {
            fallbackRate = 0;
        }

        int96 maxBufferRate = _maxBufferConstrainedRate(flow);
        if (fallbackRate > maxBufferRate) {
            fallbackRate = maxBufferRate;
        }
    }

    function _linearSpendDownCap(
        IFlow flow,
        int96 targetRate,
        uint256 treasuryBalance,
        uint256 timeRemaining
    ) private view returns (int96 cappedRate) {
        cappedRate = targetRate;
        if (cappedRate <= 0) return 0;
        if (treasuryBalance == 0 || timeRemaining == 0) return 0;

        int96 maxBufferRate = _maxBufferConstrainedRate(flow);
        if (maxBufferRate <= 0) return 0;
        if (maxBufferRate == type(int96).max) return cappedRate;

        // Keep proactive caps in play even when the target exceeds the current buffer-affordable limit.
        if (cappedRate > maxBufferRate) cappedRate = maxBufferRate;

        uint256 maxBufferRateU = uint256(uint96(maxBufferRate));

        // If arithmetic overflows, skip this proactive cap and rely on write-time fallback behavior.
        if (timeRemaining > type(uint256).max / maxBufferRateU) return cappedRate;
        uint256 horizonCost = maxBufferRateU * timeRemaining;
        if (horizonCost > type(uint256).max - treasuryBalance) return cappedRate;

        uint256 linearSafeRate = Math.mulDiv(treasuryBalance, maxBufferRateU, treasuryBalance + horizonCost);
        if (linearSafeRate > uint256(uint96(type(int96).max))) {
            linearSafeRate = uint256(uint96(type(int96).max));
        }

        int96 linearSafeRate96 = int96(uint96(linearSafeRate));
        if (cappedRate > linearSafeRate96) {
            cappedRate = linearSafeRate96;
        }
    }

    function _maxBufferConstrainedRate(IFlow flow) private view returns (int96 maxBufferRate) {
        ISuperToken token = flow.superToken();
        if (address(token) == address(0)) return 0;

        uint256 available = token.balanceOf(address(flow));
        if (available == 0) return 0;

        address hostAddress;
        try token.getHost() returns (address host_) {
            hostAddress = host_;
        } catch {
            return 0;
        }
        if (hostAddress == address(0)) return 0;

        ISuperAgreement cfaAgreement;
        try ISuperfluid(hostAddress).getAgreementClass(CFA_V1_TYPE) returns (ISuperAgreement agreement_) {
            cfaAgreement = agreement_;
        } catch {
            return 0;
        }
        if (address(cfaAgreement) == address(0)) return 0;

        try IConstantFlowAgreementV1(address(cfaAgreement)).getMaximumFlowRateFromDeposit(token, available) returns (
            int96 maxRate
        ) {
            if (maxRate < 0) return 0;
            return maxRate;
        } catch {
            return 0;
        }
    }
}
