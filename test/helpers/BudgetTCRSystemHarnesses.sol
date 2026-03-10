// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ISuperToken,
    ISuperfluidPool
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";

contract BudgetTCRTestSuperToken is ERC20 {
    address private immutable _host;

    constructor() ERC20("Budget Super Token", "BST") {
        BudgetTCRTestSuperTokenGDA gda = new BudgetTCRTestSuperTokenGDA();
        _host = address(new BudgetTCRTestSuperTokenHost(address(gda)));
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getHost() external view returns (address host) {
        return _host;
    }
}

contract BudgetTCRTestSuperTokenHost {
    address private immutable _gda;

    constructor(address gda_) {
        _gda = gda_;
    }

    function getAgreementClass(bytes32) external view returns (address) {
        return _gda;
    }

    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata)
        external
        returns (bytes memory returnedData)
    {
        (bool success, bytes memory data) = agreementClass.call(callData);
        require(success, "callAgreement failed");
        return data;
    }
}

contract BudgetTCRTestSuperTokenGDA {
    function connectPool(ISuperfluidPool, bytes calldata) external pure returns (bytes memory) {
        return bytes("");
    }
}

contract BudgetTCRTestDistributionPool {
    mapping(address => uint256) private _totalAmountReceivedByMember;

    function setTotalAmountReceivedByMember(address member, uint256 amount) external {
        _totalAmountReceivedByMember[member] = amount;
    }

    function getTotalAmountReceivedByMember(address member) external view returns (uint256) {
        return _totalAmountReceivedByMember[member];
    }
}

contract BudgetTCRChildFlowHarness {
    error NOT_ALLOWED();

    ISuperToken private immutable _superToken;
    address private _recipientAdmin;
    address private _flowOperator;
    address private _sweeper;
    address private immutable _owner;
    address private immutable _parent;
    address private immutable _managerRewardPool;
    address private immutable _managerRewardDistributionPool;
    address private immutable _strategy;
    uint32 private immutable _managerRewardPoolFlowRatePpm;

    int96 private _maxSafeFlowRate;
    int96 private _totalFlowRate;
    int96 private _netFlowRateOverride;
    bool private _hasNetFlowRateOverride;

    constructor(
        ISuperToken superToken_,
        address recipientAdmin_,
        address flowOperator_,
        address sweeper_,
        address owner_,
        address parent_,
        address managerRewardPool_,
        address managerRewardDistributionPool_,
        address strategy_,
        uint32 managerRewardPoolFlowRatePpm_
    ) {
        _superToken = superToken_;
        _recipientAdmin = recipientAdmin_;
        _flowOperator = flowOperator_;
        _sweeper = sweeper_;
        _owner = owner_;
        _parent = parent_;
        _managerRewardPool = managerRewardPool_;
        _managerRewardDistributionPool = managerRewardDistributionPool_;
        _strategy = strategy_;
        _managerRewardPoolFlowRatePpm = managerRewardPoolFlowRatePpm_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function sweeper() external view returns (address) {
        return _sweeper;
    }

    function parent() external view returns (address) {
        return _parent;
    }

    function managerRewardPool() external view returns (address) {
        return _managerRewardPool;
    }

    function managerRewardDistributionPool() external view returns (ISuperfluidPool) {
        return ISuperfluidPool(_managerRewardDistributionPool);
    }

    function strategy() external view returns (IAllocationStrategy) {
        return IAllocationStrategy(_strategy);
    }

    function getMaxSafeFlowRate() external view returns (int96) {
        return _maxSafeFlowRate;
    }

    function targetOutflowRate() external view returns (int96) {
        return _totalFlowRate;
    }

    function getActualFlowRate() external view returns (int96) {
        return _totalFlowRate;
    }

    function getNetFlowRate() external view returns (int96) {
        if (_hasNetFlowRateOverride) return _netFlowRateOverride;
        return -_totalFlowRate;
    }

    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        return _managerRewardPoolFlowRatePpm;
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

    function setTargetOutflowRate(int96 rate) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_ALLOWED();
        _totalFlowRate = rate;
    }

    function setRecipientAdmin(address newRecipientAdmin) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_ALLOWED();
        _recipientAdmin = newRecipientAdmin;
    }

    function sweepSuperToken(address to, uint256 amount) external returns (uint256 swept) {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_ALLOWED();
        uint256 available = ERC20(address(_superToken)).balanceOf(address(this));
        swept = amount > available ? available : amount;
        if (swept != 0) {
            ERC20(address(_superToken)).transfer(to, swept);
        }
    }
}

