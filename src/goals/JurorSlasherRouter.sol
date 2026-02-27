// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import { IStakeVault } from "src/interfaces/IStakeVault.sol";
import { IJurorSlasher } from "src/interfaces/IJurorSlasher.sol";

/// @notice Per-goal router that allows multiple arbitrators to slash jurors via a
/// single stake-vault `jurorSlasher` address.
contract JurorSlasherRouter is IJurorSlasher {
    error ADDRESS_ZERO();
    error ONLY_AUTHORITY();
    error ONLY_AUTHORIZED_SLASHER();

    event SlasherAuthorizationSet(address indexed slasher, bool authorized);

    IStakeVault public immutable stakeVault;
    address public immutable authority;
    mapping(address => bool) public isAuthorizedSlasher;

    constructor(IStakeVault stakeVault_, address authority_) {
        if (address(stakeVault_) == address(0)) revert ADDRESS_ZERO();
        if (authority_ == address(0)) revert ADDRESS_ZERO();
        stakeVault = stakeVault_;
        authority = authority_;
    }

    function setAuthorizedSlasher(address slasher, bool authorized) external {
        if (msg.sender != authority) revert ONLY_AUTHORITY();
        if (slasher == address(0)) revert ADDRESS_ZERO();
        isAuthorizedSlasher[slasher] = authorized;
        emit SlasherAuthorizationSet(slasher, authorized);
    }

    function slashJurorStake(address juror, uint256 weightAmount, address recipient) external override {
        if (!isAuthorizedSlasher[msg.sender]) revert ONLY_AUTHORIZED_SLASHER();
        stakeVault.slashJurorStake(juror, weightAmount, recipient);
    }
}
