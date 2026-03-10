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
        GoalFactoryCoreStackDeploy.CoreStackRequest memory request = GoalFactoryCoreStackDeploy.CoreStackRequest({
            goalTreasury: GoalTreasury(address(goalTreasury)),
            splitHook: GoalRevnetSplitHook(payable(address(splitHook))),
            goalFlow: CustomFlow(payable(address(goalFlow))),
            stakeVaultImpl: address(stakeVaultImpl),
            jurorSlasherRouterImpl: address(jurorSlasherRouterImpl),
            flowImpl: address(0xF10F),
            superfluidHost: ISuperfluid(address(superfluidHost)),
            budgetTcrFactory: address(0xB6D6E7),
            underwriterSlasherRouterImpl: address(underwriterSlasherRouterImpl),
            budgetStakeLedgerImpl: address(budgetStakeLedgerImpl),
            goalFlowAllocationLedgerPipelineImpl: address(allocationPipelineImpl),
            cobuildToken: address(cobuildToken),
            cobuildDecimals: 18,
            goalRevnetId: 1,
            goalToken: address(goalToken),
            predictedBudgetTcr: address(0xB6D9E7),
            rulesets: IJBRulesets(address(rulesets)),
            directory: IJBDirectory(address(directory)),
            revnetName: "Goal",
            revnetTicker: "GOAL",
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
            goalSpendPolicy: goalSpendPolicy
        });

        GoalFactoryCoreStackDeploy.initializeCoreStack(request);

        assertEq(goalTreasury.lastSpendPolicy(), goalSpendPolicy);
    }
}

contract MockGoalToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

contract MockGoalFactoryGoalTreasury {
    address public lastOwner;
    address public lastSpendPolicy;

    function initialize(address initialOwner, IGoalTreasury.GoalConfig calldata config) external {
        lastOwner = initialOwner;
        lastSpendPolicy = config.spendPolicy;
    }
}

contract MockGoalFactorySplitHook {
    address public lastGoalTreasury;

    function initialize(IJBDirectory, IGoalTreasury goalTreasury_, IFlow, uint256) external {
        lastGoalTreasury = address(goalTreasury_);
    }
}

contract MockGoalFactoryFlow {
    address public lastSuperToken;

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
        IAllocationStrategy[] calldata
    ) external {
        lastSuperToken = superToken_;
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