contract BudgetTCRGoalFlowHarness {
    error NOT_RECIPIENT_ADMIN();
    error NOT_OWNER_OR_RECIPIENT_ADMIN();
    error RECIPIENT_NOT_FOUND();

    struct RecipientInfo {
        address recipient;
        bool isRemoved;
    }

    address private _owner;
    address private _recipientAdmin;
    address private _managerRewardPool;
    address private _childManagerRewardDistributionPool;
    uint32 private _managerRewardPoolFlowRatePpm;
    ISuperToken private immutable _superToken;

    mapping(bytes32 => RecipientInfo) public recipients;
    mapping(address => uint256) private _activeRecipientRefs;
    mapping(address => int96) private _memberFlowRates;

    constructor(address owner_, address recipientAdmin_, address managerRewardPool_, ISuperToken superToken_) {
        _owner = owner_;
        _recipientAdmin = recipientAdmin_;
        _managerRewardPool = managerRewardPool_;
        _childManagerRewardDistributionPool = address(new BudgetTCRTestDistributionPool());
        _superToken = superToken_;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function recipientAdmin() external view returns (address) {
        return _recipientAdmin;
    }

    function managerRewardPool() external view returns (address) {
        return _managerRewardPool;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function managerRewardPoolFlowRatePpm() external view returns (uint32) {
        return _managerRewardPoolFlowRatePpm;
    }

    function strategy() external pure returns (IAllocationStrategy) {
        return IAllocationStrategy(address(0));
    }

    function parent() external pure returns (address) {
        return address(0);
    }

    function distributionPool() external pure returns (ISuperfluidPool) {
        return ISuperfluidPool(address(0));
    }

    function getMemberFlowRate(address member) external view returns (int96 flowRate) {
        flowRate = _memberFlowRates[member];
    }

    function recipientExists(address recipient) external view returns (bool exists) {
        return _activeRecipientRefs[recipient] != 0;
    }

    function setRecipientAdmin(address newRecipientAdmin) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _recipientAdmin = newRecipientAdmin;
    }

    function setManagerRewardPool(address newManagerRewardPool) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _managerRewardPool = newManagerRewardPool;
    }

    function setManagerRewardPoolFlowRatePpm(uint32 newManagerRewardPoolFlowRatePpm) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _managerRewardPoolFlowRatePpm = newManagerRewardPoolFlowRatePpm;
    }

    function setChildManagerRewardDistributionPool(address childManagerRewardDistributionPool_) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _childManagerRewardDistributionPool = childManagerRewardDistributionPool_;
    }

    function setMemberFlowRate(address member, int96 flowRate) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _memberFlowRates[member] = flowRate;
    }

    function addRecipient(bytes32 newRecipientId, address recipient, FlowTypes.RecipientMetadata memory)
        external
        returns (bytes32 recipientId, address recipientAddress)
    {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        _replaceRecipient(newRecipientId, recipient);
        return (newRecipientId, recipient);
    }

    function addFlowRecipient(
        bytes32 newRecipientId,
        FlowTypes.RecipientMetadata memory,
        address childRecipientAdmin,
        address flowOperator,
        address sweeper,
        address childManagerRewardPool,
        uint32 childManagerRewardPoolFlowRatePpm,
        IAllocationStrategy childStrategy
    ) external returns (bytes32 recipientId, address recipientAddress) {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();

        BudgetTCRChildFlowHarness child = new BudgetTCRChildFlowHarness(
            _superToken,
            childRecipientAdmin,
            flowOperator,
            sweeper,
            address(this),
            address(this),
            childManagerRewardPool,
            _childManagerRewardDistributionPool,
            address(childStrategy),
            childManagerRewardPoolFlowRatePpm
        );
        _replaceRecipient(newRecipientId, address(child));
        return (newRecipientId, address(child));
    }

    function removeRecipient(bytes32 recipientId) external {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();

        RecipientInfo storage info = recipients[recipientId];
        if (info.recipient == address(0) || info.isRemoved) revert RECIPIENT_NOT_FOUND();
        _activeRecipientRefs[info.recipient] -= 1;
        info.isRemoved = true;
    }

    function _replaceRecipient(bytes32 recipientId, address recipient) internal {
        RecipientInfo storage previous = recipients[recipientId];
        if (previous.recipient != address(0) && !previous.isRemoved) {
            _activeRecipientRefs[previous.recipient] -= 1;
        }

        recipients[recipientId] = RecipientInfo({recipient: recipient, isRemoved: false});
        _activeRecipientRefs[recipient] += 1;
    }
}

