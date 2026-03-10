// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CobuildPaymentTerminal} from "src/juicebox/CobuildPaymentTerminal.sol";
import {ICobuildSplitHook} from "src/interfaces/ICobuildSplitHook.sol";

import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v5/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core-v5/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

contract CobuildPaymentTerminalTest is Test {
    uint256 internal constant COBUILD_REVNET_ID = 138;
    uint256 internal constant COMMUNITY_REVNET_ID = 777;

    CobuildPaymentTerminalMockToken internal cobuildToken;
    CobuildPaymentTerminalMockDirectory internal directory;
    CobuildPaymentTerminalMockController internal controller;
    CobuildPaymentTerminalMockCobuildEthTerminal internal sourceTerminal;
    CobuildPaymentTerminalMockSplitHook internal splitHook;
    CobuildPaymentTerminalMockCommunityTerminal internal destinationTerminal;
    CobuildPaymentTerminal internal paymentTerminal;

    function setUp() public {
        cobuildToken = new CobuildPaymentTerminalMockToken("Cobuild", "COB");
        directory = new CobuildPaymentTerminalMockDirectory();
        sourceTerminal = new CobuildPaymentTerminalMockCobuildEthTerminal(cobuildToken);
        splitHook = new CobuildPaymentTerminalMockSplitHook(COMMUNITY_REVNET_ID, address(cobuildToken));
        controller = new CobuildPaymentTerminalMockController(splitHook);
        destinationTerminal = new CobuildPaymentTerminalMockCommunityTerminal(cobuildToken, controller);

        directory.setPrimaryTerminal(COBUILD_REVNET_ID, JBConstants.NATIVE_TOKEN, IJBTerminal(address(sourceTerminal)));
        directory.setPrimaryTerminal(
            COMMUNITY_REVNET_ID, address(cobuildToken), IJBTerminal(address(destinationTerminal))
        );
        directory.setController(COMMUNITY_REVNET_ID, IJBController(address(controller)));

        paymentTerminal = new CobuildPaymentTerminal(
            IJBDirectory(address(directory)),
            ICobuildSplitHook(address(splitHook)),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            COMMUNITY_REVNET_ID
        );
        splitHook.setRouteSetter(address(paymentTerminal));
    }

    function test_payWithEth_setsPendingExplicitRoute_andFlushesReservedTokens() public {
        destinationTerminal.setReturnedTokenCount(1 ether);

        uint256[] memory goalIds = new uint256[](2);
        goalIds[0] = 11;
        goalIds[1] = 22;

        uint32[] memory weights = new uint32[](2);
        weights[0] = 1;
        weights[1] = 2;

        uint256 beneficiaryTokenCount = paymentTerminal.pay{value: 2 ether}(
            COMMUNITY_REVNET_ID,
            JBConstants.NATIVE_TOKEN,
            2 ether,
            address(this),
            5,
            "community-pay",
            abi.encode(goalIds, weights)
        );

        assertEq(beneficiaryTokenCount, 1 ether);
        assertEq(sourceTerminal.lastPaidAmount(), 2 ether);
        assertEq(sourceTerminal.lastMinReturnedTokens(), 1);
        assertEq(destinationTerminal.lastReceivedCobuild(), 2 ether);
        assertEq(destinationTerminal.lastProjectId(), COMMUNITY_REVNET_ID);
        assertEq(destinationTerminal.lastBeneficiary(), address(this));
        assertEq(destinationTerminal.lastMinReturnedTokens(), 5);
        assertEq(destinationTerminal.lastMetadata().length, 0);
        assertEq(splitHook.beginPendingRouteCallCount(), 1);
        assertEq(splitHook.beginPendingHistoricalRouteCallCount(), 0);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(splitHook.lastBacklogTokenCount(), 0);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
        assertEq(splitHook.lastPayer(), address(this));
        assertEq(splitHook.lastBeneficiary(), address(this));
        assertFalse(splitHook.lastUsesHistoricalDefault());

        uint256[] memory storedGoalIds = splitHook.lastGoalIds();
        uint32[] memory storedWeights = splitHook.lastWeights();
        assertEq(storedGoalIds.length, 2);
        assertEq(storedGoalIds[0], 11);
        assertEq(storedGoalIds[1], 22);
        assertEq(storedWeights.length, 2);
        assertEq(storedWeights[0], 1);
        assertEq(storedWeights[1], 2);
    }

    function test_payWithCobuild_revertsWhenExplicitRouteIsNotConsumed() public {
        uint256[] memory goalIds = new uint256[](1);
        goalIds[0] = 11;

        uint32[] memory weights = new uint32[](1);
        weights[0] = 1;

        destinationTerminal.setReturnedTokenCount(0.5 ether);
        controller.setConsumePendingRouteOnSend(false);
        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(paymentTerminal), 1 ether);

        vm.expectRevert(CobuildPaymentTerminal.ROUTE_NOT_CONSUMED.selector);
        paymentTerminal.pay(
            COMMUNITY_REVNET_ID,
            address(cobuildToken),
            1 ether,
            address(this),
            0,
            "community-pay",
            abi.encode(goalIds, weights)
        );
    }

    function test_payWithCobuild_usesHistoricalPendingRouteWhenMetadataEmpty() public {
        destinationTerminal.setReturnedTokenCount(2 ether);

        cobuildToken.mint(address(this), 5 ether);
        cobuildToken.approve(address(paymentTerminal), 5 ether);

        uint256 beneficiaryTokenCount = paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 2 ether);
        assertEq(destinationTerminal.lastReceivedCobuild(), 5 ether);
        assertEq(splitHook.beginPendingRouteCallCount(), 0);
        assertEq(splitHook.beginPendingHistoricalRouteCallCount(), 1);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(splitHook.lastBacklogTokenCount(), 0);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
        assertEq(splitHook.lastPayer(), address(this));
        assertEq(splitHook.lastBeneficiary(), address(this));
        assertTrue(splitHook.lastUsesHistoricalDefault());
    }

    function test_payWithCobuild_revertsWhenHistoricalRouteIsNotConsumed() public {
        destinationTerminal.setReturnedTokenCount(2 ether);
        controller.setConsumePendingRouteOnSend(false);
        cobuildToken.mint(address(this), 5 ether);
        cobuildToken.approve(address(paymentTerminal), 5 ether);

        vm.expectRevert(CobuildPaymentTerminal.ROUTE_NOT_CONSUMED.selector);
        paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );
    }

    function test_payWithCobuild_cancelsPendingRouteWhenNoReservedTokensWereCreated() public {
        destinationTerminal.setReturnedTokenCount(5 ether);

        cobuildToken.mint(address(this), 5 ether);
        cobuildToken.approve(address(paymentTerminal), 5 ether);

        uint256 beneficiaryTokenCount = paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 5 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 5 ether);
        assertEq(splitHook.beginPendingHistoricalRouteCallCount(), 1);
        assertEq(splitHook.cancelPendingRouteCallCount(), 1);
        assertFalse(splitHook.hasPendingRoute());
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 0);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_pay_startsRouteWithExistingControllerBacklog_andFlushesOnlyWhenNewReservedTokensWereCreated() public {
        controller.setPendingReservedTokenBalance(COMMUNITY_REVNET_ID, 1 ether);
        destinationTerminal.setReturnedTokenCount(0.5 ether);
        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(paymentTerminal), 1 ether);

        uint256 beneficiaryTokenCount = paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 1 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 0.5 ether);
        assertEq(splitHook.lastBacklogTokenCount(), 1 ether);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 1);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 0);
    }

    function test_pay_cancelsPendingRouteWhenControllerBacklogExistsButCurrentPayCreatesNoReservedTokens() public {
        controller.setPendingReservedTokenBalance(COMMUNITY_REVNET_ID, 1 ether);
        destinationTerminal.setReturnedTokenCount(1 ether);
        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(paymentTerminal), 1 ether);

        uint256 beneficiaryTokenCount = paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 1 ether, address(this), 0, "community-pay", bytes("")
        );

        assertEq(beneficiaryTokenCount, 1 ether);
        assertEq(splitHook.lastBacklogTokenCount(), 1 ether);
        assertEq(splitHook.cancelPendingRouteCallCount(), 1);
        assertEq(controller.sendReservedTokensToSplitsCallCount(), 0);
        assertEq(controller.pendingReservedTokenBalanceOf(COMMUNITY_REVNET_ID), 1 ether);
        assertFalse(splitHook.hasPendingRoute());
    }

    function test_pay_revertsWhenProjectIdDoesNotMatchCommunityRevnet() public {
        vm.expectRevert(
            abi.encodeWithSelector(CobuildPaymentTerminal.INVALID_PROJECT.selector, COMMUNITY_REVNET_ID, 999)
        );
        paymentTerminal.pay(999, JBConstants.NATIVE_TOKEN, 1 ether, address(this), 0, "memo", bytes(""));
    }

    function test_constructor_revertsWhenSplitHookIsNotContract() public {
        address nonContract = makeAddr("not-contract");

        vm.expectRevert(abi.encodeWithSelector(CobuildPaymentTerminal.NOT_A_CONTRACT.selector, nonContract));
        new CobuildPaymentTerminal(
            IJBDirectory(address(directory)),
            ICobuildSplitHook(nonContract),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            COMMUNITY_REVNET_ID
        );
    }

    function test_constructor_allowsFactoryBootstrapBeforeHookInitialization() public {
        CobuildPaymentTerminalMockSplitHook bootstrapHook = new CobuildPaymentTerminalMockSplitHook(0, address(0));
        CobuildPaymentTerminal bootstrapTerminal = new CobuildPaymentTerminal(
            IJBDirectory(address(directory)),
            ICobuildSplitHook(address(bootstrapHook)),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            COMMUNITY_REVNET_ID
        );

        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(bootstrapTerminal), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(CobuildPaymentTerminal.INVALID_PROJECT.selector, COMMUNITY_REVNET_ID, 0));
        bootstrapTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 1 ether, address(this), 0, "community-pay", bytes("")
        );
    }

    function test_pay_revertsWhenSplitHookCommunityRevnetIdDoesNotMatchTerminal() public {
        CobuildPaymentTerminalMockSplitHook mismatchedHook =
            new CobuildPaymentTerminalMockSplitHook(COMMUNITY_REVNET_ID + 1, address(cobuildToken));
        CobuildPaymentTerminal mismatchedTerminal = new CobuildPaymentTerminal(
            IJBDirectory(address(directory)),
            ICobuildSplitHook(address(mismatchedHook)),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            COMMUNITY_REVNET_ID
        );
        mismatchedHook.setRouteSetter(address(mismatchedTerminal));
        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(mismatchedTerminal), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_PROJECT.selector, COMMUNITY_REVNET_ID, COMMUNITY_REVNET_ID + 1
            )
        );
        mismatchedTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 1 ether, address(this), 0, "community-pay", bytes("")
        );
    }

    function test_pay_revertsWhenSplitHookCommunityTokenDoesNotMatchTerminal() public {
        CobuildPaymentTerminalMockToken wrongToken = new CobuildPaymentTerminalMockToken("Wrong", "WRONG");
        CobuildPaymentTerminalMockSplitHook mismatchedHook =
            new CobuildPaymentTerminalMockSplitHook(COMMUNITY_REVNET_ID, address(wrongToken));
        CobuildPaymentTerminal mismatchedTerminal = new CobuildPaymentTerminal(
            IJBDirectory(address(directory)),
            ICobuildSplitHook(address(mismatchedHook)),
            address(cobuildToken),
            COBUILD_REVNET_ID,
            COMMUNITY_REVNET_ID
        );
        mismatchedHook.setRouteSetter(address(mismatchedTerminal));
        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(mismatchedTerminal), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_COMMUNITY_TOKEN.selector, address(cobuildToken), address(wrongToken)
            )
        );
        mismatchedTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 1 ether, address(this), 0, "community-pay", bytes("")
        );
    }

    function test_pay_revertsWhenSplitHookRouteSetterDoesNotMatchTerminal() public {
        address wrongRouteSetter = makeAddr("wrong-route-setter");
        splitHook.setRouteSetter(wrongRouteSetter);

        cobuildToken.mint(address(this), 1 ether);
        cobuildToken.approve(address(paymentTerminal), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CobuildPaymentTerminal.INVALID_ROUTE_SETTER.selector, address(paymentTerminal), wrongRouteSetter
            )
        );
        paymentTerminal.pay(
            COMMUNITY_REVNET_ID, address(cobuildToken), 1 ether, address(this), 0, "community-pay", bytes("")
        );
    }
}

