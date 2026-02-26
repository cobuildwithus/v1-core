// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice External wrappers for AddressSet operations to keep callers slim.
library FlowSets {
    using EnumerableSet for EnumerableSet.AddressSet;

    function add(EnumerableSet.AddressSet storage set, address value) external returns (bool) {
        return set.add(value);
    }

    function values(EnumerableSet.AddressSet storage set) external view returns (address[] memory) {
        return set.values();
    }
}
