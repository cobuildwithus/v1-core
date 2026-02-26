// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {FlowInitializationAndAccessBase} from "test/flows/FlowInitializationAndAccess.t.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";
import {IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {FlowInitialization} from "src/library/FlowInitialization.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Vm} from "forge-std/Vm.sol";

contract FlowInitializationAndAccessInitTest is FlowInitializationAndAccessBase {
    bytes32 internal constant METADATA_SET_SIG = keccak256("MetadataSet((string,string,string,string,string))");
    bytes32 internal constant FLOW_INITIALIZED_SIG =
        keccak256("FlowInitialized(address,address,address,address,address,address,address,address,address,address,uint32,address)");
    bytes32 internal constant ALLOCATION_STRATEGY_REGISTERED_SIG =
        keccak256("AllocationStrategyRegistered(address,address,string)");

    function test_initialize_success_setsState() public view {
        assertEq(flow.recipientAdmin(), manager);
        assertEq(flow.flowOperator(), manager);
        assertEq(flow.sweeper(), manager);
        assertEq(flow.parent(), address(0));
        assertEq(flow.managerRewardPool(), managerRewardPool);
        assertEq(flow.flowImplementation(), address(flowImplementation));
        assertEq(flow.strategies().length, 1);
        assertEq(flow.ppmScale(), 1_000_000);
        assertEq(FlowInitialization.ppmScale, 1_000_000);
        assertEq(flow.ppmScale(), FlowInitialization.ppmScale);
        assertEq(flow.managerRewardPoolFlowRatePpm(), flowParams.managerRewardPoolFlowRatePpm);
        assertEq(flow.connectPoolAdmin(), connectPoolAdmin);
        assertEq(address(flow.superToken()), address(superToken));
        assertTrue(address(flow.distributionPool()) != address(0));
        assertEq(flow.distributionPool().getUnits(address(flow)), 0);
    }

    function test_initialize_emitsFlowInitialized_withRoleAndStrategySurface() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();

        vm.recordLogs();
        CustomFlow deployed = _deployFlowWith(
            owner,
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory initializedLog = _findFlowLog(logs, address(deployed), FLOW_INITIALIZED_SIG);
        assertEq(initializedLog.topics.length, 4);
        assertEq(initializedLog.topics[1], bytes32(uint256(uint160(manager))));
        assertEq(initializedLog.topics[2], bytes32(uint256(uint160(address(superToken)))));
        assertEq(initializedLog.topics[3], bytes32(uint256(uint160(address(flowImplementation)))));

        (
            address flowOperator,
            address sweeper,
            address emittedConnectPoolAdmin,
            address emittedManagerRewardPool,
            address allocationPipeline,
            address parent,
            address distributionPool,
            uint32 managerRewardPoolFlowRatePpm,
            address strategyAddress
        ) = abi.decode(initializedLog.data, (address, address, address, address, address, address, address, uint32, address));

        assertEq(flowOperator, manager);
        assertEq(sweeper, manager);
        assertEq(emittedConnectPoolAdmin, connectPoolAdmin);
        assertEq(emittedManagerRewardPool, managerRewardPool);
        assertEq(allocationPipeline, address(0));
        assertEq(parent, address(0));
        assertEq(distributionPool, address(deployed.distributionPool()));
        assertEq(managerRewardPoolFlowRatePpm, flowParams.managerRewardPoolFlowRatePpm);
        assertEq(strategyAddress, address(strategy));

        assertEq(_countFlowLogs(logs, address(deployed), ALLOCATION_STRATEGY_REGISTERED_SIG), 0);
    }

    function test_initialize_emitsMetadataSet() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();

        vm.recordLogs();
        CustomFlow deployed = _deployFlowWith(
            owner,
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasMetadataSetLog(logs, address(deployed), flowMetadata));
    }

    function test_initialize_revertsOnZeroAddressesAndInvalidMetadata() public {
        IAllocationStrategy[] memory strategies = _oneStrategy();

        _expectInitRevert(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(superToken),
            address(0),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        _expectInitRevert(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(0),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        FlowTypes.RecipientMetadata memory bad = flowMetadata;
        bad.title = "";
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.INVALID_METADATA.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            bad,
            strategies
        );

        _expectInitRevert(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(superToken),
            address(flowImplementation),
            address(0),
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );

        bad = flowMetadata;
        bad.description = "";
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.INVALID_METADATA.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            bad,
            strategies
        );

        bad = flowMetadata;
        bad.image = "";
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.INVALID_METADATA.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            bad,
            strategies
        );
    }

    function test_initialize_revertsOnInvalidPercentagesAndStrategies() public {
        IFlow.FlowParams memory badParams = flowParams;
        badParams.managerRewardPoolFlowRatePpm = 1_000_001;
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.INVALID_RATE_PPM.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            badParams,
            flowMetadata,
            _oneStrategy()
        );

        badParams = flowParams;
        badParams.managerRewardPoolFlowRatePpm = 1;
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            address(0),
            address(0),
            connectPoolAdmin,
            badParams,
            flowMetadata,
            _oneStrategy()
        );

        IAllocationStrategy[] memory emptyStrategies = new IAllocationStrategy[](0);
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.FLOW_REQUIRES_SINGLE_STRATEGY.selector, 0),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            emptyStrategies
        );

        MockAllocationStrategy strategy2 = new MockAllocationStrategy();
        IAllocationStrategy[] memory dupStrategies = new IAllocationStrategy[](2);
        dupStrategies[0] = IAllocationStrategy(address(strategy2));
        dupStrategies[1] = IAllocationStrategy(address(strategy2));

        _expectInitRevert(
            abi.encodeWithSelector(IFlow.FLOW_REQUIRES_SINGLE_STRATEGY.selector, 2),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            dupStrategies
        );

        IAllocationStrategy[] memory zeroStrategies = new IAllocationStrategy[](1);
        zeroStrategies[0] = IAllocationStrategy(address(0));
        _expectInitRevert(
            abi.encodeWithSelector(IFlow.ADDRESS_ZERO.selector),
            address(superToken),
            address(flowImplementation),
            manager,
            managerRewardPool,
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            zeroStrategies
        );
    }

    function test_initialize_onlyOnceAndImplementationLocked() public {
        vm.prank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        flow.initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            _oneStrategy()
        );

        CustomFlow impl = new CustomFlow();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            address(superToken),
            address(flowImplementation),
            manager,
            manager,
            manager,
            managerRewardPool,
            address(0),
            address(0),
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            _oneStrategy()
        );
    }

    function test_initialize_allowsZeroManagerRewardPool() public {
        IFlow.FlowParams memory params = flowParams;
        params.managerRewardPoolFlowRatePpm = 0;
        IAllocationStrategy[] memory strategies = _oneStrategy();
        CustomFlow deployed = _deployFlowWith(
            owner,
            address(superToken),
            address(flowImplementation),
            manager,
            address(0),
            address(0),
            connectPoolAdmin,
            params,
            flowMetadata,
            strategies
        );

        assertEq(deployed.managerRewardPool(), address(0));
        assertEq(deployed.getManagerRewardPoolFlowRate(), 0);

        vm.prank(manager);
        _assertCallFails(
            address(deployed),
            abi.encodeWithSignature("setManagerRewardFlowRatePercent(uint32)", uint32(1))
        );
    }

    function _hasMetadataSetLog(
        Vm.Log[] memory logs,
        address flowAddress,
        FlowTypes.RecipientMetadata memory expectedMetadata
    ) internal pure returns (bool) {
        bytes32 expectedHash = keccak256(abi.encode(expectedMetadata));

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != flowAddress) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != METADATA_SET_SIG) continue;
            if (keccak256(logs[i].data) == expectedHash) return true;
        }
        return false;
    }

    function _findFlowLog(
        Vm.Log[] memory logs,
        address flowAddress,
        bytes32 eventSignature
    ) internal pure returns (Vm.Log memory foundLog) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != flowAddress) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSignature) continue;
            return logs[i];
        }
        revert("LOG_NOT_FOUND");
    }

    function _countFlowLogs(
        Vm.Log[] memory logs,
        address flowAddress,
        bytes32 eventSignature
    ) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != flowAddress) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != eventSignature) continue;
            unchecked {
                ++count;
            }
        }
    }
}
