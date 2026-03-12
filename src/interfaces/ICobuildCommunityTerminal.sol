// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { ICobuildSplitHook } from "./ICobuildSplitHook.sol";

/// @notice Canonical cross-domain read boundary for shared community-terminal routing config.
interface ICobuildCommunityTerminal {
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
        );
}
