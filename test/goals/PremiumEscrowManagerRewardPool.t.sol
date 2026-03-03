// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { PremiumEscrow } from "src/goals/PremiumEscrow.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IGoalTreasury } from "src/interfaces/IGoalTreasury.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISuperToken, ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

interface IPremiumEscrowManagerRewardPoolTransferHook {
    function onPremiumTokenReceived(address from, uint256 amount) external;
}

interface IPremiumEscrowCheckpointEntrypoint {
    function checkpoint(address account) external;
}

contract PremiumEscrowManagerRewardPoolTest is Test {
    uint32 internal constant SLASH_PPM = 200_000;

    address internal constant ALICE = address(0xA11CE);
    address internal constant CONTROLLER = address(0xBEEF);
    address internal constant ATTACKER = address(0xBAD);

    PremiumEscrowManagerRewardPoolMockHost internal host;
    PremiumEscrowManagerRewardPoolMockGDA internal gda;
    PremiumEscrowMockSuperToken internal premiumToken;
    PremiumEscrowManagerRewardPoolMockBudgetStakeLedger internal ledger;
    PremiumEscrowManagerRewardPoolMockBudgetTreasury internal budgetTreasury;
    PremiumEscrowManagerRewardPoolMockGoalFlow internal goalFlow;
    PremiumEscrowManagerRewardPoolMockGoalTreasury internal goalTreasury;
    PremiumEscrowManagerRewardPoolMockRouter internal router;
    PremiumEscrow internal escrow;

    function setUp() public {
        gda = new PremiumEscrowManagerRewardPoolMockGDA();
        host = new PremiumEscrowManagerRewardPoolMockHost(address(gda));
        premiumToken = new PremiumEscrowMockSuperToken(address(host));
        ledger = new PremiumEscrowManagerRewardPoolMockBudgetStakeLedger();
        budgetTreasury = new PremiumEscrowManagerRewardPoolMockBudgetTreasury(address(premiumToken), CONTROLLER);
        goalFlow = new PremiumEscrowManagerRewardPoolMockGoalFlow(address(premiumToken));
        goalTreasury = new PremiumEscrowManagerRewardPoolMockGoalTreasury();
        goalFlow.setFlowOperator(address(goalTreasury));
        router = new PremiumEscrowManagerRewardPoolMockRouter();

        // Set flow before initialize so budgetFlow gets cached.
        budgetTreasury.setFlow(address(goalFlow));

        PremiumEscrow implementation = new PremiumEscrow();
        escrow = PremiumEscrow(Clones.clone(address(implementation)));
        escrow.initialize(address(budgetTreasury), address(ledger), address(goalFlow), address(router), SLASH_PPM);
    }

    function test_connectManagerRewardPool_revertsForUnauthorizedAndInvalidPool() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();

        vm.expectRevert(PremiumEscrow.ONLY_BUDGET_CONTROL.selector);
        vm.prank(ATTACKER);
        escrow.connectManagerRewardPool(address(pool));

        vm.expectRevert(abi.encodeWithSelector(PremiumEscrow.INVALID_MANAGER_REWARD_POOL.selector, address(0)));
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(0));

        address nonContractPool = makeAddr("non-contract-pool");
        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.INVALID_MANAGER_REWARD_POOL.selector, nonContractPool)
        );
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(nonContractPool);
    }

    function test_connectManagerRewardPool_setsBaselineAndAllowsSamePoolIdempotentReconnect() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();
        uint256 baseline = 50e18;
        pool.setTotalAmountReceivedByMember(address(escrow), baseline);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit PremiumEscrow.ManagerRewardPoolConnected(address(pool), baseline);

        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(pool));

        assertEq(address(escrow.managerRewardPool()), address(pool));
        assertEq(escrow.accountedManagerRewardReceived(), baseline);
        assertEq(gda.lastConnectedPool(), address(pool));

        vm.prank(CONTROLLER);
        escrow.connectManagerRewardPool(address(pool));

        assertEq(address(escrow.managerRewardPool()), address(pool));
        assertEq(escrow.accountedManagerRewardReceived(), baseline);
    }

    function test_connectManagerRewardPool_revertsWhenSwitchingPool() public {
        PremiumEscrowManagerRewardPoolMockPool poolA = new PremiumEscrowManagerRewardPoolMockPool();
        PremiumEscrowManagerRewardPoolMockPool poolB = new PremiumEscrowManagerRewardPoolMockPool();

        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(poolA));

        vm.expectRevert(
            abi.encodeWithSelector(PremiumEscrow.MANAGER_REWARD_POOL_ALREADY_SET.selector, address(poolA))
        );
        vm.prank(CONTROLLER);
        escrow.connectManagerRewardPool(address(poolB));
    }

    function test_connectManagerRewardPool_revertsWhenHostConnectFails() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();
        host.setShouldRevertCallAgreement(true);

        vm.expectRevert(PremiumEscrowManagerRewardPoolMockHost.CALL_AGREEMENT_REVERT.selector);
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(pool));
    }

    function test_checkpoint_revertsWhenManagerRewardPoolNotConnected() public {
        vm.expectRevert(PremiumEscrow.MANAGER_REWARD_POOL_NOT_CONNECTED.selector);
        escrow.checkpoint(ALICE);
    }

    function test_checkpoint_connectedPool_ignoresDirectTransfersAndIndexesOnlyPoolDelta() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();
        pool.setTotalAmountReceivedByMember(address(escrow), 20e18);

        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(pool));
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        // Direct transfers after connection must not affect premium indexing.
        premiumToken.mint(address(escrow), 100e18);
        escrow.checkpoint(ALICE);
        assertEq(escrow.claimable(ALICE), 0);
        assertEq(escrow.premiumEarned(ALICE), 0);

        // Only cumulative pool-received deltas are indexable.
        pool.setTotalAmountReceivedByMember(address(escrow), 70e18);
        premiumToken.mint(address(escrow), 50e18);
        escrow.checkpoint(ALICE);
        assertEq(escrow.claimable(ALICE), 50e18);
        assertEq(escrow.premiumEarned(ALICE), 50e18);

        premiumToken.mint(address(escrow), 25e18);
        escrow.checkpoint(ALICE);
        assertEq(escrow.claimable(ALICE), 50e18);
        assertEq(escrow.premiumEarned(ALICE), 50e18);

        pool.setTotalAmountReceivedByMember(address(escrow), 90e18);
        premiumToken.mint(address(escrow), 20e18);
        escrow.checkpoint(ALICE);
        assertEq(escrow.claimable(ALICE), 70e18);
        assertEq(escrow.premiumEarned(ALICE), 70e18);
    }

    function test_checkpoint_connectedPool_orphanRecycleHandlesReentrantTokenHook() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(pool));

        pool.setTotalAmountReceivedByMember(address(escrow), 25e18);
        premiumToken.mint(address(escrow), 25e18);
        premiumToken.setTransferHookEnabled(true);

        goalFlow.setReentryCheckpoint(address(escrow), ALICE);
        goalFlow.setReenterOnTokenReceive(true);

        escrow.checkpoint(ALICE);

        assertTrue(goalFlow.reentered());
        assertEq(premiumToken.balanceOf(address(goalFlow)), 25e18);
        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(escrow.accountedManagerRewardReceived(), 25e18);
    }

    function test_burnOnGoalFailure_connectedPool_sweepsEscrowBalanceAndSettlesLateResidual() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(pool));
        ledger.setCoverage(ALICE, address(budgetTreasury), 100);
        escrow.checkpoint(ALICE);

        goalTreasury.setState(IGoalTreasury.GoalState.Expired);
        premiumToken.mint(address(escrow), 45e18);

        uint256 goalFlowBefore = premiumToken.balanceOf(address(goalFlow));

        uint256 amount = escrow.burnOnGoalFailure();

        assertEq(amount, 45e18);
        assertEq(premiumToken.balanceOf(address(escrow)), 0);
        assertEq(premiumToken.balanceOf(address(goalFlow)), goalFlowBefore + 45e18);
        assertEq(goalTreasury.settleLateResidualCalls(), 1);
    }

    function test_burnOnGoalFailure_connectedPool_roundingDust_doesNotBrickLaterCloseCheckpoint() public {
        PremiumEscrowManagerRewardPoolMockPool pool = new PremiumEscrowManagerRewardPoolMockPool();
        vm.prank(address(budgetTreasury));
        escrow.connectManagerRewardPool(address(pool));
        // Use a non-divisible incoming amount to create manager-pool accounting dust.
        ledger.setCoverage(ALICE, address(budgetTreasury), 3);
        escrow.checkpoint(ALICE);

        pool.setTotalAmountReceivedByMember(address(escrow), 5);
        premiumToken.mint(address(escrow), 5);
        escrow.checkpoint(ALICE);
        assertEq(escrow.accountedManagerRewardReceived(), 4);

        goalTreasury.setState(IGoalTreasury.GoalState.Expired);
        escrow.burnOnGoalFailure();

        // Drop coverage to zero so the next global checkpoint would recycle any remaining incoming delta.
        ledger.setCoverage(ALICE, address(budgetTreasury), 0);
        escrow.checkpoint(ALICE);
        assertEq(escrow.totalCoverage(), 0);

        vm.warp(1);
        vm.prank(address(budgetTreasury));
        escrow.close(IBudgetTreasury.BudgetState.Expired, 0, 1);

        assertTrue(escrow.closed());
        assertEq(escrow.accountedManagerRewardReceived(), 5);
    }
}

