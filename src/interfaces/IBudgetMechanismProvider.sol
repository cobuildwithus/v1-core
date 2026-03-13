// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.34;

interface IBudgetMechanismProvider {
    function initialMechanismFactories() external view returns (address[] memory);
    function roundFactory() external view returns (address);
    function allocationMechanismTcrImplementation() external view returns (address);
    function allocationMechanismArbitratorImplementation() external view returns (address);
}
