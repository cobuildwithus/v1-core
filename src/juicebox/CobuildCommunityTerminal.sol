// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBCashOutHook } from "@bananapus/core-v5/interfaces/IJBCashOutHook.sol";
import { IJBCashOutTerminal } from "@bananapus/core-v5/interfaces/IJBCashOutTerminal.sol";
import { IJBPayHook } from "@bananapus/core-v5/interfaces/IJBPayHook.sol";
import { IJBController } from "@bananapus/core-v5/interfaces/IJBController.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBTerminalStore } from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";
import { JBAccountingContext } from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import { JBAfterCashOutRecordedContext } from "@bananapus/core-v5/structs/JBAfterCashOutRecordedContext.sol";
import { JBAfterPayRecordedContext } from "@bananapus/core-v5/structs/JBAfterPayRecordedContext.sol";
import { JBCashOutHookSpecification } from "@bananapus/core-v5/structs/JBCashOutHookSpecification.sol";
import { JBPayHookSpecification } from "@bananapus/core-v5/structs/JBPayHookSpecification.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { JBSplit } from "@bananapus/core-v5/structs/JBSplit.sol";
import { JBTokenAmount } from "@bananapus/core-v5/structs/JBTokenAmount.sol";
import { JBConstants } from "@bananapus/core-v5/libraries/JBConstants.sol";

import { ICobuildCommunityTerminal } from "src/interfaces/ICobuildCommunityTerminal.sol";
import { ICobuildSplitHook } from "src/interfaces/ICobuildSplitHook.sol";
import { ICommunityGoalRegistry } from "src/tcr/interfaces/ICommunityGoalRegistry.sol";

