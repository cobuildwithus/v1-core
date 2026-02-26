// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Superfluid } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/Superfluid.sol";
import { TestGovernance } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestGovernance.sol";
import { ConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/agreements/ConstantFlowAgreementV1.sol";
import {
    IGeneralDistributionAgreementV1,
    GeneralDistributionAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/agreements/gdav1/GeneralDistributionAgreementV1.sol";
import {
    PoolAdminNFT,
    IPoolAdminNFT
} from "@superfluid-finance/ethereum-contracts/contracts/agreements/gdav1/PoolAdminNFT.sol";
import {
    SuperTokenFactory,
    ISuperTokenFactory,
    IPoolMemberNFT
} from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperTokenFactory.sol";
import { ISuperToken, SuperToken } from "@superfluid-finance/ethereum-contracts/contracts/superfluid/SuperToken.sol";
import { TestToken } from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import { SuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/agreements/gdav1/SuperfluidPool.sol";
import {
    SuperfluidUpgradeableBeacon
} from "@superfluid-finance/ethereum-contracts/contracts/upgradability/SuperfluidUpgradeableBeacon.sol";
import { UUPSProxy } from "@superfluid-finance/ethereum-contracts/contracts/upgradability/UUPSProxy.sol";
import { SimpleForwarder } from "@superfluid-finance/ethereum-contracts/contracts/utils/SimpleForwarder.sol";
import { ERC2771Forwarder } from "@superfluid-finance/ethereum-contracts/contracts/utils/ERC2771Forwarder.sol";
import { SimpleACL } from "@superfluid-finance/ethereum-contracts/contracts/utils/SimpleACL.sol";

contract FlowSuperfluidFrameworkDeployer {
    uint256 internal constant DEFAULT_LIQUIDATION_PERIOD = 4 hours;
    uint256 internal constant DEFAULT_PATRICIAN_PERIOD = 30 minutes;
    address internal constant DEFAULT_REWARD_ADDRESS = address(69);

    struct Framework {
        TestGovernance governance;
        Superfluid host;
        ConstantFlowAgreementV1 cfa;
        GeneralDistributionAgreementV1 gda;
        SuperTokenFactory superTokenFactory;
        ISuperToken superTokenLogic;
    }

    Framework internal _framework;

    function deployTestFramework() external {
        if (address(_framework.host) != address(0)) revert("already deployed");

        TestGovernance governance = new TestGovernance();
        governance.transferOwnership(address(this));

        SimpleForwarder simpleForwarder = new SimpleForwarder();
        ERC2771Forwarder erc2771Forwarder = new ERC2771Forwarder();
        SimpleACL simpleAcl = new SimpleACL();

        Superfluid host = new Superfluid(
            true,
            false,
            3_000_000,
            address(simpleForwarder),
            address(erc2771Forwarder),
            address(simpleAcl)
        );
        simpleForwarder.transferOwnership(address(host));
        erc2771Forwarder.transferOwnership(address(host));

        host.initialize(governance);
        governance.initialize(
            host,
            DEFAULT_REWARD_ADDRESS,
            DEFAULT_LIQUIDATION_PERIOD,
            DEFAULT_PATRICIAN_PERIOD,
            new address[](0)
        );

        ConstantFlowAgreementV1 cfaLogic = new ConstantFlowAgreementV1(host);
        governance.registerAgreementClass(host, address(cfaLogic));
        ConstantFlowAgreementV1 cfa = ConstantFlowAgreementV1(address(host.getAgreementClass(cfaLogic.agreementType())));

        SuperfluidPool bootstrapPoolLogic = new SuperfluidPool(GeneralDistributionAgreementV1(address(0)));
        SuperfluidUpgradeableBeacon poolBeacon = new SuperfluidUpgradeableBeacon(address(bootstrapPoolLogic));
        GeneralDistributionAgreementV1 gdaLogic = new GeneralDistributionAgreementV1(host, poolBeacon);
        governance.registerAgreementClass(host, address(gdaLogic));
        GeneralDistributionAgreementV1 gda = GeneralDistributionAgreementV1(address(host.getAgreementClass(gdaLogic.agreementType())));

        SuperfluidPool superfluidPoolLogic = new SuperfluidPool(gda);
        superfluidPoolLogic.castrate();
        gdaLogic.superfluidPoolBeacon().upgradeTo(address(superfluidPoolLogic));
        gdaLogic.superfluidPoolBeacon().transferOwnership(address(host));

        bytes32 aclPoolConnectExclusiveRoleAdmin = keccak256("ACL_POOL_CONNECT_EXCLUSIVE_ROLE_ADMIN");
        SimpleACL(address(host.getSimpleACL())).setRoleAdmin(
            gda.ACL_POOL_CONNECT_EXCLUSIVE_ROLE(),
            aclPoolConnectExclusiveRoleAdmin
        );
        SimpleACL(address(host.getSimpleACL())).grantRole(aclPoolConnectExclusiveRoleAdmin, address(gda));

        PoolAdminNFT poolAdminNFTProxy = PoolAdminNFT(address(new UUPSProxy()));
        PoolAdminNFT poolAdminNFTLogic = new PoolAdminNFT(host, IGeneralDistributionAgreementV1(address(gda)));
        poolAdminNFTLogic.castrate();
        UUPSProxy(payable(address(poolAdminNFTProxy))).initializeProxy(address(poolAdminNFTLogic));
        poolAdminNFTProxy.initialize("Pool Admin NFT", "PA");

        ISuperToken superTokenLogic = ISuperToken(address(new SuperToken(host, IPoolAdminNFT(address(poolAdminNFTProxy)))));
        SuperTokenFactory superTokenFactoryLogic = new SuperTokenFactory(
            host,
            superTokenLogic,
            IPoolAdminNFT(poolAdminNFTProxy.getCodeAddress()),
            IPoolMemberNFT(address(0))
        );

        governance.updateContracts(host, address(0), new address[](0), address(superTokenFactoryLogic), address(0));
        SuperTokenFactory superTokenFactory = SuperTokenFactory(address(host.getSuperTokenFactory()));

        _framework = Framework({
            governance: governance,
            host: host,
            cfa: cfa,
            gda: gda,
            superTokenFactory: superTokenFactory,
            superTokenLogic: superTokenLogic
        });
    }

    function getFramework() external view returns (Framework memory) {
        return _framework;
    }

    function deployWrapperSuperToken(
        string calldata _underlyingName,
        string calldata _underlyingSymbol,
        uint8 _decimals,
        uint256 _mintLimit,
        address _admin
    ) external returns (TestToken underlyingToken, SuperToken superToken) {
        if (address(_framework.superTokenFactory) == address(0)) revert("framework not deployed");

        underlyingToken = new TestToken(_underlyingName, _underlyingSymbol, _decimals, _mintLimit);
        superToken = SuperToken(
            address(
                _framework.superTokenFactory.createERC20Wrapper(
                    IERC20Metadata(address(underlyingToken)),
                    underlyingToken.decimals(),
                    ISuperTokenFactory.Upgradability.SEMI_UPGRADABLE,
                    string.concat("Super ", _underlyingSymbol),
                    string.concat(_underlyingSymbol, "x"),
                    _admin
                )
            )
        );
    }
}
