// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { FlowProtocolConstants } from "src/library/FlowProtocolConstants.sol";
import { TreasuryFlowRateSync } from "src/goals/library/TreasuryFlowRateSync.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { ICustomFlow, IFlow } from "src/interfaces/IFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TeamFlow is Initializable, IAllocationStrategy {
    uint32 public constant DEFAULT_MEMBER_UNITS = 20;
    string public constant STRATEGY_KEY = "TeamFlow";

    bytes32 private constant _SEAT_RECIPIENT_DOMAIN = keccak256("TeamFlow.SeatRecipient");
    uint256 private constant _INT96_MAX_UINT = uint256(uint96(type(int96).max));
    uint256 private constant _MEMBER_UNIT_WEIGHT =
        uint256(DEFAULT_MEMBER_UNITS) * FlowProtocolConstants.UNIT_WEIGHT_SCALE;

    struct InitConfig {
        bytes32 mechanismId;
        address manager;
        address childFlow;
        uint256 perSeatRate;
        uint256 maxTotalRate;
    }

    struct SeatState {
        bytes32 recipientId;
        uint64 nonce;
        uint256 activeIndexPlusOne;
    }

    error ONLY_MANAGER();
    error MEMBER_ALREADY_ACTIVE(address member);
    error MEMBER_NOT_ACTIVE(address member);
    error INVALID_CHILD_FLOW(address childFlow);
    error TOO_MANY_ACTIVE_MEMBERS(uint256 activeMembers);

    event TeamFlowInitialized(
        bytes32 indexed mechanismId,
        address indexed manager,
        address indexed childFlow,
        uint256 perSeatRate,
        uint256 maxTotalRate
    );
    event TeamFlowMemberAdded(address indexed member, bytes32 indexed recipientId, uint64 nonce);
    event TeamFlowMemberRemoved(address indexed member, bytes32 indexed recipientId);
    event TeamFlowRateConfigUpdated(uint256 perSeatRate, uint256 maxTotalRate);
    event TeamFlowSynced(uint256 activeMembers, int96 targetRate, int96 appliedRate);

    bytes32 public mechanismId;
    address public manager;
    ICustomFlow public childFlow;
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

    function initialize(InitConfig calldata config) external initializer {
        if (config.manager == address(0)) revert ADDRESS_ZERO();
        if (config.childFlow == address(0) || config.childFlow.code.length == 0) {
            revert INVALID_CHILD_FLOW(config.childFlow);
        }

        mechanismId = config.mechanismId;
        manager = config.manager;
        childFlow = ICustomFlow(config.childFlow);
        perSeatRate = config.perSeatRate;
        maxTotalRate = config.maxTotalRate;

        emit TeamFlowInitialized(
            config.mechanismId,
            config.manager,
            config.childFlow,
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

        childFlow.addRecipient(recipientId, member, metadata);
        _syncTeamState();

        emit TeamFlowMemberAdded(member, recipientId, seat.nonce);
    }

    function removeMember(address member) external onlyManager returns (bytes32 removedRecipientId) {
        SeatState storage seat = _seatState[member];
        uint256 activeIndexPlusOne = seat.activeIndexPlusOne;
        if (activeIndexPlusOne == 0) revert MEMBER_NOT_ACTIVE(member);

        removedRecipientId = seat.recipientId;
        childFlow.removeRecipient(removedRecipientId);

        _removeActiveMember(activeIndexPlusOne);
        delete seat.activeIndexPlusOne;
        delete seat.recipientId;

        _syncTeamState();

        emit TeamFlowMemberRemoved(member, removedRecipientId);
    }

    function setRateConfig(uint256 perSeatRate_, uint256 maxTotalRate_) external onlyManager {
        perSeatRate = perSeatRate_;
        maxTotalRate = maxTotalRate_;

        _syncTeamState();
        emit TeamFlowRateConfigUpdated(perSeatRate_, maxTotalRate_);
    }

    function sync() external returns (int96 appliedRate) {
        appliedRate = _syncTeamState();
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

    function allocationKey(address caller, bytes calldata) external pure override returns (uint256) {
        return uint256(uint160(caller));
    }

    function currentWeight(uint256 key) external view override returns (uint256) {
        if (key != _selfAllocationKey()) return 0;
        return _allocationWeight();
    }

    function canAllocate(uint256 key, address caller) external view override returns (bool) {
        return key == _selfAllocationKey() && caller == address(this);
    }

    function canAccountAllocate(address account) external view override returns (bool) {
        return account == address(this);
    }

    function accountAllocationWeight(address account) external view override returns (uint256) {
        if (account != address(this)) return 0;
        return _allocationWeight();
    }

    function strategyKey() external pure override returns (string memory) {
        return STRATEGY_KEY;
    }

    function _syncTeamState() internal returns (int96 appliedRate) {
        uint256 activeCount = _activeMembers.length;
        if (activeCount == 0) {
            bytes32 existingCommit = childFlow.getAllocationCommitment(address(this), _selfAllocationKey());
            if (existingCommit != bytes32(0)) {
                childFlow.clearStaleAllocation(address(this), _selfAllocationKey());
            }

            appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(IFlow(address(childFlow)), 0);
            emit TeamFlowSynced(0, 0, appliedRate);
            return appliedRate;
        }

        if (activeCount > FlowProtocolConstants.PPM_SCALE_UINT256) {
            revert TOO_MANY_ACTIVE_MEMBERS(activeCount);
        }

        (bytes32[] memory recipientIds, uint32[] memory allocationsPpm) = _equalAllocationVector(activeCount);
        childFlow.allocate(recipientIds, allocationsPpm);

        int96 targetRate = _targetRate(activeCount);
        appliedRate = TreasuryFlowRateSync.applyCappedFlowRate(IFlow(address(childFlow)), targetRate);

        emit TeamFlowSynced(activeCount, targetRate, appliedRate);
    }

    function _equalAllocationVector(
        uint256 activeCount
    ) internal view returns (bytes32[] memory recipientIds, uint32[] memory allocationsPpm) {
        recipientIds = new bytes32[](activeCount);
        allocationsPpm = new uint32[](activeCount);

        for (uint256 i = 0; i < activeCount; i++) {
            recipientIds[i] = _seatState[_activeMembers[i]].recipientId;
        }
        _sortRecipientIds(recipientIds);

        uint256 baseAllocation = FlowProtocolConstants.PPM_SCALE_UINT256 / activeCount;
        uint256 remainder = FlowProtocolConstants.PPM_SCALE_UINT256 % activeCount;
        for (uint256 i = 0; i < activeCount; i++) {
            allocationsPpm[i] = SafeCast.toUint32(baseAllocation + (i < remainder ? 1 : 0));
        }
    }

    function _sortRecipientIds(bytes32[] memory recipientIds) internal pure {
        uint256 count = recipientIds.length;
        for (uint256 i = 1; i < count; i++) {
            bytes32 current = recipientIds[i];
            uint256 j = i;
            while (j != 0 && current < recipientIds[j - 1]) {
                recipientIds[j] = recipientIds[j - 1];
                unchecked {
                    j -= 1;
                }
            }
            recipientIds[j] = current;
        }
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
}
