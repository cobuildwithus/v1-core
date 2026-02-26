// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";

contract MockBudgetTCRSuperToken is ERC20 {
    constructor() ERC20("Budget Super Token", "BST") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockBudgetChildFlow {
    error NOT_ALLOWED();

    ISuperToken private immutable _superToken;
    address private _recipientAdmin;
    address private _flowOperator;
    address private _sweeper;
    address private immutable _owner;
    address private immutable _parent;
    address private immutable _strategy;

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
        address strategy_
    ) {
        _superToken = superToken_;
        _recipientAdmin = recipientAdmin_;
        _flowOperator = flowOperator_;
        _sweeper = sweeper_;
        _owner = owner_;
        _parent = parent_;
        _strategy = strategy_;
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

    function strategies() external view returns (IAllocationStrategy[] memory s) {
        if (_strategy == address(0)) return new IAllocationStrategy[](0);
        s = new IAllocationStrategy[](1);
        s[0] = IAllocationStrategy(_strategy);
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

contract MockGoalFlowForBudgetTCR {
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
    ISuperToken private immutable _superToken;

    mapping(bytes32 => RecipientInfo) public recipients;

    constructor(address owner_, address recipientAdmin_, address managerRewardPool_, ISuperToken superToken_) {
        _owner = owner_;
        _recipientAdmin = recipientAdmin_;
        _managerRewardPool = managerRewardPool_;
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

    function managerRewardPoolFlowRatePpm() external pure returns (uint32) {
        return 0;
    }

    function strategies() external pure returns (IAllocationStrategy[] memory s) {
        s = new IAllocationStrategy[](0);
    }

    function parent() external pure returns (address) {
        return address(0);
    }

    function distributionPool() external pure returns (ISuperfluidPool) {
        return ISuperfluidPool(address(0));
    }

    function recipientExists(address recipient) external view returns (bool exists) {
        // O(n) scan is acceptable for test-only mocks.
        for (uint256 i = 0; i < 16; i++) {
            bytes32 itemID = bytes32(i + 1);
            RecipientInfo memory info = recipients[itemID];
            if (!info.isRemoved && info.recipient == recipient) return true;
        }
        return false;
    }

    function setRecipientAdmin(address newRecipientAdmin) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _recipientAdmin = newRecipientAdmin;
    }

    function setManagerRewardPool(address newManagerRewardPool) external {
        if (msg.sender != _owner && msg.sender != _recipientAdmin) revert NOT_OWNER_OR_RECIPIENT_ADMIN();
        _managerRewardPool = newManagerRewardPool;
    }

    function addRecipient(bytes32 newRecipientId, address recipient, FlowTypes.RecipientMetadata memory)
        external
        returns (bytes32 recipientId, address recipientAddress)
    {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        recipients[newRecipientId] = RecipientInfo({ recipient: recipient, isRemoved: false });
        return (newRecipientId, recipient);
    }

    function addFlowRecipient(
        bytes32 newRecipientId,
        FlowTypes.RecipientMetadata memory,
        address childRecipientAdmin,
        address flowOperator,
        address sweeper,
        address,
        IAllocationStrategy[] calldata strategies
    ) external returns (bytes32 recipientId, address recipientAddress) {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();
        address strategy = strategies.length == 0 ? address(0) : address(strategies[0]);

        MockBudgetChildFlow child =
            new MockBudgetChildFlow(
                _superToken,
                childRecipientAdmin,
                flowOperator,
                sweeper,
                address(this),
                address(this),
                strategy
            );
        recipients[newRecipientId] = RecipientInfo({ recipient: address(child), isRemoved: false });
        return (newRecipientId, address(child));
    }

    function removeRecipient(bytes32 recipientId) external {
        if (msg.sender != _recipientAdmin) revert NOT_RECIPIENT_ADMIN();

        RecipientInfo storage info = recipients[recipientId];
        if (info.recipient == address(0) || info.isRemoved) revert RECIPIENT_NOT_FOUND();
        info.isRemoved = true;
    }

}

contract MockGoalTreasuryForBudgetTCR {
    uint64 public deadline;
    address public rewardEscrow;

    constructor(uint64 deadline_) {
        deadline = deadline_;
        rewardEscrow = address(new MockRewardEscrowForBudgetTCR(address(0xCAFE)));
    }

    function setRewardEscrow(address rewardEscrow_) external {
        rewardEscrow = rewardEscrow_;
    }
}

contract MockRewardEscrowForBudgetTCR {
    address public budgetStakeLedger;

    constructor(address budgetStakeLedger_) {
        budgetStakeLedger = budgetStakeLedger_;
    }

}

contract MockBudgetStakeLedgerForBudgetTCR {
    mapping(bytes32 => address) public budgetForRecipient;

    uint256 public registerCallCount;
    uint256 public removeCallCount;

    function registerBudget(bytes32 recipientId, address budget) external {
        budgetForRecipient[recipientId] = budget;
        registerCallCount += 1;
    }

    function removeBudget(bytes32 recipientId) external {
        delete budgetForRecipient[recipientId];
        removeCallCount += 1;
    }
}