contract PremiumEscrowMockSuperToken is ERC20 {
    address internal _host;
    bool internal _transferHookEnabled;
    bool internal _transferHookBeforeTransfer;

    constructor(address host_) ERC20("PremiumToken", "PRM") {
        _host = host_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferHookEnabled(bool enabled) external {
        _transferHookEnabled = enabled;
    }

    function setTransferHookBeforeTransfer(bool enabled) external {
        _transferHookBeforeTransfer = enabled;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (_transferHookEnabled && _transferHookBeforeTransfer && to.code.length != 0) {
            IPremiumEscrowManagerRewardPoolTransferHook(to).onPremiumTokenReceived(_msgSender(), value);
        }
        bool success = super.transfer(to, value);
        if (_transferHookEnabled && !_transferHookBeforeTransfer && to.code.length != 0) {
            IPremiumEscrowManagerRewardPoolTransferHook(to).onPremiumTokenReceived(_msgSender(), value);
        }
        return success;
    }

    function getHost() external view returns (address) {
        return _host;
    }
}

contract PremiumEscrowManagerRewardPoolMockHost {
    error CALL_AGREEMENT_REVERT();

    address internal _gda;
    bool internal _shouldRevertCallAgreement;

    constructor(address gda_) {
        _gda = gda_;
    }

    function setShouldRevertCallAgreement(bool shouldRevert) external {
        _shouldRevertCallAgreement = shouldRevert;
    }

    function getAgreementClass(bytes32) external view returns (address) {
        return _gda;
    }

    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata)
        external
        returns (bytes memory returnedData)
    {
        if (_shouldRevertCallAgreement) revert CALL_AGREEMENT_REVERT();
        (bool success, bytes memory result) = agreementClass.call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }
}

