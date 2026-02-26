// SPDX-License-Identifier: GPL-3.0-or-later
// CappedMath.sol is a modified version of Kleros' CappedMath.sol:
// https://github.com/kleros/tcr
//
// CappedMath.sol source code Copyright Kleros licensed under the MIT license.

pragma solidity ^0.8.34;

/**
 * @title CappedMath
 * @dev Math operations with caps for under and overflow.
 */
library CappedMath {
    uint256 private constant UINT_MAX = 2 ** 256 - 1;

    /**
     * @dev Adds two unsigned integers, returns 2^256 - 1 on overflow.
     */
    function addCap(uint256 _a, uint256 _b) internal pure returns (uint256) {
        unchecked {
            uint256 c = _a + _b;
            return c >= _a ? c : UINT_MAX;
        }
    }

    /**
     * @dev Subtracts two integers, returns 0 on underflow.
     */
    function subCap(uint256 _a, uint256 _b) internal pure returns (uint256) {
        if (_b > _a) return 0;
        else return _a - _b;
    }
}
