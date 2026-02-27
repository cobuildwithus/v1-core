// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IArbitrable } from "src/tcr/interfaces/IArbitrable.sol";
import { IArbitrator } from "src/tcr/interfaces/IArbitrator.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";

import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RoundTestArbitrator is IArbitrator {
    IVotes public votingToken;
    address public arbitrable;

    uint256 public arbitrationCostValue;
    uint256 public disputeCount;

    ArbitratorParams internal _params;

    mapping(uint256 => DisputeStatus) internal _status;
    mapping(uint256 => IArbitrable.Party) internal _ruling;

    constructor(
        IVotes votingToken_,
        address arbitrable_,
        uint256 votingDelay_,
        uint256 votingPeriod_,
        uint256 revealPeriod_,
        uint256 arbitrationCost_
    ) {
        votingToken = votingToken_;
        arbitrable = arbitrable_;
        arbitrationCostValue = arbitrationCost_;
        _params = ArbitratorParams({
            votingPeriod: votingPeriod_,
            votingDelay: votingDelay_,
            revealPeriod: revealPeriod_,
            arbitrationCost: arbitrationCost_,
            wrongOrMissedSlashBps: 0,
            slashCallerBountyBps: 0
        });
    }

    function createDispute(uint256 choices, bytes calldata) external returns (uint256 disputeID) {
        require(msg.sender == arbitrable, "ONLY_ARBITRABLE");
        require(choices == 2, "ONLY_TWO_CHOICES");

        disputeCount += 1;
        disputeID = disputeCount;
        _status[disputeID] = DisputeStatus.Waiting;
        _ruling[disputeID] = IArbitrable.Party.None;

        emit DisputeCreation(disputeID, IArbitrable(msg.sender));
    }

    function arbitrationCost(bytes calldata) external view returns (uint256 cost) {
        return arbitrationCostValue;
    }

    function disputeStatus(uint256 disputeID) external view returns (DisputeStatus status) {
        return _status[disputeID];
    }

    function currentRuling(uint256 disputeID) external view returns (IArbitrable.Party ruling) {
        return _ruling[disputeID];
    }

    function getArbitratorParamsForFactory() external view returns (ArbitratorParams memory) {
        return _params;
    }

    function setSolved(uint256 disputeID, IArbitrable.Party ruling_) external {
        _status[disputeID] = DisputeStatus.Solved;
        _ruling[disputeID] = ruling_;
    }

    function giveRuling(address arbitrable_, uint256 disputeID, uint256 ruling_) external {
        _status[disputeID] = DisputeStatus.Solved;
        _ruling[disputeID] = IArbitrable.Party(ruling_);

        (bool ok, bytes memory data) = arbitrable_.call(abi.encodeWithSignature("rule(uint256,uint256)", disputeID, ruling_));
        require(ok, string(data));
    }
}

contract RoundTestSuperToken is ERC20 {
    IERC20 public immutable underlying;

    constructor(string memory name_, string memory symbol_, IERC20 underlying_) ERC20(name_, symbol_) {
        underlying = underlying_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function downgrade(uint256 amount) external {
        _burn(msg.sender, amount);
        require(underlying.transfer(msg.sender, amount), "UNDERLYING_TRANSFER_FAILED");
    }

    function getUnderlyingToken() external view returns (address) {
        return address(underlying);
    }
}

contract RoundTestManagedFlow {
    error NOT_RECIPIENT_ADMIN();

    address public recipientAdmin;
    address public flowOperator;
    address public parent;
    address public superToken;

    mapping(bytes32 => address) public recipientById;
    mapping(address => bool) public recipientExists;
    mapping(bytes32 => FlowTypes.RecipientMetadata) public metadataById;

    constructor(address recipientAdmin_, address flowOperator_, address parent_, address superToken_) {
        recipientAdmin = recipientAdmin_;
        flowOperator = flowOperator_;
        parent = parent_;
        superToken = superToken_;
    }

    function setRecipientAdmin(address next) external {
        recipientAdmin = next;
    }

    function setFlowOperator(address next) external {
        flowOperator = next;
    }

    function setParent(address next) external {
        parent = next;
    }

    function setSuperToken(address next) external {
        superToken = next;
    }

    function addRecipient(
        bytes32 recipientId,
        address recipient,
        FlowTypes.RecipientMetadata memory metadata
    ) external returns (bytes32 newRecipientId, address recipientAddress) {
        if (msg.sender != recipientAdmin) revert NOT_RECIPIENT_ADMIN();

        recipientById[recipientId] = recipient;
        recipientExists[recipient] = true;
        metadataById[recipientId] = metadata;
        return (recipientId, recipient);
    }

    function removeRecipient(bytes32 recipientId) external {
        if (msg.sender != recipientAdmin) revert NOT_RECIPIENT_ADMIN();

        address recipient = recipientById[recipientId];
        if (recipient != address(0)) {
            recipientExists[recipient] = false;
        }

        delete recipientById[recipientId];
        delete metadataById[recipientId];
    }
}

contract RoundTestBudgetTreasury {
    address public flow;

    constructor(address flow_) {
        flow = flow_;
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }
}

contract RoundTestRewardEscrow {
    address public budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
    }

    function setBudgetStakeLedger(address budgetStakeLedger_) external {
        budgetStakeLedger = budgetStakeLedger_;
    }
}

contract RoundTestGoalTreasury {
    address public flow;
    address public rewardEscrow;
    address public stakeVault;
    bool public resolved;

    constructor(address flow_, address rewardEscrow_, address stakeVault_) {
        flow = flow_;
        rewardEscrow = rewardEscrow_;
        stakeVault = stakeVault_;
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }

    function setStakeVault(address stakeVault_) external {
        stakeVault = stakeVault_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }
}