contract CobuildPaymentTerminalMockDirectory {
    mapping(uint256 => mapping(address => IJBTerminal)) internal _primaryTerminalOf;
    mapping(uint256 => IJBController) internal _controllerOf;

    function setPrimaryTerminal(uint256 projectId, address token, IJBTerminal terminal) external {
        _primaryTerminalOf[projectId][token] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address token) external view returns (IJBTerminal) {
        return _primaryTerminalOf[projectId][token];
    }

    function setController(uint256 projectId, IJBController controller_) external {
        _controllerOf[projectId] = controller_;
    }

    function controllerOf(uint256 projectId) external view returns (IJBController) {
        return _controllerOf[projectId];
    }
}

contract CobuildPaymentTerminalMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract CobuildPaymentTerminalMockCobuildEthTerminal {
    CobuildPaymentTerminalMockToken internal immutable _token;
    uint256 internal _lastPaidAmount;
    uint256 internal _lastMinReturnedTokens;

    constructor(CobuildPaymentTerminalMockToken token_) {
        _token = token_;
    }

    function pay(
        uint256,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    ) external payable returns (uint256) {
        require(token == JBConstants.NATIVE_TOKEN, "token");
        require(msg.value == amount, "value");

        _lastPaidAmount = amount;
        _lastMinReturnedTokens = minReturnedTokens;
        _token.mint(beneficiary, amount);
        return amount;
    }

    function lastPaidAmount() external view returns (uint256) {
        return _lastPaidAmount;
    }

    function lastMinReturnedTokens() external view returns (uint256) {
        return _lastMinReturnedTokens;
    }
}

