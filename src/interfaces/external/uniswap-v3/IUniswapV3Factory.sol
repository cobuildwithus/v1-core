// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}
