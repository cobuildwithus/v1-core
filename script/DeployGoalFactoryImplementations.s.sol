// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBRulesets} from "@bananapus/core-v5/interfaces/IJBRulesets.sol";

import {DeployScript} from "script/DeployScript.s.sol";
import {IREVDeployer} from "src/interfaces/external/revnet/IREVDeployer.sol";
import {CobuildTerminal} from "src/juicebox/CobuildTerminal.sol";
import {IStakeVault} from "src/interfaces/IStakeVault.sol";
import {GoalTreasury} from "src/goals/GoalTreasury.sol";
import {StakeVault} from "src/goals/StakeVault.sol";
import {BudgetStakeLedger} from "src/goals/BudgetStakeLedger.sol";
import {BudgetTreasury} from "src/goals/BudgetTreasury.sol";
import {JurorSlasherRouter} from "src/goals/JurorSlasherRouter.sol";
import {PremiumEscrow} from "src/goals/PremiumEscrow.sol";
import {UnderwriterSlasherRouter} from "src/goals/UnderwriterSlasherRouter.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {GoalRevnetSplitHook} from "src/hooks/GoalRevnetSplitHook.sol";
import {GoalFlowAllocationLedgerPipeline} from "src/hooks/GoalFlowAllocationLedgerPipeline.sol";
import {TeamFlow} from "src/teamflow/TeamFlow.sol";
import {TeamFlowFactory} from "src/teamflow/TeamFlowFactory.sol";
import {BudgetTCR} from "src/tcr/BudgetTCR.sol";
import {ERC20VotesArbitrator} from "src/tcr/ERC20VotesArbitrator.sol";
import {BudgetTCRDeployer} from "src/tcr/BudgetTCRDeployer.sol";
import {AllocationMechanismTCR} from "src/tcr/AllocationMechanismTCR.sol";
import {BudgetFlowRouterStrategy} from "src/allocation-strategies/BudgetFlowRouterStrategy.sol";
import {MechanismFundingEscrow} from "src/escrow/MechanismFundingEscrow.sol";
import {RoundFactory} from "src/rounds/RoundFactory.sol";
import {RoundPrizeVault} from "src/rounds/RoundPrizeVault.sol";
import {RoundSubmissionTCR} from "src/tcr/RoundSubmissionTCR.sol";
import {PrizePoolSubmissionDepositStrategy} from "src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol";
import {FakeUMATreasurySuccessResolver} from "src/mocks/FakeUMATreasurySuccessResolver.sol";

