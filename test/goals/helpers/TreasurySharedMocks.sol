// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTypes } from "src/storage/FlowStorage.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SharedMockUnderlying is ERC20 {
    constructor() ERC20("Shared Underlying", "sUND") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SharedMockSuperToken is ERC20 {
    error UNDERLYING_NOT_CONFIGURED();

    address private immutable _underlying;
    address private _host;

    constructor(address underlying_) ERC20("Shared Super", "sSUP") {
        _underlying = underlying_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getUnderlyingToken() external view returns (address) {
        return _underlying;
    }

    function setHost(address host_) external {
        _host = host_;
    }

    function getHost() external view returns (address host) {
        return _host;
    }

    function downgrade(uint256 amount) external {
        if (_underlying == address(0)) revert UNDERLYING_NOT_CONFIGURED();
        _burn(msg.sender, amount);
        SharedMockUnderlying(_underlying).mint(msg.sender, amount);
    }

    function upgrade(uint256 amount) external {
        if (_underlying == address(0)) revert UNDERLYING_NOT_CONFIGURED();
        IERC20(_underlying).transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }
}

contract SharedMockSuperfluidHost {
    bytes32 private constant CFA_V1_TYPE = keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");

    address private _cfa;

    function setCFA(address cfa_) external {
        _cfa = cfa_;
    }

    function getAgreementClass(bytes32 agreementType) external view returns (address agreementClass) {
        if (agreementType == CFA_V1_TYPE) return _cfa;
        return address(0);
    }
}

contract SharedMockCFA {
    uint256 public depositPerFlowRate = 1e18;

    function setDepositPerFlowRate(uint256 depositPerFlowRate_) external {
        depositPerFlowRate = depositPerFlowRate_;
    }

    function getMaximumFlowRateFromDeposit(address, uint256 deposit) external view returns (int96 flowRate) {
        if (depositPerFlowRate == 0) return type(int96).max;
        uint256 rate = deposit / depositPerFlowRate;
        uint256 int96Max = uint256(uint96(type(int96).max));
        if (rate > int96Max) rate = int96Max;
        return int96(int256(rate));
    }
}

contract SharedMockFeeOnTransferSuperToken is SharedMockSuperToken {
    uint256 public immutable feeBps;
    address public immutable feeRecipient;

    constructor(address underlying_, uint256 feeBps_, address feeRecipient_) SharedMockSuperToken(underlying_) {
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            uint256 remainder = value - fee;

            if (fee != 0) super._update(from, feeRecipient, fee);
            if (remainder != 0) super._update(from, to, remainder);
            return;
        }

        super._update(from, to, value);
    }
}

