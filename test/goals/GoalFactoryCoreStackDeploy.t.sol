// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {JurorSlasherRouter} from "src/goals/JurorSlasherRouter.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {GoalFactoryCoreStackDeploy} from "src/goals/library/GoalFactoryCoreStackDeploy.sol";
import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";

import {
    ISuperfluid,
    ISuperToken
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {
    ISuperTokenFactory
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperTokenFactory.sol";

contract GoalFactoryCoreStackDeployTest is Test {
    MockGoalToken internal goalToken;
    MockGoalToken internal cobuildToken;
    MockGoalFactoryGoalTreasury internal goalTreasury;
    MockGoalFactorySplitHook internal splitHook;
    MockGoalFactoryFlow internal goalFlow;
    MockGoalFactoryStakeVault internal stakeVaultImpl;
    MockGoalFactoryBudgetStakeLedger internal budgetStakeLedgerImpl;
    MockGoalFactoryAllocationPipeline internal allocationPipelineImpl;
    MockGoalFactoryJurorSlasherRouter internal jurorSlasherRouterImpl;
    MockGoalFactoryUnderwriterSlasherRouter internal underwriterSlasherRouterImpl;
    MockGoalFactorySuperfluidHost internal superfluidHost;
    MockGoalFactorySuperTokenFactory internal superTokenFactory;
    MockGoalFactoryRulesets internal rulesets;
    MockGoalFactoryDirectory internal directory;

    function setUp() public {
        goalToken = new MockGoalToken("Goal", "GOAL");
        cobuildToken = new MockGoalToken("Cobuild", "CBD");
        goalTreasury = new MockGoalFactoryGoalTreasury();
        splitHook = new MockGoalFactorySplitHook();
        goalFlow = new MockGoalFactoryFlow();
        stakeVaultImpl = new MockGoalFactoryStakeVault();
        budgetStakeLedgerImpl = new MockGoalFactoryBudgetStakeLedger();
        allocationPipelineImpl = new MockGoalFactoryAllocationPipeline();
        jurorSlasherRouterImpl = new MockGoalFactoryJurorSlasherRouter();
        underwriterSlasherRouterImpl = new MockGoalFactoryUnderwriterSlasherRouter();
        superTokenFactory = new MockGoalFactorySuperTokenFactory();
        superfluidHost = new MockGoalFactorySuperfluidHost(address(superTokenFactory));
        rulesets = new MockGoalFactoryRulesets();
        directory = new MockGoalFactoryDirectory();
    }

    function test_initializeCoreStack_forwardsGoalSpendPolicyIntoGoalTreasuryConfig() public {
        address goalSpendPolicy = address(0xBEEF);
        GoalFactoryCoreStackDeploy.CoreStackResult memory core = GoalFactoryCoreStackDeploy.deployCoreBase(_baseBaseRequest());

        GoalFactoryCoreStackDeploy.finalizeCoreStack(core, _baseFinalizeRequest(goalSpendPolicy, address(core.stakeVault)));

        assertEq(goalTreasury.lastSpendPolicy(), goalSpendPolicy);
    }

    function test_initializeCoreStack_initializesSplitHookWithDirectoryGoalTreasuryAndRevnetId() public {
        uint256 goalRevnetId = 77;
        GoalFactoryCoreStackDeploy.CoreBaseRequest memory baseRequest = _baseBaseRequest();
        baseRequest.goalRevnetId = goalRevnetId;

        GoalFactoryCoreStackDeploy.CoreStackResult memory core = GoalFactoryCoreStackDeploy.deployCoreBase(baseRequest);
        GoalFactoryCoreStackDeploy.CoreFinalizeRequest memory finalizeRequest =
            _baseFinalizeRequest(address(0xBEEF), address(core.stakeVault));
        finalizeRequest.goalRevnetId = goalRevnetId;

        GoalFactoryCoreStackDeploy.finalizeCoreStack(core, finalizeRequest);

        assertEq(splitHook.initializeCallCount(), 1);
        assertEq(splitHook.lastDirectory(), address(directory));
        assertEq(splitHook.lastGoalTreasury(), address(goalTreasury));
        assertEq(splitHook.lastFlow(), address(goalFlow));
        assertEq(splitHook.lastSuperToken(), goalFlow.lastSuperToken());
        assertEq(splitHook.lastGoalRevnetId(), goalRevnetId);
    }

    function test_finalizeCoreStack_usesExplicitGoalFlowStrategy() public {
        GoalFactoryCoreStackDeploy.CoreStackResult memory core = GoalFactoryCoreStackDeploy.deployCoreBase(_baseBaseRequest());
        MockGoalFactoryExplicitStrategy explicitStrategy = new MockGoalFactoryExplicitStrategy();

        GoalFactoryCoreStackDeploy.finalizeCoreStack(core, _baseFinalizeRequest(address(0xBEEF), address(explicitStrategy)));

        assertTrue(address(core.stakeVault) != address(0));
        assertEq(goalFlow.lastStrategy(), address(explicitStrategy));
    }

    function _baseBaseRequest()
        internal
        view
        returns (GoalFactoryCoreStackDeploy.CoreBaseRequest memory request)
    {
        request = GoalFactoryCoreStackDeploy.CoreBaseRequest({
            goalTreasury: GoalTreasury(address(goalTreasury)),
            splitHook: GoalRevnetSplitHook(payable(address(splitHook))),
            goalFlow: CustomFlow(payable(address(goalFlow))),
            stakeVaultImpl: address(stakeVaultImpl),
            superfluidHost: ISuperfluid(address(superfluidHost)),
            budgetStakeLedgerImpl: address(budgetStakeLedgerImpl),
            goalFlowAllocationLedgerPipelineImpl: address(allocationPipelineImpl),
            cobuildToken: address(cobuildToken),
            cobuildDecimals: 18,
            goalRevnetId: 1,
            goalToken: address(goalToken),
            rulesets: IJBRulesets(address(rulesets)),
            revnetName: "Goal",
            revnetTicker: "GOAL"
        });
    }

    function _baseFinalizeRequest(
        address goalSpendPolicy,
        address goalAllocatorStrategy
    ) internal view returns (GoalFactoryCoreStackDeploy.CoreFinalizeRequest memory request) {
        request = GoalFactoryCoreStackDeploy.CoreFinalizeRequest({
            goalAllocatorStrategy: goalAllocatorStrategy,
            budgetController: address(0xB6D9E7),
            jurorSlasherAuthority: address(0xB6D6E7),
            jurorSlasherRouterImpl: address(jurorSlasherRouterImpl),
            underwriterSlasherRouterImpl: address(underwriterSlasherRouterImpl),
            flowImpl: address(0xF10F),
            goalToken: address(goalToken),
            cobuildToken: address(cobuildToken),
            goalRevnetId: 1,
            rulesets: IJBRulesets(address(rulesets)),
            directory: IJBDirectory(address(directory)),
            flowTitle: "Flow",
            flowDescription: "Goal flow",
            flowImage: "ipfs://image",
            flowTagline: "tagline",
            flowUrl: "https://goal.example",
            minRaiseDeadline: 123,
            minRaise: 456,
            budgetPremiumPpm: 0,
            budgetSlashPpm: 0,
            successResolver: address(0x1234),
            successAssertionLiveness: 1 days,
            successAssertionBond: 0,
            successOracleSpecHash: keccak256("spec"),
            successAssertionPolicyHash: keccak256("policy"),
            goalSpendPolicy: goalSpendPolicy,
            terminalRolloverCooldown: 0
        });
    }
}

contract MockGoalFactoryExplicitStrategy {}

contract MockGoalToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract MockGoalFactoryGoalTreasury {
    address public lastSpendPolicy;
    address public lastFlow;
    ISuperToken public lastSuperToken;

    function initialize(IGoalTreasury.GoalConfig calldata config) external {
        lastSpendPolicy = config.spendPolicy;
        lastFlow = config.flow;
        lastSuperToken = ISuperToken(MockGoalFactoryFlow(config.flow).lastSuperToken());
    }

    function flow() external view returns (address) {
        return lastFlow;
    }

    function superToken() external view returns (ISuperToken) {
        return lastSuperToken;
    }
}

contract MockGoalFactorySplitHook {
    uint256 public initializeCallCount;
    address public lastDirectory;
    address public lastGoalTreasury;
    address public lastFlow;
    address public lastSuperToken;
    uint256 public lastGoalRevnetId;

    function initialize(IJBDirectory directory_, IGoalTreasury goalTreasury_, uint256 goalRevnetId_) external {
        initializeCallCount += 1;
        lastDirectory = address(directory_);
        lastGoalTreasury = address(goalTreasury_);
        lastFlow = goalTreasury_.flow();
        lastSuperToken = address(goalTreasury_.superToken());
        lastGoalRevnetId = goalRevnetId_;
    }
}

contract MockGoalFactoryFlow {
    address public lastSuperToken;
    address public lastStrategy;

    function initialize(
        address superToken_,
        address,
        address,
        address,
        address,
        address,
        address,
        address,
        IFlow.FlowParams memory,
        FlowTypes.RecipientMetadata memory,
        IAllocationStrategy strategy_
    ) external {
        lastSuperToken = superToken_;
        lastStrategy = address(strategy_);
    }
}

contract MockGoalFactoryStakeVault {
    address public goalTreasury;
    IERC20 public goalToken;
    IERC20 public cobuildToken;

    function initialize(address goalTreasury_, IERC20 goalToken_, IERC20 cobuildToken_, IJBRulesets, uint256, uint8)
        external
    {
        goalTreasury = goalTreasury_;
        goalToken = goalToken_;
        cobuildToken = cobuildToken_;
    }
}

contract MockGoalFactoryBudgetStakeLedger {
    address public goalTreasury;

    function initialize(address goalTreasury_) external {
        goalTreasury = goalTreasury_;
    }
}

contract MockGoalFactoryAllocationPipeline {
    address public allocationLedger;

    function initialize(address allocationLedger_) external {
        allocationLedger = allocationLedger_;
    }
}

contract MockGoalFactoryJurorSlasherRouter {
    address public authority;

    function initialize(IStakeVault, address authority_) external {
        authority = authority_;
    }
}

contract MockGoalFactoryUnderwriterSlasherRouter {
    address public goalFundingTarget;

    function initialize(
        IStakeVault,
        address,
        IJBDirectory,
        uint256,
        IERC20,
        IERC20,
        ISuperToken,
        address goalFundingTarget_
    ) external {
        goalFundingTarget = goalFundingTarget_;
    }
}

contract MockGoalFactorySuperfluidHost {
    address private immutable _superTokenFactory;

    constructor(address superTokenFactory_) {
        _superTokenFactory = superTokenFactory_;
    }

    function getSuperTokenFactory() external view returns (ISuperTokenFactory) {
        return ISuperTokenFactory(_superTokenFactory);
    }
}

contract MockGoalFactorySuperTokenFactory {
    function createERC20Wrapper(
        IERC20Metadata,
        uint8,
        ISuperTokenFactory.Upgradability,
        string calldata,
        string calldata
    ) external returns (ISuperToken) {
        return ISuperToken(address(new MockGoalFactorySuperToken()));
    }
}

contract MockGoalFactorySuperToken {
    function getUnderlyingToken() external pure returns (address) {
        return address(0);
    }
}

contract MockGoalFactoryRulesets {}

contract MockGoalFactoryDirectory {}
