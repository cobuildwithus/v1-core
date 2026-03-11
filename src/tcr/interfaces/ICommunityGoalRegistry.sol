// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";

import { IGeneralizedTCR } from "./IGeneralizedTCR.sol";

interface ICommunityGoalRegistry is IGeneralizedTCR {
    struct GoalItemData {
        uint256 goalId;
        string metadataURI;
    }

    struct GoalListingView {
        uint256 goalId;
        bytes32 itemId;
        string metadataURI;
        bool selectable;
    }

    error INVALID_GOAL_ID();
    error GOAL_ALREADY_LISTED(uint256 goalId);
    error GOAL_NOT_DEPLOYED(uint256 goalId);
    error GOAL_TERMINAL_NOT_CONFIGURED(uint256 goalId);
    error GOAL_CANNOT_ROUTE_TO_SELF(uint256 goalId);

    event GoalListed(bytes32 indexed itemId, uint256 indexed goalId, string metadataURI);
    event GoalDelisted(bytes32 indexed itemId, uint256 indexed goalId);

    function communityRevnetId() external view returns (uint256);
    function communityToken() external view returns (address);
    function directory() external view returns (IJBDirectory);
    function goalDeploymentRegistry() external view returns (IGoalDeploymentRegistry);

    function listedGoalIds() external view returns (uint256[] memory goalIds);
    function selectableGoalIds() external view returns (uint256[] memory goalIds);
    function listingOf(uint256 goalId) external view returns (GoalListingView memory listing);
    function isListed(uint256 goalId) external view returns (bool);
    function isSelectable(uint256 goalId) external view returns (bool);
}
