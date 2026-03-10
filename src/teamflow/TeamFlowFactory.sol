// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { TeamFlow } from "src/teamflow/TeamFlow.sol";
import { IAllocationMechanismFactory } from "src/tcr/interfaces/IAllocationMechanismFactory.sol";
import { IBudgetTreasury } from "src/interfaces/IBudgetTreasury.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { IManagedFlow } from "src/interfaces/IManagedFlow.sol";
import { FlowTypes } from "src/storage/FlowStorage.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract TeamFlowFactory is IAllocationMechanismFactory {
    using Clones for address;

    struct AllocationMechanismConfig {
        address manager;
        uint256 perSeatRate;
        uint256 maxTotalRate;
        FlowTypes.RecipientMetadata flowMetadata;
    }

    error ADDRESS_ZERO();
    error INVALID_BUDGET_CONTEXT();
    error IMPLEMENTATION_HAS_NO_CODE(address implementation);

    event TeamFlowDeployed(
        bytes32 indexed mechanismId,
        address indexed budgetTreasury,
        address indexed teamFlow,
        address manager,
        uint256 perSeatRate,
        uint256 maxTotalRate
    );

    address public immutable teamFlowImplementation;

    constructor(address teamFlowImplementation_) {
        _assertImplementationAddress(teamFlowImplementation_);

        teamFlowImplementation = teamFlowImplementation_;
    }

    function deployForBudget(
        bytes32 mechanismId,
        address budgetTreasury,
        bytes calldata mechanismConfig
    ) external override returns (IAllocationMechanismFactory.DeployedMechanism memory out) {
        AllocationMechanismConfig memory cfg = abi.decode(mechanismConfig, (AllocationMechanismConfig));
        if (cfg.manager == address(0)) revert ADDRESS_ZERO();

        _requireDeployedContract(budgetTreasury);
        address budgetFlow = _requireDeployedContract(IBudgetTreasury(budgetTreasury).flow());
        address superToken = _requireDeployedContract(address(IManagedFlow(budgetFlow).superToken()));

        TeamFlow teamFlow = TeamFlow(teamFlowImplementation.clone());

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(teamFlow));

        teamFlow.initialize(
            TeamFlow.InitConfig({
                mechanismId: mechanismId,
                manager: cfg.manager,
                superToken: superToken,
                flowImplementation: teamFlowImplementation,
                perSeatRate: cfg.perSeatRate,
                maxTotalRate: cfg.maxTotalRate,
                metadata: cfg.flowMetadata
            }),
            strategies
        );

        out = IAllocationMechanismFactory.DeployedMechanism({
            mechanism: address(teamFlow),
            payoutRecipient: address(teamFlow),
            arbitrator: address(0),
            auxiliary: address(0)
        });

        emit TeamFlowDeployed(
            mechanismId,
            budgetTreasury,
            address(teamFlow),
            cfg.manager,
            cfg.perSeatRate,
            cfg.maxTotalRate
        );
    }

    function _assertImplementationAddress(address implementation) internal view {
        if (implementation == address(0)) revert ADDRESS_ZERO();
        if (implementation.code.length == 0) revert IMPLEMENTATION_HAS_NO_CODE(implementation);
    }

    function _requireDeployedContract(address candidate) internal view returns (address deployed) {
        if (candidate == address(0) || candidate.code.length == 0) revert INVALID_BUDGET_CONTEXT();
        return candidate;
    }
}
