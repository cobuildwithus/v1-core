// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowTestBase} from "test/flows/helpers/FlowTestBase.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {ICustomFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract FlowAllocationsBase is FlowTestBase {
    function _emptyChildSyncs() internal pure returns (LegacyChildSyncRequestCompact[] memory childSyncs) {
        childSyncs = new LegacyChildSyncRequestCompact[](0);
    }

    function _units(uint256 weight, uint32 scaled) internal pure returns (uint128) {
        uint256 w = Math.mulDiv(weight, scaled, 1e6);
        uint256 u = w / 1e15;
        return uint128(u);
    }

    function _deployFlowWithStrategies(IAllocationStrategy[] memory strategies)
        internal
        returns (CustomFlow deployed)
    {
        CustomFlow impl = new CustomFlow();
        address proxy = address(new ERC1967Proxy(address(impl), ""));

        vm.prank(owner);
        ICustomFlow(proxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            flowParams,
            flowMetadata,
            strategies
        );

        deployed = CustomFlow(proxy);

        vm.prank(owner);
        superToken.transfer(address(deployed), 500_000e18);
    }
}
