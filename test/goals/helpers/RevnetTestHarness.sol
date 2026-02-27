// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { JBApprovalStatus } from "@bananapus/core-v5/enums/JBApprovalStatus.sol";
import { IJBDirectory } from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import { IJBProjects } from "@bananapus/core-v5/interfaces/IJBProjects.sol";
import { IJBRulesetApprovalHook } from "@bananapus/core-v5/interfaces/IJBRulesetApprovalHook.sol";
import { IJBRulesets } from "@bananapus/core-v5/interfaces/IJBRulesets.sol";
import { IJBTerminal } from "@bananapus/core-v5/interfaces/IJBTerminal.sol";
import { IJBToken } from "@bananapus/core-v5/interfaces/IJBToken.sol";
import { IJBTokens } from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import { JBRuleset } from "@bananapus/core-v5/structs/JBRuleset.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract RevnetTestDirectory is IJBDirectory {
    error UNAUTHORIZED(address caller);

    mapping(uint256 => IERC165) public override controllerOf;
    mapping(address => bool) public override isAllowedToSetFirstController;
    mapping(uint256 => IJBTerminal[]) internal _terminalsOf;

    address public immutable owner;

    IJBProjects public immutable override PROJECTS = IJBProjects(address(0));

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UNAUTHORIZED(msg.sender);
        _;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) public view override returns (bool) {
        IJBTerminal[] memory terminals = _terminalsOf[projectId];
        for (uint256 i; i < terminals.length; i++) {
            if (terminals[i] == terminal) return true;
        }
        return false;
    }

    function primaryTerminalOf(uint256 projectId, address) external view override returns (IJBTerminal) {
        IJBTerminal[] memory terminals = _terminalsOf[projectId];
        if (terminals.length == 0) return IJBTerminal(address(0));
        return terminals[0];
    }

    function terminalsOf(uint256 projectId) external view override returns (IJBTerminal[] memory) {
        return _terminalsOf[projectId];
    }

    function setControllerOf(uint256 projectId, IERC165 controller) external override onlyOwner {
        controllerOf[projectId] = controller;
        emit SetController(projectId, controller, msg.sender);
    }

    function setIsAllowedToSetFirstController(address account, bool flag) external override onlyOwner {
        isAllowedToSetFirstController[account] = flag;
        emit SetIsAllowedToSetFirstController(account, flag, msg.sender);
    }

    function setPrimaryTerminalOf(uint256 projectId, address token, IJBTerminal terminal) external override onlyOwner {
        if (!isTerminalOf(projectId, terminal)) _terminalsOf[projectId].push(terminal);
        emit SetPrimaryTerminal(projectId, token, terminal, msg.sender);
    }

    function setTerminalsOf(uint256 projectId, IJBTerminal[] calldata terminals) external override onlyOwner {
        _terminalsOf[projectId] = terminals;
        emit SetTerminals(projectId, terminals, msg.sender);
    }
}

