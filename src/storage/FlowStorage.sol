// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IAllocationStrategy } from "../interfaces/IAllocationStrategy.sol";

interface FlowTypes {
    // Enum to handle type of grant recipient, either address or flow contract
    // Helpful to set a flow rate if recipient is flow contract
    enum RecipientType {
        None,
        ExternalAccount,
        FlowContract
    }

    // Struct to hold metadata for the flow contract itself
    struct RecipientMetadata {
        string title;
        string description;
        string image;
        string tagline;
        string url;
    }

    // Struct to handle potential recipients
    struct FlowRecipient {
        // the account to stream funds to
        address recipient;
        /// Append-only recipient index (+1 sentinel) used for compact allocation snapshot encoding.
        uint32 recipientIndexPlusOne;
        // whether or not the recipient has been removed
        bool isRemoved;
        // the type of recipient, either account or flow contract
        RecipientType recipientType;
        // the metadata of the recipient
        RecipientMetadata metadata;
    }

    struct Config {
        /// The proportion of the total flow rate allocated to the manager rewards pool in scaled (1e6 == 100%)
        uint32 managerRewardPoolFlowRatePpm;
        /// The flow implementation
        address flowImplementation;
        /// The parent flow contract (optional)
        address parent;
        /// Recipient administration authority.
        address recipientAdmin;
        /// Flow-rate operations authority.
        address flowOperator;
        /// Sweep authority for held SuperToken balances.
        address sweeper;
        /// The manager reward pool
        address managerRewardPool;
        // Public field for the flow contract metadata
        RecipientMetadata metadata;
        /// The SuperToken used to pay out the grantees
        ISuperToken superToken;
        /// The Superfluid pool used to distribute recipient allocations in the SuperToken
        ISuperfluidPool distributionPool;
        // Allocation scale for PPM share math (1e6 == 100%).
        /// @notice PPM share scale (`1_000_000 == 100%`).
        uint32 ppmScale;
        // The address of the address that can connect the pool
        address connectPoolAdmin;
    }

    struct RecipientsState {
        /// Counter for active recipients (not removed)
        uint256 activeRecipientCount;
        /// Append-only recipient-id index table used by compact allocation snapshots.
        bytes32[] recipientIdByIndex;
        /// The mapping of recipients
        mapping(bytes32 => FlowRecipient) recipients;
        /// The mapping of addresses to whether they are a recipient
        mapping(address => bool) recipientExists;
    }

    struct AllocationState {
        // The allocation strategies
        IAllocationStrategy[] strategies;
        /**
         * @notice Commitment of the last allocation for (strategy, allocationKey).
         * @dev commit = keccak256(abi.encode(canonical(recipientIds[], allocationsPpm[])))
         * Canonical means sorted by recipientId asc. The contract canonicalizes both when verifying and when storing.
         */
        mapping(address => mapping(uint256 => bytes32)) allocCommit;
        /// Previous committed allocation weight for (strategy, allocationKey), stored as weight + 1.
        /// 0 means unset and 1 encodes weight 0.
        mapping(address => mapping(uint256 => uint256)) allocWeightPlusOne;
        /// Packed previous allocation snapshot for (strategy, allocationKey).
        /// Layout: uint16 count + repeated (uint32 recipientIndex, uint32 allocationScaled).
        mapping(address => mapping(uint256 => bytes)) allocSnapshotPacked;
    }

    struct RateState {
        // The cached flow rate
        int96 cachedFlowRate;
    }

    struct PipelineState {
        /// Optional post-allocation pipeline.
        address allocationPipeline;
    }
}

library FlowConfigStorage {
    bytes32 internal constant STORAGE_LOCATION = 0x778b009f07b9110138975cd4ea4a6b894e83771cc4d932d4c0daad56bbd8b400;

    /// @custom:storage-location erc7201:cobuild.storage.Flow.config
    struct Layout {
        FlowTypes.Config value;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := location
        }
    }
}

library FlowRecipientsStorage {
    bytes32 internal constant STORAGE_LOCATION = 0xd278facd207785013bb21352590c189eee89614f714477ab163066f12899b500;

    /// @custom:storage-location erc7201:cobuild.storage.Flow.recipients
    struct Layout {
        FlowTypes.RecipientsState value;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := location
        }
    }
}

library FlowAllocStorage {
    bytes32 internal constant STORAGE_LOCATION = 0xec99f0a88c8217d873dc1f006d43648a9c64971b5d0403486aac00b6b2bec900;

    /// @custom:storage-location erc7201:cobuild.storage.Flow.alloc
    struct Layout {
        FlowTypes.AllocationState value;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := location
        }
    }
}

library FlowRatesStorage {
    bytes32 internal constant STORAGE_LOCATION = 0x4484f98e4620bef0ab3bd3f7fc948d161a868ba8dedac6c50057034f58b53d00;

    /// @custom:storage-location erc7201:cobuild.storage.Flow.rates
    struct Layout {
        FlowTypes.RateState value;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := location
        }
    }
}

library FlowPipelineStorage {
    bytes32 internal constant STORAGE_LOCATION = 0x34d55fe27ff8bb7eb7d32520bdabd6c3f4305046fda1c8aa433b4bfd582c4700;

    /// @custom:storage-location erc7201:cobuild.storage.Flow.pipeline
    struct Layout {
        FlowTypes.PipelineState value;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := location
        }
    }
}

library FlowChildFlowsStorage {
    bytes32 internal constant STORAGE_LOCATION = 0xc8ab633c39b2ade69663164a96dea258f0a8ad1826174bee8fea0a82c777b600;

    /// @custom:storage-location erc7201:cobuild.storage.Flow.childFlows
    struct Layout {
        EnumerableSet.AddressSet value;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 location = STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := location
        }
    }
}

/// @notice Flow Storage V1
/// @author rocketman
/// @notice The Flow storage contract
contract FlowStorageV1 is FlowTypes {
    function _cfgStorage() internal view returns (Config storage cfg) {
        cfg = FlowConfigStorage.layout().value;
    }

    function _recipientsStorage() internal view returns (RecipientsState storage recipients) {
        recipients = FlowRecipientsStorage.layout().value;
    }

    function _allocStorage() internal view returns (AllocationState storage alloc) {
        alloc = FlowAllocStorage.layout().value;
    }

    function _ratesStorage() internal view returns (RateState storage rates) {
        rates = FlowRatesStorage.layout().value;
    }

    function _pipelineStorage() internal view returns (PipelineState storage pipeline) {
        pipeline = FlowPipelineStorage.layout().value;
    }

    function _childFlowsSet() internal view returns (EnumerableSet.AddressSet storage childFlows) {
        childFlows = FlowChildFlowsStorage.layout().value;
    }
}
