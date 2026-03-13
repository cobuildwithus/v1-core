// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

import { IStakeVault } from "./IStakeVault.sol";
import { IJurorSlasher } from "./IJurorSlasher.sol";

interface IJurorSlasherRouter is IJurorSlasher {
    function initialize(IStakeVault stakeVault_, address authority_) external;
    function stakeVault() external view returns (IStakeVault);
    function authority() external view returns (address);
    function isAuthorizedSlasher(address slasher) external view returns (bool);
    function setAuthorizedSlasher(address slasher, bool authorized) external;
}