/// @notice Minimal ruleset simulator used by Goal/Revnet integration tests.
/// @dev Not a canonical Nana/JBX rulesets implementation. Keep parity/spec-lock tests up to date when changing this.
/// @dev Implements only behavior relied on by StakeVault/GoalTreasury integration paths.
contract RevnetTestRulesets is IJBRulesets {
    error UNSUPPORTED();
    error UNAUTHORIZED(address caller);
    error INVALID_DURATION(uint256 duration);
    error INVALID_WEIGHT(uint256 weight);
    error INVALID_WEIGHT_CUT_PERCENT(uint256 weightCutPercent);
    error INVALID_START(uint256 start);
    error RULESET_ID_OVERFLOW();

    IJBDirectory public immutable DIRECTORY;

    uint48 private _nextId = 1;

    mapping(uint256 => uint256) public override latestRulesetIdOf;
    mapping(uint256 => mapping(uint256 => JBRuleset)) internal _rulesetOf;
    mapping(uint256 => uint48[]) internal _rulesetIdsOf;

    constructor(IJBDirectory directory_) {
        DIRECTORY = directory_;
    }

    modifier onlyControllerOf(uint256 projectId) {
        if (address(DIRECTORY.controllerOf(projectId)) != msg.sender) revert UNAUTHORIZED(msg.sender);
        _;
    }

    function currentApprovalStatusForLatestRulesetOf(uint256 projectId) external view returns (JBApprovalStatus) {
        return _approvalStatusOf(projectId, _rulesetOf[projectId][latestRulesetIdOf[projectId]]);
    }

    function currentOf(uint256 projectId) external view returns (JBRuleset memory ruleset) {
        uint48[] storage ids = _rulesetIdsOf[projectId];
        uint256 length = ids.length;
        if (length == 0) return ruleset;

        uint256 nowTs = block.timestamp;
        uint48 selectedId;
        uint48 selectedStart;

        for (uint256 i; i < length; i++) {
            JBRuleset storage candidate = _rulesetOf[projectId][ids[i]];
            if (candidate.start > nowTs) continue;

            if (selectedId == 0 || candidate.start > selectedStart || (candidate.start == selectedStart && candidate.id > selectedId)) {
                selectedId = candidate.id;
                selectedStart = candidate.start;
            }
        }

        if (selectedId == 0) return ruleset;
        return _rulesetOf[projectId][selectedId];
    }

    function deriveCycleNumberFrom(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        revert UNSUPPORTED();
    }

    function deriveStartFrom(uint256, uint256, uint256) external pure returns (uint256) {
        revert UNSUPPORTED();
    }

    function deriveWeightFrom(uint256, uint256, uint256, uint256, uint256, uint256, uint256)
        external
        pure
        returns (uint256)
    {
        revert UNSUPPORTED();
    }

    function getRulesetOf(uint256 projectId, uint256 rulesetId) external view returns (JBRuleset memory) {
        return _rulesetOf[projectId][rulesetId];
    }

    function latestQueuedOf(uint256 projectId) external view returns (JBRuleset memory ruleset, JBApprovalStatus approvalStatus) {
        uint256 latestId = latestRulesetIdOf[projectId];
        ruleset = _rulesetOf[projectId][latestId];
        approvalStatus = _approvalStatusOf(projectId, ruleset);
    }

    function allOf(uint256, uint256, uint256) external pure returns (JBRuleset[] memory) {
        revert UNSUPPORTED();
    }

    function upcomingOf(uint256) external pure returns (JBRuleset memory) {
        revert UNSUPPORTED();
    }

    function queueFor(
        uint256 projectId,
        uint256 duration,
        uint256 weight,
        uint256 weightCutPercent,
        IJBRulesetApprovalHook approvalHook,
        uint256 metadata,
        uint256 mustStartAtOrAfter
    ) external onlyControllerOf(projectId) returns (JBRuleset memory ruleset) {
        if (_nextId == type(uint48).max) revert RULESET_ID_OVERFLOW();
        if (duration > type(uint32).max) revert INVALID_DURATION(duration);
        if (weight > type(uint112).max) revert INVALID_WEIGHT(weight);
        if (weightCutPercent > type(uint32).max) revert INVALID_WEIGHT_CUT_PERCENT(weightCutPercent);
        if (mustStartAtOrAfter > type(uint48).max) revert INVALID_START(mustStartAtOrAfter);

        uint48 id = _nextId++;
        uint48 basedOnId = uint48(latestRulesetIdOf[projectId]);
        uint48 cycleNumber = basedOnId == 0 ? 1 : _rulesetOf[projectId][basedOnId].cycleNumber + 1;

        uint256 startTs = mustStartAtOrAfter;
        if (startTs < block.timestamp) startTs = block.timestamp;

        ruleset = JBRuleset({
            cycleNumber: cycleNumber,
            id: id,
            basedOnId: basedOnId,
            start: uint48(startTs),
            duration: uint32(duration),
            weight: uint112(weight),
            weightCutPercent: uint32(weightCutPercent),
            approvalHook: approvalHook,
            metadata: metadata
        });

        _rulesetOf[projectId][id] = ruleset;
        _rulesetIdsOf[projectId].push(id);
        latestRulesetIdOf[projectId] = id;

        emit RulesetInitialized(id, projectId, basedOnId, msg.sender);
        emit RulesetQueued(id, projectId, duration, weight, weightCutPercent, approvalHook, metadata, mustStartAtOrAfter, msg.sender);
    }

    function updateRulesetWeightCache(uint256) external pure {
        revert UNSUPPORTED();
    }

    function _approvalStatusOf(uint256 projectId, JBRuleset memory ruleset) internal view returns (JBApprovalStatus) {
        if (ruleset.basedOnId == 0) return JBApprovalStatus.Empty;

        JBRuleset memory approvalHookRuleset = _rulesetOf[projectId][ruleset.basedOnId];
        if (approvalHookRuleset.approvalHook == IJBRulesetApprovalHook(address(0))) {
            return JBApprovalStatus.Empty;
        }

        return approvalHookRuleset.approvalHook.approvalStatusOf(projectId, ruleset);
    }
}