contract BudgetTCRGoalTreasuryHarness {
    uint64 public deadline;
    address public budgetStakeLedger;
    address public flow;
    address public stakeVault;
    bool public resolved;
    bool public shouldRevertSync;
    uint256 public syncCallCount;

    constructor(uint64 deadline_) {
        deadline = deadline_;
        budgetStakeLedger = address(0xCAFE);
    }

    function setBudgetStakeLedger(address budgetStakeLedger_) external {
        budgetStakeLedger = budgetStakeLedger_;
    }

    function setRewardEscrow(address rewardEscrow_) external {
        if (rewardEscrow_.code.length == 0) {
            budgetStakeLedger = rewardEscrow_;
            return;
        }

        try BudgetTCRRewardEscrowHarness(rewardEscrow_).budgetStakeLedger() returns (address ledger) {
            budgetStakeLedger = ledger;
        } catch {
            budgetStakeLedger = rewardEscrow_;
        }
    }

    function setFlow(address flow_) external {
        flow = flow_;
    }

    function setStakeVault(address stakeVault_) external {
        stakeVault = stakeVault_;
    }

    function setResolved(bool resolved_) external {
        resolved = resolved_;
    }

    function setShouldRevertSync(bool shouldRevertSync_) external {
        shouldRevertSync = shouldRevertSync_;
    }

    function sync() external {
        if (shouldRevertSync) revert("GOAL_SYNC_FAILED");
        syncCallCount += 1;
    }
}

contract BudgetTCRRewardEscrowHarness {
    address public budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
    }
}

contract BudgetTCRStakeLedgerHarness {
    mapping(bytes32 => address) public budgetForRecipient;

    uint256 public registerCallCount;
    uint256 public removeCallCount;

    function registerBudget(bytes32 recipientId, address budget) external {
        budgetForRecipient[recipientId] = budget;
        registerCallCount += 1;
    }

    function removeBudget(bytes32 recipientId) external {
        address budget = budgetForRecipient[recipientId];
        if (budget == address(0)) return;

        delete budgetForRecipient[recipientId];
        removeCallCount += 1;
    }
}

contract BudgetTCRStakeVaultHarness {
    address public goalTreasury;
    address public jurorSlasher;
    address public underwriterSlasher;

    constructor(address goalTreasury_) {
        goalTreasury = goalTreasury_;
    }

    function setJurorSlasher(address jurorSlasher_) external {
        jurorSlasher = jurorSlasher_;
    }

    function setUnderwriterSlasher(address underwriterSlasher_) external {
        underwriterSlasher = underwriterSlasher_;
    }
}
