// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library VotingTokenCompatibility {
    function readErc20AndDecimals(
        address token,
        address account
    ) internal view returns (bool isCompatible, uint8 decimals) {
        if (!_returnsUint256(token, abi.encodeWithSelector(IERC20.totalSupply.selector))) {
            return (false, 0);
        }

        if (!_returnsUint256(token, abi.encodeWithSelector(IERC20.balanceOf.selector, account))) {
            return (false, 0);
        }

        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || data.length < 32) return (false, 0);

        return (true, abi.decode(data, (uint8)));
    }

    function _returnsUint256(address target, bytes memory callData) private view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(callData);
        if (!ok || data.length < 32) return false;

        abi.decode(data, (uint256));
        return true;
    }
}
