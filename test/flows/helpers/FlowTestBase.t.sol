// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TestableCustomFlow} from "test/harness/TestableCustomFlow.sol";
import {MockAllocationStrategy} from "test/mocks/MockAllocationStrategy.sol";
import {PrevStateCacheHelper} from "test/flows/helpers/PrevStateCacheHelper.sol";

import {ICustomFlow, IFlow} from "src/interfaces/IFlow.sol";
import {IAllocationStrategy} from "src/interfaces/IAllocationStrategy.sol";
import {CustomFlow} from "src/flows/CustomFlow.sol";
import {FlowTypes} from "src/storage/FlowStorage.sol";
import {FlowSuperfluidFrameworkDeployer} from "test/utils/FlowSuperfluidFrameworkDeployer.sol";

import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperTokenV1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import {ERC1820RegistryCompiled} from
    "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import {TestToken} from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import {SuperToken} from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";

abstract contract FlowTestBase is Test, PrevStateCacheHelper {
    using SuperTokenV1Library for ISuperToken;

    address internal owner = address(0xA11CE);
    address internal manager = owner;
    address internal managerRewardPool = address(0xCAFE);
    address internal connectPoolAdmin = address(0xD00D);
    address internal allocator = address(0xA110CA7E);
    address internal other = address(0xBAD);

    FlowSuperfluidFrameworkDeployer internal sfDeployer;
    FlowSuperfluidFrameworkDeployer.Framework internal sf;
    TestToken internal underlyingToken;
    SuperToken internal superToken;

    CustomFlow internal flow;
    CustomFlow internal flowImplementation;
    MockAllocationStrategy internal strategy;

    FlowTypes.RecipientMetadata internal flowMetadata;
    FlowTypes.RecipientMetadata internal recipientMetadata;
    IFlow.FlowParams internal flowParams;

    uint256 internal constant DEFAULT_WEIGHT = 1e24;

    function setUp() public virtual {
        flowMetadata = FlowTypes.RecipientMetadata({
            title: "Flow",
            description: "Flow for tests",
            image: "ipfs://flow",
            tagline: "tagline",
            url: "https://flow.test"
        });

        recipientMetadata = FlowTypes.RecipientMetadata({
            title: "Recipient",
            description: "Recipient",
            image: "ipfs://recipient",
            tagline: "tagline",
            url: "https://recipient.test"
        });

        flowParams = IFlow.FlowParams({managerRewardPoolFlowRatePpm: 100_000});

        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        sfDeployer = new FlowSuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();
        sf = sfDeployer.getFramework();

        (TestToken u, SuperToken s) =
            sfDeployer.deployWrapperSuperToken("MockUSD", "mUSD", 18, type(uint256).max, owner);
        underlyingToken = u;
        superToken = s;

        strategy = new MockAllocationStrategy();
        strategy.setUseAuxAsKey(true);
        uint256 allocatorKey = strategy.allocationKey(allocator, bytes(""));
        strategy.setWeight(allocatorKey, DEFAULT_WEIGHT);
        strategy.setCanAllocate(allocatorKey, allocator, true);
        strategy.setCanAccountAllocate(allocator, true);

        flowImplementation = new TestableCustomFlow();
        address flowProxy = address(new ERC1967Proxy(address(flowImplementation), ""));

        IAllocationStrategy[] memory strategies = new IAllocationStrategy[](1);
        strategies[0] = IAllocationStrategy(address(strategy));

        vm.prank(owner);
        ICustomFlow(flowProxy).initialize(
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
            strategies
        );

        flow = CustomFlow(flowProxy);

        _mintAndUpgrade(owner, 5_000_000e18);
        vm.prank(owner);
        superToken.transfer(address(flow), 2_000_000e18);

        // Give allocator and helper addresses token balances for stream operations.
        _mintAndUpgrade(allocator, 1_000_000e18);
        _mintAndUpgrade(other, 1_000_000e18);
    }

    function _mintAndUpgrade(address to, uint256 amount) internal {
        vm.startPrank(to);
        underlyingToken.mint(to, amount);
        underlyingToken.approve(address(superToken), amount);
        ISuperToken(address(superToken)).upgrade(amount);
        vm.stopPrank();
    }

    function _addRecipient(bytes32 id, address recipient) internal {
        vm.prank(manager);
        flow.addRecipient(id, recipient, recipientMetadata);
    }

    function _deployFlowWithConfig(
        address initCaller,
        address manager_,
        address managerRewardPool_,
        address allocationPipeline_,
        address parent_,
        IAllocationStrategy[] memory strategies
    ) internal returns (CustomFlow deployed) {
        address flowProxy = address(new ERC1967Proxy(address(flowImplementation), ""));
        vm.prank(initCaller);
        ICustomFlow(flowProxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager_,
            manager_,
            manager_,
            managerRewardPool_,
            allocationPipeline_,
            parent_,
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
        deployed = CustomFlow(flowProxy);
    }

    function _deployFlowWithConfigAndRoles(
        address initCaller,
        address manager_,
        address flowOperator_,
        address sweeper_,
        address managerRewardPool_,
        address allocationPipeline_,
        address parent_,
        IAllocationStrategy[] memory strategies
    ) internal returns (CustomFlow deployed) {
        address flowProxy = address(new ERC1967Proxy(address(flowImplementation), ""));
        vm.prank(initCaller);
        ICustomFlow(flowProxy).initialize(
            address(superToken),
            address(flowImplementation),
            manager_,
            flowOperator_,
            sweeper_,
            managerRewardPool_,
            allocationPipeline_,
            parent_,
            connectPoolAdmin,
            flowParams,
            flowMetadata,
            strategies
        );
        deployed = CustomFlow(flowProxy);
    }

    function _addNRecipients(uint256 n) internal returns (bytes32[] memory ids, address[] memory addrs) {
        ids = new bytes32[](n);
        addrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = bytes32(uint256(i + 1));
            addrs[i] = vm.addr(i + 100);
            _addRecipient(ids[i], addrs[i]);
        }
    }

    function _defaultAllocationDataForKey(uint256) internal pure returns (bytes[][] memory arr) {
        arr = new bytes[][](1);
        arr[0] = new bytes[](1);
        arr[0][0] = bytes("");
    }

    function _allocatorKey() internal view returns (uint256) {
        return strategy.allocationKey(allocator, bytes(""));
    }

    function _allocateSingleKey(uint256 key, bytes32[] memory recipientIds, uint32[] memory scaled) internal {
        address keyAllocator = address(uint160(key));
        strategy.setWeight(key, DEFAULT_WEIGHT);
        strategy.setCanAllocate(key, keyAllocator, true);
        strategy.setCanAccountAllocate(keyAllocator, true);
        bytes[][] memory allocationData = _defaultAllocationDataForKey(key);
        _allocateWithPrevStateForStrategy(keyAllocator, allocationData, address(strategy), address(flow), recipientIds, scaled);
    }

    function _makeIncomingFlow(address from, int96 flowRate) internal {
        vm.startPrank(from);
        ISuperToken(address(superToken)).createFlow(address(flow), flowRate);
        vm.stopPrank();
    }

    function _harnessFlow() internal view returns (TestableCustomFlow) {
        return TestableCustomFlow(address(flow));
    }

    function _assertCallFails(address target, bytes memory callData) internal {
        (bool success,) = target.call(callData);
        assertFalse(success);
    }

    function _assertRemovedConfigSettersNotExposed(address target) internal {
        _assertCallFails(target, abi.encodeWithSignature("setFlowImpl(address)", address(0xBEEF)));
        _assertCallFails(target, abi.encodeWithSignature("setConnectPoolAdmin(address)", address(0xBEEF)));
        _assertCallFails(target, abi.encodeWithSignature("setManagerRewardFlowRatePercent(uint32)", uint32(1)));
        _assertCallFails(target, abi.encodeWithSignature("setDefaultBufferMultiplier(uint256)", uint256(2)));
        _assertCallFails(target, abi.encodeWithSignature("setManagerRewardPool(address)", address(0xBEEF)));
        _assertCallFails(target, abi.encodeWithSignature("setAllocationPipeline(address)", address(0xBEEF)));
    }
}