contract PremiumEscrowManagerRewardPoolMockGDA {
    address public lastConnectedPool;

    function connectPool(ISuperfluidPool pool, bytes calldata) external returns (bytes memory) {
        lastConnectedPool = address(pool);
        return new bytes(0);
    }
}

contract PremiumEscrowManagerRewardPoolMockPool {
    mapping(address => uint256) internal _totalReceivedByMember;

    function setTotalAmountReceivedByMember(address member, uint256 amount) external {
        _totalReceivedByMember[member] = amount;
    }

    function getTotalAmountReceivedByMember(address member) external view returns (uint256 totalAmountReceived) {
        return _totalReceivedByMember[member];
    }
}

contract PremiumEscrowManagerRewardPoolMockBudgetStakeLedger {
    mapping(address => mapping(address => uint256)) internal _coverageByBudget;
    mapping(address => uint256) internal _totalCoverageByBudget;

    function setCoverage(address account, address budget, uint256 coverage) external {
        uint256 current = _coverageByBudget[account][budget];
        if (coverage > current) {
            _totalCoverageByBudget[budget] += coverage - current;
        } else if (current > coverage) {
            _totalCoverageByBudget[budget] -= current - coverage;
        }
        _coverageByBudget[account][budget] = coverage;
    }

    function userAllocatedStakeOnBudget(address account, address budget) external view returns (uint256) {
        return _coverageByBudget[account][budget];
    }

    function budgetTotalAllocatedStake(address budget) external view returns (uint256) {
        return _totalCoverageByBudget[budget];
    }
}

