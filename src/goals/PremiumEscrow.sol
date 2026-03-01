// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IPremiumEscrow } from "../interfaces/IPremiumEscrow.sol";
import { IBudgetStakeLedger } from "../interfaces/IBudgetStakeLedger.sol";
import { IBudgetTreasury } from "../interfaces/IBudgetTreasury.sol";
import { IUnderwriterSlasherRouter } from "../interfaces/IUnderwriterSlasherRouter.sol";
import { IFlow } from "../interfaces/IFlow.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract PremiumEscrow is IPremiumEscrow, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant _PPM_SCALE = 1_000_000;
    uint256 private constant _INDEX_SCALE = 1e27;

    error ADDRESS_ZERO();
    error INVALID_SLASH_PPM(uint32 value);
    error ONLY_BUDGET_TREASURY();
    error INVALID_CLOSE_STATE(IBudgetTreasury.BudgetState state);
    error INVALID_CLOSE_WINDOW(uint64 activatedAt, uint64 closedAt);
    error INVALID_CLOSE_TIMESTAMP(uint64 closedAt);
    error SUPER_TOKEN_MISMATCH(address goalFlowSuperToken, address budgetTreasurySuperToken);
    error ALREADY_CLOSED();
    error NOT_CLOSED();
    error NOT_SLASHABLE();

    event PremiumIndexed(
        uint256 indexed distributedPremium,
        uint256 indexed totalCoverage,
        uint256 indexDelta,
        uint256 newPremiumIndex
    );
    event OrphanPremiumRecycled(address indexed destination, uint256 amount);
    event AccountCheckpointed(
        address indexed account,
        uint256 previousCoverage,
        uint256 currentCoverage,
        uint256 claimableAmount,
        uint256 exposureIntegral,
        uint256 totalCoverage
    );
    event Claimed(address indexed account, address indexed to, uint256 amount);
    event Closed(IBudgetTreasury.BudgetState indexed finalState, uint64 activatedAt, uint64 closedAt);
    event UnderwriterSlashed(
        address indexed underwriter,
        uint256 exposureIntegral,
        uint256 slashWeight,
        uint256 duration
    );

    struct AccountState {
        uint256 userIndex;
        uint256 claimable;
        uint256 userCov;
        uint256 exposureIntegral;
        uint64 lastExposureTs;
        bool slashed;
    }

    address public budgetTreasury;
    address public budgetStakeLedger;
    IERC20 public premiumToken;
    address public goalFlow;
    address public underwriterSlasherRouter;
    uint32 public budgetSlashPpm;

    uint256 public premiumIndex;
    uint256 public accountedBalance;
    uint256 public totalCoverage;

    bool public closed;
    IBudgetTreasury.BudgetState public finalState;
    uint64 public activatedAt;
    uint64 public closedAt;

    mapping(address => AccountState) private _accountStates;

    constructor() {
        _disableInitializers();
    }

    modifier onlyBudgetTreasury() {
        if (msg.sender != budgetTreasury) revert ONLY_BUDGET_TREASURY();
        _;
    }

    function initialize(
        address budgetTreasury_,
        address budgetStakeLedger_,
        address goalFlow_,
        address underwriterSlasherRouter_,
        uint32 budgetSlashPpm_
    ) external override initializer {
        if (budgetTreasury_ == address(0)) revert ADDRESS_ZERO();
        if (budgetStakeLedger_ == address(0)) revert ADDRESS_ZERO();
        if (goalFlow_ == address(0)) revert ADDRESS_ZERO();
        if (underwriterSlasherRouter_ == address(0)) revert ADDRESS_ZERO();
        if (budgetSlashPpm_ > _PPM_SCALE) revert INVALID_SLASH_PPM(budgetSlashPpm_);

        address premiumTokenAddress = address(IFlow(goalFlow_).superToken());
        if (premiumTokenAddress == address(0)) revert ADDRESS_ZERO();
        address budgetTreasurySuperToken = address(IBudgetTreasury(budgetTreasury_).superToken());
        if (budgetTreasurySuperToken == address(0)) revert ADDRESS_ZERO();
        if (premiumTokenAddress != budgetTreasurySuperToken) {
            revert SUPER_TOKEN_MISMATCH(premiumTokenAddress, budgetTreasurySuperToken);
        }

        budgetTreasury = budgetTreasury_;
        budgetStakeLedger = budgetStakeLedger_;
        premiumToken = IERC20(premiumTokenAddress);
        goalFlow = goalFlow_;
        underwriterSlasherRouter = underwriterSlasherRouter_;
        budgetSlashPpm = budgetSlashPpm_;
    }

    function userIndex(address account) external view returns (uint256) {
        return _accountStates[account].userIndex;
    }

    function claimable(address account) external view returns (uint256) {
        return _accountStates[account].claimable;
    }

    function userCov(address account) external view returns (uint256) {
        return _accountStates[account].userCov;
    }

    function exposureIntegral(address account) external view returns (uint256) {
        return _accountStates[account].exposureIntegral;
    }

    function lastExposureTs(address account) external view returns (uint64) {
        return _accountStates[account].lastExposureTs;
    }

    function slashed(address account) external view returns (bool) {
        return _accountStates[account].slashed;
    }

    function isSlashable() public view returns (bool) {
        if (!closed) return false;
        if (activatedAt == 0) return false;
        return finalState == IBudgetTreasury.BudgetState.Failed || finalState == IBudgetTreasury.BudgetState.Expired;
    }

    function checkpoint(address account) external override {
        _checkpoint(account, !closed);
    }

    function claim(address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ADDRESS_ZERO();

        _checkpoint(msg.sender, !closed);

        AccountState storage accountState = _accountStates[msg.sender];
        uint256 claimableAmount = accountState.claimable;
        if (claimableAmount == 0) return 0;

        uint256 available = premiumToken.balanceOf(address(this));
        amount = claimableAmount > available ? available : claimableAmount;
        if (amount == 0) return 0;

        accountState.claimable = claimableAmount - amount;
        accountedBalance = amount > accountedBalance ? 0 : accountedBalance - amount;

        premiumToken.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    function close(
        IBudgetTreasury.BudgetState state_,
        uint64 activatedAt_,
        uint64 closedAt_
    ) external override onlyBudgetTreasury {
        if (closed) {
            if (state_ == finalState && activatedAt_ == activatedAt && closedAt_ == closedAt) return;
            revert ALREADY_CLOSED();
        }
        if (state_ == IBudgetTreasury.BudgetState.Funding || state_ == IBudgetTreasury.BudgetState.Active) {
            revert INVALID_CLOSE_STATE(state_);
        }
        if (closedAt_ == 0 || closedAt_ > block.timestamp) revert INVALID_CLOSE_TIMESTAMP(closedAt_);
        if (activatedAt_ > closedAt_) revert INVALID_CLOSE_WINDOW(activatedAt_, closedAt_);

        _checkpointGlobal();

        closed = true;
        finalState = state_;
        activatedAt = activatedAt_;
        closedAt = closedAt_;

        emit Closed(state_, activatedAt_, closedAt_);
    }

    function slash(address underwriter) external override nonReentrant returns (uint256 slashWeight) {
        if (underwriter == address(0)) revert ADDRESS_ZERO();
        if (!closed) revert NOT_CLOSED();
        if (!isSlashable()) revert NOT_SLASHABLE();

        _checkpointGlobal();
        _checkpointAccount(underwriter, false);

        AccountState storage accountState = _accountStates[underwriter];
        if (accountState.slashed) return 0;
        accountState.slashed = true;

        uint256 duration = uint256(closedAt - activatedAt);
        if (duration != 0 && budgetSlashPpm != 0 && accountState.exposureIntegral != 0) {
            slashWeight = Math.mulDiv(accountState.exposureIntegral, uint256(budgetSlashPpm), duration * _PPM_SCALE);
            if (slashWeight != 0) {
                IUnderwriterSlasherRouter(underwriterSlasherRouter).slashUnderwriter(underwriter, slashWeight);
            }
        }

        emit UnderwriterSlashed(underwriter, accountState.exposureIntegral, slashWeight, duration);
    }

    function _checkpoint(address account, bool syncCoverage) internal {
        if (account == address(0)) revert ADDRESS_ZERO();
        _checkpointGlobal();
        _checkpointAccount(account, syncCoverage);
    }

    function _checkpointAccount(address account, bool syncCoverage) internal {
        AccountState storage accountState = _accountStates[account];
        uint256 previousCoverage = accountState.userCov;

        _accruePremium(accountState);
        _accrueExposure(accountState);

        if (syncCoverage) {
            uint256 currentCoverage = IBudgetStakeLedger(budgetStakeLedger).userAllocatedStakeOnBudget(
                account,
                budgetTreasury
            );
            if (currentCoverage != previousCoverage) {
                if (currentCoverage > previousCoverage) {
                    totalCoverage += currentCoverage - previousCoverage;
                } else {
                    totalCoverage -= previousCoverage - currentCoverage;
                }
                accountState.userCov = currentCoverage;
            }
        }

        emit AccountCheckpointed(
            account,
            previousCoverage,
            accountState.userCov,
            accountState.claimable,
            accountState.exposureIntegral,
            totalCoverage
        );
    }

    function _accruePremium(AccountState storage accountState) internal {
        uint256 indexDelta = premiumIndex - accountState.userIndex;
        if (indexDelta != 0 && accountState.userCov != 0) {
            accountState.claimable += Math.mulDiv(accountState.userCov, indexDelta, _INDEX_SCALE);
        }
        accountState.userIndex = premiumIndex;
    }

    function _accrueExposure(AccountState storage accountState) internal {
        uint64 startTs = _executionStart();
        uint64 exposureTs = _exposureTimestamp();

        if (startTs == 0) {
            accountState.lastExposureTs = exposureTs;
            return;
        }

        uint64 fromTs = accountState.lastExposureTs;
        if (fromTs < startTs) fromTs = startTs;

        if (exposureTs > fromTs && accountState.userCov != 0) {
            accountState.exposureIntegral += accountState.userCov * uint256(exposureTs - fromTs);
        }

        accountState.lastExposureTs = exposureTs;
    }

    function _checkpointGlobal() internal {
        uint256 currentBalance = premiumToken.balanceOf(address(this));
        uint256 previousAccounted = accountedBalance;

        if (currentBalance < previousAccounted) {
            accountedBalance = currentBalance;
            previousAccounted = currentBalance;
        }
        if (currentBalance == previousAccounted) return;

        uint256 incoming = currentBalance - previousAccounted;
        uint256 oldTotalCoverage = totalCoverage;

        if (oldTotalCoverage == 0) {
            premiumToken.safeTransfer(goalFlow, incoming);
            accountedBalance = premiumToken.balanceOf(address(this));
            emit OrphanPremiumRecycled(goalFlow, incoming);
            return;
        }

        uint256 indexDelta = Math.mulDiv(incoming, _INDEX_SCALE, oldTotalCoverage);
        if (indexDelta == 0) return;

        uint256 distributed = Math.mulDiv(indexDelta, oldTotalCoverage, _INDEX_SCALE);
        premiumIndex += indexDelta;
        accountedBalance = previousAccounted + distributed;

        emit PremiumIndexed(distributed, oldTotalCoverage, indexDelta, premiumIndex);
    }

    function _executionStart() internal view returns (uint64) {
        if (closed) return activatedAt;
        return IBudgetTreasury(budgetTreasury).activatedAt();
    }

    function _exposureTimestamp() internal view returns (uint64) {
        if (closed) return closedAt;
        return uint64(block.timestamp);
    }
}
