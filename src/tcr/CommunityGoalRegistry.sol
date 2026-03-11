// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { GeneralizedTCR } from "./GeneralizedTCR.sol";
import { IGeneralizedTCRConfig } from "./interfaces/IGeneralizedTCRConfig.sol";
import { ICommunityGoalRegistry } from "./interfaces/ICommunityGoalRegistry.sol";
import { IGoalDeploymentRegistry } from "src/interfaces/IGoalDeploymentRegistry.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CommunityGoalRegistry is GeneralizedTCR, ICommunityGoalRegistry {
    struct InitConfig {
        IGeneralizedTCRConfig.RegistryConfig tcrConfig;
        IJBDirectory directory;
        IGoalDeploymentRegistry goalDeploymentRegistry;
        uint256 communityRevnetId;
        address communityToken;
    }

    struct GoalListing {
        string metadataURI;
    }

    error NOT_A_CONTRACT(address account);
    error VOTING_TOKEN_MISMATCH(address expectedToken, address actualToken);
    error GOAL_FUNDING_CONTEXT_MISMATCH(
        uint256 goalId,
        uint256 expectedRevnetId,
        uint256 actualRevnetId,
        address expectedToken,
        address actualToken
    );

    IJBDirectory public directory;
    IGoalDeploymentRegistry public goalDeploymentRegistry;
    uint256 public override communityRevnetId;
    address public override communityToken;

    mapping(uint256 goalId => GoalListing listing) private _goalListings;
    uint256[] private _listedGoalIds;
    mapping(uint256 goalId => uint256 indexPlusOne) private _listedGoalIndexPlusOne;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitConfig calldata initConfig) external initializer {
        address directoryAddress = address(initConfig.directory);
        address goalDeploymentRegistryAddress = address(initConfig.goalDeploymentRegistry);
        address communityToken_ = initConfig.communityToken;

        if (
            directoryAddress == address(0) ||
            goalDeploymentRegistryAddress == address(0) ||
            initConfig.communityRevnetId == 0 ||
            communityToken_ == address(0)
        ) revert ADDRESS_ZERO();
        if (directoryAddress.code.length == 0) revert NOT_A_CONTRACT(directoryAddress);
        if (goalDeploymentRegistryAddress.code.length == 0) revert NOT_A_CONTRACT(goalDeploymentRegistryAddress);
        if (communityToken_.code.length == 0) revert NOT_A_CONTRACT(communityToken_);
        address votingToken_ = address(initConfig.tcrConfig.votingToken);
        if (votingToken_ != communityToken_) revert VOTING_TOKEN_MISMATCH(communityToken_, votingToken_);

        directory = initConfig.directory;
        goalDeploymentRegistry = initConfig.goalDeploymentRegistry;
        communityRevnetId = initConfig.communityRevnetId;
        communityToken = communityToken_;

        __GeneralizedTCR_init(initConfig.tcrConfig);
    }

    function listedGoalIds() external view override returns (uint256[] memory goalIds) {
        goalIds = _listedGoalIds;
    }

    function selectableGoalIds() public view override returns (uint256[] memory goalIds) {
        uint256 listedLength = _listedGoalIds.length;
        uint256 count;
        for (uint256 i = 0; i < listedLength; i++) {
            if (_isSelectableGoal(_listedGoalIds[i])) count++;
        }

        goalIds = new uint256[](count);
        uint256 cursor;
        for (uint256 i = 0; i < listedLength; i++) {
            uint256 goalId = _listedGoalIds[i];
            if (!_isSelectableGoal(goalId)) continue;
            goalIds[cursor] = goalId;
            cursor++;
        }
    }

    function listingOf(uint256 goalId) external view override returns (GoalListingView memory listing) {
        GoalListing storage stored = _goalListings[goalId];
        bool listed = _isListedGoal(goalId);
        listing = GoalListingView({
            goalId: goalId,
            itemId: listed ? _goalItemId(goalId) : bytes32(0),
            metadataURI: stored.metadataURI,
            selectable: _isSelectableGoal(goalId)
        });
    }

    function isListed(uint256 goalId) public view override returns (bool) {
        return _isListedGoal(goalId);
    }

    function isSelectable(uint256 goalId) external view override returns (bool) {
        return _isSelectableGoal(goalId);
    }

    function _constructNewItemID(bytes calldata item) internal pure override returns (bytes32 itemID) {
        GoalItemData memory data = abi.decode(item, (GoalItemData));
        itemID = _goalItemId(data.goalId);
    }

    function _verifyItemData(bytes calldata item) internal view override returns (bool valid) {
        GoalItemData memory data;
        try this.decodeGoalItemData(item) returns (GoalItemData memory decoded) {
            data = decoded;
        } catch {
            return false;
        }

        if (data.goalId == 0) return false;
        if (data.goalId == communityRevnetId) return false;
        if (!_isRegisteredGoal(data.goalId)) return false;
        if (!_goalMatchesCommunity(data.goalId)) return false;
        if (!_goalHasPrimaryTerminal(data.goalId)) return false;
        return true;
    }

    function _assertCanAddItem(bytes32 itemID, bytes calldata item) internal view override {
        uint256 goalId = uint256(itemID);
        if (_isListedGoal(goalId)) revert GOAL_ALREADY_LISTED(goalId);

        GoalItemData memory data = abi.decode(item, (GoalItemData));
        if (data.goalId != goalId) revert INVALID_ITEM_DATA();

        _assertGoalCanExist(goalId);
    }

    function _onItemRegistered(bytes32 itemID, bytes memory item) internal override {
        GoalItemData memory data = abi.decode(item, (GoalItemData));
        uint256 goalId = data.goalId;
        if (_isListedGoal(goalId)) revert GOAL_ALREADY_LISTED(goalId);
        _addListedGoal(goalId);
        _goalListings[goalId].metadataURI = data.metadataURI;

        emit GoalListed(itemID, goalId, data.metadataURI);
    }

    function _onItemRemoved(bytes32 itemID) internal override {
        uint256 goalId = uint256(itemID);
        if (!_isListedGoal(goalId)) return;

        _removeListedGoal(goalId);
        delete _goalListings[goalId];

        emit GoalDelisted(itemID, goalId);
    }

    function decodeGoalItemData(bytes calldata item) external pure returns (GoalItemData memory data) {
        data = abi.decode(item, (GoalItemData));
    }

    function _assertGoalCanExist(uint256 goalId) internal view {
        if (goalId == 0) revert INVALID_GOAL_ID();
        if (goalId == communityRevnetId) revert GOAL_CANNOT_ROUTE_TO_SELF(goalId);
        if (!_isRegisteredGoal(goalId)) revert GOAL_NOT_DEPLOYED(goalId);
        _requireGoalMatchesCommunity(goalId);
        if (!_goalHasPrimaryTerminal(goalId)) revert GOAL_TERMINAL_NOT_CONFIGURED(goalId);
    }

    function _goalHasPrimaryTerminal(uint256 goalId) internal view returns (bool) {
        address terminalAddress = address(directory.primaryTerminalOf(goalId, communityToken));
        return terminalAddress.code.length != 0;
    }

    function _isRegisteredGoal(uint256 goalId) internal view returns (bool) {
        return goalDeploymentRegistry.isRegisteredGoal(goalId);
    }

    function _goalMatchesCommunity(uint256 goalId) internal view returns (bool) {
        address goalTreasuryAddress = goalDeploymentRegistry.goalTreasuryOf(goalId);
        if (goalTreasuryAddress == address(0) || goalTreasuryAddress.code.length == 0) return false;

        IGoalTreasury goalTreasury = IGoalTreasury(goalTreasuryAddress);
        uint256 goalCommunityRevnetId;
        address goalCommunityToken;

        try goalTreasury.cobuildRevnetId() returns (uint256 resolvedRevnetId) {
            goalCommunityRevnetId = resolvedRevnetId;
        } catch {
            return false;
        }

        address stakeVaultAddress;
        try goalTreasury.stakeVault() returns (address resolvedStakeVault) {
            stakeVaultAddress = resolvedStakeVault;
        } catch {
            return false;
        }
        if (stakeVaultAddress == address(0) || stakeVaultAddress.code.length == 0) return false;

        try IStakeVault(stakeVaultAddress).cobuildToken() returns (IERC20 resolvedToken) {
            goalCommunityToken = address(resolvedToken);
        } catch {
            return false;
        }

        return goalCommunityRevnetId == communityRevnetId && goalCommunityToken == communityToken;
    }

    function _requireGoalMatchesCommunity(uint256 goalId) internal view {
        address goalTreasuryAddress = goalDeploymentRegistry.goalTreasuryOf(goalId);
        if (goalTreasuryAddress == address(0) || goalTreasuryAddress.code.length == 0) {
            revert GOAL_NOT_DEPLOYED(goalId);
        }

        IGoalTreasury goalTreasury = IGoalTreasury(goalTreasuryAddress);
        uint256 actualRevnetId = goalTreasury.cobuildRevnetId();
        address stakeVaultAddress = goalTreasury.stakeVault();
        if (stakeVaultAddress == address(0) || stakeVaultAddress.code.length == 0) {
            revert GOAL_FUNDING_CONTEXT_MISMATCH(goalId, communityRevnetId, actualRevnetId, communityToken, address(0));
        }
        address actualToken = address(IStakeVault(stakeVaultAddress).cobuildToken());

        if (actualRevnetId != communityRevnetId || actualToken != communityToken) {
            revert GOAL_FUNDING_CONTEXT_MISMATCH(
                goalId,
                communityRevnetId,
                actualRevnetId,
                communityToken,
                actualToken
            );
        }
    }

    function _isSelectableGoal(uint256 goalId) internal view returns (bool) {
        if (!_isListedGoal(goalId)) return false;
        if (goalId == communityRevnetId) return false;
        if (!_isRegisteredGoal(goalId)) return false;
        if (!_goalMatchesCommunity(goalId)) return false;
        return _goalHasPrimaryTerminal(goalId);
    }

    function _isListedGoal(uint256 goalId) internal view returns (bool) {
        return _listedGoalIndexPlusOne[goalId] != 0;
    }

    function _addListedGoal(uint256 goalId) internal {
        if (_listedGoalIndexPlusOne[goalId] != 0) return;

        _listedGoalIndexPlusOne[goalId] = _listedGoalIds.length + 1;
        _listedGoalIds.push(goalId);
    }

    function _removeListedGoal(uint256 goalId) internal {
        uint256 indexPlusOne = _listedGoalIndexPlusOne[goalId];
        if (indexPlusOne == 0) return;

        uint256 removeIndex = indexPlusOne - 1;
        uint256 lastIndex = _listedGoalIds.length - 1;
        if (removeIndex != lastIndex) {
            uint256 movedGoalId = _listedGoalIds[lastIndex];
            _listedGoalIds[removeIndex] = movedGoalId;
            _listedGoalIndexPlusOne[movedGoalId] = removeIndex + 1;
        }

        _listedGoalIds.pop();
        delete _listedGoalIndexPlusOne[goalId];
    }

    function _goalItemId(uint256 goalId) internal pure returns (bytes32) {
        return bytes32(uint256(goalId));
    }
}
