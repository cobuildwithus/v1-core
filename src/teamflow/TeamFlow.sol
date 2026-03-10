// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { Flow } from "src/Flow.sol";
import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { FlowPools } from "src/library/FlowPools.sol";
import { FlowRecipients } from "src/library/FlowRecipients.sol";
import { TreasuryFlowRateSync } from "src/goals/library/TreasuryFlowRateSync.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TeamFlow is Flow {
    uint32 public constant DEFAULT_MEMBER_UNITS = 20;
    string public constant STRATEGY_KEY = "TeamFlow";

    bytes32 private constant _SEAT_RECIPIENT_DOMAIN = keccak256("TeamFlow.SeatRecipient");
    uint256 private constant _INT96_MAX_UINT = uint256(uint96(type(int96).max));
    uint256 private constant _MEMBER_UNIT_WEIGHT =
        uint256(DEFAULT_MEMBER_UNITS) * FlowProtocolConstants.UNIT_WEIGHT_SCALE;

    struct InitConfig {
        bytes32 mechanismId;
        address manager;
        address superToken;
        address flowImplementation;
        uint256 perSeatRate;
        uint256 maxTotalRate;
        FlowTypes.RecipientMetadata metadata;
    }

    struct SeatState {
        bytes32 recipientId;
        uint64 nonce;
        uint256 activeIndexPlusOne;
    }

    error ONLY_MANAGER();
    error MEMBER_ALREADY_ACTIVE(address member);
    error MEMBER_NOT_ACTIVE(address member);
    error TEAMFLOW_REQUIRES_SELF_STRATEGY(address strategy);

    event TeamFlowInitialized(
        bytes32 indexed mechanismId,
        address indexed manager,
        address indexed superToken,
        uint256 perSeatRate,
        uint256 maxTotalRate
    );
    event TeamFlowMemberAdded(address indexed member, bytes32 indexed recipientId, uint64 nonce);
    event TeamFlowMemberRemoved(address indexed member, bytes32 indexed recipientId);
    event TeamFlowRateConfigUpdated(uint256 perSeatRate, uint256 maxTotalRate);
    event TeamFlowSynced(uint256 activeMembers, int96 targetRate, int96 appliedRate);

    bytes32 public mechanismId;
    address public manager;
    uint256 public perSeatRate;
    uint256 public maxTotalRate;

    mapping(address member => SeatState seat) private _seatState;
    address[] private _activeMembers;

    constructor() {
        _disableInitializers();
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert ONLY_MANAGER();
        _;
    }

    function initialize(InitConfig calldata config, IAllocationStrategy[] calldata strategies) external initializer {
        if (config.manager == address(0)) revert ADDRESS_ZERO();
        if (config.superToken.code.length == 0) revert NOT_A_CONTRACT(config.superToken);
        if (config.flowImplementation.code.length == 0) revert NOT_A_CONTRACT(config.flowImplementation);
        if (strategies.length != 1) revert FLOW_REQUIRES_SINGLE_STRATEGY(strategies.length);
        if (address(strategies[0]) != address(this)) revert TEAMFLOW_REQUIRES_SELF_STRATEGY(address(strategies[0]));

        mechanismId = config.mechanismId;
        manager = config.manager;
        perSeatRate = config.perSeatRate;
        maxTotalRate = config.maxTotalRate;

        __Flow_initWithRoles(
            IFlow.FlowInitConfig({
                superToken: config.superToken,
                flowImplementation: config.flowImplementation,
                recipientAdmin: address(this),
                managerRewardPool: address(0),
                allocationPipeline: address(0),
                parent: address(0),
                flowParams: IFlow.FlowParams({ managerRewardPoolFlowRatePpm: 0 }),
                metadata: config.metadata
            }),
            address(this),
            address(this),
            strategies
        );

        emit TeamFlowInitialized(
            config.mechanismId,
            config.manager,
            config.superToken,
            config.perSeatRate,
            config.maxTotalRate
        );
    }

    function addMember(
        address member,
        FlowTypes.RecipientMetadata calldata metadata
    ) external onlyManager returns (bytes32 recipientId) {
        if (member == address(0)) revert ADDRESS_ZERO();

        SeatState storage seat = _seatState[member];
        if (seat.activeIndexPlusOne != 0) revert MEMBER_ALREADY_ACTIVE(member);

        unchecked {
            seat.nonce += 1;
        }
        recipientId = keccak256(abi.encode(_SEAT_RECIPIENT_DOMAIN, mechanismId, member, seat.nonce));

        seat.recipientId = recipientId;
        seat.activeIndexPlusOne = _activeMembers.length + 1;
        _activeMembers.push(member);

        FlowTypes.RecipientsState storage recipientsState = _recipientsStorage();
        FlowRecipients.addRecipient(
            recipientsState,
            recipientId,
            member,
            metadata,
            address(this),
            _cfgStorage().managerRewardPool
        );

        emit RecipientCreated(recipientId, recipientsState.recipients[recipientId], msg.sender);

        FlowPools.updateDistributionMemberUnits(_cfgStorage(), member, uint128(DEFAULT_MEMBER_UNITS));
        _syncTargetRate();

        emit TeamFlowMemberAdded(member, recipientId, seat.nonce);
    }

    function removeMember(address member) external onlyManager returns (bytes32 removedRecipientId) {
        SeatState storage seat = _seatState[member];
        uint256 activeIndexPlusOne = seat.activeIndexPlusOne;
        if (activeIndexPlusOne == 0) revert MEMBER_NOT_ACTIVE(member);

        removedRecipientId = seat.recipientId;

        FlowTypes.RecipientsState storage recipientsState = _recipientsStorage();
        address recipientAddress = FlowRecipients.markRecipientRemoved(
            recipientsState,
            _childFlowsSet(),
            removedRecipientId
        );

        emit RecipientRemoved(recipientAddress, removedRecipientId);

        FlowPools.removeFromPools(_cfgStorage(), recipientAddress);

        _removeActiveMember(activeIndexPlusOne);
        delete seat.activeIndexPlusOne;
        delete seat.recipientId;

        _syncTargetRate();

        emit TeamFlowMemberRemoved(member, removedRecipientId);
    }

    function setRateConfig(uint256 perSeatRate_, uint256 maxTotalRate_) external onlyManager {
        perSeatRate = perSeatRate_;
        maxTotalRate = maxTotalRate_;

        _syncTargetRate();
        emit TeamFlowRateConfigUpdated(perSeatRate_, maxTotalRate_);
    }

    function sync() external returns (int96 appliedRate) {
        appliedRate = _syncTargetRate();
    }

    function activeMembers() external view returns (address[] memory members) {
        members = _activeMembers;
    }

    function activeMemberCount() external view returns (uint256 count) {
        count = _activeMembers.length;
    }

    function memberRecipientId(address member) external view returns (bytes32 recipientId) {
        recipientId = _seatState[member].recipientId;
    }

    function allocationKey(address caller, bytes calldata) external pure returns (uint256) {
        return uint256(uint160(caller));
    }

    function currentWeight(uint256 key) external view returns (uint256) {
        if (key != _selfAllocationKey()) return 0;
        return _allocationWeight();
    }

    function canAllocate(uint256 key, address caller) external view returns (bool) {
        return key == _selfAllocationKey() && caller == address(this);
    }

    function canAccountAllocate(address account) external view returns (bool) {
        return account == address(this);
    }

    function accountAllocationWeight(address account) external view returns (uint256) {
        if (account != address(this)) return 0;
        return _allocationWeight();
    }

    function strategyKey() external pure returns (string memory) {
        return STRATEGY_KEY;
    }

    function _syncTargetRate() internal returns (int96 appliedRate) {
        uint256 activeCount = _activeMembers.length;
        int96 targetRate = _targetRate(activeCount);
        appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(IFlow(address(this)), targetRate);

        emit TeamFlowSynced(activeCount, targetRate, appliedRate);
    }

    function _allocationWeight() internal view returns (uint256 weight) {
        weight = _activeMembers.length * _MEMBER_UNIT_WEIGHT;
    }

    function _selfAllocationKey() internal view returns (uint256) {
        return uint256(uint160(address(this)));
    }

    function _targetRate(uint256 activeCount) internal view returns (int96) {
        if (activeCount == 0 || perSeatRate == 0) return 0;

        uint256 aggregate = perSeatRate;
        if (activeCount > 1) {
            if (aggregate > _INT96_MAX_UINT / activeCount) {
                aggregate = _INT96_MAX_UINT;
            } else {
                aggregate *= activeCount;
            }
        }

        uint256 configuredCap = maxTotalRate;
        if (configuredCap != 0 && aggregate > configuredCap) {
            aggregate = configuredCap;
        }

        if (aggregate == 0) return 0;
        if (aggregate >= _INT96_MAX_UINT) return type(int96).max;
        return SafeCast.toInt96(SafeCast.toInt256(aggregate));
    }

    function _removeActiveMember(uint256 activeIndexPlusOne) internal {
        uint256 removeIndex = activeIndexPlusOne - 1;
        uint256 lastIndex = _activeMembers.length - 1;

        if (removeIndex != lastIndex) {
            address movedMember = _activeMembers[lastIndex];
            _activeMembers[removeIndex] = movedMember;
            _seatState[movedMember].activeIndexPlusOne = activeIndexPlusOne;
        }

        _activeMembers.pop();
    }

    function _deployFlowRecipient(
        bytes32,
        RecipientMetadata calldata,
        address,
        address,
        address,
        address,
        uint32,
        IAllocationStrategy[] calldata
    ) internal pure override returns (address) {
        revert NESTED_FLOW_RECIPIENTS_DISABLED();
    }
}