contract PremiumEscrowManagerRewardPoolMockBudgetTreasury {
    ISuperToken internal _superToken;
    address internal _controller;
    uint64 internal _activatedAt;
    address internal _flow;

    constructor(address superToken_, address controller_) {
        _superToken = ISuperToken(superToken_);
        _controller = controller_;
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function controller() external view returns (address) {
        return _controller;
    }

    function activatedAt() external view returns (uint64) {
        return _activatedAt;
    }

    function setActivatedAt(uint64 activatedAt_) external {
        _activatedAt = activatedAt_;
    }

    function setFlow(address flow_) external {
        _flow = flow_;
    }

    function flow() external view returns (address) {
        return _flow;
    }
}

contract PremiumEscrowManagerRewardPoolMockGoalFlow is IPremiumEscrowManagerRewardPoolTransferHook {
    ISuperToken internal _superToken;
    address internal _flowOperator;
    address internal _managerRewardDistributionPool;
    address internal _reentryEscrow;
    address internal _reentryAccount;
    bool internal _reenterOnTokenReceive;
    bool internal _reentered;

    constructor(address superToken_) {
        _superToken = ISuperToken(superToken_);
    }

    function superToken() external view returns (ISuperToken) {
        return _superToken;
    }

    function flowOperator() external view returns (address) {
        return _flowOperator;
    }

    function setFlowOperator(address flowOperator_) external {
        _flowOperator = flowOperator_;
    }

    function setManagerRewardDistributionPool(address pool_) external {
        _managerRewardDistributionPool = pool_;
    }

    function managerRewardDistributionPool() external view returns (ISuperfluidPool) {
        return ISuperfluidPool(_managerRewardDistributionPool);
    }

    function setReentryCheckpoint(address escrow_, address account_) external {
        _reentryEscrow = escrow_;
        _reentryAccount = account_;
        _reentered = false;
    }

    function setReenterOnTokenReceive(bool enabled) external {
        _reenterOnTokenReceive = enabled;
        if (!enabled) _reentered = false;
    }

    function reentered() external view returns (bool) {
        return _reentered;
    }

    function onPremiumTokenReceived(address, uint256) external override {
        if (msg.sender != address(_superToken)) return;
        if (!_reenterOnTokenReceive || _reentered || _reentryEscrow == address(0)) return;

        _reentered = true;
        IPremiumEscrowCheckpointEntrypoint(_reentryEscrow).checkpoint(_reentryAccount);
    }

    function getTotalReceivedByMember(address) external pure returns (uint256) {
        return 0;
    }
}

contract PremiumEscrowManagerRewardPoolMockGoalTreasury {
    IGoalTreasury.GoalState internal _state = IGoalTreasury.GoalState.Succeeded;
    uint256 public settleLateResidualCalls;

    function setState(IGoalTreasury.GoalState state_) external {
        _state = state_;
    }

    function state() external view returns (IGoalTreasury.GoalState) {
        return _state;
    }

    function settleLateResidual() external {
        settleLateResidualCalls += 1;
    }
}

contract PremiumEscrowManagerRewardPoolMockRouter {
    function slashUnderwriter(address, uint256) external { }
}
