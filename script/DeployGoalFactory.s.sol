// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {GoalFactory} from "src/goals/GoalFactory.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";

import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";

import {BudgetTCRFactory} from "src/tcr/BudgetTCRFactory.sol";
import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {FakeUMATreasurySuccessResolver} from "src/mocks/FakeUMATreasurySuccessResolver.sol";

contract DeployGoalFactory is DeployScript {
    uint256 internal constant GOAL_FACTORY_CREATE_OFFSET = 3;
    string internal constant LATEST_IMPLEMENTATIONS_FILE = "deploys/LATEST_IMPLEMENTATIONS.txt";
    string internal constant HISTORY_DIR = "deploys/history";

    address internal revDeployerAddressOut;
    address internal superfluidHostAddressOut;
    address internal cobuildTokenAddressOut;
    uint256 internal cobuildRevnetIdOut;

    address internal goalTreasuryImplOut;
    address internal stakeVaultImplOut;
    address internal budgetStakeLedgerImplOut;
    address internal goalFlowAllocationLedgerPipelineImplOut;
    address internal premiumEscrowImplOut;
    address internal underwriterSlasherRouterImplOut;
    address internal customFlowImplOut;
    address internal splitHookImplOut;
    address internal budgetTcrImplOut;
    address internal erc20VotesArbitratorImplOut;
    address internal budgetTcrDeployerImplOut;

    address internal budgetTcrFactoryOut;
    address internal defaultSubmissionDepositStrategyOut;
    address internal fakeUmaResolverOut;
    address internal goalFactoryOut;

    address internal defaultAllocationMechanismAdminOut;
    address internal defaultInvalidRoundRewardsSinkOut;
    address internal fakeUmaOwnerOut;
    address internal fakeUmaEscalationManagerOut;
    bytes32 internal fakeUmaDomainIdOut;

    error GOAL_FACTORY_ADDRESS_MISMATCH(address predicted, address actual);

    function run() public override {
        super.run();
        _writeLatestImplementationArtifacts();
    }

    function deploy() internal override {
        address revDeployer = vm.envOr("REV_DEPLOYER", address(0x2cA27BDe7e7D33E353b44c27aCfCf6c78ddE251d));
        address sfHost = vm.envOr("SUPERFLUID_HOST", address(0x4C073B3baB6d8826b8C5b229f3cfdC1eC6E47E74));
        address cobuildToken = vm.envOr("COBUILD_TOKEN", address(0x62f05B1aD94c5d7B9f989A294d2A0f36a1AE10Fb));
        IERC20 cobuildErc20 = IERC20(cobuildToken);
        uint256 cobuildRevnetId = vm.envOr("COBUILD_REVNET_ID", uint256(138));

        uint256 escrowBondBps = vm.envOr("ESCROW_BOND_BPS", uint256(5000));
        address defaultAllocationMechanismAdmin = vm.envOr("DEFAULT_ALLOCATION_MECHANISM_ADMIN", deployerAddress);
        address invalidRoundRewardsSink = vm.envOr("DEFAULT_INVALID_ROUND_REWARDS_SINK", BURN);
        address fakeUmaOwner = vm.envOr("FAKE_UMA_OWNER", deployerAddress);
        address fakeUmaEscalationManager = vm.envOr("FAKE_UMA_ESCALATION_MANAGER", deployerAddress);
        bytes32 fakeUmaDomainId = vm.envOr("FAKE_UMA_DOMAIN_ID", bytes32(0));

        GoalTreasury goalTreasuryImpl = new GoalTreasury();
        StakeVault stakeVaultImpl = new StakeVault(
            address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0
        );
        BudgetStakeLedger budgetStakeLedgerImpl = new BudgetStakeLedger(deployerAddress);
        GoalFlowAllocationLedgerPipeline goalFlowAllocationLedgerPipelineImpl =
            new GoalFlowAllocationLedgerPipeline(address(0));
        BudgetTCR budgetTcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbitratorImpl = new ERC20VotesArbitrator();
        BudgetTreasury budgetTreasuryImpl = new BudgetTreasury();
        RoundFactory roundFactoryImpl = new RoundFactory();
        AllocationMechanismTCR allocationMechanismTcrImpl =
            new AllocationMechanismTCR(address(new MechanismFundingEscrow()));
        BudgetFlowRouterStrategy budgetFlowRouterStrategyImpl = new BudgetFlowRouterStrategy();
        PremiumEscrow premiumEscrowImpl = new PremiumEscrow();
        UnderwriterSlasherRouter underwriterSlasherRouterImpl = _deployUnderwriterSlasherRouterImplementation();
        CustomFlow flowImpl = new CustomFlow();
        GoalRevnetSplitHook splitHookImpl = new GoalRevnetSplitHook();

        BudgetTCRDeployer stackDeployerImpl = new BudgetTCRDeployer(
            address(budgetTreasuryImpl),
            address(roundFactoryImpl),
            address(allocationMechanismTcrImpl),
            address(arbitratorImpl),
            address(budgetFlowRouterStrategyImpl)
        );
        uint256 nextDeployerNonce = vm.getNonce(deployerAddress);
        address predictedGoalFactory =
            vm.computeCreateAddress(deployerAddress, nextDeployerNonce + GOAL_FACTORY_CREATE_OFFSET);

        BudgetTCRFactory budgetTcrFactory = new BudgetTCRFactory(
            address(budgetTcrImpl),
            address(arbitratorImpl),
            address(stackDeployerImpl),
            predictedGoalFactory,
            escrowBondBps
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
            address(stakeVaultImpl),
            address(flowImpl),
            address(splitHookImpl),
            address(budgetStakeLedgerImpl),
            address(goalFlowAllocationLedgerPipelineImpl),
            address(premiumEscrowImpl),
            address(underwriterSlasherRouterImpl),
            address(depositStrategy),
            defaultAllocationMechanismAdmin,
            invalidRoundRewardsSink
        );
        if (address(goalFactory) != predictedGoalFactory) {
            revert GOAL_FACTORY_ADDRESS_MISMATCH(predictedGoalFactory, address(goalFactory));
        }

        revDeployerAddressOut = revDeployer;
        superfluidHostAddressOut = sfHost;
        cobuildTokenAddressOut = cobuildToken;
        cobuildRevnetIdOut = cobuildRevnetId;

        goalTreasuryImplOut = address(goalTreasuryImpl);
        stakeVaultImplOut = address(stakeVaultImpl);
        budgetStakeLedgerImplOut = address(budgetStakeLedgerImpl);
        goalFlowAllocationLedgerPipelineImplOut = address(goalFlowAllocationLedgerPipelineImpl);
        premiumEscrowImplOut = address(premiumEscrowImpl);
        underwriterSlasherRouterImplOut = address(underwriterSlasherRouterImpl);
        customFlowImplOut = address(flowImpl);
        splitHookImplOut = address(splitHookImpl);
        budgetTcrImplOut = address(budgetTcrImpl);
        erc20VotesArbitratorImplOut = address(arbitratorImpl);
        budgetTcrDeployerImplOut = address(stackDeployerImpl);

        budgetTcrFactoryOut = address(budgetTcrFactory);
        defaultSubmissionDepositStrategyOut = address(depositStrategy);
        fakeUmaResolverOut = address(fakeUmaResolver);
        goalFactoryOut = address(goalFactory);

        defaultAllocationMechanismAdminOut = defaultAllocationMechanismAdmin;
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
        console2.log("StakeVault impl:", stakeVaultImplOut);
        console2.log("BudgetStakeLedger impl:", budgetStakeLedgerImplOut);
        console2.log("GoalFlowAllocationLedgerPipeline impl:", goalFlowAllocationLedgerPipelineImplOut);
        console2.log("PremiumEscrow impl:", premiumEscrowImplOut);
        console2.log("UnderwriterSlasherRouter impl:", underwriterSlasherRouterImplOut);
        console2.log("CustomFlow impl:", customFlowImplOut);
        console2.log("GoalRevnetSplitHook impl:", splitHookImplOut);
        console2.log("BudgetTCR impl:", budgetTcrImplOut);
        console2.log("ERC20VotesArbitrator impl:", erc20VotesArbitratorImplOut);
        console2.log("BudgetTCRDeployer impl:", budgetTcrDeployerImplOut);
        console2.log("--- BudgetTCR stack ---");
        console2.log("BudgetTCRFactory:", budgetTcrFactoryOut);
        console2.log("DepositStrategy:", defaultSubmissionDepositStrategyOut);
        console2.log("--- Fake resolver ---");
        console2.log("FakeUMATreasurySuccessResolver:", fakeUmaResolverOut);
        console2.log("FAKE_UMA_OWNER:", fakeUmaOwnerOut);
        console2.log("--- Goal factory ---");
        console2.log("GoalFactory:", goalFactoryOut);
    }

    function _deployUnderwriterSlasherRouterImplementation() internal returns (UnderwriterSlasherRouter) {
        return new UnderwriterSlasherRouter(
            IStakeVault(address(0)),
            address(0),
            IJBDirectory(address(0)),
            0,
            IERC20(address(0)),
            IERC20(address(0)),
            ISuperToken(address(0)),
            address(0)
        );
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
        _writeAddressLine(filePath, "StakeVaultImpl", stakeVaultImplOut);
        _writeAddressLine(filePath, "BudgetStakeLedgerImpl", budgetStakeLedgerImplOut);
        _writeAddressLine(filePath, "GoalFlowAllocationLedgerPipelineImpl", goalFlowAllocationLedgerPipelineImplOut);
        _writeAddressLine(filePath, "PremiumEscrowImpl", premiumEscrowImplOut);
        _writeAddressLine(filePath, "UnderwriterSlasherRouterImpl", underwriterSlasherRouterImplOut);
        _writeAddressLine(filePath, "CustomFlowImpl", customFlowImplOut);
        _writeAddressLine(filePath, "GoalRevnetSplitHookImpl", splitHookImplOut);
        _writeAddressLine(filePath, "BudgetTCRImpl", budgetTcrImplOut);
        _writeAddressLine(filePath, "ERC20VotesArbitratorImpl", erc20VotesArbitratorImplOut);
        _writeAddressLine(filePath, "BudgetTCRDeployerImpl", budgetTcrDeployerImplOut);

        _writeAddressLine(filePath, "BudgetTCRFactory", budgetTcrFactoryOut);
        _writeAddressLine(filePath, "DefaultSubmissionDepositStrategy", defaultSubmissionDepositStrategyOut);
        _writeAddressLine(filePath, "FakeUMATreasurySuccessResolver", fakeUmaResolverOut);
        _writeAddressLine(filePath, "GoalFactory", goalFactoryOut);

        _writeAddressLine(filePath, "DEFAULT_ALLOCATION_MECHANISM_ADMIN", defaultAllocationMechanismAdminOut);
        _writeAddressLine(filePath, "DEFAULT_INVALID_ROUND_REWARDS_SINK", defaultInvalidRoundRewardsSinkOut);
        _writeAddressLine(filePath, "FAKE_UMA_OWNER", fakeUmaOwnerOut);
        _writeAddressLine(filePath, "FAKE_UMA_ESCALATION_MANAGER", fakeUmaEscalationManagerOut);
        vm.writeLine(filePath, string(abi.encodePacked("FAKE_UMA_DOMAIN_ID: ", vm.toString(fakeUmaDomainIdOut))));
    }

    function _writeLatestImplementationArtifacts() internal {
        string memory canonicalFilePath =
            string(abi.encodePacked("deploys/", deploymentName(), ".", vm.toString(chainId), ".txt"));
        string memory artifact = vm.readFile(canonicalFilePath);

        vm.writeFile(LATEST_IMPLEMENTATIONS_FILE, artifact);
        console2.log("Latest implementation artifact written:", LATEST_IMPLEMENTATIONS_FILE);

        vm.createDir(HISTORY_DIR, true);
        uint256 unixTimeMs = vm.unixTime();
        uint256 collisionIndex;
        string memory snapshotFilePath = _snapshotFilePath(unixTimeMs, collisionIndex);
        while (vm.isFile(snapshotFilePath)) {
            unchecked {
                collisionIndex++;
            }
            snapshotFilePath = _snapshotFilePath(unixTimeMs, collisionIndex);
        }
        vm.writeFile(snapshotFilePath, artifact);
        console2.log("Implementation snapshot written:", snapshotFilePath);
    }

    function _snapshotFilePath(uint256 unixTimeMs, uint256 collisionIndex) internal view returns (string memory) {
        if (collisionIndex == 0) {
            return string(
                abi.encodePacked(
                    HISTORY_DIR, "/", deploymentName(), ".", vm.toString(chainId), ".", vm.toString(unixTimeMs), ".txt"
                )
            );
        }

        return string(
            abi.encodePacked(
                HISTORY_DIR,
                "/",
                deploymentName(),
                ".",
                vm.toString(chainId),
                ".",
                vm.toString(unixTimeMs),
                ".",
                vm.toString(collisionIndex),
                ".txt"
            )
        );
    }
}