contract CobuildPaymentTerminalMockController {
    CobuildPaymentTerminalMockSplitHook internal immutable _splitHook;

    bool internal _consumePendingRouteOnSend = true;
    uint256 internal _sendReservedTokensToSplitsCallCount;
    mapping(uint256 => uint256) internal _pendingReservedTokenBalanceOf;

    constructor(CobuildPaymentTerminalMockSplitHook splitHook_) {
        _splitHook = splitHook_;
    }

    function setConsumePendingRouteOnSend(bool shouldConsume) external {
        _consumePendingRouteOnSend = shouldConsume;
    }

    function setPendingReservedTokenBalance(uint256 projectId, uint256 amount) external {
        _pendingReservedTokenBalanceOf[projectId] = amount;
    }

    function recordReservedTokens(uint256 projectId, uint256 amount) external {
        _pendingReservedTokenBalanceOf[projectId] += amount;
    }

    function pendingReservedTokenBalanceOf(uint256 projectId) external view returns (uint256) {
        return _pendingReservedTokenBalanceOf[projectId];
    }

    function sendReservedTokensToSplitsOf(uint256 projectId) external returns (uint256 tokenCount) {
        _sendReservedTokensToSplitsCallCount += 1;
        tokenCount = _pendingReservedTokenBalanceOf[projectId];
        require(tokenCount != 0, "reserved");

        _pendingReservedTokenBalanceOf[projectId] = 0;
        if (_consumePendingRouteOnSend && _splitHook.hasPendingRoute()) {
            _splitHook.consumePendingRoute();
        }
    }

    function sendReservedTokensToSplitsCallCount() external view returns (uint256) {
        return _sendReservedTokensToSplitsCallCount;
    }
}

