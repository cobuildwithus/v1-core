// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface IUMATreasurySuccessResolver {
    function finalize(bytes32 assertionId) external returns (bool applied);
}
