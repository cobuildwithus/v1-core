// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { GoalFactory } from "src/goals/GoalFactory.sol";
import { IREVDeployer } from "src/interfaces/external/revnet/IREVDeployer.sol";
import { ISuperfluid } from
    "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { BudgetTCRFactory } from "src/tcr/BudgetTCRFactory.sol";

contract GoalFactoryUnderwritingSlashConfigGuardTest is Test {
    GoalFactory internal factory;

    function setUp() public {
        MockToken cobuildToken = new MockToken();
        DummyContract goalTreasuryImpl = new DummyContract();
        DummyContract flowImpl = new DummyContract();
        DummyContract splitHookImpl = new DummyContract();
        DummyContract defaultSubmissionDepositStrategy = new DummyContract();

        factory = new GoalFactory(
            IREVDeployer(address(0x1001)),
            ISuperfluid(address(0x1002)),
            BudgetTCRFactory(address(0x1003)),
            address(cobuildToken),
            1,
            address(goalTreasuryImpl),
            address(flowImpl),
            address(splitHookImpl),
            address(defaultSubmissionDepositStrategy),
            address(0x1004),
            address(0x1005)
        );
    }

    function test_deployGoal_revertsWhenSlashEnabledAndBudgetPremiumPpmIsZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.underwriting.coverageLambda = 10;
        p.underwriting.budgetPremiumPpm = 0;
        p.underwriting.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.underwriting.budgetPremiumPpm,
                p.underwriting.budgetSlashPpm,
                p.underwriting.coverageLambda
            )
        );
        factory.deployGoal(p);
    }

    function test_deployGoal_revertsWhenSlashEnabledAndCoverageLambdaIsZero() public {
        GoalFactory.DeployParams memory p = _baseDeployParams();
        p.underwriting.coverageLambda = 0;
        p.underwriting.budgetPremiumPpm = 100_000;
        p.underwriting.budgetSlashPpm = 50_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                GoalFactory.INVALID_UNDERWRITING_SLASH_CONFIG.selector,
                p.underwriting.budgetPremiumPpm,
                p.underwriting.budgetSlashPpm,
                p.underwriting.coverageLambda
            )
        );
        factory.deployGoal(p);
    }

    function _baseDeployParams() internal pure returns (GoalFactory.DeployParams memory p) {
        p.revnet = GoalFactory.RevnetParams({
            owner: address(0xAAAA),
            name: "Goal",
            ticker: "GOAL",
            uri: "ipfs://goal",
            initialIssuance: 1,
            cashOutTaxRate: 0,
            reservedPercent: 0,
            durationSeconds: 7 days
        });
        p.timing = GoalFactory.GoalTimingParams({ minRaise: 0, minRaiseDurationSeconds: 0 });
        p.success = GoalFactory.SuccessParams({
            successResolver: address(0xBBBB),
            successAssertionLiveness: 1 days,
            successAssertionBond: 0,
            successOracleSpecHash: keccak256("spec"),
            successAssertionPolicyHash: keccak256("policy")
        });
        p.flowMetadata = GoalFactory.FlowMetadataParams({
            title: "title",
            description: "description",
            image: "ipfs://image",
            tagline: "tagline",
            url: "https://example.com"
        });
    }
}

contract DummyContract { }

contract MockToken is ERC20 {
    constructor() ERC20("Cobuild", "CBD") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
