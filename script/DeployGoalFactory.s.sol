// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";
import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";

import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";

import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {FakeUMATreasurySuccessResolver} from "src/mocks/FakeUMATreasurySuccessResolver.sol";

contract DeployGoalFactory is DeployScript {
    address internal revDeployerAddressOut;
    address internal superfluidHostAddressOut;
    address internal cobuildTokenAddressOut;
    uint256 internal cobuildRevnetIdOut;

    address internal goalTreasuryImplOut;
    address internal customFlowImplOut;
    address internal splitHookImplOut;

    address internal budgetTcrFactoryOut;
    address internal defaultSubmissionDepositStrategyOut;
    address internal fakeUmaResolverOut;
    address internal goalFactoryOut;

    address internal defaultBudgetTcrGovernorOut;
    address internal defaultInvalidRoundRewardsSinkOut;
    address internal fakeUmaOwnerOut;
    address internal fakeUmaEscalationManagerOut;
    bytes32 internal fakeUmaDomainIdOut;

    function deploy() internal override {
        address revDeployer = vm.envOr("REV_DEPLOYER", address(0x2cA27BDe7e7D33E353b44c27aCfCf6c78ddE251d));
        address sfHost = vm.envOr("SUPERFLUID_HOST", address(0x4C073B3baB6d8826b8C5b229f3cfdC1eC6E47E74));
        address cobuildToken = vm.envOr("COBUILD_TOKEN", address(0x62f05B1aD94c5d7B9f989A294d2A0f36a1AE10Fb));
        IERC20 cobuildErc20 = IERC20(cobuildToken);
        uint256 cobuildRevnetId = vm.envOr("COBUILD_REVNET_ID", uint256(138));

        uint256 escrowBondBps = vm.envOr("ESCROW_BOND_BPS", uint256(5000));
        address defaultGovernor = vm.envOr("DEFAULT_BUDGET_TCR_GOVERNOR", BURN);
        address invalidRoundRewardsSink = vm.envOr("DEFAULT_INVALID_ROUND_REWARDS_SINK", BURN);
        address fakeUmaOwner = vm.envOr("FAKE_UMA_OWNER", deployerAddress);
        address fakeUmaEscalationManager = vm.envOr("FAKE_UMA_ESCALATION_MANAGER", deployerAddress);
        bytes32 fakeUmaDomainId = vm.envOr("FAKE_UMA_DOMAIN_ID", bytes32(0));

        IGoalTreasury.GoalConfig memory emptyGoalConfig;
        GoalTreasury goalTreasuryImpl = new GoalTreasury(address(0), emptyGoalConfig);
        CustomFlow flowImpl = new CustomFlow();
        GoalRevnetSplitHook splitHookImpl =
            new GoalRevnetSplitHook(IJBDirectory(address(0)), IGoalTreasury(address(0)), IFlow(address(0)), 0);

        BudgetTCRDeployer stackDeployerImpl = new BudgetTCRDeployer();
        BudgetTCR budgetTcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbitratorImpl = new ERC20VotesArbitrator();

        BudgetTCRFactory budgetTcrFactory = new BudgetTCRFactory(
            address(budgetTcrImpl), address(arbitratorImpl), address(stackDeployerImpl), escrowBondBps
        );

        PrizePoolSubmissionDepositStrategy depositStrategy = new PrizePoolSubmissionDepositStrategy(cobuildErc20, BURN);

        FakeUMATreasurySuccessResolver fakeUmaResolver =
            new FakeUMATreasurySuccessResolver(cobuildErc20, fakeUmaEscalationManager, fakeUmaDomainId, fakeUmaOwner);

        GoalFactory goalFactory = new GoalFactory(
            IREVDeployer(revDeployer),
            ISuperfluid(sfHost),
            budgetTcrFactory,
            cobuildToken,
            cobuildRevnetId,
            address(goalTreasuryImpl),
            address(flowImpl),
            address(splitHookImpl),
            address(depositStrategy),
            defaultGovernor,
            invalidRoundRewardsSink
        );

        revDeployerAddressOut = revDeployer;
        superfluidHostAddressOut = sfHost;
        cobuildTokenAddressOut = cobuildToken;
        cobuildRevnetIdOut = cobuildRevnetId;

        goalTreasuryImplOut = address(goalTreasuryImpl);
        customFlowImplOut = address(flowImpl);
        splitHookImplOut = address(splitHookImpl);

        budgetTcrFactoryOut = address(budgetTcrFactory);
        defaultSubmissionDepositStrategyOut = address(depositStrategy);
        fakeUmaResolverOut = address(fakeUmaResolver);
        goalFactoryOut = address(goalFactory);

        defaultBudgetTcrGovernorOut = defaultGovernor;
        defaultInvalidRoundRewardsSinkOut = invalidRoundRewardsSink;
        fakeUmaOwnerOut = fakeUmaOwner;
        fakeUmaEscalationManagerOut = fakeUmaEscalationManager;
        fakeUmaDomainIdOut = fakeUmaDomainId;

        console2.log("Deployer:", deployerAddress);
        console2.log("--- Core addresses ---");
        console2.log("REV_DEPLOYER:", revDeployerAddressOut);
        console2.log("SUPERFLUID_HOST:", superfluidHostAddressOut);
        console2.log("COBUILD_TOKEN:", cobuildTokenAddressOut);
        console2.log("COBUILD_REVNET_ID:", cobuildRevnetIdOut);
        console2.log("--- Impl addresses ---");
        console2.log("GoalTreasury impl:", goalTreasuryImplOut);
        console2.log("CustomFlow impl:", customFlowImplOut);
        console2.log("GoalRevnetSplitHook impl:", splitHookImplOut);
        console2.log("--- BudgetTCR stack ---");
        console2.log("BudgetTCRFactory:", budgetTcrFactoryOut);
        console2.log("DepositStrategy:", defaultSubmissionDepositStrategyOut);
        console2.log("--- Fake resolver ---");
        console2.log("FakeUMATreasurySuccessResolver:", fakeUmaResolverOut);
        console2.log("FAKE_UMA_OWNER:", fakeUmaOwnerOut);
        console2.log("--- Goal factory ---");
        console2.log("GoalFactory:", goalFactoryOut);
    }

    function deploymentName() internal pure override returns (string memory) {
        return "DeployGoalFactory";
    }

    function writeDeploymentDetails(string memory filePath) internal override {
        _writeAddressLine(filePath, "REV_DEPLOYER", revDeployerAddressOut);
        _writeAddressLine(filePath, "SUPERFLUID_HOST", superfluidHostAddressOut);
        _writeAddressLine(filePath, "COBUILD_TOKEN", cobuildTokenAddressOut);
        _writeUintLine(filePath, "COBUILD_REVNET_ID", cobuildRevnetIdOut);

        _writeAddressLine(filePath, "GoalTreasuryImpl", goalTreasuryImplOut);
        _writeAddressLine(filePath, "CustomFlowImpl", customFlowImplOut);
        _writeAddressLine(filePath, "GoalRevnetSplitHookImpl", splitHookImplOut);

        _writeAddressLine(filePath, "BudgetTCRFactory", budgetTcrFactoryOut);
        _writeAddressLine(filePath, "DefaultSubmissionDepositStrategy", defaultSubmissionDepositStrategyOut);
        _writeAddressLine(filePath, "FakeUMATreasurySuccessResolver", fakeUmaResolverOut);
        _writeAddressLine(filePath, "GoalFactory", goalFactoryOut);

        _writeAddressLine(filePath, "DEFAULT_BUDGET_TCR_GOVERNOR", defaultBudgetTcrGovernorOut);
        _writeAddressLine(filePath, "DEFAULT_INVALID_ROUND_REWARDS_SINK", defaultInvalidRoundRewardsSinkOut);
        _writeAddressLine(filePath, "FAKE_UMA_OWNER", fakeUmaOwnerOut);
        _writeAddressLine(filePath, "FAKE_UMA_ESCALATION_MANAGER", fakeUmaEscalationManagerOut);
        vm.writeLine(filePath, string(abi.encodePacked("FAKE_UMA_DOMAIN_ID: ", vm.toString(fakeUmaDomainIdOut))));
    }
}