/// @notice Canonical shared community terminal that mints community tokens and routes reserved-token splits into child goals.
/// @dev Each community binds a fixed split hook plus payment-source config once. Native pays can either mint directly
/// on this terminal or recursively acquire the registered payment token through another community or external native terminal.
contract CobuildCommunityTerminal is ICobuildCommunityTerminal, IJBCashOutTerminal, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant RESERVED_TOKENS_GROUP_ID = 1;

    struct CommunityConfig {
        ICobuildSplitHook splitHook;
        address paymentToken;
        uint8 paymentTokenDecimals;
        uint256 paymentSourceRevnetId;
        bool directNativeAllowed;
        bool exists;
    }

    struct CommunityPayMetadata {
        uint256[] goalIds;
        uint32[] weights;
        bytes jbMetadata;
    }

    IJBDirectory public immutable DIRECTORY;
    IJBTerminalStore public immutable STORE;
    address public immutable approvedFactory;

    mapping(uint256 communityRevnetId => CommunityConfig config) private _communityConfigOf;

    error ADDRESS_ZERO();
    error NOT_A_CONTRACT(address account);
    error UNAUTHORIZED(address expected, address actual);
    error NO_VALUE();
    error INCORRECT_VALUE();
    error UNSUPPORTED_TOKEN(address token);
    error COMMUNITY_NOT_REGISTERED(uint256 communityRevnetId);
    error COMMUNITY_ALREADY_REGISTERED(uint256 communityRevnetId);
    error INVALID_PROJECT(uint256 expectedProjectId, uint256 actualProjectId);
    error INVALID_COMMUNITY_TOKEN(address expectedToken, address actualToken);
    error INVALID_ROUTE_SETTER(address expectedRouteSetter, address actualRouteSetter);
    error INVALID_DIRECTORY(address expectedDirectory, address actualDirectory);
    error INVALID_PAYMENT_SOURCE(uint256 paymentSourceRevnetId, address expectedToken, address actualToken);
    error INVALID_NATIVE_TERMINAL(address expectedTerminal, address actualTerminal);
    error INVALID_PAYMENT_TERMINAL(address expectedTerminal, address actualTerminal);
    error INVALID_RESERVED_SPLIT_COUNT(uint256 expectedCount, uint256 actualCount);
    error INVALID_RESERVED_SPLIT_PERCENT(uint256 expectedPercent, uint256 actualPercent);
    error NO_PAYMENT_ETH_TERMINAL(uint256 paymentSourceRevnetId);
    error PAYMENT_SOURCE_NOT_REGISTERED(uint256 paymentSourceRevnetId);
    error ZERO_PAYMENT_OUT();
    error ROUTE_NOT_CONSUMED();
    error NO_CONTROLLER(uint256 communityRevnetId);
    error UNAUTHORIZED_FACTORY(address expectedFactory, address actualFactory);
    error UNDER_MIN_TOKENS_RECLAIMED(uint256 reclaimAmount, uint256 minTokensReclaimed);
    error INSUFFICIENT_RECLAIM_LIQUIDITY(address token, uint256 needed, uint256 have);
    error NATIVE_TRANSFER_FAILED(address to, uint256 amount);
    error INVALID_DIRECT_NATIVE_PAYMENT_SOURCE(
        uint256 expectedPaymentSourceRevnetId,
        uint256 actualPaymentSourceRevnetId
    );

    event CommunityRegistered(
        uint256 indexed communityRevnetId,
        address indexed splitHook,
        address indexed paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed,
        address goalRegistry,
        address registrant
    );

    constructor(IJBDirectory directory, IJBTerminalStore store, address approvedFactory_) {
        if (address(directory) == address(0)) revert ADDRESS_ZERO();
        if (address(store) == address(0)) revert ADDRESS_ZERO();
        if (address(directory).code.length == 0) revert NOT_A_CONTRACT(address(directory));
        if (address(store).code.length == 0) revert NOT_A_CONTRACT(address(store));
        if (approvedFactory_ != address(0) && approvedFactory_.code.length == 0) {
            revert NOT_A_CONTRACT(approvedFactory_);
        }
        if (store.DIRECTORY() != directory) revert INVALID_DIRECTORY(address(directory), address(store.DIRECTORY()));

        DIRECTORY = directory;
        STORE = store;
        approvedFactory = approvedFactory_;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return
            interfaceId == type(ICobuildCommunityTerminal).interfaceId ||
            interfaceId == type(IJBCashOutTerminal).interfaceId ||
            interfaceId == type(IJBTerminal).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function communityConfigOf(
        uint256 communityRevnetId
    )
        external
        view
        returns (
            ICobuildSplitHook splitHook,
            address paymentToken,
            uint256 paymentSourceRevnetId,
            bool directNativeAllowed,
            bool exists
        )
    {
        CommunityConfig storage config = _communityConfigOf[communityRevnetId];
        return (
            config.splitHook,
            config.paymentToken,
            config.paymentSourceRevnetId,
            config.directNativeAllowed,
            config.exists
        );
    }

    function registerCommunity(
        uint256 communityRevnetId,
        ICobuildSplitHook splitHook,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed
    ) external {
        _registerCommunity(
            msg.sender,
            communityRevnetId,
            splitHook,
            paymentToken,
            paymentSourceRevnetId,
            directNativeAllowed
        );
    }

    function registerCommunityFromFactory(
        address registrant,
        uint256 communityRevnetId,
        ICobuildSplitHook splitHook,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed
    ) external {
        address factory = approvedFactory;
        if (msg.sender != factory) revert UNAUTHORIZED_FACTORY(factory, msg.sender);

        _registerCommunity(
            registrant,
            communityRevnetId,
            splitHook,
            paymentToken,
            paymentSourceRevnetId,
            directNativeAllowed
        );
    }

    function _registerCommunity(
        address registrant,
        uint256 communityRevnetId,
        ICobuildSplitHook splitHook,
        address paymentToken,
        uint256 paymentSourceRevnetId,
        bool directNativeAllowed
    ) internal {
        if (address(splitHook) == address(0)) revert ADDRESS_ZERO();
        if (paymentToken == address(0)) revert ADDRESS_ZERO();
        if (communityRevnetId == 0 || paymentSourceRevnetId == 0) revert ADDRESS_ZERO();
        if (address(splitHook).code.length == 0) revert NOT_A_CONTRACT(address(splitHook));
        if (paymentToken.code.length == 0) revert NOT_A_CONTRACT(paymentToken);
        if (_communityConfigOf[communityRevnetId].exists) revert COMMUNITY_ALREADY_REGISTERED(communityRevnetId);

        address goalRegistryAddress = splitHook.goalRegistry();
        if (goalRegistryAddress == address(0)) revert ADDRESS_ZERO();
        if (goalRegistryAddress.code.length == 0) revert NOT_A_CONTRACT(goalRegistryAddress);

        ICommunityGoalRegistry goalRegistry = ICommunityGoalRegistry(goalRegistryAddress);
        uint256 registeredCommunityRevnetId = goalRegistry.communityRevnetId();
        if (registeredCommunityRevnetId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, registeredCommunityRevnetId);
        }
        IJBDirectory goalRegistryDirectory = goalRegistry.directory();
        if (goalRegistryDirectory != DIRECTORY) {
            revert INVALID_DIRECTORY(address(DIRECTORY), address(goalRegistryDirectory));
        }
        address projectOwner = DIRECTORY.PROJECTS().ownerOf(communityRevnetId);
        if (registrant != projectOwner) revert UNAUTHORIZED(projectOwner, registrant);

        address registeredCommunityToken = goalRegistry.communityToken();
        address configuredCommunityToken = splitHook.communityToken();
        if (configuredCommunityToken != registeredCommunityToken) {
            revert INVALID_COMMUNITY_TOKEN(registeredCommunityToken, configuredCommunityToken);
        }

        _requireSplitHookConfiguration(splitHook, communityRevnetId);
        _requireLiveReservedSplitHook(splitHook, communityRevnetId);
        _requireCanonicalCommunityTerminals(communityRevnetId, paymentToken);
        if (directNativeAllowed && paymentSourceRevnetId != communityRevnetId) {
            revert INVALID_DIRECT_NATIVE_PAYMENT_SOURCE(communityRevnetId, paymentSourceRevnetId);
        }
        _requirePaymentSource(paymentSourceRevnetId, paymentToken, !directNativeAllowed);

        _communityConfigOf[communityRevnetId] = CommunityConfig({
            splitHook: splitHook,
            paymentToken: paymentToken,
            paymentTokenDecimals: IERC20Metadata(paymentToken).decimals(),
            paymentSourceRevnetId: paymentSourceRevnetId,
            directNativeAllowed: directNativeAllowed,
            exists: true
        });

        emit CommunityRegistered(
            communityRevnetId,
            address(splitHook),
            paymentToken,
            paymentSourceRevnetId,
            directNativeAllowed,
            goalRegistryAddress,
            registrant
        );
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    ) external payable override nonReentrant returns (uint256 beneficiaryTokenCount) {
        CommunityConfig storage config = _communityConfigOf[projectId];
        if (!config.exists) revert COMMUNITY_NOT_REGISTERED(projectId);

        CommunityPayMetadata memory payMetadata = _decodePayMetadata(metadata);
        if (token == JBConstants.NATIVE_TOKEN) {
            if (msg.value == 0) revert NO_VALUE();
            if (msg.value != amount) revert INCORRECT_VALUE();
            return
                _payWithEth(
                    config,
                    projectId,
                    msg.sender,
                    msg.sender,
                    amount,
                    beneficiary,
                    minReturnedTokens,
                    memo,
                    payMetadata
                );
        }

        if (token == config.paymentToken) {
            if (msg.value != 0) revert INCORRECT_VALUE();
            return
                _payWithPaymentToken(
                    config,
                    projectId,
                    msg.sender,
                    msg.sender,
                    amount,
                    beneficiary,
                    minReturnedTokens,
                    memo,
                    payMetadata
                );
        }

        revert UNSUPPORTED_TOKEN(token);
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    ) external override nonReentrant returns (uint256 reclaimAmount) {
        CommunityConfig storage config = _communityConfigOf[projectId];
        if (!config.exists) revert COMMUNITY_NOT_REGISTERED(projectId);
        if (beneficiary == address(0)) revert ADDRESS_ZERO();
        if (holder != msg.sender) revert UNAUTHORIZED(holder, msg.sender);
        if (tokenToReclaim != JBConstants.NATIVE_TOKEN && tokenToReclaim != config.paymentToken) {
            revert UNSUPPORTED_TOKEN(tokenToReclaim);
        }

        JBAccountingContext memory accountingContext = _accountingContextFor(config, tokenToReclaim);
        JBAccountingContext[] memory balanceAccountingContexts = _defaultAccountingContexts(config);

        (
            JBRuleset memory ruleset,
            uint256 recordedReclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) = STORE.recordCashOutFor(
                holder,
                projectId,
                cashOutCount,
                accountingContext,
                balanceAccountingContexts,
                metadata
            );

        if (cashOutCount != 0) _controllerOf(projectId).burnTokensOf(holder, projectId, cashOutCount, "");

        uint256 totalOutbound = _totalCashOutOutbound(recordedReclaimAmount, hookSpecifications);
        _requireAvailableBalance(tokenToReclaim, totalOutbound);

        if (recordedReclaimAmount < minTokensReclaimed) {
            revert UNDER_MIN_TOKENS_RECLAIMED(recordedReclaimAmount, minTokensReclaimed);
        }

        if (recordedReclaimAmount != 0) {
            _transferAccountingToken(tokenToReclaim, beneficiary, recordedReclaimAmount);
        }

        if (hookSpecifications.length != 0) {
            _fulfillCashOutHookSpecificationsFor(
                projectId,
                hookSpecifications,
                holder,
                cashOutCount,
                ruleset,
                accountingContext,
                beneficiary,
                recordedReclaimAmount,
                cashOutTaxRate,
                metadata
            );
        }

        reclaimAmount = recordedReclaimAmount;

        emit CashOutTokens(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            holder,
            beneficiary,
            cashOutCount,
            cashOutTaxRate,
            reclaimAmount,
            metadata,
            msg.sender
        );
    }

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    ) external view override returns (JBAccountingContext memory context) {
        CommunityConfig storage config = _communityConfigOf[projectId];
        context = _accountingContextFor(config, token);
    }

    function accountingContextsOf(
        uint256 projectId
    ) external view override returns (JBAccountingContext[] memory contexts) {
        CommunityConfig storage config = _communityConfigOf[projectId];
        if (!config.exists) return new JBAccountingContext[](0);

        contexts = _defaultAccountingContexts(config);
    }

    function currentSurplusOf(
        uint256 projectId,
        JBAccountingContext[] memory accountingContexts,
        uint256 decimals,
        uint256 currency
    ) external view override returns (uint256 surplus) {
        if (accountingContexts.length != 0) {
            return STORE.currentSurplusOf(address(this), projectId, accountingContexts, decimals, currency);
        }

        CommunityConfig storage config = _communityConfigOf[projectId];
        if (!config.exists) return 0;

        return STORE.currentSurplusOf(address(this), projectId, _defaultAccountingContexts(config), decimals, currency);
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool,
        string calldata memo,
        bytes calldata metadata
    ) external payable override nonReentrant {
        CommunityConfig storage config = _communityConfigOf[projectId];
        if (!config.exists) revert COMMUNITY_NOT_REGISTERED(projectId);

        uint256 accountedAmount = _receiveAccountingTokens(config, token, amount);
        STORE.recordAddedBalanceFor(projectId, token, accountedAmount);
        emit AddToBalance(projectId, accountedAmount, 0, memo, metadata, msg.sender);
    }

    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    ) external override nonReentrant returns (uint256 balance) {
        address projectOwner = DIRECTORY.PROJECTS().ownerOf(projectId);
        if (msg.sender != projectOwner) revert UNAUTHORIZED(projectOwner, msg.sender);
        if (to.accountingContextForTokenOf(projectId, token).token == address(0)) revert UNSUPPORTED_TOKEN(token);

        balance = STORE.recordTerminalMigration(projectId, token);
        emit MigrateTerminal(projectId, token, to, balance, msg.sender);
        if (balance == 0) return 0;

        if (token == JBConstants.NATIVE_TOKEN) {
            to.addToBalanceOf{ value: balance }(projectId, token, balance, false, "", bytes(""));
            return balance;
        }

        IERC20 tokenRef = IERC20(token);
        tokenRef.forceApprove(address(to), 0);
        tokenRef.forceApprove(address(to), balance);
        to.addToBalanceOf(projectId, token, balance, false, "", bytes(""));
        tokenRef.forceApprove(address(to), 0);
    }

    function _payWithEth(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        address payer,
        address caller,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        CommunityPayMetadata memory payMetadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        if (config.directNativeAllowed) {
            return
                _payWithHeldAmount(
                    config,
                    communityRevnetId,
                    payer,
                    caller,
                    JBConstants.NATIVE_TOKEN,
                    amount,
                    beneficiary,
                    minReturnedTokens,
                    memo,
                    payMetadata
                );
        }

        uint256 paymentReceived = _receivePaymentTokensFromEth(config, amount, memo);
        return
            _payWithHeldAmount(
                config,
                communityRevnetId,
                payer,
                caller,
                config.paymentToken,
                paymentReceived,
                beneficiary,
                minReturnedTokens,
                memo,
                payMetadata
            );
    }

    function _receivePaymentTokensFromEth(
        CommunityConfig storage config,
        uint256 amount,
        string calldata memo
    ) internal returns (uint256 paymentReceived) {
        IJBTerminal paymentEthTerminal = DIRECTORY.primaryTerminalOf(
            config.paymentSourceRevnetId,
            JBConstants.NATIVE_TOKEN
        );
        if (address(paymentEthTerminal) == address(0)) revert NO_PAYMENT_ETH_TERMINAL(config.paymentSourceRevnetId);

        IERC20 paymentTokenRef = IERC20(config.paymentToken);
        uint256 paymentBalanceBefore = paymentTokenRef.balanceOf(address(this));

        if (address(paymentEthTerminal) == address(this)) {
            CommunityConfig storage sourceConfig = _communityConfigOf[config.paymentSourceRevnetId];
            if (!sourceConfig.exists) revert PAYMENT_SOURCE_NOT_REGISTERED(config.paymentSourceRevnetId);
            _payWithEth(
                sourceConfig,
                config.paymentSourceRevnetId,
                address(this),
                address(this),
                amount,
                address(this),
                1,
                memo,
                _emptyPayMetadata()
            );
        } else {
            paymentEthTerminal.pay{ value: amount }(
                config.paymentSourceRevnetId,
                JBConstants.NATIVE_TOKEN,
                amount,
                address(this),
                1,
                memo,
                bytes("")
            );
        }

        paymentReceived = paymentTokenRef.balanceOf(address(this)) - paymentBalanceBefore;
        if (paymentReceived == 0) revert ZERO_PAYMENT_OUT();
    }

    function _payWithPaymentToken(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        address payer,
        address caller,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        CommunityPayMetadata memory payMetadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        IERC20 paymentTokenRef = IERC20(config.paymentToken);
        uint256 paymentBalanceBefore = paymentTokenRef.balanceOf(address(this));
        paymentTokenRef.safeTransferFrom(msg.sender, address(this), amount);
        uint256 paymentReceived = paymentTokenRef.balanceOf(address(this)) - paymentBalanceBefore;
        if (paymentReceived == 0) revert ZERO_PAYMENT_OUT();

        beneficiaryTokenCount = _payWithHeldAmount(
            config,
            communityRevnetId,
            payer,
            caller,
            config.paymentToken,
            paymentReceived,
            beneficiary,
            minReturnedTokens,
            memo,
            payMetadata
        );
    }

    function _payWithHeldAmount(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        address payer,
        address caller,
        address accountingToken,
        uint256 paymentAmount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        CommunityPayMetadata memory payMetadata
    ) internal returns (uint256 beneficiaryTokenCount) {
        (
            IJBController controller,
            uint256 pendingReservedTokenBalance,
            uint256 hookBacklogTokenCount,
            uint256 hookSplitPercent
        ) = _beginRoute(config, communityRevnetId, payer, beneficiary, payMetadata.goalIds, payMetadata.weights);

        bytes memory jbMetadata = payMetadata.jbMetadata;
        JBTokenAmount memory tokenAmount = _tokenAmountFrom(config, accountingToken, paymentAmount);
        (JBRuleset memory ruleset, uint256 tokenCount, JBPayHookSpecification[] memory hookSpecifications) = STORE
            .recordPaymentFrom(payer, tokenAmount, communityRevnetId, beneficiary, jbMetadata);
        if (tokenCount != 0) {
            beneficiaryTokenCount = controller.mintTokensOf(communityRevnetId, tokenCount, beneficiary, "", true);
        }
        if (beneficiaryTokenCount < minReturnedTokens) revert ZERO_PAYMENT_OUT();

        emit Pay(
            ruleset.id,
            ruleset.cycleNumber,
            communityRevnetId,
            payer,
            beneficiary,
            paymentAmount,
            beneficiaryTokenCount,
            memo,
            jbMetadata,
            caller
        );

        if (hookSpecifications.length != 0) {
            _fulfillPayHookSpecificationsFor(
                communityRevnetId,
                hookSpecifications,
                tokenAmount,
                payer,
                caller,
                ruleset,
                beneficiary,
                beneficiaryTokenCount,
                jbMetadata
            );
        }

        _finishRoute(
            config.splitHook,
            controller,
            communityRevnetId,
            pendingReservedTokenBalance,
            hookBacklogTokenCount,
            hookSplitPercent
        );
    }

    function _beginRoute(
        CommunityConfig storage config,
        uint256 communityRevnetId,
        address payer,
        address beneficiary,
        uint256[] memory goalIds,
        uint32[] memory weights
    )
        internal
        returns (
            IJBController controller,
            uint256 pendingReservedTokenBalance,
            uint256 hookBacklogTokenCount,
            uint256 hookSplitPercent
        )
    {
        _requireSplitHookConfiguration(config.splitHook, communityRevnetId);

        controller = _controllerOf(communityRevnetId);
        hookSplitPercent = _requireLiveReservedSplitHook(config.splitHook, communityRevnetId);
        pendingReservedTokenBalance = controller.pendingReservedTokenBalanceOf(communityRevnetId);
        hookBacklogTokenCount = _reservedTokenShareOf(pendingReservedTokenBalance, hookSplitPercent);

        if (goalIds.length != 0) {
            config.splitHook.beginPendingRoute(payer, beneficiary, hookBacklogTokenCount, goalIds, weights);
        }
    }

    function _finishRoute(
        ICobuildSplitHook splitHook,
        IJBController controller,
        uint256 communityRevnetId,
        uint256 pendingReservedTokenBalanceBeforePay,
        uint256 hookBacklogTokenCount,
        uint256 hookSplitPercent
    ) internal {
        uint256 pendingReservedTokenBalance = controller.pendingReservedTokenBalanceOf(communityRevnetId);
        if (pendingReservedTokenBalance <= pendingReservedTokenBalanceBeforePay) {
            if (splitHook.hasPendingRoute()) splitHook.cancelPendingRoute();
            return;
        }

        uint256 liveHookSplitPercent = _requireLiveReservedSplitHook(splitHook, communityRevnetId);
        if (liveHookSplitPercent != hookSplitPercent) {
            revert INVALID_RESERVED_SPLIT_PERCENT(hookSplitPercent, liveHookSplitPercent);
        }

        uint256 hookPendingReservedTokenBalance = _reservedTokenShareOf(
            pendingReservedTokenBalance,
            liveHookSplitPercent
        );
        if (hookPendingReservedTokenBalance <= hookBacklogTokenCount && splitHook.hasPendingRoute()) {
            splitHook.cancelPendingRoute();
        }

        controller.sendReservedTokensToSplitsOf(communityRevnetId);
        if (splitHook.hasPendingRoute()) revert ROUTE_NOT_CONSUMED();
    }

    function _controllerOf(uint256 communityRevnetId) internal view returns (IJBController controller) {
        address controllerAddress = address(DIRECTORY.controllerOf(communityRevnetId));
        if (controllerAddress == address(0)) revert NO_CONTROLLER(communityRevnetId);
        if (controllerAddress.code.length == 0) revert NOT_A_CONTRACT(controllerAddress);

        controller = IJBController(controllerAddress);
    }

    function _requireSplitHookConfiguration(ICobuildSplitHook splitHook, uint256 communityRevnetId) internal view {
        uint256 configuredCommunityRevnetId = splitHook.communityRevnetId();
        if (configuredCommunityRevnetId != communityRevnetId) {
            revert INVALID_PROJECT(communityRevnetId, configuredCommunityRevnetId);
        }

        address configuredRouteSetter = splitHook.routeSetter();
        if (configuredRouteSetter != address(this)) {
            revert INVALID_ROUTE_SETTER(address(this), configuredRouteSetter);
        }
    }

    function _requireLiveReservedSplitHook(
        ICobuildSplitHook splitHook,
        uint256 communityRevnetId
    ) internal view returns (uint256 hookSplitPercent) {
        IJBController controller = _controllerOf(communityRevnetId);
        (JBRuleset memory ruleset, ) = controller.currentRulesetOf(communityRevnetId);
        JBSplit[] memory reservedSplits = controller.SPLITS().splitsOf(
            communityRevnetId,
            ruleset.id,
            RESERVED_TOKENS_GROUP_ID
        );

        uint256 matchingSplitCount;
        for (uint256 i; i < reservedSplits.length; i++) {
            JBSplit memory reservedSplit = reservedSplits[i];
            if (reservedSplit.percent == 0) continue;
            if (address(reservedSplit.hook) != address(splitHook)) continue;

            matchingSplitCount += 1;
            hookSplitPercent = reservedSplit.percent;
        }

        if (matchingSplitCount != 1) revert INVALID_RESERVED_SPLIT_COUNT(1, matchingSplitCount);
    }

    function _reservedTokenShareOf(uint256 reservedTokenBalance, uint256 splitPercent) internal pure returns (uint256) {
        if (reservedTokenBalance == 0 || splitPercent == 0) return 0;
        return (reservedTokenBalance * splitPercent) / uint256(JBConstants.SPLITS_TOTAL_PERCENT);
    }

    function _requireCanonicalCommunityTerminals(uint256 communityRevnetId, address paymentToken) internal view {
        address actualNativeTerminal = address(
            DIRECTORY.primaryTerminalOf(communityRevnetId, JBConstants.NATIVE_TOKEN)
        );
        if (actualNativeTerminal != address(this)) {
            revert INVALID_NATIVE_TERMINAL(address(this), actualNativeTerminal);
        }

        address actualPaymentTerminal = address(DIRECTORY.primaryTerminalOf(communityRevnetId, paymentToken));
        if (actualPaymentTerminal != address(this)) {
            revert INVALID_PAYMENT_TERMINAL(address(this), actualPaymentTerminal);
        }
    }

    function _requirePaymentSource(
        uint256 paymentSourceRevnetId,
        address paymentToken,
        bool requireRegisteredIfSelf
    ) internal view {
        IJBController controller = _controllerOf(paymentSourceRevnetId);
        address paymentSourceToken = address(controller.TOKENS().tokenOf(paymentSourceRevnetId));
        if (paymentSourceToken != paymentToken) {
            revert INVALID_PAYMENT_SOURCE(paymentSourceRevnetId, paymentToken, paymentSourceToken);
        }

        IJBTerminal paymentEthTerminal = DIRECTORY.primaryTerminalOf(paymentSourceRevnetId, JBConstants.NATIVE_TOKEN);
        if (address(paymentEthTerminal) == address(0)) revert NO_PAYMENT_ETH_TERMINAL(paymentSourceRevnetId);
        if (requireRegisteredIfSelf && address(paymentEthTerminal) == address(this)) {
            if (!_communityConfigOf[paymentSourceRevnetId].exists) {
                revert PAYMENT_SOURCE_NOT_REGISTERED(paymentSourceRevnetId);
            }
        }
    }

    function _decodePayMetadata(
        bytes calldata metadata
    ) internal pure returns (CommunityPayMetadata memory payMetadata) {
        if (metadata.length == 0) return _emptyPayMetadata();
        (payMetadata.goalIds, payMetadata.weights, payMetadata.jbMetadata) = abi.decode(
            metadata,
            (uint256[], uint32[], bytes)
        );
    }

    function _emptyPayMetadata() internal pure returns (CommunityPayMetadata memory payMetadata) {
        payMetadata = CommunityPayMetadata({
            goalIds: new uint256[](0),
            weights: new uint32[](0),
            jbMetadata: bytes("")
        });
    }

    function _nativeAccountingContext() internal pure returns (JBAccountingContext memory) {
        return
            JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: _currencyFromToken(JBConstants.NATIVE_TOKEN)
            });
    }

    function _defaultAccountingContexts(
        CommunityConfig storage config
    ) internal view returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](2);
        contexts[0] = _nativeAccountingContext();
        contexts[1] = _paymentTokenAccountingContext(config);
    }

    function _accountingContextFor(
        CommunityConfig storage config,
        address token
    ) internal view returns (JBAccountingContext memory) {
        if (token == JBConstants.NATIVE_TOKEN) return _nativeAccountingContext();
        if (token == config.paymentToken) return _paymentTokenAccountingContext(config);
        if (!config.exists) return _erc20AccountingContext(token);

        return JBAccountingContext({ token: address(0), decimals: 0, currency: 0 });
    }

    function _paymentTokenAccountingContext(
        CommunityConfig storage config
    ) internal view returns (JBAccountingContext memory) {
        return _erc20AccountingContext(config.paymentToken, config.paymentTokenDecimals);
    }

    function _erc20AccountingContext(address token) internal view returns (JBAccountingContext memory context) {
        if (token.code.length == 0) return JBAccountingContext({ token: address(0), decimals: 0, currency: 0 });

        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return _erc20AccountingContext(token, decimals);
        } catch {
            return JBAccountingContext({ token: address(0), decimals: 0, currency: 0 });
        }
    }

    function _erc20AccountingContext(
        address token,
        uint8 decimals
    ) internal pure returns (JBAccountingContext memory context) {
        context = JBAccountingContext({ token: token, decimals: decimals, currency: _currencyFromToken(token) });
    }

    function _currencyFromToken(address token) internal pure returns (uint32 currency) {
        assembly {
            currency := and(token, 0xffffffff)
        }
    }

    function _receiveAccountingTokens(
        CommunityConfig storage config,
        address token,
        uint256 amount
    ) internal returns (uint256 accountedAmount) {
        if (token == JBConstants.NATIVE_TOKEN) {
            if (msg.value == 0) revert NO_VALUE();
            if (msg.value != amount) revert INCORRECT_VALUE();
            return amount;
        }

        if (token != config.paymentToken) revert UNSUPPORTED_TOKEN(token);
        if (msg.value != 0) revert INCORRECT_VALUE();

        IERC20 paymentTokenRef = IERC20(token);
        uint256 balanceBefore = paymentTokenRef.balanceOf(address(this));
        paymentTokenRef.safeTransferFrom(msg.sender, address(this), amount);
        accountedAmount = paymentTokenRef.balanceOf(address(this)) - balanceBefore;
        if (accountedAmount == 0) revert ZERO_PAYMENT_OUT();
    }

    function _tokenAmountFrom(
        CommunityConfig storage config,
        address token,
        uint256 amount
    ) internal view returns (JBTokenAmount memory tokenAmount) {
        JBAccountingContext memory accountingContext = _accountingContextFor(config, token);

        tokenAmount = JBTokenAmount({
            token: accountingContext.token,
            decimals: accountingContext.decimals,
            currency: accountingContext.currency,
            value: amount
        });
    }

    function _fulfillPayHookSpecificationsFor(
        uint256 projectId,
        JBPayHookSpecification[] memory specifications,
        JBTokenAmount memory tokenAmount,
        address payer,
        address caller,
        JBRuleset memory ruleset,
        address beneficiary,
        uint256 newlyIssuedTokenCount,
        bytes memory payerMetadata
    ) internal {
        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: ruleset.id,
            amount: tokenAmount,
            forwardedAmount: tokenAmount,
            weight: ruleset.weight,
            newlyIssuedTokenCount: newlyIssuedTokenCount,
            beneficiary: beneficiary,
            hookMetadata: bytes(""),
            payerMetadata: payerMetadata
        });

        uint256 specificationsLength = specifications.length;
        for (uint256 i; i < specificationsLength; i++) {
            JBPayHookSpecification memory specification = specifications[i];
            context.forwardedAmount = JBTokenAmount({
                token: tokenAmount.token,
                decimals: tokenAmount.decimals,
                currency: tokenAmount.currency,
                value: specification.amount
            });
            context.hookMetadata = specification.metadata;

            uint256 payValue = _beforeTransferTo(address(specification.hook), tokenAmount.token, specification.amount);
            specification.hook.afterPayRecordedWith{ value: payValue }(context);
            _afterTransferTo(address(specification.hook), tokenAmount.token);

            emit HookAfterRecordPay(IJBPayHook(specification.hook), context, specification.amount, caller);
        }
    }

    function _fulfillCashOutHookSpecificationsFor(
        uint256 projectId,
        JBCashOutHookSpecification[] memory specifications,
        address holder,
        uint256 cashOutCount,
        JBRuleset memory ruleset,
        JBAccountingContext memory accountingContext,
        address payable beneficiary,
        uint256 reclaimAmount,
        uint256 cashOutTaxRate,
        bytes memory cashOutMetadata
    ) internal {
        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: holder,
            projectId: projectId,
            rulesetId: ruleset.id,
            cashOutCount: cashOutCount,
            reclaimedAmount: JBTokenAmount({
                token: accountingContext.token,
                decimals: accountingContext.decimals,
                currency: accountingContext.currency,
                value: reclaimAmount
            }),
            forwardedAmount: JBTokenAmount({
                token: accountingContext.token,
                decimals: accountingContext.decimals,
                currency: accountingContext.currency,
                value: 0
            }),
            cashOutTaxRate: cashOutTaxRate,
            beneficiary: beneficiary,
            hookMetadata: bytes(""),
            cashOutMetadata: cashOutMetadata
        });

        uint256 specificationsLength = specifications.length;
        for (uint256 i; i < specificationsLength; i++) {
            JBCashOutHookSpecification memory specification = specifications[i];
            context.forwardedAmount = JBTokenAmount({
                token: accountingContext.token,
                decimals: accountingContext.decimals,
                currency: accountingContext.currency,
                value: specification.amount
            });
            context.hookMetadata = specification.metadata;

            uint256 payValue = _beforeTransferTo(
                address(specification.hook),
                accountingContext.token,
                specification.amount
            );
            specification.hook.afterCashOutRecordedWith{ value: payValue }(context);
            _afterTransferTo(address(specification.hook), accountingContext.token);

            emit HookAfterRecordCashOut(
                IJBCashOutHook(specification.hook),
                context,
                specification.amount,
                0,
                msg.sender
            );
        }
    }

    function _totalCashOutOutbound(
        uint256 reclaimAmount,
        JBCashOutHookSpecification[] memory specifications
    ) internal pure returns (uint256 totalOutbound) {
        totalOutbound = reclaimAmount;

        uint256 specificationsLength = specifications.length;
        for (uint256 i; i < specificationsLength; i++) {
            totalOutbound += specifications[i].amount;
        }
    }

    function _requireAvailableBalance(address token, uint256 needed) internal view {
        if (needed == 0) return;

        uint256 have = _balanceOf(token);
        if (have < needed) revert INSUFFICIENT_RECLAIM_LIQUIDITY(token, needed, have);
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == JBConstants.NATIVE_TOKEN) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function _transferAccountingToken(address token, address payable beneficiary, uint256 amount) internal {
        if (amount == 0) return;

        if (token == JBConstants.NATIVE_TOKEN) {
            (bool success, ) = beneficiary.call{ value: amount }("");
            if (!success) revert NATIVE_TRANSFER_FAILED(beneficiary, amount);
            return;
        }

        IERC20(token).safeTransfer(beneficiary, amount);
    }

    function _beforeTransferTo(address to, address token, uint256 amount) internal returns (uint256 payValue) {
        if (token == JBConstants.NATIVE_TOKEN) return amount;

        IERC20(token).safeIncreaseAllowance(to, amount);
        return 0;
    }

    function _afterTransferTo(address to, address token) internal {
        if (token == JBConstants.NATIVE_TOKEN) return;

        IERC20(token).forceApprove(to, 0);
    }
}
