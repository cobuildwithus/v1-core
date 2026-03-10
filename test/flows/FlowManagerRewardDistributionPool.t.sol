// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { FlowTestBase } from "test/flows/helpers/FlowTestBase.t.sol";
import { CustomFlow } from "src/flows/CustomFlow.sol";
import { IFlow } from "src/interfaces/IFlow.sol";
import { IAllocationStrategy } from "src/interfaces/IAllocationStrategy.sol";
import { ISuperfluidPool, ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

contract FlowManagerRewardDistributionPoolTest is FlowTestBase {
    using SuperTokenV1Library for ISuperToken;

    function test_initialize_configuresManagerRewardDistributionPool_whenManagerRewardPoolIsSet() public view {
        ISuperfluidPool managerDistributionPool = flow.managerRewardDistributionPool();

        assertTrue(address(managerDistributionPool) != address(0));
        assertTrue(address(managerDistributionPool) != address(flow.distributionPool()));
        assertEq(managerDistributionPool.admin(), address(flow));
        assertEq(managerDistributionPool.getUnits(managerRewardPool), 1);

        // Invariant: only pool admin (the flow) can distribute.
        assertFalse(flow.distributionPool().distributionFromAnyAddress());
        assertFalse(managerDistributionPool.distributionFromAnyAddress());
    }

    function test_initialize_withoutManagerRewardPool_hasNoManagerRewardDistributionPool() public {
        flowParams.managerRewardPoolFlowRatePpm = 0;

        IAllocationStrategy strategies = IAllocationStrategy(address(strategy));

        CustomFlow deployed =
            _deployFlowWithConfig(owner, manager, address(0), address(0), address(0), strategies);

        assertEq(deployed.managerRewardPool(), address(0));
        assertEq(address(deployed.managerRewardDistributionPool()), address(0));
        assertEq(deployed.getManagerRewardPoolFlowRate(), 0);
    }

    function test_managerRewardFlowRate_readsFromManagerRewardDistributionPoolFlowRate() public {
        _makeIncomingFlow(other, 2_000);

        vm.prank(owner);
        flow.setTargetOutflowRate(1_000);

        ISuperfluidPool managerDistributionPool = flow.managerRewardDistributionPool();
        int96 poolFlowRate =
            ISuperToken(address(superToken)).getFlowDistributionFlowRate(address(flow), managerDistributionPool);

        assertEq(flow.getManagerRewardPoolFlowRate(), 100);
        assertEq(poolFlowRate, 100);
        // Regression check: manager share is no longer sent as a CFA stream to managerRewardPool.
        assertEq(ISuperToken(address(superToken)).getFlowRate(address(flow), managerRewardPool), 0);
    }
}