contract RoundTestJurorSlasher {
    address public lastJuror;
    uint256 public lastWeight;
    address public lastRecipient;

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external {
        lastJuror = juror;
        lastWeight = weightAmount;
        lastRecipient = recipient;
    }
}

contract RoundTestBudgetStakeLedger {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 value;
    }

    mapping(address => Checkpoint[]) internal _allocationWeight;
    mapping(address => mapping(address => Checkpoint[])) internal _allocatedStake;

    function setUserAllocationWeight(address account, uint256 weight) external {
        _writeCheckpoint(_allocationWeight[account], weight);
    }

    function setUserAllocatedStakeOnBudget(address account, address budgetTreasury, uint256 stake) external {
        _writeCheckpoint(_allocatedStake[account][budgetTreasury], stake);
    }

    function getPastUserAllocationWeight(address account, uint256 blockNumber) external view returns (uint256) {
        return _getPastValue(_allocationWeight[account], blockNumber);
    }

    function getPastUserAllocatedStakeOnBudget(
        address account,
        address budgetTreasury,
        uint256 blockNumber
    ) external view returns (uint256) {
        return _getPastValue(_allocatedStake[account][budgetTreasury], blockNumber);
    }

    function _writeCheckpoint(Checkpoint[] storage cps, uint256 value) internal {
        require(value <= type(uint224).max, "VALUE_TOO_LARGE");

        uint32 blockNumber = uint32(block.number);
        uint224 castValue = uint224(value);
        uint256 length = cps.length;

        if (length != 0 && cps[length - 1].fromBlock == blockNumber) {
            cps[length - 1].value = castValue;
            return;
        }

        cps.push(Checkpoint({ fromBlock: blockNumber, value: castValue }));
    }

    function _getPastValue(Checkpoint[] storage cps, uint256 blockNumber) internal view returns (uint256) {
        require(blockNumber < block.number, "BLOCK_NOT_YET_MINED");

        uint256 length = cps.length;
        if (length == 0) return 0;
        if (cps[length - 1].fromBlock <= blockNumber) return cps[length - 1].value;
        if (cps[0].fromBlock > blockNumber) return 0;

        uint256 low = 0;
        uint256 high = length - 1;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (cps[mid].fromBlock <= blockNumber) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return cps[low].value;
    }
}

contract RoundTestStakeVault {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 value;
    }

    IERC20 public goalToken;
    address public goalTreasury;
    address public jurorSlasher;

    mapping(address => Checkpoint[]) internal _jurorWeight;
    Checkpoint[] internal _totalJurorWeight;
    mapping(address => mapping(address => bool)) public operatorAuth;
    mapping(address => address) public jurorDelegateOf;

    constructor(IERC20 goalToken_, address goalTreasury_, address jurorSlasher_) {
        goalToken = goalToken_;
        goalTreasury = goalTreasury_;
        jurorSlasher = jurorSlasher_;
    }

    function setGoalTreasury(address goalTreasury_) external {
        goalTreasury = goalTreasury_;
    }

    function setJurorSlasher(address jurorSlasher_) external {
        jurorSlasher = jurorSlasher_;
    }

    function setOperatorAuth(address juror, address operator, bool allowed) external {
        operatorAuth[juror][operator] = allowed;
    }

    function setJurorDelegate(address juror, address delegate) external {
        jurorDelegateOf[juror] = delegate;
    }

    function isAuthorizedJurorOperator(address juror, address operator) external view returns (bool) {
        return operator == juror || operatorAuth[juror][operator] || jurorDelegateOf[juror] == operator;
    }

    function setPastJurorWeight(address juror, uint256 weight) external {
        uint256 previousJurorWeight = _getLatestValue(_jurorWeight[juror]);
        _writeCheckpoint(_jurorWeight[juror], weight);

        uint256 totalPrevious = _getLatestValue(_totalJurorWeight);
        uint256 totalNext = weight >= previousJurorWeight
            ? totalPrevious + (weight - previousJurorWeight)
            : totalPrevious - (previousJurorWeight - weight);

        _writeCheckpoint(_totalJurorWeight, totalNext);
    }

    function getPastJurorWeight(address juror, uint256 blockNumber) external view returns (uint256) {
        return _getPastValue(_jurorWeight[juror], blockNumber);
    }

    function getPastTotalJurorWeight(uint256 blockNumber) external view returns (uint256) {
        return _getPastValue(_totalJurorWeight, blockNumber);
    }

    function slashJurorStake(address, uint256, address) external {}

    function _writeCheckpoint(Checkpoint[] storage cps, uint256 value) internal {
        require(value <= type(uint224).max, "VALUE_TOO_LARGE");

        uint32 blockNumber = uint32(block.number);
        uint224 castValue = uint224(value);
        uint256 length = cps.length;

        if (length != 0 && cps[length - 1].fromBlock == blockNumber) {
            cps[length - 1].value = castValue;
            return;
        }

        cps.push(Checkpoint({ fromBlock: blockNumber, value: castValue }));
    }

    function _getLatestValue(Checkpoint[] storage cps) internal view returns (uint256) {
        uint256 length = cps.length;
        if (length == 0) return 0;
        return cps[length - 1].value;
    }

    function _getPastValue(Checkpoint[] storage cps, uint256 blockNumber) internal view returns (uint256) {
        require(blockNumber < block.number, "BLOCK_NOT_YET_MINED");

        uint256 length = cps.length;
        if (length == 0) return 0;
        if (cps[length - 1].fromBlock <= blockNumber) return cps[length - 1].value;
        if (cps[0].fromBlock > blockNumber) return 0;

        uint256 low = 0;
        uint256 high = length - 1;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (cps[mid].fromBlock <= blockNumber) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return cps[low].value;
    }
}
