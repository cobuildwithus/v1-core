// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IGoalTreasury} from "src/interfaces/IGoalTreasury.sol";
import {FakeUMATreasurySuccessResolver} from "src/mocks/FakeUMATreasurySuccessResolver.sol";

contract RunGoalSuccessSmoke is Script {
    error ADDRESS_ZERO();
    error CALLER_NOT_RESOLVER_OWNER(address caller, address owner);
    error SUCCESS_RESOLVER_MISMATCH(address configuredResolver, address providedResolver);
    error GOAL_NOT_ACTIVE(uint8 currentState, uint256 totalRaised, uint256 minRaise);
    error GOAL_NOT_SUCCEEDED(uint8 currentState);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(pk);

        address treasuryAddr = vm.envAddress("GOAL_TREASURY");
        address resolverAddr = vm.envAddress("FAKE_SUCCESS_RESOLVER");
        if (treasuryAddr == address(0) || resolverAddr == address(0)) revert ADDRESS_ZERO();

        IGoalTreasury treasury = IGoalTreasury(treasuryAddr);
        FakeUMATreasurySuccessResolver resolver = FakeUMATreasurySuccessResolver(resolverAddr);

        address resolverOwner = resolver.owner();
        if (resolverOwner != caller) revert CALLER_NOT_RESOLVER_OWNER(caller, resolverOwner);

        address configuredResolver = treasury.successResolver();
        if (configuredResolver != resolverAddr) {
            revert SUCCESS_RESOLVER_MISMATCH(configuredResolver, resolverAddr);
        }

        console2.log("smoke caller:", caller);
        console2.log("goal treasury:", treasuryAddr);
        console2.log("resolver:", resolverAddr);

        vm.startBroadcast(pk);
        treasury.sync();
        vm.stopBroadcast();

        IGoalTreasury.GoalState currentState = treasury.state();
        uint256 totalRaised = treasury.totalRaised();
        uint256 minRaise = treasury.minRaise();

        console2.log("state after sync:", uint256(currentState));
        console2.log("totalRaised:", totalRaised);
        console2.log("minRaise:", minRaise);
        console2.log("deadline:", treasury.deadline());

        if (currentState != IGoalTreasury.GoalState.Active) {
            revert GOAL_NOT_ACTIVE(uint8(currentState), totalRaised, minRaise);
        }

        vm.startBroadcast(pk);
        bytes32 assertionId = resolver.prepareTruthfulAssertionForTreasury(treasuryAddr);
        console2.logBytes32(assertionId);

        resolver.resolveTreasurySuccess(treasuryAddr);
        vm.stopBroadcast();

        IGoalTreasury.GoalState finalState = treasury.state();
        if (finalState != IGoalTreasury.GoalState.Succeeded) {
            revert GOAL_NOT_SUCCEEDED(uint8(finalState));
        }

        console2.log("state after success resolve:", uint256(finalState));
        console2.log("successAt:", treasury.successAt());
        console2.log("resolvedAt:", treasury.resolvedAt());
    }
}
