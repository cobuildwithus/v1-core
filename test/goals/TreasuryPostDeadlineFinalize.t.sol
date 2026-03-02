// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {TreasuryPostDeadlineFinalize} from "src/goals/library/TreasuryPostDeadlineFinalize.sol";

contract TreasuryPostDeadlineFinalizeTest is Test {
    function test_decide_noPendingAndGraceActive_waits() public pure {
        TreasuryPostDeadlineFinalize.Decision decision = TreasuryPostDeadlineFinalize.decide(
            _inputs(bytes32(0), true, false, false, false)
        );
        assertEq(uint8(decision), uint8(TreasuryPostDeadlineFinalize.Decision.Wait));
    }

    function test_decide_noPendingAndGraceInactive_finalizesExpired() public pure {
        TreasuryPostDeadlineFinalize.Decision decision = TreasuryPostDeadlineFinalize.decide(
            _inputs(bytes32(0), false, false, false, false)
        );
        assertEq(uint8(decision), uint8(TreasuryPostDeadlineFinalize.Decision.FinalizeExpired));
    }

    function test_decide_pendingUnresolved_waits() public pure {
        TreasuryPostDeadlineFinalize.Decision decision = TreasuryPostDeadlineFinalize.decide(
            _inputs(bytes32(uint256(1)), false, false, false, false)
        );
        assertEq(uint8(decision), uint8(TreasuryPostDeadlineFinalize.Decision.Wait));
    }

    function test_decide_pendingResolvedTruthful_finalizesSucceeded() public pure {
        TreasuryPostDeadlineFinalize.Decision decision = TreasuryPostDeadlineFinalize.decide(
            _inputs(bytes32(uint256(1)), false, true, true, false)
        );
        assertEq(uint8(decision), uint8(TreasuryPostDeadlineFinalize.Decision.FinalizeSucceeded));
    }

    function test_decide_pendingResolvedFalseAndGraceUnused_clearsAndActivatesGrace() public pure {
        TreasuryPostDeadlineFinalize.Decision decision = TreasuryPostDeadlineFinalize.decide(
            _inputs(bytes32(uint256(1)), false, true, false, false)
        );
        assertEq(uint8(decision), uint8(TreasuryPostDeadlineFinalize.Decision.ClearPendingAndActivateGrace));
    }

    function test_decide_pendingResolvedFalseAndGraceUsed_finalizesExpired() public pure {
        TreasuryPostDeadlineFinalize.Decision decision = TreasuryPostDeadlineFinalize.decide(
            _inputs(bytes32(uint256(1)), false, true, false, true)
        );
        assertEq(uint8(decision), uint8(TreasuryPostDeadlineFinalize.Decision.FinalizeExpired));
    }

    function _inputs(
        bytes32 pendingAssertionId,
        bool reassertGraceActive,
        bool assertionResolved,
        bool assertionTruthful,
        bool reassertGraceUsed
    ) internal pure returns (TreasuryPostDeadlineFinalize.Inputs memory) {
        return TreasuryPostDeadlineFinalize.Inputs({
            pendingAssertionId: pendingAssertionId,
            reassertGraceActive: reassertGraceActive,
            assertionResolved: assertionResolved,
            assertionTruthful: assertionTruthful,
            reassertGraceUsed: reassertGraceUsed
        });
    }
}