contract CobuildPaymentTerminalMockCommunityTerminal {
    CobuildPaymentTerminalMockToken internal immutable _token;
    CobuildPaymentTerminalMockController internal immutable _controller;

    uint256 internal _returnedTokenCount;
    uint256 internal _lastProjectId;
    uint256 internal _lastReceivedCobuild;
    address internal _lastBeneficiary;
    uint256 internal _lastMinReturnedTokens;
    bytes internal _lastMetadata;

    constructor(CobuildPaymentTerminalMockToken token_, CobuildPaymentTerminalMockController controller_) {
        _token = token_;
        _controller = controller_;
        _returnedTokenCount = type(uint256).max;
    }

    function setReturnedTokenCount(uint256 returnedTokenCount_) external {
        _returnedTokenCount = returnedTokenCount_;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata metadata
    ) external returns (uint256 beneficiaryTokenCount) {
        require(token == address(_token), "token");
        _token.transferFrom(msg.sender, address(this), amount);

        _lastProjectId = projectId;
        _lastReceivedCobuild = amount;
        _lastBeneficiary = beneficiary;
        _lastMinReturnedTokens = minReturnedTokens;
        _lastMetadata = metadata;

        beneficiaryTokenCount = _returnedTokenCount == type(uint256).max ? amount : _returnedTokenCount;
        require(beneficiaryTokenCount <= amount, "returned");

        uint256 reservedTokenCount = amount - beneficiaryTokenCount;
        if (reservedTokenCount != 0) {
            _controller.recordReservedTokens(projectId, reservedTokenCount);
        }
    }

    function lastProjectId() external view returns (uint256) {
        return _lastProjectId;
    }

    function lastReceivedCobuild() external view returns (uint256) {
        return _lastReceivedCobuild;
    }

    function lastBeneficiary() external view returns (address) {
        return _lastBeneficiary;
    }

    function lastMinReturnedTokens() external view returns (uint256) {
        return _lastMinReturnedTokens;
    }

    function lastMetadata() external view returns (bytes memory) {
        return _lastMetadata;
    }
}