contract DeployGoalFactoryImplementations is DeployScript {
    string internal constant LATEST_IMPLEMENTATIONS_FILE = "deploys/LATEST_IMPLEMENTATIONS.txt";
    string internal constant LATEST_IMPLEMENTATIONS_TOML_FILE = "deploys/LATEST_IMPLEMENTATIONS.toml";
    string internal constant HISTORY_DIR = "deploys/history";

    address internal revDeployerAddressOut;
    address internal superfluidHostAddressOut;
    address internal cobuildTokenAddressOut;
    uint256 internal cobuildRevnetIdOut;
    address internal cobuildTerminalOut;
    address internal buybackHookDataHookOut;
    address internal buybackHookOut;

    address internal goalTreasuryImplOut;
    address internal stakeVaultImplOut;
    address internal budgetStakeLedgerImplOut;
    address internal goalFlowAllocationLedgerPipelineImplOut;
    address internal premiumEscrowImplOut;
    address internal jurorSlasherRouterImplOut;
    address internal underwriterSlasherRouterImplOut;
    address internal customFlowImplOut;
    address internal splitHookImplOut;
    address internal budgetTcrImplOut;
    address internal erc20VotesArbitratorImplOut;
    address internal budgetTcrDeployerImplOut;
    address internal budgetTreasuryImplOut;
    address internal roundSubmissionTcrImplOut;
    address internal roundPrizeVaultImplOut;
    address internal prizePoolSubmissionDepositStrategyImplOut;
    address internal roundFactoryImplOut;
    address internal allocationMechanismTcrImplOut;
    address internal budgetFlowRouterStrategyImplOut;
    address internal teamFlowImplOut;
    address internal teamFlowFactoryImplOut;

    address internal defaultSubmissionDepositStrategyOut;
    uint256 internal escrowBondBpsOut;
    address internal defaultAllocationMechanismAdminOut;
    address internal defaultInvalidRoundRewardsSinkOut;

    address internal fakeUmaResolverOut;
    address internal fakeUmaOwnerOut;
    address internal fakeUmaEscalationManagerOut;
    bytes32 internal fakeUmaDomainIdOut;

    function run() public override {
        super.run();
        _writeLatestImplementationArtifacts();
        _writeLatestImplementationTomlArtifacts();
    }

    function deploy() internal override {
        revDeployerAddressOut = vm.envOr("REV_DEPLOYER", address(0x2cA27BDe7e7D33E353b44c27aCfCf6c78ddE251d));
        superfluidHostAddressOut = vm.envOr("SUPERFLUID_HOST", address(0x4C073B3baB6d8826b8C5b229f3cfdC1eC6E47E74));
        cobuildTokenAddressOut = vm.envOr("COBUILD_TOKEN", address(0x62f05B1aD94c5d7B9f989A294d2A0f36a1AE10Fb));
        cobuildRevnetIdOut = vm.envOr("COBUILD_REVNET_ID", uint256(138));
        buybackHookDataHookOut = vm.envAddress("BUYBACK_HOOK_DATA_HOOK");
        buybackHookOut = vm.envAddress("BUYBACK_HOOK");

        escrowBondBpsOut = vm.envOr("ESCROW_BOND_BPS", uint256(5000));
        defaultAllocationMechanismAdminOut = vm.envOr("DEFAULT_ALLOCATION_MECHANISM_ADMIN", deployerAddress);
        defaultInvalidRoundRewardsSinkOut = vm.envOr("DEFAULT_INVALID_ROUND_REWARDS_SINK", BURN);

        fakeUmaOwnerOut = vm.envOr("FAKE_UMA_OWNER", deployerAddress);
        fakeUmaEscalationManagerOut = vm.envOr("FAKE_UMA_ESCALATION_MANAGER", deployerAddress);
        fakeUmaDomainIdOut = vm.envOr("FAKE_UMA_DOMAIN_ID", bytes32(0));

        CobuildTerminal cobuildTerminal = new CobuildTerminal(
            IREVDeployer(revDeployerAddressOut).DIRECTORY(), cobuildTokenAddressOut, cobuildRevnetIdOut
        );

        GoalTreasury goalTreasuryImpl = new GoalTreasury();
        StakeVault stakeVaultImpl =
            new StakeVault(address(0), IERC20(address(0)), IERC20(address(0)), IJBRulesets(address(0)), 0, 0);
        BudgetStakeLedger budgetStakeLedgerImpl = new BudgetStakeLedger(deployerAddress);
        GoalFlowAllocationLedgerPipeline goalFlowAllocationLedgerPipelineImpl =
            new GoalFlowAllocationLedgerPipeline(address(0));
        BudgetTCR budgetTcrImpl = new BudgetTCR();
        ERC20VotesArbitrator arbitratorImpl = new ERC20VotesArbitrator();
        BudgetTreasury budgetTreasuryImpl = new BudgetTreasury();
        RoundSubmissionTCR roundSubmissionTcrImpl = new RoundSubmissionTCR();
        RoundPrizeVault roundPrizeVaultImpl = new RoundPrizeVault();
        PrizePoolSubmissionDepositStrategy prizePoolSubmissionDepositStrategyImpl =
            new PrizePoolSubmissionDepositStrategy();
        RoundFactory roundFactoryImpl = new RoundFactory(
            address(roundSubmissionTcrImpl),
            address(roundPrizeVaultImpl),
            address(prizePoolSubmissionDepositStrategyImpl),
            address(arbitratorImpl)
        );
        AllocationMechanismTCR allocationMechanismTcrImpl =
            new AllocationMechanismTCR(address(new MechanismFundingEscrow()));
        BudgetFlowRouterStrategy budgetFlowRouterStrategyImpl = new BudgetFlowRouterStrategy();
        PremiumEscrow premiumEscrowImpl = new PremiumEscrow();
        JurorSlasherRouter jurorSlasherRouterImpl = _deployJurorSlasherRouterImplementation();
        UnderwriterSlasherRouter underwriterSlasherRouterImpl = _deployUnderwriterSlasherRouterImplementation();
        CustomFlow flowImpl = new CustomFlow();
        TeamFlow teamFlowImpl = new TeamFlow();
        TeamFlowFactory teamFlowFactoryImpl = new TeamFlowFactory(address(teamFlowImpl));
        GoalRevnetSplitHook splitHookImpl = new GoalRevnetSplitHook();

        BudgetTCRDeployer stackDeployerImpl = new BudgetTCRDeployer(
            address(budgetTreasuryImpl),
            address(roundFactoryImpl),
            address(teamFlowFactoryImpl),
            address(allocationMechanismTcrImpl),
            address(arbitratorImpl),
            address(budgetFlowRouterStrategyImpl)
        );

        PrizePoolSubmissionDepositStrategy defaultSubmissionDepositStrategy =
            PrizePoolSubmissionDepositStrategy(Clones.clone(address(prizePoolSubmissionDepositStrategyImpl)));
        defaultSubmissionDepositStrategy.initialize(IERC20(cobuildTokenAddressOut), BURN);
        FakeUMATreasurySuccessResolver fakeUmaResolver = new FakeUMATreasurySuccessResolver(
            IERC20(cobuildTokenAddressOut), fakeUmaEscalationManagerOut, fakeUmaDomainIdOut, fakeUmaOwnerOut
        );

        goalTreasuryImplOut = address(goalTreasuryImpl);
        stakeVaultImplOut = address(stakeVaultImpl);
        budgetStakeLedgerImplOut = address(budgetStakeLedgerImpl);
        goalFlowAllocationLedgerPipelineImplOut = address(goalFlowAllocationLedgerPipelineImpl);
        premiumEscrowImplOut = address(premiumEscrowImpl);
        jurorSlasherRouterImplOut = address(jurorSlasherRouterImpl);
        underwriterSlasherRouterImplOut = address(underwriterSlasherRouterImpl);
        customFlowImplOut = address(flowImpl);
        splitHookImplOut = address(splitHookImpl);
        budgetTcrImplOut = address(budgetTcrImpl);
        erc20VotesArbitratorImplOut = address(arbitratorImpl);
        budgetTcrDeployerImplOut = address(stackDeployerImpl);
        budgetTreasuryImplOut = address(budgetTreasuryImpl);
        roundSubmissionTcrImplOut = address(roundSubmissionTcrImpl);
        roundPrizeVaultImplOut = address(roundPrizeVaultImpl);
        prizePoolSubmissionDepositStrategyImplOut = address(prizePoolSubmissionDepositStrategyImpl);
        roundFactoryImplOut = address(roundFactoryImpl);
        allocationMechanismTcrImplOut = address(allocationMechanismTcrImpl);
        budgetFlowRouterStrategyImplOut = address(budgetFlowRouterStrategyImpl);
        teamFlowImplOut = address(teamFlowImpl);
        teamFlowFactoryImplOut = address(teamFlowFactoryImpl);

        defaultSubmissionDepositStrategyOut = address(defaultSubmissionDepositStrategy);
        cobuildTerminalOut = address(cobuildTerminal);
        fakeUmaResolverOut = address(fakeUmaResolver);

        console2.log("Deployer:", deployerAddress);
        console2.log("--- Core addresses ---");
        console2.log("REV_DEPLOYER:", revDeployerAddressOut);
        console2.log("SUPERFLUID_HOST:", superfluidHostAddressOut);
        console2.log("COBUILD_TOKEN:", cobuildTokenAddressOut);
        console2.log("COBUILD_REVNET_ID:", cobuildRevnetIdOut);
        console2.log("COBUILD_TERMINAL:", cobuildTerminalOut);
        console2.log("BUYBACK_HOOK_DATA_HOOK:", buybackHookDataHookOut);
        console2.log("BUYBACK_HOOK:", buybackHookOut);
        console2.log("--- Impl addresses ---");
        console2.log("GoalTreasury impl:", goalTreasuryImplOut);
        console2.log("StakeVault impl:", stakeVaultImplOut);
        console2.log("BudgetStakeLedger impl:", budgetStakeLedgerImplOut);
        console2.log("GoalFlowAllocationLedgerPipeline impl:", goalFlowAllocationLedgerPipelineImplOut);
        console2.log("PremiumEscrow impl:", premiumEscrowImplOut);
        console2.log("JurorSlasherRouter impl:", jurorSlasherRouterImplOut);
        console2.log("UnderwriterSlasherRouter impl:", underwriterSlasherRouterImplOut);
        console2.log("CustomFlow impl:", customFlowImplOut);
        console2.log("GoalRevnetSplitHook impl:", splitHookImplOut);
        console2.log("BudgetTCR impl:", budgetTcrImplOut);
        console2.log("ERC20VotesArbitrator impl:", erc20VotesArbitratorImplOut);
        console2.log("BudgetTCRDeployer impl:", budgetTcrDeployerImplOut);
        console2.log("--- Shared runtime deps ---");
        console2.log("RoundSubmissionTCR impl:", roundSubmissionTcrImplOut);
        console2.log("RoundPrizeVault impl:", roundPrizeVaultImplOut);
        console2.log("PrizePoolSubmissionDepositStrategy impl:", prizePoolSubmissionDepositStrategyImplOut);
        console2.log("RoundFactory impl:", roundFactoryImplOut);
        console2.log("AllocationMechanismTCR impl:", allocationMechanismTcrImplOut);
        console2.log("BudgetFlowRouterStrategy impl:", budgetFlowRouterStrategyImplOut);
        console2.log("TeamFlow impl:", teamFlowImplOut);
        console2.log("TeamFlowFactory impl:", teamFlowFactoryImplOut);
        console2.log("DefaultSubmissionDepositStrategy:", defaultSubmissionDepositStrategyOut);
        console2.log("--- Fake resolver ---");
        console2.log("FakeUMATreasurySuccessResolver:", fakeUmaResolverOut);
        console2.log("FAKE_UMA_OWNER:", fakeUmaOwnerOut);
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

    function _deployJurorSlasherRouterImplementation() internal returns (JurorSlasherRouter) {
        return new JurorSlasherRouter(IStakeVault(address(0)), address(0));
    }

    function deploymentName() internal pure override returns (string memory) {
        return "DeployGoalFactoryImplementations";
    }

    function writeDeploymentDetails(string memory filePath) internal override {
        _writeAddressLine(filePath, "REV_DEPLOYER", revDeployerAddressOut);
        _writeAddressLine(filePath, "SUPERFLUID_HOST", superfluidHostAddressOut);
        _writeAddressLine(filePath, "COBUILD_TOKEN", cobuildTokenAddressOut);
        _writeUintLine(filePath, "COBUILD_REVNET_ID", cobuildRevnetIdOut);
        _writeAddressLine(filePath, "COBUILD_TERMINAL", cobuildTerminalOut);
        _writeAddressLine(filePath, "BUYBACK_HOOK_DATA_HOOK", buybackHookDataHookOut);
        _writeAddressLine(filePath, "BUYBACK_HOOK", buybackHookOut);

        _writeAddressLine(filePath, "GoalTreasuryImpl", goalTreasuryImplOut);
        _writeAddressLine(filePath, "StakeVaultImpl", stakeVaultImplOut);
        _writeAddressLine(filePath, "BudgetStakeLedgerImpl", budgetStakeLedgerImplOut);
        _writeAddressLine(filePath, "GoalFlowAllocationLedgerPipelineImpl", goalFlowAllocationLedgerPipelineImplOut);
        _writeAddressLine(filePath, "PremiumEscrowImpl", premiumEscrowImplOut);
        _writeAddressLine(filePath, "JurorSlasherRouterImpl", jurorSlasherRouterImplOut);
        _writeAddressLine(filePath, "UnderwriterSlasherRouterImpl", underwriterSlasherRouterImplOut);
        _writeAddressLine(filePath, "CustomFlowImpl", customFlowImplOut);
        _writeAddressLine(filePath, "GoalRevnetSplitHookImpl", splitHookImplOut);
        _writeAddressLine(filePath, "BudgetTCRImpl", budgetTcrImplOut);
        _writeAddressLine(filePath, "ERC20VotesArbitratorImpl", erc20VotesArbitratorImplOut);
        _writeAddressLine(filePath, "BudgetTCRDeployerImpl", budgetTcrDeployerImplOut);
        _writeAddressLine(filePath, "BudgetTreasuryImpl", budgetTreasuryImplOut);
        _writeAddressLine(filePath, "RoundSubmissionTCRImpl", roundSubmissionTcrImplOut);
        _writeAddressLine(filePath, "RoundPrizeVaultImpl", roundPrizeVaultImplOut);
        _writeAddressLine(filePath, "PrizePoolSubmissionDepositStrategyImpl", prizePoolSubmissionDepositStrategyImplOut);
        _writeAddressLine(filePath, "RoundFactoryImpl", roundFactoryImplOut);
        _writeAddressLine(filePath, "AllocationMechanismTCRImpl", allocationMechanismTcrImplOut);
        _writeAddressLine(filePath, "BudgetFlowRouterStrategyImpl", budgetFlowRouterStrategyImplOut);

        _writeAddressLine(filePath, "DefaultSubmissionDepositStrategy", defaultSubmissionDepositStrategyOut);
        _writeUintLine(filePath, "ESCROW_BOND_BPS", escrowBondBpsOut);
        _writeAddressLine(filePath, "DEFAULT_ALLOCATION_MECHANISM_ADMIN", defaultAllocationMechanismAdminOut);
        _writeAddressLine(filePath, "DEFAULT_INVALID_ROUND_REWARDS_SINK", defaultInvalidRoundRewardsSinkOut);

        _writeAddressLine(filePath, "FakeUMATreasurySuccessResolver", fakeUmaResolverOut);
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

        string memory chainScopedLatest =
            string(abi.encodePacked("deploys/LATEST_IMPLEMENTATIONS.", vm.toString(chainId), ".txt"));
        vm.writeFile(chainScopedLatest, artifact);
        console2.log("Chain-scoped implementation artifact written:", chainScopedLatest);

        _writeHistorySnapshot(artifact, ".txt", "Implementation snapshot written:");
    }

    function _writeLatestImplementationTomlArtifacts() internal {
        string memory artifact = _buildTomlArtifact();

        vm.writeFile(LATEST_IMPLEMENTATIONS_TOML_FILE, artifact);
        console2.log("Latest implementation TOML written:", LATEST_IMPLEMENTATIONS_TOML_FILE);

        string memory chainScopedLatest =
            string(abi.encodePacked("deploys/LATEST_IMPLEMENTATIONS.", vm.toString(chainId), ".toml"));
        vm.writeFile(chainScopedLatest, artifact);
        console2.log("Chain-scoped implementation TOML written:", chainScopedLatest);

        _writeHistorySnapshot(artifact, ".toml", "Implementation TOML snapshot written:");
    }

    function _writeHistorySnapshot(string memory artifact, string memory extension, string memory logLabel) internal {
        vm.createDir(HISTORY_DIR, true);
        uint256 unixTimeMs = vm.unixTime();
        uint256 collisionIndex;
        string memory snapshotFilePath = _snapshotFilePath(unixTimeMs, collisionIndex, extension);
        while (vm.isFile(snapshotFilePath)) {
            unchecked {
                collisionIndex++;
            }
            snapshotFilePath = _snapshotFilePath(unixTimeMs, collisionIndex, extension);
        }
        vm.writeFile(snapshotFilePath, artifact);
        console2.log(logLabel, snapshotFilePath);
    }

    function _snapshotFilePath(uint256 unixTimeMs, uint256 collisionIndex, string memory extension)
        internal
        view
        returns (string memory)
    {
        if (collisionIndex == 0) {
            return string(
                abi.encodePacked(
                    HISTORY_DIR,
                    "/",
                    deploymentName(),
                    ".",
                    vm.toString(chainId),
                    ".",
                    vm.toString(unixTimeMs),
                    extension
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
                extension
            )
        );
    }

    function _buildTomlArtifact() internal view returns (string memory artifact) {
        artifact = string.concat(
            "[core]\n",
            "chainId = ",
            vm.toString(chainId),
            "\n",
            "deployer = \"",
            vm.toString(deployerAddress),
            "\"\n",
            "revDeployer = \"",
            vm.toString(revDeployerAddressOut),
            "\"\n",
            "superfluidHost = \"",
            vm.toString(superfluidHostAddressOut),
            "\"\n",
            "cobuildToken = \"",
            vm.toString(cobuildTokenAddressOut),
            "\"\n",
            "cobuildRevnetId = ",
            vm.toString(cobuildRevnetIdOut),
            "\n",
            "cobuildTerminal = \"",
            vm.toString(cobuildTerminalOut),
            "\"\n",
            "buybackHookDataHook = \"",
            vm.toString(buybackHookDataHookOut),
            "\"\n",
            "buybackHook = \"",
            vm.toString(buybackHookOut),
            "\"\n\n"
        );

        artifact = string.concat(
            artifact,
            "[implementations]\n",
            "goalTreasury = \"",
            vm.toString(goalTreasuryImplOut),
            "\"\n",
            "stakeVault = \"",
            vm.toString(stakeVaultImplOut),
            "\"\n",
            "budgetStakeLedger = \"",
            vm.toString(budgetStakeLedgerImplOut),
            "\"\n",
            "goalFlowAllocationLedgerPipeline = \"",
            vm.toString(goalFlowAllocationLedgerPipelineImplOut),
            "\"\n",
            "premiumEscrow = \"",
            vm.toString(premiumEscrowImplOut),
            "\"\n",
            "jurorSlasherRouter = \"",
            vm.toString(jurorSlasherRouterImplOut),
            "\"\n",
            "underwriterSlasherRouter = \"",
            vm.toString(underwriterSlasherRouterImplOut),
            "\"\n",
            "customFlow = \"",
            vm.toString(customFlowImplOut),
            "\"\n",
            "goalRevnetSplitHook = \"",
            vm.toString(splitHookImplOut),
            "\"\n"
        );

        artifact = string.concat(
            artifact,
            "budgetTCR = \"",
            vm.toString(budgetTcrImplOut),
            "\"\n",
            "erc20VotesArbitrator = \"",
            vm.toString(erc20VotesArbitratorImplOut),
            "\"\n",
            "budgetTCRDeployer = \"",
            vm.toString(budgetTcrDeployerImplOut),
            "\"\n",
            "budgetTreasury = \"",
            vm.toString(budgetTreasuryImplOut),
            "\"\n",
            "roundSubmissionTCR = \"",
            vm.toString(roundSubmissionTcrImplOut),
            "\"\n",
            "roundPrizeVault = \"",
            vm.toString(roundPrizeVaultImplOut),
            "\"\n",
            "prizePoolSubmissionDepositStrategy = \"",
            vm.toString(prizePoolSubmissionDepositStrategyImplOut),
            "\"\n",
            "roundFactory = \"",
            vm.toString(roundFactoryImplOut),
            "\"\n",
            "allocationMechanismTCR = \"",
            vm.toString(allocationMechanismTcrImplOut),
            "\"\n",
            "budgetFlowRouterStrategy = \"",
            vm.toString(budgetFlowRouterStrategyImplOut),
            "\"\n\n"
        );

        artifact = string.concat(
            artifact,
            "[defaults]\n",
            "escrowBondBps = ",
            vm.toString(escrowBondBpsOut),
            "\n",
            "allocationMechanismAdmin = \"",
            vm.toString(defaultAllocationMechanismAdminOut),
            "\"\n",
            "invalidRoundRewardsSink = \"",
            vm.toString(defaultInvalidRoundRewardsSinkOut),
            "\"\n",
            "submissionDepositStrategy = \"",
            vm.toString(defaultSubmissionDepositStrategyOut),
            "\"\n\n"
        );

        artifact = string.concat(
            artifact,
            "[fakeUma]\n",
            "resolver = \"",
            vm.toString(fakeUmaResolverOut),
            "\"\n",
            "owner = \"",
            vm.toString(fakeUmaOwnerOut),
            "\"\n",
            "escalationManager = \"",
            vm.toString(fakeUmaEscalationManagerOut),
            "\"\n",
            "domainId = \"",
            vm.toString(fakeUmaDomainIdOut),
            "\"\n"
        );
    }
}