contract SharedMockFlow {
    error SET_FLOW_RATE_REVERT();
    error FLOW_RATE_UNSETTABLE(int96 requestedRate, int96 maxSettableRate);
    error SWEEP_REVERT();
    error TARGET_FLOW_RATE_REVERT();

    ISuperToken private immutable _superToken;
    address private _parent = address(0x1111);
    int96 private _maxSafeFlowRate;
    int96 private _totalFlowRate;
    int96 private _netFlowRateOverride;
    bool private _hasNetFlowRateOverride;
    bool private _shouldRevertSetFlowRate;
    bool private _shouldRevertTargetOutflowRate;
    bool private _enforceMaxSettableFlowRate;
    int96 private _maxSettableFlowRate;
    bool private _shouldRevertSweep;
    bool private _returnZeroSuperToken;
    address private _recipientAdmin;
    address private _flowOperator;
    address private _sweeper;

    uint256 public setFlowRateCallCount;
    uint256 public sweepCallCount;
    address public lastSweepTo;
    uint256 public lastSweepAmount;

    mapping(bytes32 => address) private _recipientById;

    constructor(ISuperToken superToken_) {
        _superToken = superToken_;
        _maxSettableFlowRate = type(int96).max;
        _recipientAdmin = msg.sender;
        _flowOperator = msg.sender;
        _sweeper = msg.sender;
    }

    function superToken() external view returns (ISuperToken) {
        if (_returnZeroSuperToken) return ISuperToken(address(0));
        return _superToken;
    }

    function getMaxSafeFlowRate() external view returns (int96) {
        return _maxSafeFlowRate;
    }

    function targetOutflowRate() external view returns (int96) {
        if (_shouldRevertTargetOutflowRate) revert TARGET_FLOW_RATE_REVERT();
        return _totalFlowRate;
    }

    function getActualFlowRate() external view returns (int96) {
        return _totalFlowRate;
    }

    function getNetFlowRate() external view returns (int96) {
        if (_hasNetFlowRateOverride) return _netFlowRateOverride;
        // Default to "no incoming flow": net = incoming - outgoing = 0 - outgoing.
        return -_totalFlowRate;
    }

    function setMaxSafeFlowRate(int96 rate) external {
        _maxSafeFlowRate = rate;
    }

    function setNetFlowRate(int96 netFlowRate_) external {
        _netFlowRateOverride = netFlowRate_;
        _hasNetFlowRateOverride = true;
    }

    function clearNetFlowRateOverride() external {
        _hasNetFlowRateOverride = false;
    }

    function setShouldRevertSetFlowRate(bool shouldRevert) external {
        _shouldRevertSetFlowRate = shouldRevert;
    }

    function setShouldRevertTargetOutflowRate(bool shouldRevert) external {
        _shouldRevertTargetOutflowRate = shouldRevert;
    }

    function setMaxSettableFlowRate(int96 maxSettableRate) external {
        _enforceMaxSettableFlowRate = true;
        _maxSettableFlowRate = maxSettableRate;
    }

    function setShouldRevertSweep(bool shouldRevert) external {
        _shouldRevertSweep = shouldRevert;
    }

    function setReturnZeroSuperToken(bool shouldReturnZero) external {
        _returnZeroSuperToken = shouldReturnZero;
    }

    function setParent(address parent_) external {
        _parent = parent_;
    }

    function parent() external view returns (address) {
        return _parent;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }

    function setRecipientAdmin(address recipientAdmin_) external {
        _recipientAdmin = recipientAdmin_;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function setFlowOperator(address flowOperator_) external {
        _flowOperator = flowOperator_;
    }

    function sweeper() external view returns (address) {
        return _sweeper;
    }

    function setSweeper(address sweeper_) external {
        _sweeper = sweeper_;
    }

    function setTargetOutflowRate(int96 rate) external {
        _setTargetOutflowRate(rate);
    }

    function refreshTargetOutflowRate() external {
        int96 cachedRate = _totalFlowRate;
        if (cachedRate <= 0) return;
        _setTargetOutflowRate(cachedRate);
    }

    function _setTargetOutflowRate(int96 rate) internal {
        if (_shouldRevertSetFlowRate) revert SET_FLOW_RATE_REVERT();
        if (_enforceMaxSettableFlowRate && rate > _maxSettableFlowRate) {
            revert FLOW_RATE_UNSETTABLE(rate, _maxSettableFlowRate);
        }
        setFlowRateCallCount += 1;
        _totalFlowRate = rate;
    }

    function setRecipient(bytes32 recipientId, address recipient) external {
        _recipientById[recipientId] = recipient;
    }

    function getRecipientById(bytes32 recipientId) external view returns (FlowTypes.FlowRecipient memory recipient) {
        recipient.recipient = _recipientById[recipientId];
        recipient.recipientType = FlowTypes.RecipientType.FlowContract;
    }

    function sweepSuperToken(address to, uint256 amount) external returns (uint256 swept) {
        if (_shouldRevertSweep) revert SWEEP_REVERT();
        if (to == address(0)) revert();
        uint256 available = IERC20(address(_superToken)).balanceOf(address(this));
        swept = amount > available ? available : amount;
        if (swept != 0) {
            IERC20(address(_superToken)).transfer(to, swept);
        }
        sweepCallCount += 1;
        lastSweepTo = to;
        lastSweepAmount = swept;
    }
}

contract SharedMockStakeVault {
    error MARK_REVERT();

    address public goalTreasury;
    address public jurorSlasher;
    bool public goalResolved;
    bool private _shouldRevertMark;
    uint256 public markCallCount;
    IERC20 private _goalToken;
    IERC20 private _cobuildToken;

    function setGoalTreasury(address goalTreasury_) external {
        goalTreasury = goalTreasury_;
    }

    function setGoalToken(IERC20 goalToken_) external {
        _goalToken = goalToken_;
    }

    function setCobuildToken(IERC20 cobuildToken_) external {
        _cobuildToken = cobuildToken_;
    }

    function setShouldRevertMark(bool shouldRevert) external {
        _shouldRevertMark = shouldRevert;
    }

    function setGoalResolved(bool resolved_) external {
        goalResolved = resolved_;
    }

    function goalToken() external view returns (IERC20) {
        return _goalToken;
    }

    function cobuildToken() external view returns (IERC20) {
        return _cobuildToken;
    }

    function weightOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalWeight() external pure returns (uint256) {
        return 0;
    }

    function markGoalResolved() external {
        if (_shouldRevertMark) revert MARK_REVERT();
        markCallCount += 1;
        goalResolved = true;
    }

    function setJurorSlasher(address slasher) external {
        jurorSlasher = slasher;
    }
}