contract CobuildPaymentTerminalMockSplitHook is ICobuildSplitHook {
    uint256 public immutable override communityRevnetId;
    address public immutable override communityToken;

    address public override routeSetter;
    address public override goalRegistry;
    uint256 public override historicalBacklogAmount;
    bool internal _hasPendingRoute;
    bool internal _lastUsesHistoricalDefault;

    uint256 public beginPendingRouteCallCount;
    uint256 public beginPendingHistoricalRouteCallCount;
    uint256 public cancelPendingRouteCallCount;
    uint256 public lastBacklogTokenCount;
    address public lastPayer;
    address public lastBeneficiary;
    uint256[] internal _lastGoalIds;
    uint32[] internal _lastWeights;

    constructor(uint256 communityRevnetId_, address communityToken_) {
        communityRevnetId = communityRevnetId_;
        communityToken = communityToken_;
        routeSetter = msg.sender;
        goalRegistry = msg.sender;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }

    function observedVolumeOf(uint256) external pure override returns (uint256) {
        return 0;
    }

    function cumulativeObservedVolume() external pure override returns (uint256) {
        return 0;
    }

    function currentHistoricalTotalVolume() external pure override returns (uint256) {
        return 0;
    }

    function selectableGoalIds() external pure override returns (uint256[] memory goalIds) {
        goalIds = new uint256[](0);
    }

    function historicalRoute() external pure override returns (uint256[] memory goalIds, uint256[] memory volumes) {
        goalIds = new uint256[](0);
        volumes = new uint256[](0);
    }

    function historicalBacklogProgress()
        external
        pure
        override
        returns (HistoricalBacklogProgressView memory progress)
    {
        progress = HistoricalBacklogProgressView({
            active: false,
            epoch: 0,
            remainingAmount: 0,
            processedGoalCount: 0
        });
    }

    function pendingRoute() external view override returns (PendingRouteView memory out) {
        out = PendingRouteView({
            payer: lastPayer,
            beneficiary: lastBeneficiary,
            createdAt: 0,
            backlogTokenCount: lastBacklogTokenCount,
            usesHistoricalDefault: _lastUsesHistoricalDefault,
            goalIds: _copyUint256Array(_lastGoalIds),
            weights: _copyUint32Array(_lastWeights)
        });
    }

    function hasPendingRoute() public view override returns (bool) {
        return _hasPendingRoute;
    }

    function beginPendingRoute(
        address payer,
        address beneficiary,
        uint256 backlogTokenCount,
        uint256[] calldata goalIds,
        uint32[] calldata weights
    ) external override {
        beginPendingRouteCallCount += 1;
        _hasPendingRoute = true;
        _lastUsesHistoricalDefault = false;
        lastBacklogTokenCount = backlogTokenCount;
        lastPayer = payer;
        lastBeneficiary = beneficiary;
        _lastGoalIds = _copyUint256Calldata(goalIds);
        _lastWeights = _copyUint32Calldata(weights);
    }

    function beginPendingHistoricalRoute(
        address payer,
        address beneficiary,
        uint256 backlogTokenCount
    ) external override {
        beginPendingHistoricalRouteCallCount += 1;
        _hasPendingRoute = true;
        _lastUsesHistoricalDefault = true;
        lastBacklogTokenCount = backlogTokenCount;
        lastPayer = payer;
        lastBeneficiary = beneficiary;
        delete _lastGoalIds;
        delete _lastWeights;
    }

    function cancelPendingRoute() external override {
        cancelPendingRouteCallCount += 1;
        _hasPendingRoute = false;
    }

    function flushHistoricalBacklog(uint256) external override returns (uint256 routedAmount) {
        routedAmount = historicalBacklogAmount;
        historicalBacklogAmount = 0;
    }

    function setRouteSetter(address routeSetter_) external {
        routeSetter = routeSetter_;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {}

    function consumePendingRoute() external {
        _hasPendingRoute = false;
    }

    function lastUsesHistoricalDefault() external view returns (bool) {
        return _lastUsesHistoricalDefault;
    }

    function lastGoalIds() external view returns (uint256[] memory) {
        return _copyUint256Array(_lastGoalIds);
    }

    function lastWeights() external view returns (uint32[] memory) {
        return _copyUint32Array(_lastWeights);
    }

    function _copyUint256Calldata(uint256[] calldata values) private pure returns (uint256[] memory copied) {
        copied = new uint256[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }

    function _copyUint32Calldata(uint32[] calldata values) private pure returns (uint32[] memory copied) {
        copied = new uint32[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }

    function _copyUint256Array(uint256[] storage values) private view returns (uint256[] memory copied) {
        copied = new uint256[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }

    function _copyUint32Array(uint32[] storage values) private view returns (uint32[] memory copied) {
        copied = new uint32[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            copied[i] = values[i];
        }
    }
}
