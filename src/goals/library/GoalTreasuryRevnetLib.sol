// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IGoalRevnetHookDirectoryReader } from "src/interfaces/IGoalRevnetHookDirectoryReader.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBControlled } from "@bananapus/core-v5/interfaces/IJBControlled.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBApprovalStatus } from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GoalTreasuryRevnetLib {
    uint8 private constant DIRECTORY_FAILURE_NONE = 0;
    uint8 private constant DIRECTORY_FAILURE_INVALID = 1;
    uint8 private constant DIRECTORY_FAILURE_REVERT = 2;

    function deriveInitState(
        IStakeVault configuredStakeVault,
        ISuperToken configuredSuperToken,
        IJBRulesets configuredGoalRulesets,
        address configuredHook,
        uint256 configuredGoalRevnetId
    ) public view returns (address goalToken, address cobuildToken, uint256 cobuildRevnetId, uint64 deadline) {
        goalToken = address(configuredStakeVault.goalToken());
        cobuildToken = address(configuredStakeVault.cobuildToken());
        cobuildRevnetId = _deriveCobuildRevnetId(
            configuredGoalRevnetId,
            IERC20(cobuildToken),
            configuredGoalRulesets,
            configuredHook
        );
        _requireGoalTokenInvariants(
            configuredSuperToken,
            IERC20(goalToken),
            configuredGoalRulesets,
            configuredHook,
            configuredGoalRevnetId
        );
        deadline = deriveDeadline(configuredGoalRulesets, configuredGoalRevnetId);
    }

    function requireResolvedDirectory(
        IJBRulesets configuredGoalRulesets,
        address configuredHook
    ) public view returns (IJBDirectory directory) {
        (directory, ) = _resolveRevnetDirectory(configuredGoalRulesets, configuredHook);
        if (address(directory) == address(0)) revert IGoalTreasury.INVALID_REVNET_CONTROLLER(address(0));
    }

    function burnViaController(
        IJBRulesets configuredGoalRulesets,
        address configuredHook,
        uint256 revnetId,
        uint256 amount,
        string memory memo
    ) public {
        IJBDirectory directory = requireResolvedDirectory(configuredGoalRulesets, configuredHook);
        address controller = address(directory.controllerOf(revnetId));
        if (controller == address(0)) revert IGoalTreasury.INVALID_REVNET_CONTROLLER(controller);
        IJBController(controller).burnTokensOf(address(this), revnetId, amount, memo);
    }

    function deriveDeadline(
        IJBRulesets configuredGoalRulesets,
        uint256 configuredGoalRevnetId
    ) public view returns (uint64) {
        (JBRuleset memory terminal, JBApprovalStatus approvalStatus) = configuredGoalRulesets.latestQueuedOf(
            configuredGoalRevnetId
        );
        if (
            terminal.id == 0 ||
            terminal.start == 0 ||
            terminal.basedOnId == 0 ||
            terminal.weight != 0 ||
            (approvalStatus != JBApprovalStatus.Empty && approvalStatus != JBApprovalStatus.Approved)
        ) {
            revert IGoalTreasury.DEADLINE_NOT_DERIVABLE();
        }

        JBRuleset memory initial = configuredGoalRulesets.getRulesetOf(configuredGoalRevnetId, terminal.basedOnId);
        if (initial.id == 0 || initial.weight == 0 || initial.basedOnId != 0 || initial.start >= terminal.start) {
            revert IGoalTreasury.DEADLINE_NOT_DERIVABLE();
        }

        return uint64(terminal.start);
    }

    function _deriveCobuildRevnetId(
        uint256 goalRevnetIdForLookup,
        IERC20 configuredCobuildToken,
        IJBRulesets configuredGoalRulesets,
        address configuredHook
    ) private view returns (uint256) {
        if (address(configuredCobuildToken) == address(0)) return 0;

        (IJBDirectory directory, bytes memory directoryFailureReason) = _resolveRevnetDirectory(
            configuredGoalRulesets,
            configuredHook
        );
        if (address(directory) == address(0)) {
            revert IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE_WITH_REASON(
                address(configuredCobuildToken),
                directoryFailureReason
            );
        }

        address controller = address(directory.controllerOf(goalRevnetIdForLookup));
        if (controller == address(0)) revert IGoalTreasury.INVALID_REVNET_CONTROLLER(controller);

        IJBTokens tokens;
        try IJBController(controller).TOKENS() returns (IJBTokens resolvedTokens) {
            tokens = resolvedTokens;
        } catch {
            revert IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
        }

        if (address(tokens) == address(0)) {
            revert IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
        }

        try tokens.projectIdOf(IJBToken(address(configuredCobuildToken))) returns (uint256 derivedRevnetId) {
            if (derivedRevnetId == 0) {
                revert IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
            }

            address cobuildController = address(directory.controllerOf(derivedRevnetId));
            if (cobuildController == address(0)) {
                revert IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
            }
            return derivedRevnetId;
        } catch {
            revert IGoalTreasury.COBUILD_REVNET_ID_NOT_DERIVABLE(address(configuredCobuildToken));
        }
    }

    function _requireGoalTokenInvariants(
        ISuperToken configuredSuperToken,
        IERC20 configuredGoalToken,
        IJBRulesets configuredGoalRulesets,
        address configuredHook,
        uint256 configuredGoalRevnetId
    ) private view {
        address underlyingToken = configuredSuperToken.getUnderlyingToken();
        if (underlyingToken != address(configuredGoalToken)) {
            revert IGoalTreasury.GOAL_TOKEN_SUPER_TOKEN_UNDERLYING_MISMATCH(
                address(configuredGoalToken),
                underlyingToken
            );
        }

        (IJBDirectory directory, bytes memory directoryFailureReason) = _resolveRevnetDirectory(
            configuredGoalRulesets,
            configuredHook
        );
        if (address(directory) == address(0)) {
            revert IGoalTreasury.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE_WITH_REASON(
                address(configuredGoalToken),
                directoryFailureReason
            );
        }

        _requireTokenMatchesRevnetId(directory, configuredGoalRevnetId, configuredGoalToken);
    }

    function _requireTokenMatchesRevnetId(IJBDirectory directory, uint256 expectedRevnetId, IERC20 token) private view {
        address controller = address(directory.controllerOf(expectedRevnetId));
        if (controller == address(0)) revert IGoalTreasury.INVALID_REVNET_CONTROLLER(controller);

        IJBTokens tokens;
        try IJBController(controller).TOKENS() returns (IJBTokens resolvedTokens) {
            tokens = resolvedTokens;
        } catch {
            revert IGoalTreasury.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(token));
        }

        if (address(tokens) == address(0)) {
            revert IGoalTreasury.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(token));
        }

        uint256 derivedRevnetId;
        try tokens.projectIdOf(IJBToken(address(token))) returns (uint256 resolvedRevnetId) {
            derivedRevnetId = resolvedRevnetId;
        } catch {
            revert IGoalTreasury.GOAL_TOKEN_REVNET_ID_NOT_DERIVABLE(address(token));
        }

        if (derivedRevnetId != expectedRevnetId) {
            revert IGoalTreasury.GOAL_TOKEN_REVNET_MISMATCH(address(token), expectedRevnetId, derivedRevnetId);
        }
    }

    function _resolveRevnetDirectory(
        IJBRulesets configuredGoalRulesets,
        address configuredHook
    ) private view returns (IJBDirectory directory, bytes memory failureReason) {
        uint8 rulesetsFailure = DIRECTORY_FAILURE_NONE;
        bytes memory rulesetsFailureReason;
        uint8 hookFailure = DIRECTORY_FAILURE_NONE;
        bytes memory hookFailureReason;

        try IJBControlled(address(configuredGoalRulesets)).DIRECTORY() returns (IJBDirectory rulesetsDirectory) {
            if (address(rulesetsDirectory) != address(0) && address(rulesetsDirectory).code.length != 0) {
                return (rulesetsDirectory, bytes(""));
            }
            rulesetsFailure = DIRECTORY_FAILURE_INVALID;
        } catch (bytes memory reason) {
            rulesetsFailure = DIRECTORY_FAILURE_REVERT;
            rulesetsFailureReason = reason;
        }

        try IGoalRevnetHookDirectoryReader(configuredHook).directory() returns (IJBDirectory hookDirectory) {
            if (address(hookDirectory) != address(0) && address(hookDirectory).code.length != 0) {
                return (hookDirectory, bytes(""));
            }
            hookFailure = DIRECTORY_FAILURE_INVALID;
        } catch (bytes memory reason) {
            hookFailure = DIRECTORY_FAILURE_REVERT;
            hookFailureReason = reason;
        }

        failureReason = abi.encode(
            address(configuredGoalRulesets),
            rulesetsFailure,
            rulesetsFailureReason,
            configuredHook,
            hookFailure,
            hookFailureReason
        );
        return (IJBDirectory(address(0)), failureReason);
    }
}