contract RevnetTestTokens {
    error UNAUTHORIZED(address caller);

    address public immutable owner;
    mapping(address => uint256) private _projectIdOf;

    constructor(address owner_) {
        owner = owner_;
    }

    function setProjectIdOf(address token, uint256 projectId) external {
        if (msg.sender != owner) revert UNAUTHORIZED(msg.sender);
        _projectIdOf[token] = projectId;
    }

    function projectIdOf(IJBToken token) external view returns (uint256) {
        return _projectIdOf[address(token)];
    }
}

/// @notice Harness for deploying revnet-style projects with immutable staged weights.
/// @dev Uses local `RevnetTestRulesets` simulator instead of canonical core-v5 contracts to avoid mixed-solc islands.
contract RevnetTestHarness is IERC165 {
    error INVALID_MINT_CLOSE(uint40 mintCloseTimestamp, uint40 currentTimestamp);
    error UNAUTHORIZED(address caller);

    event TokensBurned(address indexed holder, uint256 indexed revnetId, uint256 tokenCount, string memo);

    RevnetTestDirectory public immutable directory;
    RevnetTestRulesets public immutable rulesets;
    IJBTokens public immutable TOKENS;
    RevnetTestTokens private immutable _tokens;
    address public immutable owner;

    uint256 public revnetCount;
    mapping(uint256 => uint256) public burnedTokenCountOf;

    constructor() {
        owner = msg.sender;
        directory = new RevnetTestDirectory(address(this));
        rulesets = new RevnetTestRulesets(IJBDirectory(address(directory)));
        RevnetTestTokens tokens = new RevnetTestTokens(address(this));
        _tokens = tokens;
        TOKENS = IJBTokens(address(tokens));
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UNAUTHORIZED(msg.sender);
        _;
    }

    function createRevnet(uint112 weight) external onlyOwner returns (uint256 revnetId) {
        return createRevnetWithMintClose(weight, 0);
    }

    function createRevnetWithMintClose(uint112 weight, uint40 mintCloseTimestamp)
        public
        onlyOwner
        returns (uint256 revnetId)
    {
        revnetId = ++revnetCount;
        directory.setControllerOf(revnetId, IERC165(address(this)));

        uint256 nowTs = block.timestamp;
        rulesets.queueFor(revnetId, 0, weight, 0, IJBRulesetApprovalHook(address(0)), 0, nowTs);

        if (mintCloseTimestamp != 0) {
            if (mintCloseTimestamp <= nowTs) revert INVALID_MINT_CLOSE(mintCloseTimestamp, uint40(nowTs));
            rulesets.queueFor(revnetId, 0, 0, 0, IJBRulesetApprovalHook(address(0)), 0, mintCloseTimestamp);
        }
    }

    function burnTokensOf(address holder, uint256 revnetId, uint256 tokenCount, string calldata memo) external {
        burnedTokenCountOf[revnetId] += tokenCount;
        emit TokensBurned(holder, revnetId, tokenCount, memo);
    }

    function setTokenProjectId(address token, uint256 projectId) external onlyOwner {
        _tokens.setProjectIdOf(token, projectId);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}
