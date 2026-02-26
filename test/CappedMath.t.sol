// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import {CappedMath} from "src/tcr/utils/CappedMath.sol";

contract CappedMathTest is Test {
    function test_addCap() public pure {
        uint256 max = type(uint256).max;

        assertEq(CappedMath.addCap(1, 2), 3);
        assertEq(CappedMath.addCap(max, 1), max);
    }

    function test_subCap() public pure {
        assertEq(CappedMath.subCap(10, 3), 7);
        assertEq(CappedMath.subCap(3, 10), 0);
    }

}
